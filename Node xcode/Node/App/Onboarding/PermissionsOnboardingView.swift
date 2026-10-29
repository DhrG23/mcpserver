//
//  PermissionsOnboardingView.swift
//  Node
//
//  First-launch slideshow (like Apple's phone setup): one permission per page,
//  "Allow" shows the real system prompt, "Not now" moves on. Shown once.
//
//  Pages are skipped automatically when a source can't be used here
//  (e.g. Motion on a Mac / the simulator, Health before HealthKit is set up),
//  or when it is already on or denied.
//

import SwiftUI

struct PermissionsOnboardingView: View {

    let onFinish: () -> Void

    @ObservedObject private var manager = DataSourceManager.shared
    @State private var pages: [Page] = [.welcome, .done]
    @State private var index = 0
    @State private var movingForward = true
    @State private var isWorking = false
    @State private var loaded = false

    enum Page: Hashable {
        case welcome
        case alwaysOn
        case source(DataSource)
        case done
    }

    /// Every source that needs a system permission, in the order the pages appear.
    /// (Wi-Fi name has no prompt of its own, so it is switched on automatically with Location.)
    private static let order: [DataSource] = [
        .location, .photos, .contacts, .calendars, .reminders,
        .motion, .health, .bluetooth, .camera, .microphone,
        .notifications, .screenTime
    ]

    private struct PageContent {
        let icon: String
        let title: String
        let message: String
        let detail: String?
        let color: Color
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            GlassBackground()

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 0)

                ZStack {
                    pageView(current)
                        .id(index)
                        .transition(.asymmetric(
                            insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)
                        ))
                }
                .padding(.horizontal, 28)

                Spacer(minLength: 0)

                dots
                    .padding(.bottom, 18)

                buttons
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: 520)
        }
        .task { await load() }
    }

    private var current: Page {
        pages.indices.contains(index) ? pages[index] : .done
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack {
            if index > 0 && current != .done {
                Button { goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            } else {
                Color.clear.frame(width: 32, height: 32)
            }

            Spacer()

            if current != .done {
                Button("Skip") { onFinish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isWorking)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .frame(height: 52)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { i in
                Circle()
                    .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch current {
        case .welcome, .alwaysOn:
            primaryButton("Continue") { goNext() }
        case .source(let source):
            VStack(spacing: 10) {
                primaryButton("Allow") { allow(source) }
                Button("Not now") { goNext() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isWorking)
                    .frame(height: 28)
            }
        case .done:
            primaryButton("Get started") { onFinish() }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isWorking { ProgressView() } else { Text(title) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isWorking)
    }

    private func pageView(_ page: Page) -> some View {
        let c = content(for: page)
        return VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(c.color.opacity(0.15))
                    .frame(width: 132, height: 132)
                Image(systemName: c.icon)
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(c.color)
            }

            Text(c.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text(c.message)
                .font(.body)
                .multilineTextAlignment(.center)

            if let detail = c.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content

    private func content(for page: Page) -> PageContent {
        switch page {
        case .welcome:
            return PageContent(
                icon: "antenna.radiowaves.left.and.right",
                title: "Welcome to Node",
                message: "Node shows how this device is doing and sends it to your own server. Next, choose what to share. Everything is optional.",
                detail: "You can change any of this later in Account → Data sharing.",
                color: .accentColor
            )
        case .alwaysOn:
            return PageContent(
                icon: "checkmark.shield.fill",
                title: "Already on",
                message: "These need no permission, so Node includes them by default:",
                detail: "Device & system (model, OS, battery, storage, memory)\nNetwork & app (Wi-Fi or cellular, speed)\nVendor ID and device name",
                color: .teal
            )
        case .source(let source):
            return PageContent(
                icon: source.icon,
                title: source.title,
                message: Self.purpose(source),
                detail: source.sentDescription,
                color: Self.tint(source)
            )
        case .done:
            let on = manager.enabled.count
            let message = on == 0
                ? "Nothing is being shared yet. You can turn things on any time in Account → Data sharing."
                : "\(on) data source\(on == 1 ? " is" : "s are") on. You can change this any time in Account → Data sharing."
            return PageContent(
                icon: "checkmark.circle.fill",
                title: "You're all set",
                message: message,
                detail: nil,
                color: .green
            )
        }
    }

    private static func purpose(_ source: DataSource) -> String {
        switch source {
        case .photos:    return "Show your photo, video and screenshot totals on the Core tab."
        case .contacts:  return "Show how many contacts you have on the Core tab."
        case .calendars: return "Show how many events you have today and when the next one starts."
        case .reminders: return "Show how many reminders are open and due today."
        case .motion:    return "Show your steps, distance and what you're doing right now."
        case .health:    return "Show your steps, active energy and resting heart rate."
        case .location:      return "Include where this device is. This also lets Node show your Wi-Fi network name."
        case .bluetooth:     return "Show how many Bluetooth devices are nearby."
        case .camera:        return "Node only checks that camera access is allowed. It never records anything."
        case .microphone:    return "Node only checks that microphone access is allowed. It never records anything."
        case .notifications: return "Let your server show notifications on this device."
        case .screenTime:    return "Let Node know whether Screen Time access is approved."
        default:         return "Share this with your Node server."
        }
    }

    private static func tint(_ source: DataSource) -> Color {
        switch source {
        case .photos:    return .purple
        case .contacts:  return .blue
        case .calendars: return .red
        case .reminders: return .orange
        case .motion:    return .green
        case .health:    return .pink
        case .location:      return .blue
        case .bluetooth:     return .indigo
        case .camera:        return .gray
        case .microphone:    return .mint
        case .notifications: return .yellow
        case .screenTime:    return .teal
        default:         return .accentColor
        }
    }

    // MARK: - Actions

    private func load() async {
        guard !loaded else { return }
        loaded = true
        await manager.refreshStatuses()
        let sources = Self.order.filter { source in
            guard source.isSupportedHere, !manager.isEnabled(source) else { return false }
            let state = manager.statuses[source] ?? .notDetermined
            return state != .unavailable && state != .restricted && state != .denied
        }
        pages = [.welcome, .alwaysOn] + sources.map { Page.source($0) } + [.done]
        index = 0
        await enableSourcesWithoutPrompt()
    }

    /// Sources that need no prompt of their own are switched on as soon as what they rely on is allowed.
    /// Wi-Fi name rides on Location, so it turns on by itself once Location is on.
    private func enableSourcesWithoutPrompt() async {
        let wifi = DataSource.wifiName
        if wifi.isSupportedHere, manager.isEnabled(.location), !manager.isEnabled(wifi) {
            await manager.setEnabled(wifi, true)
        }
    }

    private func allow(_ source: DataSource) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await manager.setEnabled(source, true)   // shows the system prompt
            if source == .location { await enableSourcesWithoutPrompt() }
            isWorking = false
            goNext()
        }
    }

    private func goNext() {
        movingForward = true
        withAnimation(.easeInOut(duration: 0.3)) {
            index = min(index + 1, pages.count - 1)
        }
    }

    private func goBack() {
        movingForward = false
        withAnimation(.easeInOut(duration: 0.3)) {
            index = max(index - 1, 0)
        }
    }
}

#Preview {
    PermissionsOnboardingView(onFinish: {})
}
