//
//  NetworkMonitor.swift
//  Node
//
//  Core/Services/NetworkMonitor.swift
//  Real connectivity info via NWPathMonitor (replaces the placeholder).
//

import Foundation
import Network

@MainActor
final class NetworkMonitor {

    struct State: Sendable, Equatable {
        enum Interface: String, Sendable {
            case wifi, cellular, wired, other, offline
        }

        var interface: Interface = .offline
        var isExpensive = false       // cellular / personal hotspot
        var isConstrained = false     // Low Data Mode

        var isConnected: Bool { interface != .offline }

        static let offline = State()
    }

    private(set) var state = State.offline

    /// Called on the main actor whenever the network state changes.
    var onChange: (() -> Void)?

    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.apply(path) }
        }
        m.start(queue: DispatchQueue(label: "node.network-monitor"))
        monitor = m
    }

    func stop() {
        monitor?.cancel()      // an NWPathMonitor can't be restarted, so drop it
        monitor = nil
    }

    private func apply(_ path: NWPath) {
        var new = State()
        if path.status == .satisfied {
            if path.usesInterfaceType(.wifi)               { new.interface = .wifi }
            else if path.usesInterfaceType(.cellular)      { new.interface = .cellular }
            else if path.usesInterfaceType(.wiredEthernet) { new.interface = .wired }
            else                                           { new.interface = .other }
            new.isExpensive = path.isExpensive
            new.isConstrained = path.isConstrained
        }
        guard new != state else { return }
        state = new
        onChange?()
    }
}
