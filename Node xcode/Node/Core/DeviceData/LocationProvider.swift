//
//  LocationProvider.swift
//  Node
//
//  Core/DeviceData/LocationProvider.swift
//  Asks for "When In Use" location permission and keeps the latest coordinate,
//  so a heartbeat can include it. Handles precise vs approximate location.
//  "Always" location is not used: it needs the Background Modes capability.
//
//  Needs: NSLocationWhenInUseUsageDescription (Info.plist) and, on macOS,
//  the Location entitlement (ENABLE_RESOURCE_ACCESS_LOCATION) — both are set in the project.
//

import Foundation
import CoreLocation
import Combine

@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var status: LocationStatus
    @Published private(set) var coordinates: DeviceSnapshot.Coordinates?

    /// Called whenever the permission or the coordinate changes.
    var onChange: (() -> Void)?

    /// True while the user has Location sharing switched on in Node. Without it the
    /// permission can exist (granted earlier) but no location is fetched or sent.
    var isActive = false

    /// True when the user allowed only approximate location (iOS 14+ "Precise Location" off).
    var isApproximate: Bool { manager.accuracyAuthorization == .reducedAccuracy }

    private let manager: CLLocationManager

    override init() {
        let m = CLLocationManager()
        manager = m
        status = LocationStatus(m.authorizationStatus)
        super.init()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyHundredMeters   // a heartbeat doesn't need GPS precision
    }

    /// Shows the system permission prompt the first time; does nothing afterwards.
    func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Asks for one fresh fix (result arrives via the delegate). Does nothing without permission.
    func refresh() {
        guard status == .granted, isActive else { return }
        manager.requestLocation()
    }

    // MARK: CLLocationManagerDelegate (called off the main actor)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let raw = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = LocationStatus(raw)
            if self.status != .granted { self.coordinates = nil }
            else if self.isActive { self.manager.requestLocation() }
            self.onChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let approximate = manager.accuracyAuthorization == .reducedAccuracy
        let fix = DeviceSnapshot.Coordinates(
            latitude: last.coordinate.latitude,
            longitude: last.coordinate.longitude,
            accuracyMeters: last.horizontalAccuracy,
            isApproximate: approximate,
            timestamp: last.timestamp
        )
        Task { @MainActor [weak self] in
            self?.coordinates = fix
            self?.onChange?()
        }
    }

    // Required when using requestLocation(); a failed fix simply keeps the previous coordinate.
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
