//
//  MotionProvider.swift
//  Node
//
//  Steps, distance and current activity from CoreMotion (iPhone only).
//

import Foundation
#if os(iOS)
import CoreMotion
#endif

@MainActor
final class MotionProvider {

    #if os(iOS)
    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    #endif

    static func status() -> PermissionState {
        #if os(iOS)
        guard CMPedometer.isStepCountingAvailable() else { return .unavailable }
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
        #else
        return .unavailable
        #endif
    }

    /// There is no explicit "request" call: the first query shows the system prompt.
    func request() async -> PermissionState {
        #if os(iOS)
        _ = await querySteps()
        #endif
        return Self.status()
    }

    func read() async -> SourcesInfo.MotionInfo? {
        #if os(iOS)
        guard Self.status().allowsReading else { return nil }
        guard let steps = await querySteps() else { return nil }
        let activity = await currentActivity()
        return .init(stepsToday: steps.steps, distanceMetersToday: steps.distance, activity: activity)
        #else
        return nil
        #endif
    }

    #if os(iOS)
    private func querySteps() async -> (steps: Int, distance: Double?)? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let pedometer = self.pedometer
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: Date()) { @Sendable data, _ in
                guard let data else { continuation.resume(returning: nil); return }
                continuation.resume(returning: (data.numberOfSteps.intValue, data.distance?.doubleValue))
            }
        }
    }

    private func currentActivity() async -> String? {
        guard CMMotionActivityManager.isActivityAvailable() else { return nil }
        let manager = activityManager
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(
                from: Date().addingTimeInterval(-600),
                to: Date(),
                to: OperationQueue()
            ) { @Sendable activities, _ in
                guard let last = activities?.last(where: { !$0.unknown }) else {
                    continuation.resume(returning: nil)
                    return
                }
                let name: String
                if last.running         { name = "running" }
                else if last.walking    { name = "walking" }
                else if last.cycling    { name = "cycling" }
                else if last.automotive { name = "automotive" }
                else if last.stationary { name = "stationary" }
                else                    { name = "unknown" }
                continuation.resume(returning: name)
            }
        }
    }
    #endif
}
