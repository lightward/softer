import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject var appDelegate: AppDelegate
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
                    RoomListView(store: store, pendingRoomID: $pendingRoomID)
                        .modelContainer(container)
                } else {
                    ProgressView("Loading...")
                }
            }
        }
        .onChange(of: appDelegate.pendingShareRoomID) { _, roomID in
            guard let roomID = roomID else { return }
            Task {
                await handleShareAccepted(roomID: roomID)
            }
        }
    }

    private func handleShareAccepted(roomID: String) async {
        // Clear the pending room ID immediately
        appDelegate.pendingShareRoomID = nil

        // Share was already accepted by SceneDelegate, just need to sync and navigate
        await store.refreshRooms()
        // Small delay to allow sync to complete
        try? await Task.sleep(for: .milliseconds(500))
        pendingRoomID = roomID
    }
}
