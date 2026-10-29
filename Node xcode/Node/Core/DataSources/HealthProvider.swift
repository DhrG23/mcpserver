//
//  HealthProvider.swift
//  Node
//
//  HealthKit: steps, active energy and resting heart rate (read-only).
//
//  ⚠️ HealthKit CRASHES the app if the HealthKit capability is missing, so all of
//  this code is compiled out until you opt in:
//    1. Xcode → target Node → Signing & Capabilities → + Capability → HealthKit
//    2. Build Settings → "Active Compilation Conditions" → add  HEALTHKIT_ENABLED
//  Until then the Health switch reports "Unavailable".
//
//  iOS never tells an app whether *read* access was granted (privacy by design),
//  so the state after asking is `.requested`; empty results just mean "no data".
//

import Foundation
#if HEALTHKIT_ENABLED
import HealthKit
#endif

@MainActor
final class HealthProvider {

    private static let askedKey = "health.authorizationRequested"

    static func status() -> PermissionState {
        #if HEALTHKIT_ENABLED
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        return UserDefaults.standard.bool(forKey: askedKey) ? .requested : .notDetermined
        #else
        return .unavailable
        #endif
    }

    #if HEALTHKIT_ENABLED
    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        [HKQuantityType(.stepCount),
         HKQuantityType(.activeEnergyBurned),
         HKQuantityType(.restingHeartRate)]
    }
    #endif

    func request() async -> PermissionState {
        #if HEALTHKIT_ENABLED
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            UserDefaults.standard.set(true, forKey: Self.askedKey)
        } catch {
            return .denied
        }
        return Self.status()
        #else
        return .unavailable
        #endif
    }

    func read() async -> SourcesInfo.HealthInfo? {
        #if HEALTHKIT_ENABLED
        guard Self.status().allowsReading else { return nil }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let today = HKQuery.predicateForSamples(withStart: startOfDay, end: now)

        async let steps = sum(.stepCount, unit: .count(), predicate: today)
        async let energy = sum(.activeEnergyBurned, unit: .kilocalorie(), predicate: today)
        async let heart = latestRestingHeartRate()

        let (s, e, h) = await (steps, energy, heart)
        if s == nil && e == nil && h == nil { return nil }
        return .init(stepsToday: s.map { Int($0) }, activeEnergyKcalToday: e, restingHeartRateBpm: h)
        #else
        return nil
        #endif
    }

    #if HEALTHKIT_ENABLED
    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, predicate: NSPredicate) async -> Double? {
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate),
            options: .cumulativeSum
        )
        let stats = try? await descriptor.result(for: store)
        return stats?.sumQuantity()?.doubleValue(for: unit)
    }

    private func latestRestingHeartRate() async -> Double? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.restingHeartRate))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try? await descriptor.result(for: store)
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        return samples?.first?.quantity.doubleValue(for: perMinute)
    }
    #endif
}
