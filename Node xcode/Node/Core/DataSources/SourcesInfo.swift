//
//  SourcesInfo.swift
//  Node
//
//  Core/DataSources/SourcesInfo.swift
//  The optional "sources" section of the heartbeat payload. A field is nil
//  (and therefore absent from the JSON) unless the user switched that source on
//  AND the system permission is granted.
//

import Foundation

extension DeviceSnapshot {

    nonisolated struct SourcesInfo: Codable, Sendable {

        /// Permission state of every source, so the server knows what it can expect.
        var permissions: [String: String] = [:]
        /// Sources the user has switched on in Node.
        var enabled: [String] = []

        var contacts: ContactsInfo?
        var calendar: CalendarInfo?
        var reminders: RemindersInfo?
        var motion: MotionInfo?
        var health: HealthInfo?
        var bluetooth: BluetoothInfo?
        var photos: PhotosInfo?
        var wifi: WiFiInfo?

        nonisolated struct ContactsInfo: Codable, Sendable {
            var count: Int
        }

        nonisolated struct CalendarInfo: Codable, Sendable {
            var eventsToday: Int
            var eventsNext7Days: Int
            var nextEventStart: Date?
        }

        nonisolated struct RemindersInfo: Codable, Sendable {
            var openCount: Int
            var dueTodayCount: Int
        }

        nonisolated struct MotionInfo: Codable, Sendable {
            var stepsToday: Int
            var distanceMetersToday: Double?
            var activity: String?          // walking | running | cycling | automotive | stationary
        }

        nonisolated struct HealthInfo: Codable, Sendable {
            var stepsToday: Int?
            var activeEnergyKcalToday: Double?
            var restingHeartRateBpm: Double?
        }

        nonisolated struct BluetoothInfo: Codable, Sendable {
            var state: String              // powered_on | powered_off | unauthorized | unsupported | unknown
            var nearbyCount: Int?          // distinct devices seen in a short scan
        }

        nonisolated struct PhotosInfo: Codable, Sendable {
            var photoCount: Int
            var videoCount: Int
            var screenshotCount: Int
            var latestPhotoDate: Date?
            var isLimitedSelection: Bool   // user only shared some photos with Node
        }

        nonisolated struct WiFiInfo: Codable, Sendable {
            var ssid: String
        }
    }
}

typealias SourcesInfo = DeviceSnapshot.SourcesInfo
