import SwiftUI
import SwiftData

struct RoomListView: View {
    let store: SofterStore
    @Binding var pendingRoomID: String?
    var acceptingShare: Bool = false
    @State private var showCreateRoom = false
    @State private var navigationPath = NavigationPath()
    @State private var roomToDelete: RoomLifecycle?

    // SwiftUI's @Query observes SwiftData directly — no manual reactivity needed
    @Query(sort: \PersistedRoom.createdAt, order: .reverse)
    private var persistedRooms: [PersistedRoom]

    private var rooms: [RoomLifecycle] {
        persistedRooms.compactMap { $0.toRoomLifecycle() }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if !store.initialLoadCompleted || acceptingShare {
                    ProgressView(acceptingShare ? "Locating room..." : "")
                } else if rooms.isEmpty {
                    ContentUnavailableView {
                        Label("No Rooms", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Create a room to start a conversation with Lightward.")
                    } actions: {
                        Button {
                            showCreateRoom = true
                        } label: {
                            Text("Create Room")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
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
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if let urlString = persistedRooms.first(where: { $0.id == lifecycle.spec.id })?.shareURL,
                                   let url = URL(string: urlString) {
                                    ShareLink(item: url) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    .tint(.blue)
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
                    Text(deleteConfirmationMessage(for: room))
                }
            }
        }
    }

    private func deleteConfirmationMessage(for room: RoomLifecycle) -> String {
        let isSharedWithMe = persistedRooms.first(where: { $0.id == room.spec.id })?.isSharedWithMe ?? false

        if !isSharedWithMe {
            // Originator — deletion removes the record for everyone
            return "This will permanently remove the room for everyone."
        }

        // Participant (shared-with-me)
        switch room.state {
        case .active:
            return "You'll leave this room — it will end for everyone."
        case .pendingParticipants:
            return "You'll decline to join this room."
        case .defunct:
            return "This will remove the room from your device."
        default:
            return "This will remove the room from your device."
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
        case .pendingParticipants:
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
        case .pendingParticipants(let signaled):
            let remaining = lifecycle.spec.participants.count - signaled.count
            return "Waiting for \(remaining) participant\(remaining == 1 ? "" : "s")..."
        case .active(let turn):
            let index = turn.currentTurnIndex % lifecycle.spec.participants.count
            let participant = lifecycle.spec.participants[index]
            return "\(participant.nickname)'s turn"
        case .defunct(let reason):
            switch reason {
            case .participantLeft:
                return "Ended"
            case .participantDeclined:
                return "Declined"
            case .cancelled:
                return "Cancelled"
            default:
                return "Ended"
            }
        }
    }
}

