import SwiftUI
import UIKit
import CloudKit

@main
struct SofterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appDelegate)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    @Published var pendingShareRoomID: String?

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

// MARK: - Scene Delegate

class SceneDelegate: NSObject, UIWindowSceneDelegate {

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        print("SceneDelegate: User accepted CloudKit share")
        print("SceneDelegate: Root record ID: \(cloudKitShareMetadata.hierarchicalRootRecordID?.recordName ?? "unknown")")

        // Get the app delegate to set the pending room ID
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            print("SceneDelegate: Could not get AppDelegate")
            return
        }

        // Accept the share using the container
        let container = CKContainer(identifier: Constants.containerIdentifier)

        Task {
            do {
                try await container.accept(cloudKitShareMetadata)
                print("SceneDelegate: Share accepted successfully")

                // Navigate to the room
                let roomID = cloudKitShareMetadata.hierarchicalRootRecordID?.recordName
                await MainActor.run {
                    appDelegate.pendingShareRoomID = roomID
                }
            } catch {
                print("SceneDelegate: Failed to accept share: \(error)")
            }
        }
    }
}
