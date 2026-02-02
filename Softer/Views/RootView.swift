import SwiftUI
import SwiftData

struct RootView: View {
    @State private var store = SofterStore()

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
                    RoomListView(store: store)
                        .modelContainer(container)
                } else {
                    ProgressView("Loading...")
                }
            }
        }
    }
}
