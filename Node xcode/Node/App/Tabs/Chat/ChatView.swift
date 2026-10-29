//
//  ChatView.swift
//  Node
//
//  Created by Veerjyot Singh on 04/10/26.
//


//
//  ChatView.swift
//  Node
//
//  App/Tabs/Chat/ChatView.swift
//  Chat tab: talk to the assistant on your server over a WebSocket.
//
//  The connection is opened while the app is active and closed in the background
//  (iOS suspends sockets anyway). Messages live only in memory; the server keeps the
//  history and sends it again after every reconnect.
//

import SwiftUI

struct ChatView: View {

    @StateObject private var store: ChatStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    private let bottomID = "chat.bottom"

    init() { _store = StateObject(wrappedValue: ChatStore()) }
    init(store: ChatStore) { _store = StateObject(wrappedValue: store) }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                VStack(spacing: 0) {
                    ConnectionBanner(state: store.state, onRetry: { store.reconnectNow() })

                    if store.messages.isEmpty {
                        EmptyChatState(enabled: store.state == .connected && !store.isAssistantBusy) {
                            store.send($0)
                        }
                    } else {
                        transcript
                    }

                    ChatComposer(
                        text: $store.draft,
                        canSend: store.canSend,
                        isBusy: store.isAssistantBusy,
                        maxChars: store.maxMessageChars,
                        onSend: { store.send() },
                        onStop: { store.cancelGeneration() }
                    )
                    .frame(maxWidth: CoreLayout.maxContentWidth)
                }
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text("Chat").font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Chat, \(statusLabel)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { store.reconnectNow() } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear { if scenePhase == .active { store.start() } }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:     store.start()
            case .background: store.stop()
            default:          break
            }
        }
        // Signing out wipes the conversation from memory and closes the socket.
        .onChange(of: appState.isAuthenticated) { _, signedIn in
            if !signedIn { store.reset() }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.messages) { message in
                        MessageRow(message: message, onRetry: { store.retry(message.id) })
                    }
                    if store.pendingReplyTo != nil { TypingBubble() }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: CoreLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: store.messages.count) { _, _ in scrollToBottom(proxy, animated: true) }
            .onChange(of: store.messages.last?.text) { _, _ in scrollToBottom(proxy, animated: false) }
            .onChange(of: store.pendingReplyTo) { _, _ in scrollToBottom(proxy, animated: true) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    // MARK: Status

    private var statusColor: Color {
        switch store.state {
        case .connected:                 return .green
        case .connecting, .reconnecting: return .orange
        case .idle:                      return .gray
        case .failed:                    return .red
        }
    }

    private var statusLabel: String {
        switch store.state {
        case .connected:    return "connected"
        case .connecting:   return "connecting"
        case .reconnecting: return "reconnecting"
        case .idle:         return "offline"
        case .failed:       return "disconnected"
        }
    }
}

#Preview("Conversation") {
    ChatView(store: ChatStore(previewMessages: ChatStore.sampleMessages))
        .environmentObject(AppState())
}

#Preview("Empty") {
    ChatView(store: ChatStore(previewMessages: []))
        .environmentObject(AppState())
}