//
//  CalendarProvider.swift
//  Node
//
//  Calendar events and reminders via EventKit. Only counts and times are read;
//  titles, notes, locations and attendees never leave the device.
//

import Foundation
import EventKit

@MainActor
final class CalendarProvider {

    private let store = EKEventStore()

    // MARK: Status

    static func eventStatus() -> PermissionState { map(EKEventStore.authorizationStatus(for: .event)) }
    static func reminderStatus() -> PermissionState { map(EKEventStore.authorizationStatus(for: .reminder)) }

    private static func map(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess:    return .granted
        case .writeOnly:     return .denied          // can add events but not read them
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    // MARK: Requests

    func requestEvents() async -> PermissionState {
        _ = try? await store.requestFullAccessToEvents()
        return Self.eventStatus()
    }

    func requestReminders() async -> PermissionState {
        _ = try? await store.requestFullAccessToReminders()
        return Self.reminderStatus()
    }

    // MARK: Reads

    func readEvents() -> SourcesInfo.CalendarInfo? {
        guard Self.eventStatus().allowsReading else { return nil }
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay),
              let weekEnd = cal.date(byAdding: .day, value: 7, to: startOfDay) else { return nil }

        let predicate = store.predicateForEvents(withStart: startOfDay, end: weekEnd, calendars: nil)
        let week = store.events(matching: predicate)
        let today = week.filter { $0.startDate < endOfDay }
        let next = week
            .filter { $0.startDate >= now }
            .min { $0.startDate < $1.startDate }

        return .init(eventsToday: today.count,
                     eventsNext7Days: week.count,
                     nextEventStart: next?.startDate)
    }

    func readReminders() async -> SourcesInfo.RemindersInfo? {
        guard Self.reminderStatus().allowsReading else { return nil }
        let cal = Calendar.current
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )

        let counts: (open: Int, due: Int) = await withCheckedContinuation { continuation in
            // @Sendable: EventKit calls this on a background queue.
            store.fetchReminders(matching: predicate) { @Sendable reminders in
                let list = reminders ?? []
                let due = list.filter { reminder in
                    guard let comps = reminder.dueDateComponents,
                          let date = Calendar.current.date(from: comps) else { return false }
                    return date < endOfDay
                }.count
                continuation.resume(returning: (list.count, due))
            }
        }
        return .init(openCount: counts.open, dueTodayCount: counts.due)
    }
}
