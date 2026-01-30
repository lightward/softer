import Foundation
import CloudKit
import UIKit

final class NotificationHandler: NSObject, @unchecked Sendable {
    private let cloudKitManager: CloudKitManager

    init(cloudKitManager: CloudKitManager) {
        self.cloudKitManager = cloudKitManager
        super.init()
    }

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
            // CKSyncEngine handles the actual fetch — this just wakes the app
            print("Received CloudKit zone notification")
        }
    }

    func handleShareAcceptance(_ metadata: CKShare.Metadata) {
        Task {
            try? await cloudKitManager.acceptShare(metadata)
        }
    }
}
