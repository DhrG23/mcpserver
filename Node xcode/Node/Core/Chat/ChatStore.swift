//
//  ChatStore.swift
//  Node
//
//  Created by Veerjyot Singh on 04/10/26.
//


//
//  ChatStore.swift
//  Node
//
//  Core/Chat/ChatStore.swift
//  Owns the conversation shown in the Chat tab: connection state, reconnect policy,
//  sending, streaming answers, retry and stop.
//
//  Reconnect policy: exponential back-off 1, 2, 4, 8, 16, 30 s (+ jitter). It stops for
//  problems only the user can fix (not signed in, rejected session, untrusted certificate).
//

import Foundation
import Combine

@MainActor
final class ChatStore: ObservableObject {

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(ChatSocket.Failure)
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var state: ConnectionState = .idle
    /// The client_id of a user message the assistant has not started answering yet.
    @Published private(set) var pendingReplyTo: String?
    /// The assistant message that is currently streaming.
    @Published private(set) var activeAssistantID: String?
    @Published private(set) var maxMessageChars = 4000
    @Published var draft = ""

    var isAssistantBusy: Bool { pendingReplyTo != nil || activeAssistantID != nil }

    var canSend: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return state == .connected && !isAssistantBusy && !trimmed.isEmpty && trimmed.count <= maxMessageChars
    }

    private let socket = ChatSocket()
    private let isPreview: Bool
    private var conversationID: String?
    private var attempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var readyTimeout: Task<Void, Never>?
    private var ackTimeouts: [String: Task<Void, Never>] = [:]
    private var lastSeq: [String: Int] = [:]

    // MARK: Init

    init() {
        isPreview = false
        wireCallbacks()
    }

    /// For SwiftUI previews: fixed messages, never touches the network.
    init(previewMessages: [ChatMessage]) {
        isPreview = true
        messages = previewMessages
        state = .connected
        wireCallbacks()
    }

    private func wireCallbacks() {
        socket.onFrame = { [weak self] frame in self?.handle(frame) }
        socket.onClose = { [weak self] failure in self?.handleClose(failure) }
    }

    // MARK: Lifecycle

    /// Connects if not already connected / connecting. Safe to call repeatedly.
    func start() {
        guard !isPreview else { return }
        switch state {
        case .connecting, .connected, .reconnecting: return
        case .idle, .failed: break
        }
        attempt = 0
        state = .connecting
        openSocket()
    }

    /// Closes the connection (app went to the background, screen left, …).
    func stop() {
        guard !isPreview else { return }
        reconnectTask?.cancel()
        readyTimeout?.cancel()
        socket.disconnect()
        settleInFlight()
        state = .idle
    }

    /// "Retry" button.
    func reconnectNow() {
        stop()
        start()
    }

    /// Forgets everything in memory (sign-out).
    func reset() {
        stop()
        messages = []
        draft = ""
        conversationID = nil
        lastSeq = [:]
    }

    // MARK: Sending

    /// Sends `override` (e.g. a suggestion chip) or the current draft.
    func send(_ override: String? = nil) {
        let body = (override ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == .connected, !isAssistantBusy, !body.isEmpty, body.count <= maxMessageChars else { return }

        let message = ChatMessage(
            id: UUID().uuidString.lowercased(),
            role: .user,
            text: body,
            createdAt: Date(),
            status: .sending
        )
        messages.append(message)
        if override == nil { draft = "" }
        transmit(message)
    }

    /// Re-sends a message that failed. Same client_id, so the server can de-duplicate.
    func retry(_ id: String) {
        guard state == .connected, !isAssistantBusy,
              let i = index(of: id), messages[i].role == .user,
              case .failed = messages[i].status else { return }
        messages[i].status = .sending
        transmit(messages[i])
    }

    /// Stop button.
    func cancelGeneration() {
        let assistantID = activeAssistantID
        let frame = ChatCancelFrame(
            messageId: assistantID,
            replyTo: assistantID == nil ? pendingReplyTo : nil
        )
        guard assistantID != nil || pendingReplyTo != nil else { return }
        Task { [weak self] in try? await self?.socket.send(frame) }

        // If the server never confirms, stop waiting after 5 s.
        let waitingFor = assistantID ?? pendingReplyTo
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, (self.activeAssistantID ?? self.pendingReplyTo) == waitingFor else { return }
            if let id = self.activeAssistantID { self.update(id) { $0.status = .cancelled } }
            self.activeAssistantID = nil
            self.pendingReplyTo = nil
        }
    }

    private func transmit(_ message: ChatMessage) {
        let id = message.id
        pendingReplyTo = id

        ackTimeouts[id]?.cancel()
        ackTimeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.failMessage(id, "The server didn't answer. Tap to retry.")
        }

        let frame = ChatSendFrame(
            clientId: id,
            conversationId: conversationID,
            text: message.text,
            sentAt: message.createdAt
        )
        Task { [weak self] in
            do { try await self?.socket.send(frame) }
            catch { self?.failMessage(id, "Couldn't send. Tap to retry.") }
        }
    }

    // MARK: Connection

    private func openSocket() {
        do {
            try socket.connect()
        } catch let failure as ChatSocket.Failure {
            handleClose(failure)
            return
        } catch {
            handleClose(.network)
            return
        }
        // The connection must say "ready" within 15 s or we try again.
        readyTimeout?.cancel()
        readyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.state != .connected else { return }
            self.socket.disconnect()
            self.handleClose(.network)
        }
    }

    private func handleClose(_ failure: ChatSocket.Failure) {
        readyTimeout?.cancel()
        settleInFlight()
        if failure.isPermanent {
            state = .failed(failure)
        } else {
            scheduleReconnect(minDelay: failure == .rateLimited ? 30 : 0)
        }
    }

    private func scheduleReconnect(minDelay: Double) {
        attempt += 1
        state = .reconnecting(attempt: attempt)
        let backoff = min(30.0, pow(2.0, Double(min(attempt - 1, 5))))
        let delay = max(minDelay, backoff) + Double.random(in: 0...0.5)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.openSocket()
        }
    }

    /// The connection ended: nothing that was in flight can still complete on it.
    private func settleInFlight() {
        for task in ackTimeouts.values { task.cancel() }
        ackTimeouts = [:]
        for i in messages.indices {
            switch messages[i].status {
            case .sending:   messages[i].status = .failed("Not delivered. Tap to retry.")
            case .streaming: messages[i].status = .interrupted
            default:         break
            }
        }
        pendingReplyTo = nil
        activeAssistantID = nil
    }

    // MARK: Incoming frames

    private func handle(_ frame: ServerFrame) {
        switch frame {

        case .ready(let f):
            readyTimeout?.cancel()
            attempt = 0
            state = .connected
            if let id = f.conversationId { conversationID = id }
            if let limit = f.maxMessageChars, limit > 0 { maxMessageChars = limit }
            let request = HistoryGetFrame(conversationId: conversationID, before: nil, limit: 50)
            Task { [weak self] in try? await self?.socket.send(request) }

        case .history(let f):
            if let id = f.conversationId { conversationID = id }
            merge(history: f.messages)

        case .ack(let f):
            acknowledge(f.clientId)

        case .assistantStart(let f):
            if let replyTo = f.replyTo { acknowledge(replyTo) }
            pendingReplyTo = nil
            activeAssistantID = f.messageId
            lastSeq[f.messageId] = 0
            if index(of: f.messageId) == nil {
                messages.append(ChatMessage(
                    id: f.messageId, role: .assistant, text: "",
                    createdAt: f.createdAt ?? Date(), status: .streaming
                ))
            }

        case .assistantDelta(let f):
            if let i = index(of: f.messageId) {
                switch messages[i].status {
                case .complete, .cancelled: return          // late duplicate
                default: break
                }
            }
            if let seq = f.seq {
                guard seq > (lastSeq[f.messageId] ?? 0) else { return }
                lastSeq[f.messageId] = seq
            }
            ensureAssistant(f.messageId)
            update(f.messageId) { $0.text += f.text; $0.status = .streaming }
            pendingReplyTo = nil
            activeAssistantID = f.messageId

        case .assistantEnd(let f):
            ensureAssistant(f.messageId)
            update(f.messageId) { message in
                if let text = f.text { message.text = text }
                switch f.finishReason {
                case "cancelled": message.status = .cancelled
                case "error":     message.status = .failed("The assistant ran into a problem.")
                default:          message.status = .complete
                }
            }
            if activeAssistantID == f.messageId { activeAssistantID = nil }
            pendingReplyTo = nil

        case .toolStatus(let f):
            ensureAssistant(f.messageId)
            let state = ChatMessage.ToolActivity.State(rawValue: f.state) ?? .running
            update(f.messageId) { message in
                if let t = message.tools.firstIndex(where: { $0.id == f.callId }) {
                    message.tools[t].state = state
                    message.tools[t].summary = f.summary
                } else {
                    message.tools.append(.init(id: f.callId, name: f.name, state: state, summary: f.summary))
                }
            }

        case .error(let f):
            if let clientId = f.clientId, index(of: clientId) != nil {
                failMessage(clientId, f.detail)
            } else {
                messages.append(ChatMessage(
                    id: UUID().uuidString.lowercased(), role: .system,
                    text: f.detail, createdAt: Date(), status: .complete
                ))
                pendingReplyTo = nil
            }

        case .unknown:
            break
        }
    }

    // MARK: Helpers

    private func acknowledge(_ clientID: String) {
        ackTimeouts[clientID]?.cancel()
        ackTimeouts[clientID] = nil
        update(clientID) { if $0.status == .sending { $0.status = .sent } }
    }

    private func failMessage(_ id: String, _ reason: String) {
        ackTimeouts[id]?.cancel()
        ackTimeouts[id] = nil
        update(id) { message in
            switch message.status {
            case .sending, .sent: message.status = .failed(reason)
            default: break
            }
        }
        if pendingReplyTo == id { pendingReplyTo = nil }
    }

    /// Server history is the source of truth; local messages the server hasn't seen stay.
    private func merge(history: [WireMessage]) {
        var byID: [String: ChatMessage] = [:]
        for message in messages { byID[message.id] = message }

        for wire in history {
            guard let role = ChatMessage.Role(rawValue: wire.role) else { continue }
            let status: ChatMessage.Status
            switch (role, wire.status) {
            case (.user, _):             status = .sent
            case (_, "streaming"):       status = .streaming
            case (_, "cancelled"):       status = .cancelled
            case (_, "interrupted"):     status = .interrupted
            case (_, "error"):           status = .failed("The assistant ran into a problem.")
            default:                     status = .complete
            }
            var tools = byID[wire.id]?.tools ?? []
            if let wireTools = wire.tools {
                tools = wireTools.map {
                    .init(id: $0.callId, name: $0.name,
                          state: ChatMessage.ToolActivity.State(rawValue: $0.state) ?? .done,
                          summary: $0.summary)
                }
            }
            byID[wire.id] = ChatMessage(
                id: wire.id, role: role, text: wire.text,
                createdAt: wire.createdAt, status: status, tools: tools
            )
            if status == .streaming {
                activeAssistantID = wire.id
                lastSeq[wire.id] = wire.lastSeq ?? 0
            }
        }
        messages = byID.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    private func index(of id: String) -> Int? {
        messages.lastIndex(where: { $0.id == id })
    }

    private func ensureAssistant(_ id: String) {
        guard index(of: id) == nil else { return }
        messages.append(ChatMessage(id: id, role: .assistant, text: "", createdAt: Date(), status: .streaming))
    }

    private func update(_ id: String, _ change: (inout ChatMessage) -> Void) {
        guard let i = index(of: id) else { return }
        change(&messages[i])
    }
}

// MARK: - Preview data

extension ChatStore {
    static var sampleMessages: [ChatMessage] {
        let now = Date()
        return [
            ChatMessage(id: "1", role: .user, text: "How's my phone's battery?",
                        createdAt: now.addingTimeInterval(-60), status: .sent),
            ChatMessage(id: "2", role: .assistant,
                        text: "Your iPhone is at **82%** and not charging. It last reported a minute ago.",
                        createdAt: now.addingTimeInterval(-55), status: .complete,
                        tools: [.init(id: "t1", name: "get_device_status", state: .done, summary: "battery, network")]),
            ChatMessage(id: "3", role: .user, text: "Where am I?",
                        createdAt: now.addingTimeInterval(-20), status: .sent),
            ChatMessage(id: "4", role: .assistant, text: "",
                        createdAt: now.addingTimeInterval(-15), status: .streaming,
                        tools: [.init(id: "t2", name: "get_location", state: .approvalRequired,
                                      summary: "Waiting for your approval")])
        ]
    }
}