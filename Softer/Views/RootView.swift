import SwiftUI
import SwiftData

struct RootView: View {
    @Binding var pendingShareURL: URL?
    @State private var store = SofterStore()
    @State private var pendingRoomID: String?
    @State private var shareError: String?

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
        .onChange(of: pendingShareURL) { _, url in
            guard let url = url else { return }
            Task {
                await acceptShare(url: url)
            }
        }
        .alert("Share Error", isPresented: .constant(shareError != nil)) {
            Button("OK") { shareError = nil }
        } message: {
            if let error = shareError {
                Text(error)
            }
        }
    }

    private func acceptShare(url: URL) async {
        // Clear the pending URL immediately
        pendingShareURL = nil

        do {
            if let roomID = try await store.acceptShare(url: url) {
                // Small delay to allow sync to complete
                try? await Task.sleep(for: .milliseconds(500))
                pendingRoomID = roomID
            }
        } catch {
            shareError = "Failed to accept share: \(error.localizedDescription)"
        }
    }
}
