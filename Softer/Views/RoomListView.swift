import SwiftUI

struct RoomListView: View {
    @Environment(CloudKitManager.self) private var cloudKitManager
    @State private var viewModel: RoomListViewModel?
    @State private var showCreateRoom = false
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                switch cloudKitManager.status {
                case .loading:
                    ProgressView()
                case .unavailable(let message):
                    ContentUnavailableView(
                        "iCloud Required",
                        systemImage: "icloud.slash",
                        description: Text(message)
                    )
                case .available:
                    if let viewModel = viewModel {
                        if !cloudKitManager.initialFetchCompleted {
                            ProgressView()
                        } else {
                            List {
                                if viewModel.rooms.isEmpty {
                                    Section {
                                        ContentUnavailableView(
                                            "No Rooms",
                                            systemImage: "bubble.left.and.bubble.right",
                                            description: Text("Create a room to start a conversation with Lightward.")
                                        )
                                    }
                                } else {
                                    Section {
                                        ForEach(viewModel.rooms) { room in
                                            NavigationLink(value: room.id) {
                                                RoomRowView(room: room)
                                            }
                                        }
                                    }
                                }

                                #if DEBUG
                                Section("Debug") {
                                    Text("User: \(cloudKitManager.localUserRecordID ?? "unknown")")
                                        .font(.caption)
                                    Text("Rooms: \(viewModel.rooms.count)")
                                        .font(.caption)
                                    Text("Container: \(Constants.containerIdentifier)")
                                        .font(.caption)
                                    #if CLOUDKIT_PRODUCTION
                                    Text("Environment: Production")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                    #else
                                    Text("Environment: Development")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                    #endif
                                }
                                #endif
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("Softer")
            .toolbar {
                if case .available = cloudKitManager.status {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showCreateRoom = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showCreateRoom) {
                CreateRoomView(cloudKitManager: cloudKitManager) { roomID in
                    showCreateRoom = false
                    navigationPath.append(roomID)
                }
            }
            .navigationDestination(for: String.self) { roomID in
                RoomView(roomID: roomID, cloudKitManager: cloudKitManager)
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = RoomListViewModel(cloudKitManager: cloudKitManager)
            }
        }
    }
}

private struct RoomRowView: View {
    let room: Room

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(room.name)
                .font(.headline)
            HStack(spacing: 8) {
                Text("\(room.turnOrder.count) participants")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if room.isLightwardTurn {
                    Text("Lightward's turn")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
