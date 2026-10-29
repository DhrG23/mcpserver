//
//  DataSourceMetrics.swift
//  Node
//
//  Core tab tiles for the optional data sources. Only sources the user switched on
//  (and that returned data) produce a tile, so the section disappears when nothing is shared.
//

import SwiftUI

extension DeviceSnapshot {

    var sourceMetrics: [Metric] {
        guard let s = sources else { return [] }
        var items: [Metric] = []

        if let motion = s.motion {
            var sub = motion.activity.map { $0.capitalized } ?? "Steps today"
            if let meters = motion.distanceMetersToday {
                sub += " · " + Measurement(value: meters, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road))
            }
            items.append(Metric(
                id: "motion", icon: "figure.walk", label: "Steps",
                value: motion.stepsToday.formatted(), subtext: sub, accent: .green,
                progress: min(1, Double(motion.stepsToday) / 10_000)
            ))
        }

        if let health = s.health {
            var parts: [String] = []
            if let kcal = health.activeEnergyKcalToday { parts.append("\(Int(kcal)) kcal") }
            if let hr = health.restingHeartRateBpm { parts.append("\(Int(hr)) bpm rest") }
            items.append(Metric(
                id: "health", icon: "heart.fill", label: "Health",
                value: health.stepsToday.map { "\($0.formatted()) steps" } ?? "—",
                subtext: parts.isEmpty ? "HealthKit" : parts.joined(separator: " · "),
                accent: .pink
            ))
        }

        if let cal = s.calendar {
            let next = cal.nextEventStart.map { "Next " + $0.formatted(date: .omitted, time: .shortened) }
                ?? "Nothing upcoming"
            items.append(Metric(
                id: "calendar", icon: "calendar", label: "Calendar",
                value: "\(cal.eventsToday) today",
                subtext: "\(cal.eventsNext7Days) this week · \(next)", accent: .red
            ))
        }

        if let rem = s.reminders {
            items.append(Metric(
                id: "reminders", icon: "checklist", label: "Reminders",
                value: "\(rem.openCount) open",
                subtext: "\(rem.dueTodayCount) due today", accent: .orange
            ))
        }

        if let contacts = s.contacts {
            items.append(Metric(
                id: "contacts", icon: "person.2.fill", label: "Contacts",
                value: contacts.count.formatted(), subtext: "Count only", accent: .blue
            ))
        }

        if let photos = s.photos {
            let latest = photos.latestPhotoDate.map { "Latest " + $0.formatted(date: .abbreviated, time: .omitted) }
                ?? "No photos"
            items.append(Metric(
                id: "photos", icon: "photo.on.rectangle", label: "Photos",
                value: photos.photoCount.formatted(),
                subtext: "\(photos.videoCount) videos · \(photos.screenshotCount) screenshots · \(latest)"
                    + (photos.isLimitedSelection ? " · limited" : ""),
                accent: .purple
            ))
        }

        if let bt = s.bluetooth {
            let on = bt.state == "powered_on"
            items.append(Metric(
                id: "bluetooth", icon: "dot.radiowaves.left.and.right", label: "Bluetooth",
                value: on ? "\(bt.nearbyCount ?? 0) nearby"
                          : bt.state.replacingOccurrences(of: "_", with: " ").capitalized,
                subtext: on ? "Devices in range at last scan" : "Not scanning", accent: .indigo
            ))
        }

        if let wifi = s.wifi {
            items.append(Metric(
                id: "wifiName", icon: "wifi", label: "Wi-Fi name",
                value: wifi.ssid, subtext: "Current network", accent: .cyan
            ))
        }

        return items
    }
}

// ─────────────────────────────────────────────
// MARK: - Always-visible tiles for the shared data sources
// ─────────────────────────────────────────────

extension DeviceSnapshot {

    /// One tile per data source. When a source has data it shows the real tile; otherwise it
    /// shows WHY there is no data (switched off, denied, unavailable, waiting for first sync).
    /// This makes a missing permission visible instead of the tile silently not appearing.
    func sourceMetrics(
        enabled: Set<DataSource>,
        statuses: [DataSource: PermissionState]
    ) -> [Metric] {

        let live = Dictionary(uniqueKeysWithValues: sourceMetrics.map { ($0.id, $0) })

        // (source, tile id, icon, label, accent) in display order
        let wanted: [(DataSource, String, String, String, Color)] = [
            (.motion,    "motion",    "figure.walk",        "Steps",     .green),
            (.health,    "health",    "heart.fill",         "Health",    .pink),
            (.calendars, "calendar",  "calendar",           "Calendar",  .red),
            (.reminders, "reminders", "checklist",          "Reminders", .orange),
            (.contacts,  "contacts",  "person.2.fill",      "Contacts",  .blue),
            (.photos,    "photos",    "photo.on.rectangle", "Photos",    .purple),
        ]

        var items: [Metric] = []
        for (source, id, icon, label, accent) in wanted where source.isSupportedHere {
            if enabled.contains(source), let tile = live[id] {
                items.append(tile)
                continue
            }
            let (value, sub) = Self.placeholder(
                source: source,
                isOn: enabled.contains(source),
                state: statuses[source] ?? .notDetermined
            )
            items.append(Metric(id: id, icon: icon, label: label,
                                value: value, subtext: sub, accent: accent.opacity(0.45)))
        }

        // Bluetooth / Wi-Fi name only appear when they have data.
        for id in ["bluetooth", "wifiName"] {
            if let tile = live[id] { items.append(tile) }
        }
        return items
    }

    private static func placeholder(source: DataSource, isOn: Bool, state: PermissionState) -> (String, String) {
        if !isOn { return ("Off", "Turn on in Account → Data sharing") }
        switch state {
        case .denied:      return ("Denied", "Allow \(source.title) in Settings")
        case .restricted:  return ("Restricted", "Blocked by device policy")
        case .unavailable:
            return source == .health
                ? ("Unavailable", "Needs HealthKit capability + HEALTHKIT_ENABLED flag")
                : ("Unavailable", "Not available on this device")
        default:           return ("Waiting…", "Tap Sync now to read")
        }
    }
}
