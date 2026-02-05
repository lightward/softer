import SwiftUI
import SwiftData

struct RoomListView: View {
    let store: SofterStore
    @Binding var pendingRoomID: String?
    @State private var showCreateRoom = false
    @State private var navigationPath = NavigationPath()
    @State private var roomToDelete: RoomLifecycle?

    // SwiftUI's @Query observes SwiftData directly — no manual reactivity needed
    @Query(sort: \PersistedRoom.createdAt, order: .reverse)
    private var persistedRooms: [PersistedRoom]

    /// Transform persisted rooms to domain models, filtering out defunct rooms
    private var rooms: [RoomLifecycle] {
        persistedRooms.compactMap { $0.toRoomLifecycle() }.filter { !$0.isDefunct }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if !store.initialLoadCompleted {
                    ProgressView()
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
                } else {
                    List {
                        ForEach(rooms, id: \.spec.id) { lifecycle in
                            NavigationLink(value: lifecycle.spec.id) {
                                RoomRow(lifecycle: lifecycle)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    roomToDelete = lifecycle
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
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
            .onChange(of: pendingRoomID) { _, roomID in
                guard let roomID = roomID else { return }
                // Clear pending and navigate
                pendingRoomID = nil
                navigationPath.append(roomID)
            }
            .alert("Delete Room?", isPresented: Binding(
                get: { roomToDelete != nil },
                set: { if !$0 { roomToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let room = roomToDelete {
                        Task {
                            try? await store.deleteRoom(id: room.spec.id)
                        }
                    }
                    roomToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    roomToDelete = nil
                }
            } message: {
                if let room = roomToDelete {
                    let names = room.spec.participants
                        .filter { !$0.isLightward }
                        .map { $0.nickname }
                        .joined(separator: ", ")
                    Text("This will permanently delete your conversation with \(names).")
                }
            }
        }
    }
}

struct RoomRow: View {
    let lifecycle: RoomLifecycle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Participant names with turn indicator dot (only when active)
            participantNamesView

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
    private var participantNamesView: some View {
        let currentTurnIndex = currentTurnParticipantIndex
        let participants = lifecycle.spec.participants
        HStack(spacing: 0) {
            ForEach(0..<participants.count, id: \.self) { index in
                if index > 0 {
                    Text(", ")
                }
                HStack(spacing: 3) {
                    if index == currentTurnIndex {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(participants[index].nickname)
                }
            }
        }
        .font(.headline)
    }

    /// Returns the current turn participant index only if room is active, nil otherwise
    private var currentTurnParticipantIndex: Int? {
        guard case .active(let turn) = lifecycle.state else { return nil }
        return turn.currentTurnIndex % lifecycle.spec.participants.count
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch lifecycle.state {
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
