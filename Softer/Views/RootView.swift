import SwiftUI

struct RootView: View {
    @State private var coordinator = AppCoordinator()

    var body: some View {
        Group {
            switch coordinator.status {
            case .loading:
                ProgressView("Connecting to iCloud...")

            case .unavailable(let message):
                ContentUnavailableView {
                    Label("iCloud Required", systemImage: "icloud.slash")
                } description: {
                    Text(message)
                }

            case .available:
                RoomListView(coordinator: coordinator)
            }
        }
    }
}
