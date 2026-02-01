import Foundation
import CloudKit
import UIKit

/// Handles push notifications for CloudKit sync.
/// Note: Share acceptance is not used in the new RoomLifecycle model.
final class NotificationHandler: NSObject, @unchecked Sendable {

    func registerForPushNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return
        }

        if notification.notificationType == .recordZone {
            // Zone notification - CloudKit data may have changed
            print("Received CloudKit zone notification")
        }
    }
}
