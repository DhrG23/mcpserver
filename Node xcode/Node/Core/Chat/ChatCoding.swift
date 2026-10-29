//
//  ChatCoding.swift
//  Node
//
//  Created by Veerjyot Singh on 04/10/26.
//


//
//  ChatProtocol.swift
//  Node
//
//  Core/Chat/ChatProtocol.swift
//  The JSON frames exchanged over the chat WebSocket. See server.md for the full contract.
//
//  Every frame is one JSON text message with a "type" field, snake_case keys and
//  ISO-8601 dates (fractional seconds accepted when reading).
//

import Foundation

// MARK: - Coding

nonisolated enum ChatCoding {

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not an ISO-8601 date: \(raw)")
            )
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

// MARK: - Client -> server

/// A user message. The server must treat `client_id` as an idempotency key and store the
/// message under that same id (a retry after a lost ack must not create a duplicate).
nonisolated struct ChatSendFrame: Encodable, Sendable {
    let type = "chat.send"
    let clientId: String
    let conversationId: String?
    let text: String
    let sentAt: Date
}

/// Stop the answer that is being generated. Send `messageId` once the assistant has started,
/// or `replyTo` (the user's client_id) if no assistant output has arrived yet.
nonisolated struct ChatCancelFrame: Encodable, Sendable {
    let type = "chat.cancel"
    let messageId: String?
    let replyTo: String?
}

/// Ask for the latest messages (sent right after `ready`).
nonisolated struct HistoryGetFrame: Encodable, Sendable {
    let type = "history.get"
    let conversationId: String?
    let before: String?
    let limit: Int
}

// MARK: - Server -> client payloads

nonisolated struct ReadyFrame: Decodable, Sendable {
    let protocolVersion: Int?
    let conversationId: String?
    let serverTime: Date?
    let userName: String?
    let maxMessageChars: Int?
    let features: [String]?
}

nonisolated struct WireTool: Decodable, Sendable {
    let callId: String
    let name: String
    let state: String
    let summary: String?
}

nonisolated struct WireMessage: Decodable, Sendable {
    let id: String
    let role: String
    let text: String
    let createdAt: Date
    /// complete | streaming | cancelled | interrupted | error  (absent for user messages)
    let status: String?
    /// For a `streaming` message: the last delta seq already included in `text`.
    let lastSeq: Int?
    let tools: [WireTool]?
}

nonisolated struct HistoryFrame: Decodable, Sendable {
    let conversationId: String?
    let messages: [WireMessage]
    let hasMore: Bool?
}

nonisolated struct AckFrame: Decodable, Sendable {
    let clientId: String
    let createdAt: Date?
}

nonisolated struct AssistantStartFrame: Decodable, Sendable {
    let messageId: String
    let replyTo: String?
    let createdAt: Date?
}

nonisolated struct AssistantDeltaFrame: Decodable, Sendable {
    let messageId: String
    let seq: Int?
    let text: String
}

nonisolated struct AssistantEndFrame: Decodable, Sendable {
    let messageId: String
    /// stop | length | cancelled | error
    let finishReason: String?
    /// Optional full final text; replaces whatever was streamed.
    let text: String?
}

nonisolated struct ToolStatusFrame: Decodable, Sendable {
    let messageId: String
    let callId: String
    let name: String
    /// running | done | failed | approval_required
    let state: String
    let summary: String?
}

nonisolated struct ErrorFrame: Decodable, Sendable {
    let code: String?
    let detail: String
    let clientId: String?
    let retryAfter: Double?
}

// MARK: - Decoding

nonisolated enum ServerFrame: Sendable {
    case ready(ReadyFrame)
    case history(HistoryFrame)
    case ack(AckFrame)
    case assistantStart(AssistantStartFrame)
    case assistantDelta(AssistantDeltaFrame)
    case assistantEnd(AssistantEndFrame)
    case toolStatus(ToolStatusFrame)
    case error(ErrorFrame)
    case unknown(String)            // newer server frame types are ignored, never an error

    private struct TypeOnly: Decodable { let type: String }

    static func decode(_ data: Data) throws -> ServerFrame {
        let decoder = ChatCoding.makeDecoder()
        let type = try decoder.decode(TypeOnly.self, from: data).type
        switch type {
        case "ready":           return .ready(try decoder.decode(ReadyFrame.self, from: data))
        case "history":         return .history(try decoder.decode(HistoryFrame.self, from: data))
        case "chat.ack":        return .ack(try decoder.decode(AckFrame.self, from: data))
        case "assistant.start": return .assistantStart(try decoder.decode(AssistantStartFrame.self, from: data))
        case "assistant.delta": return .assistantDelta(try decoder.decode(AssistantDeltaFrame.self, from: data))
        case "assistant.end":   return .assistantEnd(try decoder.decode(AssistantEndFrame.self, from: data))
        case "tool.status":     return .toolStatus(try decoder.decode(ToolStatusFrame.self, from: data))
        case "error":           return .error(try decoder.decode(ErrorFrame.self, from: data))
        default:                return .unknown(type)
        }
    }
}