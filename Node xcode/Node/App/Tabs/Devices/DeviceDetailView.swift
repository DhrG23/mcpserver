//
//  DeviceDetailView.swift
//  Node
//
//  One device: status, battery, last seen, last known location on a map,
//  and actions (send a notification, rename, copy ID, remove).
//

import SwiftUI
import MapKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct DeviceDetailView: View {

    let deviceID: String
    @ObservedObject var store: DevicesStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showNotify = false
    @State private var showRename = false
    @State private var showRemove = false
    @State private var renameText = ""
    @State private var actionError: String?
    @State private var copied = false

    private var device: RemoteDevice? { store.devices.first { $0.id == deviceID } }

    // MARK: Body

    var body: some View {
        ZStack {
            GlassBackground()

            if let device {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(device)

                        LazyVGrid(columns: CoreLayout.columns, alignment: .leading, spacing: CoreLayout.spacing) {
                            ForEach(tiles(device)) { MetricTile(metric: $0) }
                        }

                        locationCard(device)
                        actionsCard(device)
                        detailsCard(device)
                    }
                    .padding(20)
                    .frame(maxWidth: CoreLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await store.refresh() }
            } else {
                Text("This device is no longer listed.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(device?.name ?? "Device")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showNotify) {
            if let device { SendNotificationSheet(device: device, store: store) }
        }
        .alert("Rename device", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Remove this device?", isPresented: $showRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("It disappears from your server's device list. It can register again later.")
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    // MARK: Sections

    private func header(_ d: RemoteDevice) -> some View {
        let online = d.isOnline(at: store.now)
        return HStack(spacing: 16) {
            Circle()
                .fill((online ? Color.green : Color.gray).opacity(0.15))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: d.platformIcon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(online ? Color.green : Color.secondary)
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(d.name).font(.title2.bold())
                HStack(spacing: 8) {
                    StatusPill(online: online)
                    if store.isThisDevice(d) {
                        Text("This device")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tiles(_ d: RemoteDevice) -> [Metric] {
        var items: [Metric] = []

        if let b = d.battery {
            items.append(Metric(
                id: "battery",
                icon: d.isCharging == true ? "battery.100.bolt" : "battery.75",
                label: "Battery",
                value: "\(Int((b * 100).rounded()))%",
                subtext: d.isCharging == true ? "Charging" : (d.isLowBattery ? "Low" : "OK"),
                accent: d.isLowBattery ? .red : .green,
                progress: b
            ))
        }

        items.append(Metric(
            id: "seen", icon: "clock.fill", label: "Last seen",
            value: d.isOnline(at: store.now) ? "Now" : d.lastSeenLabel(at: store.now),
            subtext: d.lastSeen?.formatted(date: .abbreviated, time: .shortened) ?? "No heartbeat yet",
            accent: .blue
        ))

        items.append(Metric(
            id: "platform", icon: d.platformIcon, label: "Platform",
            value: d.platformLabel, subtext: d.osVersion ?? "Version unknown", accent: .purple
        ))

        if let owner = d.owner {
            items.append(Metric(
                id: "owner", icon: "person.fill", label: "Owner",
                value: owner, subtext: "Registered to", accent: .orange
            ))
        }
        return items
    }

    @ViewBuilder
    private func locationCard(_ d: RemoteDevice) -> some View {
        if let lat = d.latitude, let lon = d.longitude {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Last known location")

                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))) {
                    Marker(d.name, coordinate: coordinate)
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .allowsHitTesting(false)

                Button {
                    openInMaps(d, lat: lat, lon: lon)
                } label: {
                    Label("Open in Maps", systemImage: "map")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    }

    private func actionsCard(_ d: RemoteDevice) -> some View {
        let online = d.isOnline(at: store.now)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Actions")

            VStack(spacing: 0) {
                actionRow(icon: "bell.badge.fill",
                          title: "Send notification",
                          subtitle: online ? "Shown on the device's next check-in"
                                           : "Queued until the device comes online") {
                    showNotify = true
                }
                divider
                actionRow(icon: "pencil", title: "Rename", subtitle: nil) {
                    renameText = d.name
                    showRename = true
                }
                divider
                actionRow(icon: "doc.on.doc",
                          title: copied ? "Copied" : "Copy device ID",
                          subtitle: d.id) {
                    copyID(d.id)
                }
                divider
                actionRow(icon: "trash", title: "Remove device", subtitle: nil, destructive: true) {
                    showRemove = true
                }
            }
            .glassPanel(cornerRadius: 24, shadowed: false)
        }
    }

    private func detailsCard(_ d: RemoteDevice) -> some View {
        var rows: [(String, String)] = [("Device ID", d.id), ("Platform", d.platformLabel)]
        if let v = d.osVersion { rows.append(("OS version", v)) }
        if let v = d.appVersion { rows.append(("App version", v)) }
        if let v = d.owner { rows.append(("Owner", v)) }
        if let v = d.reportedStatus { rows.append(("Reported status", v)) }
        if let t = d.lastSeen { rows.append(("Last heartbeat", t.formatted(date: .abbreviated, time: .standard))) }
        if let lat = d.latitude, let lon = d.longitude {
            rows.append(("Coordinates", String(format: "%.4f, %.4f", lat, lon)))
        }

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Details")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0)
                        Spacer(minLength: 12)
                        Text(row.1)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    if index < rows.count - 1 { divider }
                }
            }
            .glassPanel(cornerRadius: 24, shadowed: false)
        }
    }

    // MARK: Pieces

    private var divider: some View {
        Divider().opacity(0.4).padding(.leading, 58)
    }

    private func actionRow(icon: String, title: String, subtitle: String?,
                           destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(destructive ? Color.red : Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(destructive ? Color.red : Color.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func rename() {
        guard let device else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task { if let error = await store.rename(device, to: name) { actionError = error } }
    }

    private func remove() {
        guard let device else { return }
        Task {
            if let error = await store.remove(device) { actionError = error } else { dismiss() }
        }
    }

    private func copyID(_ id: String) {
        #if os(iOS)
        UIPasteboard.general.string = id
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func openInMaps(_ d: RemoteDevice, lat: Double, lon: Double) {
        var parts = URLComponents(string: "https://maps.apple.com/")
        parts?.queryItems = [
            URLQueryItem(name: "ll", value: "\(lat),\(lon)"),
            URLQueryItem(name: "q", value: d.name)
        ]
        if let url = parts?.url { openURL(url) }
    }
}

// MARK: - Send notification sheet

private struct SendNotificationSheet: View {

    let device: RemoteDevice
    @ObservedObject var store: DevicesStore

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var message = ""
    @State private var isSending = false
    @State private var error: String?

    private var canSend: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !isSending
    }

    var body: some View {
        ZStack {
            GlassBackground()

            VStack(alignment: .leading, spacing: 16) {
                Text("Send notification").font(.title2.bold())
                Text("To \(device.name). Your server queues it and the device shows it the next time it checks in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("Title", text: $title).glassInput()
                TextField("Message (optional)", text: $message).glassInput()

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: send) {
                        Group {
                            if isSending { ProgressView() } else { Text("Send") }
                        }
                        .frame(minWidth: 70)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                }
            }
            .padding(24)
            .frame(maxWidth: 480)
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #else
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private func send() {
        isSending = true
        error = nil
        Task {
            let result = await store.sendNotification(
                to: device,
                title: title.trimmingCharacters(in: .whitespaces),
                body: message.trimmingCharacters(in: .whitespaces)
            )
            isSending = false
            if let result { error = result } else { dismiss() }
        }
    }
}

#Preview("Device detail") {
    NavigationStack {
        DeviceDetailView(deviceID: "d1", store: DevicesStore(previewDevices: RemoteDevice.samples))
    }
}
