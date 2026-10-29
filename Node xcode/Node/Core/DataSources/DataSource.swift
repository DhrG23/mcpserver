//
//  DataSource.swift
//  Node
//
//  Core/DataSources/DataSource.swift
//  Every extra kind of data Node can send to your server, and what state its
//  system permission is in. Everything here is OFF until the user turns it on.
//

import Foundation

/// State of the system permission behind a data source.
nonisolated enum PermissionState: String, Codable, Sendable {
    case notDetermined = "not_determined"
    case granted
    case limited                    // e.g. "selected photos only"
    case denied
    case restricted                 // blocked by parental controls / device policy
    case unavailable                // not on this device / platform, or capability not enabled
    case requested                  // asked, but iOS never reveals the answer (HealthKit)

    /// True when reading the data is allowed (or can't be ruled out).
    var allowsReading: Bool { self == .granted || self == .limited || self == .requested }

    var label: String {
        switch self {
        case .notDetermined: return "Not asked yet"
        case .granted:       return "Allowed"
        case .limited:       return "Limited access"
        case .denied:        return "Denied"
        case .restricted:    return "Restricted"
        case .unavailable:   return "Unavailable"
        case .requested:     return "Asked"
        }
    }
}

/// How much friction Apple puts in front of a source.
nonisolated enum SourceTier: Sendable {
    case prompt         // a normal permission prompt
    case entitlement    // needs a special capability / entitlement on top of (or instead of) a prompt
}

nonisolated enum DataSource: String, CaseIterable, Identifiable, Codable, Sendable {

    // Permission prompt
    case location, photos, camera, microphone, contacts, calendars, reminders
    case motion, health, bluetooth, notifications

    // Special entitlement
    case wifiName = "wifi_name"
    case screenTime = "screen_time"

    var id: String { rawValue }

    var tier: SourceTier {
        switch self {
        case .wifiName, .screenTime: return .entitlement
        default:                     return .prompt
        }
    }

    var title: String {
        switch self {
        case .location:      return "Location"
        case .photos:        return "Photo library"
        case .camera:        return "Camera"
        case .microphone:    return "Microphone"
        case .contacts:      return "Contacts"
        case .calendars:     return "Calendar"
        case .reminders:     return "Reminders"
        case .motion:        return "Motion & steps"
        case .health:        return "Health"
        case .bluetooth:     return "Bluetooth"
        case .notifications: return "Notifications"
        case .wifiName:      return "Wi-Fi network name"
        case .screenTime:    return "Screen Time"
        }
    }

    var icon: String {
        switch self {
        case .location:      return "location.fill"
        case .photos:        return "photo.on.rectangle"
        case .camera:        return "camera.fill"
        case .microphone:    return "mic.fill"
        case .contacts:      return "person.2.fill"
        case .calendars:     return "calendar"
        case .reminders:     return "checklist"
        case .motion:        return "figure.walk"
        case .health:        return "heart.fill"
        case .bluetooth:     return "dot.radiowaves.left.and.right"
        case .notifications: return "bell.badge.fill"
        case .wifiName:      return "wifi"
        case .screenTime:    return "hourglass"
        }
    }

    /// Plain-language promise of exactly what leaves the device. Shown next to the switch.
    var sentDescription: String {
        switch self {
        case .location:
            return "Approximate or precise coordinates, whichever you allow."
        case .photos:
            return "Counts only: photos, videos, screenshots, and the date of the newest one. No images."
        case .camera:
            return "Only whether access is allowed. Node never records or uploads video."
        case .microphone:
            return "Only whether access is allowed. Node never records or uploads audio."
        case .contacts:
            return "Only how many contacts you have. No names, numbers or emails."
        case .calendars:
            return "Number of events today and this week, and when the next one starts. No titles."
        case .reminders:
            return "Number of open reminders and how many are due today. No text."
        case .motion:
            return "Steps and distance today, plus your current activity (walking, driving…)."
        case .health:
            return "Steps, active energy and resting heart rate. Needs the HealthKit capability."
        case .bluetooth:
            return "Bluetooth state and how many devices are nearby. No names or addresses."
        case .notifications:
            return "Lets your server show notifications on this device. Nothing is sent from the device."
        case .wifiName:
            return "The name of the Wi-Fi network you're on. Needs the Wi-Fi capability and Location."
        case .screenTime:
            return "Only whether access is approved. iOS does not let apps read usage numbers."
        }
    }

    /// Whether this source exists on the current platform at all.
    var isSupportedHere: Bool {
        #if os(iOS)
        return true
        #else
        switch self {
        case .motion, .wifiName, .screenTime: return false
        default:                              return true
        }
        #endif
    }
}
