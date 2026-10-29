//
//  ChatText.swift
//  Node
//
//  Created by Veerjyot Singh on 04/10/26.
//


//
//  ChatBubbles.swift
//  Node
//
//  App/Tabs/Chat/ChatBubbles.swift
//  The small views the Chat screen is built from.
//

import SwiftUI

// MARK: - Safe text rendering

enum ChatText {
    /// Light Markdown (bold, italic, code) for assistant text. Links are stripped on purpose:
    /// model output can be influenced by device-originated strings, so nothing in a reply
    /// should be tappable.
    static func render(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var result = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        let linked = result.runs.filter { $0.link != nil }.map(\.range)
        for range in linked { result[range].link = nil }
        return result
    }
}

// MARK: - Message row

struct MessageRow: View {

    let message: ChatMessage
    var onRetry: () -> Void

    var body: some View {
        switch message.role {
        case .system:    systemNote
        case .user:      userRow
        case .assistant: assistantRow
        }
    }

    // MARK: User

    private var userRow: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(verbatim: message.text)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                userStatus
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var userStatus: some View {
        switch message.status {
        case .sending:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Sending").font(.caption2).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Button(action: onRetry) {
                Label(reason, systemImage: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        default:
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Assistant

    private var assistantRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(message.tools) { ToolChip(tool: $0) }
                if !message.text.isEmpty {
                    Text(ChatText.render(message.text))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassPanel(cornerRadius: 18, shadowed: false)
                }
                assistantStatus
            }
            Spacer(minLength: 48)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var assistantStatus: some View {
        switch message.status {
        case .streaming where message.text.isEmpty && message.tools.isEmpty:
            TypingDots()
        case .cancelled:
            Text("Stopped").font(.caption2).foregroundStyle(.secondary)
        case .interrupted:
            Text("Connection lost. This answer may be incomplete.")
                .font(.caption2).foregroundStyle(.orange)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    // MARK: System

    private var systemNote: some View {
        Text(verbatim: message.text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

// MARK: - Tool chip

struct ToolChip: View {

    let tool: ChatMessage.ToolActivity

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(verbatim: tool.name.replacingOccurrences(of: "_", with: " "))
                .font(.caption.weight(.medium))
            if let summary = tool.summary, !summary.isEmpty {
                Text(verbatim: "· \(summary)")       // untrusted text: plain, never Markdown
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    @ViewBuilder
    private var icon: some View {
        switch tool.state {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        case .approvalRequired:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.caption)
        }
    }
}

// MARK: - Typing indicator

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.25) % 3
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(i == step ? 1 : 0.35)
                }
            }
        }
        .accessibilityLabel("Node is typing")
    }
}

struct TypingBubble: View {
    var body: some View {
        HStack {
            TypingDots()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .glassPanel(cornerRadius: 18, shadowed: false)
            Spacer(minLength: 48)
        }
    }
}

// MARK: - Connection banner

struct ConnectionBanner: View {

    let state: ChatStore.ConnectionState
    var onRetry: () -> Void

    var body: some View {
        switch state {
        case .idle, .connected:
            EmptyView()
        case .connecting:
            banner(icon: nil, text: "Connecting…", showRetry: false)
        case .reconnecting:
            banner(icon: nil, text: "Connection lost. Reconnecting…", showRetry: true)
        case .failed(let failure):
            banner(icon: "exclamationmark.triangle.fill",
                   text: failure.errorDescription ?? "Can't connect.",
                   showRetry: true)
        }
    }

    private func banner(icon: String?, text: String, showRetry: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon).foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.footnote)
            Spacer(minLength: 8)
            if showRetry {
                Button("Retry", action: onRetry).font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 14, shadowed: false)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - Empty state

struct EmptyChatState: View {

    var enabled: Bool
    var onPick: (String) -> Void

    private let suggestions = [
        "How's my battery?",
        "Which of my devices are online?",
        "What do you know about this device?"
    ]

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Ask Node anything")
                .font(.title3.weight(.semibold))
            Text("Your assistant can look at the data you've chosen to share.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { text in
                    Button { onPick(text) } label: {
                        Text(text)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(maxWidth: 320)
                            .glassPanel(cornerRadius: 16, shadowed: false)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.5)
                }
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Composer

struct ChatComposer: View {

    @Binding var text: String
    var canSend: Bool
    var isBusy: Bool
    var maxChars: Int
    var onSend: () -> Void
    var onStop: () -> Void

    private var count: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var nearLimit: Bool { count > Int(Double(maxChars) * 0.9) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if nearLimit {
                Text("\(count)/\(maxChars)")
                    .font(.caption2)
                    .foregroundStyle(count > maxChars ? .red : .secondary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Node", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .glassPanel(cornerRadius: 22, shadowed: false)
                    #if os(iOS)
                    .submitLabel(.send)
                    #endif
                    .onSubmit { if canSend { onSend() } }

                Button(action: isBusy ? onStop : onSend) {
                    Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle().fill(isBusy || canSend ? Color.blue : Color.gray.opacity(0.45))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isBusy && !canSend)
                .accessibilityLabel(isBusy ? "Stop" : "Send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}