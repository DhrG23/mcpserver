//
//  DataSharingView.swift
//  Node
//
//  Account → Data sharing
//  One switch per kind of data. Everything is OFF until you turn it on, each row says
//  exactly what leaves the device, and flipping a switch shows the system prompt.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct DataSharingView: View {

    @ObservedObject private var manager = DataSourceManager.shared
    @Environment(\.scenePhase) private var scenePhase

    private var promptSources: [DataSource] {
        DataSource.allCases.filter { $0.tier == .prompt && $0.isSupportedHere }
    }
    private var entitlementSources: [DataSource] {
        DataSource.allCases.filter { $0.tier == .entitlement && $0.isSupportedHere }
    }

    var body: some View {
        ZStack {
            GlassBackground()

            ScrollView {
                VStack(spacing: 22) {
                    intro
                    alwaysSection
                    sourceSection(
                        "Needs your permission",
                        footer: "Each switch shows the system permission prompt the first time.",
                        sources: promptSources
                    )
                    if !entitlementSources.isEmpty {
                        sourceSection(
                            "Needs a special capability",
                            footer: "Apple only allows these when the matching capability is added to the app in Xcode.",
                            sources: entitlementSources
                        )
                    }
                    if let notice = manager.notice {
                        noticeCard(notice)
                    }
                }
                .frame(maxWidth: 560)
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Data sharing")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await manager.refreshStatuses() }
        // The user may have changed a permission in Settings while Node was in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await manager.refreshStatuses() } }
        }
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("You decide what leaves this device", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("Everything below is off by default. Node only sends a source after you switch it on and allow it in the system prompt. Use “Copy payload” on the Core tab to see exactly what is sent.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassPanel(cornerRadius: 24, shadowed: false)
    }

    /// Facts Node always sends because iOS needs no permission for them.
    private var alwaysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Always included (no permission needed)")
            VStack(spacing: 0) {
                infoRow("iphone", "Device & system",
                        "Model, OS version, battery, Low Power Mode, thermal state, storage, memory, uptime, language and time zone.")
                Divider().opacity(0.4).padding(.leading, 58)
                infoRow("network", "Network & app",
                        "Wi-Fi or cellular (not the network name), speed, and Node's own memory and GPU use.")
                Divider().opacity(0.4).padding(.leading, 58)
                infoRow("number", "Vendor ID",
                        "A random ID shared by apps from the same developer on this device. It resets if all of them are deleted.")
                #if os(iOS)
                Divider().opacity(0.4).padding(.leading, 58)
                infoRow("textformat", "Device name", deviceNameNote)
                #endif
            }
            .glassPanel(cornerRadius: 24, shadowed: false)
        }
    }

    #if os(iOS)
    private var deviceNameNote: String {
        let name = UIDevice.current.name
        if name == "iPhone" || name == "iPad" {
            return "iOS reports only “\(name)”. Apple shows your custom name only to apps with the user-assigned-device-name entitlement."
        }
        return "Sent as “\(name)”."
    }
    #endif

    private func sourceSection(_ title: String, footer: String, sources: [DataSource]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(title)
            VStack(spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    row(for: source)
                    if index < sources.count - 1 {
                        Divider().opacity(0.4).padding(.leading, 58)
                    }
                }
            }
            .glassPanel(cornerRadius: 24, shadowed: false)

            Text(footer)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        }
    }

    // MARK: - Rows

    private func row(for source: DataSource) -> some View {
        let state = manager.statuses[source] ?? .notDetermined
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: source.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                Text(source.sentDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                statusLine(state)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: binding(for: source))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func statusLine(_ state: PermissionState) -> some View {
        HStack(spacing: 8) {
            Text(state.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color(for: state))
            if state == .denied || state == .restricted {
                Button("Open Settings") { manager.openSystemSettings() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
    }

    private func infoRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func noticeCard(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassPanel(cornerRadius: 20, shadowed: false)
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
    }

    // MARK: - Helpers

    private func binding(for source: DataSource) -> Binding<Bool> {
        Binding(
            get: { manager.isEnabled(source) },
            set: { on in Task { await manager.setEnabled(source, on) } }
        )
    }

    private func color(for state: PermissionState) -> Color {
        switch state {
        case .granted, .requested: return .green
        case .limited:             return .yellow
        case .denied, .restricted: return .red
        case .notDetermined:       return .secondary
        case .unavailable:         return .orange
        }
    }
}

#Preview {
    NavigationStack { DataSharingView() }
}
