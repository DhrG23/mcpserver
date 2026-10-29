//
//  BluetoothProvider.swift
//  Node
//
//  Bluetooth state and a short scan that COUNTS nearby devices.
//  Device names and addresses are never kept or sent.
//
//  Creating the CBCentralManager is what triggers the system permission prompt,
//  so it is only created after the user switches Bluetooth on in Node.
//

import Foundation
import CoreBluetooth

@MainActor
final class BluetoothProvider: NSObject, CBCentralManagerDelegate {

    private var manager: CBCentralManager?
    private var state: CBManagerState = .unknown
    private var seen = Set<UUID>()

    static func status() -> PermissionState {
        switch CBCentralManager.authorization {
        case .allowedAlways: return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    private func ensureManager() {
        guard manager == nil else { return }
        manager = CBCentralManager(
            delegate: self,
            queue: nil,                                           // main queue
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func request() async -> PermissionState {
        ensureManager()
        // The prompt is modal; wait (up to 2 minutes) for the user to answer.
        var waited = 0.0
        while Self.status() == .notDetermined && waited < 120 {
            try? await Task.sleep(for: .milliseconds(300))
            waited += 0.3
        }
        return Self.status()
    }

    func read() async -> SourcesInfo.BluetoothInfo? {
        guard Self.status() == .granted else { return nil }
        ensureManager()

        // Wait briefly for the manager to report its state.
        var waited = 0.0
        while (state == .unknown || state == .resetting) && waited < 2 {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        guard state == .poweredOn, let manager else {
            return .init(state: Self.name(of: state), nearbyCount: nil)
        }

        seen.removeAll()
        manager.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        try? await Task.sleep(for: .seconds(4))
        manager.stopScan()
        return .init(state: "powered_on", nearbyCount: seen.count)
    }

    private static func name(of state: CBManagerState) -> String {
        switch state {
        case .poweredOn:    return "powered_on"
        case .poweredOff:   return "powered_off"
        case .unauthorized: return "unauthorized"
        case .unsupported:  return "unsupported"
        default:            return "unknown"
        }
    }

    // MARK: CBCentralManagerDelegate (called off the main actor)

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = central.state
        Task { @MainActor [weak self] in self?.state = newState }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        Task { @MainActor [weak self] in self?.seen.insert(id) }
    }
}
