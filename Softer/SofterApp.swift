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
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    print("SofterApp: onContinueUserActivity browsing web")
                    if let url = activity.webpageURL {
                        print("SofterApp: URL = \(url)")
                    }
                }
                .onContinueUserActivity("com.apple.cloudkit.share.metadata") { activity in
                    print("SofterApp: onContinueUserActivity cloudkit share metadata")
                }
                .onOpenURL { url in
                    print("SofterApp: onOpenURL called with \(url)")
                    handleShareURL(url)
                }
        }
    }

    private func handleShareURL(_ url: URL) {
        // Check if this is a CloudKit share URL
        guard url.scheme == "https" && url.host?.contains("icloud.com") == true else {
            print("SofterApp: Not a CloudKit share URL")
            return
        }

        print("SofterApp: Handling CloudKit share URL: \(url)")

        let container = CKContainer(identifier: Constants.containerIdentifier)

        Task {
            do {
                let metadata = try await container.shareMetadata(for: url)
                print("SofterApp: Got share metadata, rootRecordID: \(metadata.rootRecordID.recordName)")

                try await container.accept(metadata)
                print("SofterApp: Share accepted")

                let roomID = metadata.hierarchicalRootRecordID?.recordName ?? metadata.rootRecordID.recordName
                await MainActor.run {
                    appDelegate.pendingShareRoomID = roomID
                }
            } catch {
                print("SofterApp: Failed to handle share URL: \(error)")
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    static var shared: AppDelegate?
    @Published var pendingShareRoomID: String?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

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

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        print("SceneDelegate: scene willConnectTo called")

        // Check for CloudKit share in connection options (app launched from share URL)
        if let metadata = connectionOptions.cloudKitShareMetadata {
            print("SceneDelegate: Found share metadata in connection options")
            handleShareMetadata(metadata)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        print("SceneDelegate: userDidAcceptCloudKitShareWith called")
        handleShareMetadata(cloudKitShareMetadata)
    }

    private func handleShareMetadata(_ metadata: CKShare.Metadata) {
        // Try hierarchicalRootRecordID first, fall back to deprecated rootRecordID
        let roomID = metadata.hierarchicalRootRecordID?.recordName
            ?? metadata.rootRecordID.recordName
        print("SceneDelegate: Root record ID: \(roomID)")

        // Get the app delegate to set the pending room ID
        guard let appDelegate = AppDelegate.shared else {
            print("SceneDelegate: Could not get AppDelegate.shared")
            return
        }

        // Accept the share using the container
        let container = CKContainer(identifier: Constants.containerIdentifier)

        Task {
            do {
                try await container.accept(metadata)
                print("SceneDelegate: Share accepted successfully, navigating to room: \(roomID)")

                await MainActor.run {
                    appDelegate.pendingShareRoomID = roomID
                }
            } catch {
                print("SceneDelegate: Failed to accept share: \(error)")
            }
        }
    }
}
