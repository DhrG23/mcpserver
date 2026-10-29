//
//  NotificationsProvider.swift
//  Node
//
//  Permission to show notifications, plus a helper your server's commands can use
//  (e.g. a queued "notify" command from /devices/heartbeat → post(title:body:)).
//  Also makes notifications appear while Node is open.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationsProvider: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationsProvider()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func status() async -> PermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied:                               return .denied
        case .notDetermined:                        return .notDetermined
        @unknown default:                           return .notDetermined
        }
    }

    func request() async -> PermissionState {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        return await status()
    }

    /// Shows a local notification right away. Does nothing without permission.
    func post(title: String, body: String) async {
        guard await status() == .granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // Show banners even while the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
