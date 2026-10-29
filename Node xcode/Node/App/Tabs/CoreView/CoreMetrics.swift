//
//  CoreMetrics.swift
//  Node
//
//  Core/UI/CoreMetrics.swift
//  Turns a DeviceSnapshot into the tiles shown on screen.
//  To add a tile: add a field to the snapshot, then a Metric here.
//

import SwiftUI

// ─────────────────────────────────────────────
// MARK: - LocationStatus display
// ─────────────────────────────────────────────

extension LocationStatus {
    var label: String {
        switch self {
        case .granted:       return "Allowed"
        case .denied:        return "Denied"
        case .restricted:    return "Restricted"
        case .notDetermined: return "Not set"
        }
    }
    var detail: String {
        switch self {
        case .granted:       return "Included with each sync"
        case .denied:        return "Open Settings to enable"
        case .restricted:    return "Blocked by device policy"
        case .notDetermined: return "Asked on first sync"
        }
    }
    var icon: String {
        switch self {
        case .granted:       return "location.fill"
        case .denied:        return "location.slash.fill"
        case .restricted:    return "lock.fill"
        case .notDetermined: return "location.circle"
        }
    }
    var accent: Color {
        switch self {
        case .granted:       return .green
        case .denied:        return .red
        case .restricted:    return .orange
        case .notDetermined: return .secondary
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Metric mapping
// ─────────────────────────────────────────────

extension DeviceSnapshot {

    /// Things that change second to second.
    var liveMetrics: [Metric] {
        var items: [Metric] = []
        if let battery { items.append(batteryMetric(battery)) }
        items.append(cpuMetric)
        items.append(memoryMetric)
        items.append(storageMetric)
        items.append(thermalMetric)
        items.append(loadMetric)
        return items
    }

    /// Things that describe the device and its environment.
    var deviceMetrics: [Metric] {
        [networkMetric, systemMetric, displayMetric, locationMetric,
         uptimeMetric, regionMetric, appMetric]
    }

    // ── Live ───────────────────────────────────────────────────────────

    private func batteryMetric(_ b: BatteryInfo) -> Metric {
        let level = b.level
        let accent: Color
        switch level ?? 1 {
        case ..<0.10: accent = .red
        case ..<0.25: accent = .orange
        default:      accent = .green
        }
        let stateText: String
        switch b.state {
        case "charging":  stateText = "Charging"
        case "full":      stateText = "Full"
        case "unplugged": stateText = "On battery"
        default:          stateText = "Unknown"
        }
        return Metric(
            id: "battery",
            icon: batterySymbol(level: level, charging: b.isCharging),
            label: "Battery",
            value: level.map(Self.percent) ?? "—",
            subtext: power.isLowPowerMode ? "\(stateText) · Low Power" : stateText,
            accent: accent,
            progress: level
        )
    }

    private var cpuMetric: Metric {
        Metric(
            id: "cpu",
            icon: "cpu",
            label: "CPU",
            value: Self.percent(cpu.usage),
            subtext: "\(cpu.cores) cores",
            accent: cpu.usage < 0.6 ? .green : (cpu.usage < 0.85 ? .orange : .red),
            progress: cpu.usage
        )
    }

    private var memoryMetric: Metric {
        let fraction = memory.totalBytes > 0
            ? min(1, Double(memory.usedBytes) / Double(memory.totalBytes)) : 0

        let pressureLabel = memory.pressure.capitalized
        let appText = "App \(Self.bytes(memory.appUsedBytes, style: .memory))"
        let swapText = memory.swapUsedBytes.map { " · Swap \(Self.bytes($0, style: .memory))" } ?? ""

        let accent: Color
        switch memory.pressure {
        case "nominal":  accent = .green
        case "elevated": accent = .yellow
        case "high":     accent = .orange
        case "critical": accent = .red
        default:          accent = .pink
        }

        return Metric(
            id: "memory",
            icon: "memorychip",
            label: "Memory",
            value: "\(Self.bytes(memory.usedBytes, style: .memory)) used",
            subtext: "\(pressureLabel) pressure · \(appText)\(swapText)",
            accent: accent,
            progress: fraction
        )
    }

    private var storageMetric: Metric {
        let fraction = storage.totalBytes > 0
            ? min(1, Double(storage.usedBytes) / Double(storage.totalBytes)) : 0
        return Metric(
            id: "storage",
            icon: "internaldrive.fill",
            label: "Storage",
            value: Self.bytes(storage.usedBytes),
            subtext: "of \(Self.bytes(storage.totalBytes)) · \(Self.bytes(storage.availableBytes)) free",
            accent: fraction < 0.60 ? .purple : (fraction < 0.85 ? .orange : .red),
            progress: fraction
        )
    }

    /// The operating system's real thermal state (nominal / fair / serious / critical).
    private var thermalMetric: Metric {
        let accent: Color
        let progress: Double
        switch power.thermalState {
        case "nominal":  accent = .green;  progress = 0.25
        case "fair":     accent = .yellow; progress = 0.50
        case "serious":  accent = .orange; progress = 0.75
        case "critical": accent = .red;    progress = 1.00
        default:         accent = .gray;   progress = 0
        }
        return Metric(
            id: "thermal",
            icon: "thermometer.medium",
            label: "Thermal",
            value: power.thermalState.capitalized,
            subtext: power.isLowPowerMode ? "System state · Low Power" : "System state",
            accent: accent,
            progress: progress
        )
    }

    /// How busy the processors are right now (the higher of CPU and GPU usage).
    /// This is workload, not temperature.
    private var loadMetric: Metric {
        let activity = power.thermalActivity
        let activityLabel: String
        let accent: Color

        switch activity {
        case ..<0.35:
            activityLabel = "Low"
            accent = .green
        case ..<0.65:
            activityLabel = "Moderate"
            accent = .yellow
        case ..<0.85:
            activityLabel = "High"
            accent = .orange
        default:
            activityLabel = "Very high"
            accent = .red
        }

        let gpuText: String
        #if os(macOS)
        gpuText = " · GPU \(Self.percent(gpu.utilization ?? 0))"
        #else
        gpuText = ""
        #endif

        return Metric(
            id: "load",
            icon: "gauge.with.dots.needle.50percent",
            label: "Load",
            value: activityLabel,
            subtext: "CPU \(Self.percent(cpu.usage))\(gpuText)",
            accent: accent,
            progress: activity
        )
    }

    // ── Device ─────────────────────────────────────────────────────────

    private var networkMetric: Metric {
        let icon: String, label: String
        switch network.interface {
        case "wifi":     icon = "wifi";                                   label = "Wi-Fi"
        case "cellular": icon = "antenna.radiowaves.left.and.right";      label = "Cellular"
        case "wired":    icon = "cable.connector";                        label = "Ethernet"
        case "other":    icon = "network";                                label = "Other"
        default:         icon = "wifi.slash";                             label = "Offline"
        }
        let sub: String
        if !network.isConnected        { sub = "No connection" }
        else if network.isConstrained  { sub = "Connected · Low Data" }
        else if network.isExpensive    { sub = "Connected · Metered" }
        else                           { sub = "Connected" }
        return Metric(
            id: "network", icon: icon, label: "Network", value: label,
            subtext: sub, accent: network.isConnected ? .blue : .orange
        )
    }

    private var systemMetric: Metric {
        Metric(
            id: "system",
            icon: device.platform == "macOS" ? "laptopcomputer" : "iphone",
            label: "System",
            value: "\(device.platform) \(device.osVersion)",
            subtext: device.modelIdentifier,
            accent: .indigo
        )
    }

    private var displayMetric: Metric {
        Metric(
            id: "display",
            icon: "rectangle.on.rectangle",
            label: "Screen",
            value: "\(display.widthPx)×\(display.heightPx)",
            subtext: display.brightness.map { "\(Self.percent($0)) brightness" }
                ?? "@\(Int(display.scale))x",
            accent: .cyan,
            progress: display.brightness
        )
    }

    private var locationMetric: Metric {
        Metric(
            id: "location",
            icon: location.icon,
            label: "Location",
            value: location.label,
            subtext: location.detail,
            accent: location.accent
        )
    }

    private var uptimeMetric: Metric {
        let d = uptimeSeconds / 86_400
        let h = (uptimeSeconds % 86_400) / 3_600
        let m = (uptimeSeconds % 3_600) / 60
        let value = d > 0 ? "\(d)d \(h)h" : "\(h)h \(String(format: "%02d", m))m"
        return Metric(
            id: "uptime",
            icon: "clock.fill",
            label: "Uptime",
            value: value,
            subtext: "Since \(bootedAt.formatted(date: .abbreviated, time: .shortened))",
            accent: .teal
        )
    }

    private var regionMetric: Metric {
        let off = region.utcOffsetSeconds
        let a = abs(off)
        let utc = "UTC\(off < 0 ? "-" : "+")\(a / 3_600):\(String(format: "%02d", (a % 3_600) / 60))"
        return Metric(
            id: "region",
            icon: "globe",
            label: "Region",
            value: region.timeZone,
            subtext: "\(utc) · \(region.localeIdentifier)",
            accent: .mint
        )
    }

    private var appMetric: Metric {
        Metric(
            id: "app",
            icon: "app.badge",
            label: "App",
            value: "v\(app.version) (\(app.build))",
            subtext: app.bundleID,
            accent: .gray
        )
    }

    // ── Helpers ────────────────────────────────────────────────────────

    private static func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    private static func bytes(
        _ v: Int64,
        style: ByteCountFormatter.CountStyle = .file
    ) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: style)
    }

    private func batterySymbol(level: Double?, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level ?? 1 {
        case ..<0.13: return "battery.0"
        case ..<0.38: return "battery.25"
        case ..<0.63: return "battery.50"
        case ..<0.88: return "battery.75"
        default:      return "battery.100"
        }
    }
}
