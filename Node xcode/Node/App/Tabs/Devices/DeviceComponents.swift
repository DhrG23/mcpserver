//
//  DeviceComponents.swift
//  Node
//
//  Small views shared by the Devices list and the device detail screen.
//

import SwiftUI

struct DeviceRow: View {

    let device: RemoteDevice
    let now: Date
    var isThisDevice = false

    var body: some View {
        let online = device.isOnline(at: now)

        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill((online ? Color.green : Color.gray).opacity(0.15))
                    .frame(width: 46, height: 46)
                    .overlay {
                        Image(systemName: device.platformIcon)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(online ? Color.green : Color.secondary)
                    }
                Circle()
                    .fill(online ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                    .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    if isThisDevice {
                        Text("This device")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(online ? "Online" : "Last seen \(device.lastSeenLabel(at: now))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(online ? Color.green : Color.secondary)
            }

            Spacer(minLength: 8)

            if let battery = device.battery {
                BatteryLabel(level: battery, charging: device.isCharging)
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 20, shadowed: false)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        [device.platformLabel, device.owner].compactMap { $0 }.joined(separator: " · ")
    }
}

struct BatteryLabel: View {

    let level: Double
    var charging: Bool?

    private var symbol: String {
        if charging == true { return "battery.100.bolt" }
        switch level {
        case ..<0.13: return "battery.0"
        case ..<0.38: return "battery.25"
        case ..<0.63: return "battery.50"
        case ..<0.88: return "battery.75"
        default:      return "battery.100"
        }
    }

    private var tint: Color {
        if charging == true { return .green }
        return level < 0.2 ? .red : .secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text("\(Int((level * 100).rounded()))%")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
    }
}

struct StatusPill: View {

    let online: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(online ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(online ? "Online" : "Offline")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background((online ? Color.green : Color.gray).opacity(0.15), in: Capsule())
        .foregroundStyle(online ? Color.green : Color.secondary)
    }
}
