import Foundation
import CloudKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import UserNotifications

/// Handles push notifications for CloudKit sync and local notifications for new messages/rooms.
final class NotificationHandler: NSObject, @unchecked Sendable {

    static let shared = NotificationHandler()

    func registerForPushNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    #if os(iOS)
                    UIApplication.shared.registerForRemoteNotifications()
                    #elseif os(macOS)
                    NSApplication.shared.registerForRemoteNotifications()
                    #endif
                }
            }
        }
    }

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return
        }

        if notification.notificationType == .recordZone {
            print("Received CloudKit zone notification")
        }
    }

    // MARK: - Local Notification Posting

    /// Post a local notification for a room. Suppressed if the user is currently viewing that room.
    func postNotification(roomID: String, currentlyViewingRoomID: String?, title: String, body: String) {
        guard roomID != currentlyViewingRoomID else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = roomID
        content.userInfo = ["roomID": roomID]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationHandler: UNUserNotificationCenterDelegate {

    /// Called when a notification arrives while the app is in the foreground.
    /// Show banner + sound (suppression already happened at post time).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    /// Called when the user taps a notification. Navigate to that room.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let roomID = response.notification.request.content.userInfo["roomID"] as? String
        guard let roomID = roomID else { return }

        await MainActor.run {
            AppDelegate.shared?.pendingShareRoomID = roomID
        }
    }
}
