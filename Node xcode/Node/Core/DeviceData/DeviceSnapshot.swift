//
//  DeviceSnapshot.swift
//  Node
//
//  Core/Services/DeviceSnapshot.swift
//  Codable payload describing the device at one moment in time.
//  This is what gets sent to the server (see HeartbeatSender.swift).
//  No SwiftUI in here on purpose, so it can be reused anywhere.
//

import Foundation

enum LocationStatus: String, Codable, Sendable {
    case granted, denied, restricted
    case notDetermined = "not_determined"
}

struct DeviceSnapshot: Codable, Sendable {

    var schemaVersion = 4
    var installationID: String
    var capturedAt: Date
    var uptimeSeconds: Int
    var bootedAt: Date

    // NOTE: property order matters — the collector's memberwise init must match it.
    var device: DeviceInfo
    var app: AppInfo
    var battery: BatteryInfo?          // nil on Mac / when unknown
    var power: PowerInfo
    var cpu: CPUInfo
    var memory: MemoryInfo
    var gpu: GPUInfo
    var storage: StorageInfo
    var network: NetworkInfo
    var display: DisplayInfo
    var region: RegionInfo
    var location: LocationStatus
    var coordinates: Coordinates?      // only when the user turned Location sharing on
    var sources: SourcesInfo?          // optional extras, each opt-in (see SourcesInfo.swift)

    // MARK: Sections

    struct DeviceInfo: Codable, Sendable {
        var name: String
        var model: String
        var modelIdentifier: String     // e.g. "iPhone15,2", "Mac14,5"
        var platform: String            // "iOS", "iPadOS", "macOS"
        var osVersion: String
        var vendorID: String?           // identifierForVendor (iOS); same for all your apps on this device
    }

    struct AppInfo: Codable, Sendable {
        var version: String
        var build: String
        var bundleID: String
    }

    struct BatteryInfo: Codable, Sendable {
        var level: Double?              // 0...1
        var state: String               // charging | full | unplugged | unknown
        var isCharging: Bool
    }

    struct PowerInfo: Codable, Sendable {
        var isLowPowerMode: Bool
        var thermalState: String        // nominal | fair | serious | critical
        var thermalActivity: Double     // 0...1 estimated live thermal workload
    }

    struct CPUInfo: Codable, Sendable {
        var usage: Double               // 0...1, system-wide
        var cores: Int
        var brand: String?              // "Apple M3 Pro" (macOS only)
        var loadAverage: [Double]       // [1m, 5m, 15m]; empty if unavailable
    }

    struct MemoryInfo: Codable, Sendable {
        var totalBytes: Int64           // installed RAM
        var usedBytes: Int64            // system-wide: app + wired + compressed
        var wiredBytes: Int64
        var compressedBytes: Int64
        var swapUsedBytes: Int64?       // macOS only
        var appUsedBytes: Int64         // this app's footprint
        var pressure: String             // nominal | elevated | critical   (system memory-pressure level)
    }

    struct GPUInfo: Codable, Sendable {
        var name: String
        var utilization: Double?        // 0...1, macOS only (nil where the OS doesn't expose it)
        var memoryInUseBytes: Int64?    // system-reported GPU memory in use, macOS only
        var appAllocatedBytes: Int64    // Metal memory allocated by this app
        var recommendedWorkingSetBytes: Int64
        var hasUnifiedMemory: Bool
    }

    struct StorageInfo: Codable, Sendable {
        var totalBytes: Int64
        var usedBytes: Int64
        var availableBytes: Int64
    }

    struct NetworkInfo: Codable, Sendable {
        var isConnected: Bool
        var interface: String           // wifi | cellular | wired | other | offline
        var isExpensive: Bool
        var isConstrained: Bool
        var downBytesPerSec: Double
        var upBytesPerSec: Double
    }

    struct DisplayInfo: Codable, Sendable {
        var widthPx: Int
        var heightPx: Int
        var scale: Double
        var brightness: Double?         // 0...1, nil on Mac
    }

    struct Coordinates: Codable, Sendable {
        var latitude: Double
        var longitude: Double
        var accuracyMeters: Double
        var isApproximate: Bool         // user allowed only approximate location
        var timestamp: Date
    }

    struct RegionInfo: Codable, Sendable {
        var localeIdentifier: String
        var language: String
        var timeZone: String
        var utcOffsetSeconds: Int
    }
}

// MARK: - JSON

extension DeviceSnapshot {

    /// snake_case keys + ISO-8601 dates, which most backends expect.
    func jsonData(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    func jsonString() -> String {
        guard let data = try? jsonData(pretty: true) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
