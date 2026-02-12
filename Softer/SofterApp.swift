import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import CloudKit
import UserNotifications

@main
struct SofterApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

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

        // Show spinner immediately — before any async work
        appDelegate.acceptingShare = true

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

#if os(iOS)

class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    static var shared: AppDelegate?
    @Published var pendingShareRoomID: String?
    @Published var acceptingShare = false

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
        NotificationHandler.shared.registerForPushNotifications()
        return true
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

        // Show spinner immediately — before any async work
        Task { @MainActor in
            appDelegate.acceptingShare = true
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

#elseif os(macOS)

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static var shared: AppDelegate?
    @Published var pendingShareRoomID: String?
    @Published var acceptingShare = false

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
        NotificationHandler.shared.registerForPushNotifications()
    }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        print("AppDelegate: userDidAcceptCloudKitShareWith called")
        handleShareMetadata(cloudKitShareMetadata)
    }

    private func handleShareMetadata(_ metadata: CKShare.Metadata) {
        let roomID = metadata.hierarchicalRootRecordID?.recordName
            ?? metadata.rootRecordID.recordName
        print("AppDelegate: Root record ID: \(roomID)")

        Task { @MainActor in
            acceptingShare = true
        }

        let container = CKContainer(identifier: Constants.containerIdentifier)

        Task {
            do {
                try await container.accept(metadata)
                print("AppDelegate: Share accepted successfully, navigating to room: \(roomID)")

                await MainActor.run {
                    pendingShareRoomID = roomID
                }
            } catch {
                print("AppDelegate: Failed to accept share: \(error)")
            }
        }
    }
}

#endif
