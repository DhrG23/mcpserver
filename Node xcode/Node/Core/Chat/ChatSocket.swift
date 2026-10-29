//
//  ChatSocket.swift
//  Node
//
//  Created by Veerjyot Singh on 04/10/26.
//


//
//  ChatSocket.swift
//  Node
//
//  Core/Chat/ChatSocket.swift
//  One WebSocket connection to  wss://<server>/chat/ws.
//
//  - Uses ServerTrust.session, so self-signed servers work after the user approved the
//    certificate fingerprint on the login screen (same rule as every other request).
//  - Sends the token in the Authorization header of the upgrade request, never in the URL.
//  - Keeps the connection alive with WebSocket pings every 20 s.
//  - Knows nothing about messages: ChatStore owns the conversation and the reconnect policy.
//

import Foundation

@MainActor
final class ChatSocket {

    /// Path appended to the saved server address (https -> wss).
    static let path = "/chat/ws"

    enum Failure: LocalizedError, Equatable, Sendable {
        case noServer
        case notSignedIn
        case badURL
        case unauthorized
        case untrustedCertificate
        case rateLimited
        case network
        case closedByServer

        /// Retrying will not help until the user does something (sign in, trust the cert…).
        var isPermanent: Bool {
            switch self {
            case .noServer, .notSignedIn, .badURL, .unauthorized, .untrustedCertificate: return true
            case .rateLimited, .network, .closedByServer: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .noServer:             return "No server address saved. Sign in first."
            case .notSignedIn:          return "You're not signed in."
            case .badURL:               return "The server address isn't valid."
            case .unauthorized:         return "The server rejected your session. Sign out and sign in again."
            case .untrustedCertificate: return "The server's certificate isn't trusted. Sign in again to review it."
            case .rateLimited:          return "Too many connection attempts. Retrying shortly."
            case .network:              return "Can't reach the server."
            case .closedByServer:       return "The server closed the connection."
            }
        }
    }

    /// Called for every decoded frame (always on the main actor).
    var onFrame: ((ServerFrame) -> Void)?
    /// Called once when the connection ends for any reason except our own `disconnect()`.
    var onClose: ((Failure) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// Bumped on every connect/disconnect so late callbacks from an old connection are ignored.
    private var generation = 0

    private let encoder = ChatCoding.makeEncoder()

    // MARK: Connect / disconnect

    func connect() throws {
        disconnect()

        guard let base = ServerConfig.normalizedURL(ServerConfig.savedURL) else { throw Failure.noServer }
        guard let token = KeychainManager.shared.loadString(KeychainKey.accessToken), !token.isEmpty else {
            throw Failure.notSignedIn
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw Failure.badURL
        }
        components.scheme = "wss"
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (basePath.isEmpty ? "" : "/" + basePath) + Self.path
        guard let url = components.url else { throw Failure.badURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = ServerTrust.session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20           // 1 MiB per frame
        generation += 1
        let current = generation
        self.task = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: task, generation: current)
        }
        pingTask = Task { [weak self] in
            await self?.pingLoop(task: task, generation: current)
        }
    }

    func disconnect() {
        generation += 1
        receiveTask?.cancel()
        pingTask?.cancel()
        receiveTask = nil
        pingTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    // MARK: Sending

    func send<Frame: Encodable>(_ frame: Frame) async throws {
        guard let task else { throw Failure.network }
        let data = try encoder.encode(frame)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    // MARK: Loops

    private func receiveLoop(task: URLSessionWebSocketTask, generation current: Int) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard current == generation else { return }
                switch message {
                case .string(let text): handle(Data(text.utf8))
                case .data(let data):   handle(data)
                @unknown default:       break
                }
            } catch {
                guard current == generation else { return }
                onClose?(classify(task))
                return
            }
        }
    }

    private func pingLoop(task: URLSessionWebSocketTask, generation current: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, current == generation else { return }
            let alive: Bool = await withCheckedContinuation { continuation in
                task.sendPing { error in continuation.resume(returning: error == nil) }
            }
            if !alive {
                // receiveLoop sees the failure and reports it.
                task.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func handle(_ data: Data) {
        do {
            onFrame?(try ServerFrame.decode(data))
        } catch {
            #if DEBUG
            print("Chat: could not decode frame: \(error)")
            #endif
        }
    }

    /// Works out WHY the connection ended so the UI can say something useful.
    private func classify(_ task: URLSessionWebSocketTask) -> Failure {
        if let http = task.response as? HTTPURLResponse {
            switch http.statusCode {
            case 401, 403: return .unauthorized
            case 429:      return .rateLimited
            default:       break
            }
        }
        if let host = task.originalRequest?.url?.host,
           ServerTrust.takeRejectedFingerprint(for: host) != nil {
            return .untrustedCertificate
        }
        switch task.closeCode.rawValue {
        case 4401, 4403:  return .unauthorized          // app-level close codes, see server.md
        case 4429:        return .rateLimited
        case 1000, 1001:  return .closedByServer
        default:          return .network
        }
    }
}