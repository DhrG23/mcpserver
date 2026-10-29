//
//  RemoteDevice.swift
//  Node
//
//  One device as reported by your server (GET /devices).
//  Decoding is deliberately forgiving: several key names, ids as text or numbers,
//  ISO-8601 or epoch dates, battery as 0...1 or 0...100. Missing fields are fine.
//

import Foundation

nonisolated struct RemoteDevice: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var platform: String
    var owner: String?
    var lastSeen: Date?
    var battery: Double?               // 0...1
    var isCharging: Bool?
    var latitude: Double?
    var longitude: Double?
    var reportedStatus: String?
    var osVersion: String?
    var appVersion: String?

    /// Heartbeats arrive every ~30 s, so three missed ones = offline.
    static let onlineWindow: TimeInterval = 90

    func isOnline(at now: Date = Date()) -> Bool {
        if let lastSeen { return now.timeIntervalSince(lastSeen) < Self.onlineWindow }
        switch reportedStatus?.lowercased() {
        case "online", "active", "connected": return true
        default:                              return false
        }
    }

    var isLowBattery: Bool {
        guard let battery else { return false }
        return battery < 0.2 && isCharging != true
    }

    var platformKey: String { platform.lowercased() }

    var platformLabel: String {
        switch platformKey {
        case "ios":                       return "iOS"
        case "ipados":                    return "iPadOS"
        case "macos", "mac", "darwin":    return "macOS"
        case "android":                   return "Android"
        case "linux":                     return "Linux"
        case "windows":                   return "Windows"
        case "":                          return "Unknown"
        default:                          return platform.capitalized
        }
    }

    var platformIcon: String {
        switch platformKey {
        case "ios":                       return "iphone"
        case "ipados":                    return "ipad"
        case "macos", "mac", "darwin":    return "laptopcomputer"
        case "android":                   return "candybarphone"
        case "linux":                     return "terminal.fill"
        case "windows":                   return "display"
        default:                          return "desktopcomputer"
        }
    }

    func lastSeenLabel(at now: Date = Date()) -> String {
        guard let lastSeen else { return "Never" }
        if now.timeIntervalSince(lastSeen) < 10 { return "Just now" }
        return RelativeDateTimeFormatter().localizedString(for: lastSeen, relativeTo: now)
    }
}

// MARK: - Forgiving decoding

nonisolated private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

nonisolated private extension KeyedDecodingContainer where Key == AnyKey {

    func string(_ names: [String]) -> String? {
        for name in names {
            guard let key = AnyKey(stringValue: name) else { continue }
            if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        }
        return nil
    }

    func double(_ names: [String]) -> Double? {
        for name in names {
            guard let key = AnyKey(stringValue: name) else { continue }
            if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        }
        return nil
    }

    func bool(_ names: [String]) -> Bool? {
        for name in names {
            guard let key = AnyKey(stringValue: name) else { continue }
            if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        }
        return nil
    }

    func date(_ names: [String]) -> Date? {
        for name in names {
            guard let key = AnyKey(stringValue: name) else { continue }
            if let seconds = try? decodeIfPresent(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
            }
            if let text = try? decodeIfPresent(String.self, forKey: key), let date = parseServerDate(text) {
                return date
            }
        }
        return nil
    }

    func nested(_ name: String) -> KeyedDecodingContainer<AnyKey>? {
        guard let key = AnyKey(stringValue: name) else { return nil }
        return try? nestedContainer(keyedBy: AnyKey.self, forKey: key)
    }
}

/// Handles "2026-10-04T12:00:00Z", "...12:00:00.123456" (no zone) and "2026-10-04 12:00:00".
nonisolated private func parseServerDate(_ raw: String) -> Date? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains("T"), let space = text.firstIndex(of: " ") { text.replaceSubrange(space...space, with: "T") }

    let hasZone = text.hasSuffix("Z") || text.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
    if !hasZone { text += "Z" }

    if let range = text.range(of: #"\.\d+"#, options: .regularExpression) {
        let digits = String(text[range].dropFirst().prefix(3))
        text.replaceSubrange(range, with: "." + digits)
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}

nonisolated extension RemoteDevice: Decodable {

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)

        guard let id = c.string(["device_id", "id", "deviceId", "uuid"]) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Device has no id")
            )
        }

        var battery = c.double(["battery", "battery_level", "batteryLevel"])
        var charging = c.bool(["is_charging", "charging"])
        if let box = c.nested("battery") {
            battery = box.double(["level", "percent", "value"]) ?? battery
            charging = box.bool(["is_charging", "charging"]) ?? charging
        }
        if let b = battery, b > 1 { battery = b / 100 }          // 87 -> 0.87

        var lat = c.double(["lat", "latitude"])
        var lon = c.double(["lon", "lng", "longitude"])
        if let box = c.nested("location") {
            lat = box.double(["lat", "latitude"]) ?? lat
            lon = box.double(["lon", "lng", "longitude"]) ?? lon
        }

        self.init(
            id: id,
            name: c.string(["name", "device_name", "hostname"]) ?? "Unnamed device",
            platform: c.string(["platform", "os", "type"]) ?? "",
            owner: c.string(["owner", "user"]),
            lastSeen: c.date(["last_seen", "last_seen_at", "lastSeen", "last_heartbeat", "last_heartbeat_at", "updated_at"]),
            battery: battery,
            isCharging: charging,
            latitude: lat,
            longitude: lon,
            reportedStatus: c.string(["status", "state"]),
            osVersion: c.string(["os_version", "osVersion"]),
            appVersion: c.string(["app_version", "appVersion", "version"])
        )
    }
}

// MARK: - Sample data (previews only)

extension RemoteDevice {
    static let samples: [RemoteDevice] = [
        RemoteDevice(id: "d1", name: "Veer's iPhone", platform: "ios", owner: "veer",
                     lastSeen: Date().addingTimeInterval(-12), battery: 0.82, isCharging: true,
                     latitude: 28.6139, longitude: 77.2090, osVersion: "iOS 26.0", appVersion: "1.0 (1)"),
        RemoteDevice(id: "d2", name: "arch-desktop", platform: "linux", owner: "veer",
                     lastSeen: Date().addingTimeInterval(-40), osVersion: "Arch Linux"),
        RemoteDevice(id: "d3", name: "Pixel 9", platform: "android", owner: "veer",
                     lastSeen: Date().addingTimeInterval(-3600), battery: 0.14, isCharging: false),
        RemoteDevice(id: "d4", name: "MacBook Pro", platform: "macos", owner: "veer",
                     lastSeen: Date().addingTimeInterval(-86_400 * 2), battery: 0.55)
    ]
}
