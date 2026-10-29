//
//  DataSourceManager.swift
//  Node
//
//  Core/DataSources/DataSourceManager.swift
//  The single place that knows which data sources are switched on, what their system
//  permission is, how to ask for it, and how to read them into a SourcesInfo.
//
//  Rules it enforces:
//    • Every source is OFF by default.
//    • Turning a source on shows the system prompt; if the user says no, the switch
//      goes back off.
//    • Data is only read when the source is ON *and* the permission is granted.
//

import Foundation
import Combine
import AVFoundation

#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
final class DataSourceManager: ObservableObject {

    static let shared = DataSourceManager()

    // MARK: Published state

    @Published private(set) var enabled: Set<DataSource>
    @Published private(set) var statuses: [DataSource: PermissionState] = [:]
    /// A short message for the UI, e.g. "Location is denied. Turn it on in Settings."
    @Published var notice: String?

    /// Called after a switch changes so the monitor can re-collect straight away.
    var onSettingsChanged: (() -> Void)?

    // MARK: Providers

    let location = LocationProvider()
    private let calendar = CalendarProvider()
    private let motion = MotionProvider()
    private let health = HealthProvider()
    private let bluetooth = BluetoothProvider()

    private static let defaultsKey = "sharing.enabledSources"

    // MARK: Init

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        enabled = Set(saved.compactMap(DataSource.init(rawValue:)))
        location.isActive = enabled.contains(.location)
        _ = NotificationsProvider.shared          // installs the foreground-banner delegate
    }

    // MARK: Switches

    func isEnabled(_ source: DataSource) -> Bool { enabled.contains(source) }

    /// Turns a source on (asking for permission first) or off.
    func setEnabled(_ source: DataSource, _ on: Bool) async {
        notice = nil
        if on {
            let state = await request(source)
            statuses[source] = state
            if state.allowsReading {
                enabled.insert(source)
            } else {
                enabled.remove(source)
                notice = Self.message(for: source, state: state)
            }
        } else {
            enabled.remove(source)
        }
        persist()
        if source == .location { location.isActive = enabled.contains(.location) }
        onSettingsChanged?()
    }

    private func persist() {
        UserDefaults.standard.set(enabled.map(\.rawValue).sorted(), forKey: Self.defaultsKey)
    }

    private static func message(for source: DataSource, state: PermissionState) -> String {
        switch state {
        case .denied:
            return "\(source.title) access is denied. Allow it in Settings, then try again."
        case .restricted:
            return "\(source.title) is blocked by a device restriction."
        case .unavailable:
            switch source {
            case .health:
                return "Health needs the HealthKit capability and the HEALTHKIT_ENABLED build flag. See HealthProvider.swift."
            case .screenTime:
                return "Screen Time needs the Family Controls capability from Apple and the FAMILYCONTROLS_ENABLED build flag."
            default:
                return "\(source.title) isn't available on this device."
            }
        default:
            return "\(source.title) wasn't allowed, so it's still off."
        }
    }

    // MARK: Permission state

    func refreshStatuses() async {
        var result: [DataSource: PermissionState] = [:]
        let locationState = Self.permission(for: location.status)
        result[.location] = locationState
        result[.photos] = PhotosProvider.status()
        result[.camera] = MediaPermissions.status(.video)
        result[.microphone] = MediaPermissions.status(.audio)
        result[.contacts] = ContactsProvider.status()
        result[.calendars] = CalendarProvider.eventStatus()
        result[.reminders] = CalendarProvider.reminderStatus()
        result[.motion] = MotionProvider.status()
        result[.health] = HealthProvider.status()
        result[.bluetooth] = BluetoothProvider.status()
        result[.notifications] = await NotificationsProvider.shared.status()
        result[.wifiName] = WiFiProvider.status(location: locationState)
        result[.screenTime] = ScreenTimeProvider.status()
        statuses = result
    }

    private static func permission(for status: LocationStatus) -> PermissionState {
        switch status {
        case .granted:       return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        }
    }

    // MARK: Requests

    /// Shows the system prompt for a source (if it hasn't been shown yet) and returns the result.
    func request(_ source: DataSource) async -> PermissionState {
        guard source.isSupportedHere else { return .unavailable }

        switch source {
        case .location, .wifiName:
            location.requestPermissionIfNeeded()
            await waitWhile { self.location.status == .notDetermined }
            let state = Self.permission(for: location.status)
            return source == .wifiName ? WiFiProvider.status(location: state) : state
        case .photos:        return await PhotosProvider.request()
        case .camera:        return await MediaPermissions.request(.video)
        case .microphone:    return await MediaPermissions.request(.audio)
        case .contacts:      return await ContactsProvider.request()
        case .calendars:     return await calendar.requestEvents()
        case .reminders:     return await calendar.requestReminders()
        case .motion:        return await motion.request()
        case .health:        return await health.request()
        case .bluetooth:     return await bluetooth.request()
        case .notifications: return await NotificationsProvider.shared.request()
        case .screenTime:    return await ScreenTimeProvider.request()
        }
    }

    /// The location prompt answers through a delegate, so poll (up to 2 minutes) until decided.
    private func waitWhile(_ undecided: () -> Bool) async {
        var waited = 0.0
        while undecided() && waited < 120 {
            try? await Task.sleep(for: .milliseconds(300))
            waited += 0.3
        }
    }

    // MARK: Collecting

    private func canRead(_ source: DataSource) -> Bool {
        enabled.contains(source) && (statuses[source]?.allowsReading ?? false)
    }

    /// Reads every enabled source into the `sources` block of a heartbeat.
    ///
    /// - Parameter deep: when false (the cheap once-a-minute refresh) the slow reads
    ///   (contacts, photos, Bluetooth scan) reuse `previous` instead of running again.
    func collect(previous: SourcesInfo?, deep: Bool) async -> SourcesInfo {
        await refreshStatuses()

        var info = SourcesInfo()
        info.permissions = Dictionary(
            uniqueKeysWithValues: statuses.map { ($0.key.rawValue, $0.value.rawValue) }
        )
        info.enabled = enabled.map(\.rawValue).sorted()

        // Cheap reads: every refresh.
        if canRead(.calendars)  { info.calendar = calendar.readEvents() }
        if canRead(.reminders)  { info.reminders = await calendar.readReminders() }
        if canRead(.motion)     { info.motion = await motion.read() }
        if canRead(.health)     { info.health = await health.read() }
        if canRead(.wifiName)   {
            info.wifi = await WiFiProvider.read(location: statuses[.location] ?? .notDetermined)
        }

        // Slow reads: only on a deep refresh (e.g. "Sync now"), otherwise reuse the last value.
        if canRead(.contacts)  { info.contacts  = deep ? await ContactsProvider.read()  : previous?.contacts }
        if canRead(.photos)    { info.photos    = deep ? await PhotosProvider.read()    : previous?.photos }
        if canRead(.bluetooth) { info.bluetooth = deep ? await bluetooth.read()         : previous?.bluetooth }

        return info
    }

    // MARK: Helpers for the UI

    /// Coordinates are only passed on when the user has Location switched on.
    var shareableCoordinates: DeviceSnapshot.Coordinates? {
        isEnabled(.location) ? location.coordinates : nil
    }

    /// Opens the system page where the user can change a permission.
    func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
