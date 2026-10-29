//
//  DevicesStore.swift
//  Node
//
//  Holds the device list for the Devices tab: loads it, refreshes it every 15 s while the
//  tab is visible, and handles search / filter / sort plus the per-device actions.
//

import Foundation
import Combine
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
final class DevicesStore: ObservableObject {

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", online = "Online", offline = "Offline"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case status = "Status", name = "Name", lastSeen = "Last seen"
        var id: String { rawValue }
    }

    @Published private(set) var devices: [RemoteDevice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var now = Date()
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var filter: Filter = .all
    @Published var sort: Sort = .status

    private let api = DevicesAPI()
    private let isPreview: Bool
    private var timer: Timer?
    private var tick = 0

    init() { isPreview = false }

    /// For SwiftUI previews: shows fixed data and never touches the network.
    init(previewDevices: [RemoteDevice]) {
        isPreview = true
        devices = previewDevices
        lastUpdated = Date()
    }

    // MARK: Lifecycle

    func start() {
        guard !isPreview else { return }
        Task { await refresh() }
        timer?.invalidate()
        tick = 0
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.now = Date()                       // keeps "online" and "5 min ago" honest
                self.tick += 1
                if self.tick % 3 == 0 { await self.refresh() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        guard !isPreview, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await api.list()
            lastUpdated = Date()
            now = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Derived data

    var totalCount: Int { devices.count }
    var onlineCount: Int { devices.filter { $0.isOnline(at: now) }.count }
    var offlineCount: Int { totalCount - onlineCount }
    var lowBatteryCount: Int { devices.filter(\.isLowBattery).count }
    var attentionCount: Int { devices.filter { !$0.isOnline(at: now) || $0.isLowBattery }.count }

    var lastUpdatedLabel: String {
        guard let lastUpdated else { return "Not loaded yet" }
        if now.timeIntervalSince(lastUpdated) < 10 { return "Updated just now" }
        return "Updated " + RelativeDateTimeFormatter().localizedString(for: lastUpdated, relativeTo: now)
    }

    var visibleDevices: [RemoteDevice] {
        var list = devices

        switch filter {
        case .all:     break
        case .online:  list = list.filter { $0.isOnline(at: now) }
        case .offline: list = list.filter { !$0.isOnline(at: now) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(query)
                || $0.platformLabel.lowercased().contains(query)
                || ($0.owner ?? "").lowercased().contains(query)
            }
        }

        switch sort {
        case .status:
            list.sort { a, b in
                let aOn = a.isOnline(at: now), bOn = b.isOnline(at: now)
                if aOn != bOn { return aOn }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        case .name:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastSeen:
            list.sort { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
        }
        return list
    }

    /// Best-effort "this is the device I'm holding" hint (iOS only reports a generic name).
    func isThisDevice(_ device: RemoteDevice) -> Bool {
        #if os(iOS)
        let samePlatform = ["ios", "ipados"].contains(device.platformKey)
        let local = UIDevice.current.name
        #else
        let samePlatform = ["macos", "mac", "darwin"].contains(device.platformKey)
        let local = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
        return samePlatform && device.name.caseInsensitiveCompare(local) == .orderedSame
    }

    // MARK: Actions (each returns an error message, or nil on success)

    func sendNotification(to device: RemoteDevice, title: String, body: String) async -> String? {
        do {
            try await api.sendNotification(to: device.id, title: title, body: body)
            return nil
        } catch { return error.localizedDescription }
    }

    func rename(_ device: RemoteDevice, to name: String) async -> String? {
        do {
            try await api.rename(device.id, to: name)
            if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index].name = name }
            return nil
        } catch { return error.localizedDescription }
    }

    func remove(_ device: RemoteDevice) async -> String? {
        do {
            try await api.remove(device.id)
            devices.removeAll { $0.id == device.id }
            return nil
        } catch { return error.localizedDescription }
    }
}
