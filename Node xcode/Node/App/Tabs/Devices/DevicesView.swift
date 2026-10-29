//
//  DevicesView.swift
//  Node
//
//  Devices tab: every device registered on your server, whether it's online,
//  battery, last seen. Search, filter, sort, pull to refresh, tap for details.
//

import SwiftUI

struct DevicesView: View {

    @StateObject private var store: DevicesStore

    init() { _store = StateObject(wrappedValue: DevicesStore()) }
    init(store: DevicesStore) { _store = StateObject(wrappedValue: store) }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        summary
                        if let message = store.errorMessage { errorCard(message) }
                        if !store.devices.isEmpty { filterPicker }
                        deviceList
                    }
                    .padding(20)
                    .frame(maxWidth: CoreLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await store.refresh() }
            }
            .navigationTitle("Devices")
            .searchable(text: $store.searchText, prompt: "Search devices")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort by", selection: $store.sort) {
                            ForEach(DevicesStore.Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                DeviceDetailView(deviceID: id, store: store)
            }
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: Summary

    private var summary: some View {
        let total = store.totalCount
        let online = store.onlineCount
        let metrics: [Metric] = [
            Metric(id: "total", icon: "network", label: "Devices",
                   value: "\(total)", subtext: store.lastUpdatedLabel, accent: .blue),
            Metric(id: "online", icon: "dot.radiowaves.left.and.right", label: "Online",
                   value: "\(online)", subtext: "of \(total)", accent: .green,
                   progress: total == 0 ? nil : Double(online) / Double(total)),
            Metric(id: "attention", icon: "exclamationmark.triangle.fill", label: "Needs attention",
                   value: "\(store.attentionCount)",
                   subtext: "\(store.offlineCount) offline · \(store.lowBatteryCount) low battery",
                   accent: .orange)
        ]
        return LazyVGrid(columns: CoreLayout.columns, alignment: .leading, spacing: CoreLayout.spacing) {
            ForEach(metrics) { MetricTile(metric: $0) }
        }
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $store.filter) {
            ForEach(DevicesStore.Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: List

    @ViewBuilder
    private var deviceList: some View {
        let visible = store.visibleDevices

        if store.devices.isEmpty {
            if store.isLoading {
                ProgressView("Loading devices…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if store.errorMessage == nil {
                emptyState(icon: "network.slash",
                           title: "No devices yet",
                           message: "Devices appear here after they register with your server and send a heartbeat.")
            }
        } else if visible.isEmpty {
            emptyState(icon: "magnifyingglass",
                       title: "No matches",
                       message: "Try a different search or filter.")
        } else {
            VStack(spacing: 12) {
                ForEach(visible) { device in
                    NavigationLink(value: device.id) {
                        DeviceRow(device: device, now: store.now, isThisDevice: store.isThisDevice(device))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .glassPanel(cornerRadius: 24, shadowed: false)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Try again") { Task { await store.refresh() } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 20, shadowed: false)
    }
}

#Preview("Devices") {
    DevicesView(store: DevicesStore(previewDevices: RemoteDevice.samples))
}
