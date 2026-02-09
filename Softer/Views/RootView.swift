import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = SofterStore()
    @State private var pendingRoomID: String?

    var body: some View {
        Group {
            switch store.syncStatus {
            case .idle:
                ProgressView("Connecting to iCloud...")

            case .error(let message):
                ContentUnavailableView {
                    Label("iCloud Required", systemImage: "icloud.slash")
                } description: {
                    Text(message)
                }

            case .syncing, .synced, .offline:
                if let container = store.modelContainer {
                    RoomListView(store: store, pendingRoomID: $pendingRoomID, acceptingShare: appDelegate.acceptingShare)
                        .modelContainer(container)
                } else {
                    ProgressView("Loading...")
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await store.fetchChanges()
                }
            } else if newPhase == .background {
                store.clearAllComposing(sync: true)
            }
        }
        .onChange(of: appDelegate.pendingShareRoomID) { _, roomID in
            guard let roomID = roomID else { return }
            appDelegate.pendingShareRoomID = nil
            Task {
                await handleShareAccepted(roomID: roomID)
            }
        }
    }

    private func handleShareAccepted(roomID: String) async {
        // Share was already accepted by SofterApp/SceneDelegate, just need to sync and navigate
        await store.refreshRooms()
        // Small delay to allow sync to complete
        try? await Task.sleep(for: .milliseconds(500))

        appDelegate.acceptingShare = false
        pendingRoomID = roomID
    }
}
