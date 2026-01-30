import SwiftUI
import CloudKit

@main
struct SofterApp: App {
    @State private var cloudKitManager = CloudKitManager()

    var body: some Scene {
        WindowGroup {
            RoomListView()
                .environment(cloudKitManager)
        }
    }
}
