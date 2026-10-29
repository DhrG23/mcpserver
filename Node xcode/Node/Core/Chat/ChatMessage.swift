//
//  ChatMessage.swift
//  Node
//
//  Created by Veerjyot Singh on 04/10/26.
//


//
//  ChatMessage.swift
//  Node
//
//  Core/Chat/ChatMessage.swift
//  What the Chat tab shows. One type for user, assistant and system lines.
//
//  The message id is the SAME on the device and on the server:
//    - user messages: the client_id the app generated
//    - assistant messages: the message_id the server issued
//

import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {

    enum Role: String, Sendable {
        case user, assistant, system
    }

    enum Status: Equatable, Sendable {
        case sending                // user message written to the socket, no ack yet
        case sent                   // server acknowledged it
        case streaming              // assistant is still writing
        case complete               // assistant finished normally
        case cancelled              // stopped by the user
        case interrupted            // connection dropped while streaming
        case failed(String)         // not delivered / assistant error (text is shown to the user)
    }

    /// One tool the assistant used while answering (e.g. "get_device_status").
    /// `summary` can contain device-originated text, so it is always shown as plain text.
    struct ToolActivity: Identifiable, Equatable, Sendable {
        enum State: String, Sendable {
            case running
            case done
            case failed
            case approvalRequired = "approval_required"
        }
        let id: String
        var name: String
        var state: State
        var summary: String?
    }

    let id: String
    var role: Role
    var text: String
    var createdAt: Date
    var status: Status
    var tools: [ToolActivity] = []
}