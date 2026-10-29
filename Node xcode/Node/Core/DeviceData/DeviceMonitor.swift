//
//  DeviceMonitor.swift
//  Node
//
//  Core/Services/DeviceMonitor.swift
//  Keeps a live DeviceSnapshot up to date and can send it to the server.
//

import Foundation
import Combine
import CoreLocation

#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension LocationStatus {
    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: self = .granted
        case .denied:                                 self = .denied
        case .restricted:                             self = .restricted
        case .notDetermined:                          self = .notDetermined
        @unknown default:                             self = .notDetermined
        }
    }
}

@MainActor
final class DeviceMonitor: ObservableObject {

    @Published private(set) var snapshot: DeviceSnapshot
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var isConnectedToServer = false
    /// The latest optional "sources" block (calendar, steps, photos counts, …).
    @Published private(set) var sources: SourcesInfo?

    /// Injected sender (previews / tests). When nil, syncNow() builds a real
    /// HTTPHeartbeatSender from the saved server address and the keychain token.
    private let injectedSender: HeartbeatSender?
    private let network: NetworkMonitor
    private let cpuSampler: CPUSampler
    private let throughputSampler: NetworkThroughputSampler
    private let pressureMonitor: MemoryPressureMonitor
    private let dataSources = DataSourceManager.shared
    private var timer: Timer?
    private var tick = 0
    private var isCollectingSources = false

    init(sender: HeartbeatSender? = nil) {
        self.injectedSender = sender
        self.network = NetworkMonitor()
        self.cpuSampler = CPUSampler()
        self.throughputSampler = NetworkThroughputSampler()
        self.pressureMonitor = MemoryPressureMonitor()
        let manager = DataSourceManager.shared
        self.snapshot = SnapshotCollector.collect(
            network: .offline,
            samples: LiveSamples(),
            location: manager.location.status,
            coordinates: manager.shareableCoordinates,
            sources: nil
        )
        network.onChange = { [weak self] in self?.refresh() }
        manager.location.onChange = { [weak self] in self?.refresh() }
        // When the user flips a switch in Data sharing, re-read everything immediately.
        manager.onSettingsChanged = { [weak self] in
            Task { @MainActor [weak self] in await self?.refreshSources(deep: true) }
        }
    }

    // MARK: Lifecycle

    func start() {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        network.start()
        pressureMonitor.start()
        refresh()
        // Slow reads (contacts, photo counts, Bluetooth scan) only on the first start, then on sync.
        Task { await refreshSources(deep: sources == nil) }

        timer?.invalidate()
        tick = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.tick += 1
                // Cheap sources (calendar, steps…) refresh once a minute.
                if self.tick % 60 == 0 { Task { await self.refreshSources(deep: false) } }
            }
        }
        RunLoop.main.add(t, forMode: .common)   // keeps ticking while scrolling
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        network.stop()
        pressureMonitor.stop()
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = false
        #endif
    }

    private func refresh() {
        let speed = throughputSampler.sample()
        let samples = LiveSamples(
            cpuUsage: cpuSampler.sample(),
            downBytesPerSec: speed.down,
            upBytesPerSec: speed.up,
            memoryPressure: pressureMonitor.level
        )
        snapshot = SnapshotCollector.collect(
            network: network.state,
            samples: samples,
            location: dataSources.location.status,
            coordinates: dataSources.shareableCoordinates,
            sources: sources
        )
    }

    /// Re-reads the optional data sources. `deep` also runs the slower reads
    /// (contacts, photo counts, Bluetooth scan).
    func refreshSources(deep: Bool) async {
        guard !isCollectingSources else { return }
        isCollectingSources = true
        defer { isCollectingSources = false }
        sources = await dataSources.collect(previous: sources, deep: deep)
        refresh()
    }

    // MARK: Server

    var lastSyncLabel: String {
        guard let date = lastSyncDate else { return "Never" }
        if Date().timeIntervalSince(date) < 5 { return "Just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Location is only fetched if the user switched it on in Account → Data sharing.
        // The fresh fix lands after this sync, so the next heartbeat carries it.
        dataSources.location.refresh()

        await refreshSources(deep: true)
        refresh()
        do {
            let sender = try makeSender()
            try await sender.send(snapshot)
            // Only reached after a real 2xx response from the server.
            lastSyncDate = Date()
            lastSyncError = nil
            isConnectedToServer = true
        } catch {
            lastSyncError = error.localizedDescription
            isConnectedToServer = false
        }
    }

    /// Reads the saved server address and token at send time, so a new sign-in is picked up.
    private func makeSender() throws -> HeartbeatSender {
        if let injectedSender { return injectedSender }
        guard let base = ServerConfig.normalizedURL(ServerConfig.savedURL) else {
            throw HeartbeatError.noServer
        }
        guard let token = KeychainManager.shared.loadString(KeychainKey.accessToken),
              !token.isEmpty else {
            throw HeartbeatError.notSignedIn
        }
        return HTTPHeartbeatSender(
            endpoint: base.appendingPathComponent(HTTPHeartbeatSender.path),
            token: token
        )
    }

    /// Handy for debugging your backend contract.
    func copyPayloadToClipboard() {
        let json = snapshot.jsonString()
        #if os(iOS)
        UIPasteboard.general.string = json
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        #endif
    }
}
