import SwiftUI
import SwiftData

struct RoomListView: View {
    let store: SofterStore
    @State private var showCreateRoom = false
    @State private var navigationPath = NavigationPath()

    // SwiftUI's @Query observes SwiftData directly — no manual reactivity needed
    @Query(sort: \PersistedRoom.createdAt, order: .reverse)
    private var persistedRooms: [PersistedRoom]

    /// Transform persisted rooms to domain models, filtering out defunct rooms
    private var rooms: [RoomLifecycle] {
        persistedRooms.compactMap { $0.toRoomLifecycle() }.filter { !$0.isDefunct }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                if !store.initialLoadCompleted {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rooms.isEmpty {
                    ContentUnavailableView {
                        Label("No Rooms", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Create a room to start a conversation with Lightward.")
                    } actions: {
                        Button("Create Room") {
                            showCreateRoom = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 400)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(rooms, id: \.spec.id) { lifecycle in
                            NavigationLink(value: lifecycle.spec.id) {
                                RoomRow(lifecycle: lifecycle)
                                    .padding(.horizontal)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task {
                                        try? await store.deleteRoom(id: lifecycle.spec.id)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            Divider()
                                .padding(.leading)
                        }
                    }
                }
            }
            .navigationTitle("Softer")
            .toolbar {
                if !rooms.isEmpty {
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
                CreateRoomView(store: store, isPresented: $showCreateRoom) { roomID in
                    navigationPath.append(roomID)
                }
            }
            .navigationDestination(for: String.self) { roomID in
                RoomView(store: store, roomID: roomID)
            }
            .refreshable {
                await store.refreshRooms()
            }
            .onAppear {
                Task {
                    await store.refreshRooms()
                }
            }
        }
    }
}

struct RoomRow: View {
    let lifecycle: RoomLifecycle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Participant names
            Text(lifecycle.spec.participants.map { $0.nickname }.joined(separator: ", "))
                .font(.headline)

            // Status
            HStack {
                statusIndicator
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch lifecycle.state {
        case .active:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
        case .locked:
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .pendingLightward, .pendingHumans, .pendingCapture:
            ProgressView()
                .scaleEffect(0.6)
        default:
            EmptyView()
        }
    }

    private var statusText: String {
        switch lifecycle.state {
        case .draft:
            return "Setting up..."
        case .pendingLightward:
            return "Waiting for Lightward..."
        case .pendingHumans(let signaled):
            let remaining = lifecycle.spec.humanParticipants.count - signaled.count
            return "Waiting for \(remaining) participant\(remaining == 1 ? "" : "s")..."
        case .pendingCapture:
            return "Completing payment..."
        case .active(let turn):
            let index = turn.currentTurnIndex % lifecycle.spec.participants.count
            let participant = lifecycle.spec.participants[index]
            return "\(participant.nickname)'s turn"
        case .locked:
            return "Completed"
        case .defunct:
            return "Cancelled"
        }
    }
}
