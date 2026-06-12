import SwiftUI
import SwiftData

struct RoomListView: View {
    let store: SofterStore
    @Binding var pendingRoomID: String?
    var acceptingShare: Bool = false
    @State private var showCreateRoom = false
    @State private var selectedRoomID: String?
    @State private var roomToDelete: RoomLifecycle?

    // SwiftUI's @Query observes SwiftData directly — no manual reactivity needed
    @Query(sort: \PersistedRoom.createdAt, order: .reverse)
    private var persistedRooms: [PersistedRoom]

    private var rooms: [RoomLifecycle] {
        persistedRooms.compactMap { $0.toRoomLifecycle() }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if !store.initialLoadCompleted || acceptingShare {
                    ProgressView(acceptingShare ? "Locating room..." : "")
                } else if rooms.isEmpty {
                    ContentUnavailableView {
                        Label("Open a Room", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Start a group chat with Lightward AI. Everyone takes turns — including Lightward.")
                    } actions: {
                        Button {
                            showCreateRoom = true
                        } label: {
                            Text("Create Room")
                        }
                        .softerProminent()
                    }
                } else {
                    List(selection: $selectedRoomID) {
                        ForEach(persistedRooms, id: \.id) { room in
                            if let lifecycle = room.toRoomLifecycle() {
                            NavigationLink(value: lifecycle.spec.id) {
                                RoomRow(lifecycle: lifecycle, turnIndex: Message.turnIndex(in: room.messages()))
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    roomToDelete = lifecycle
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if let urlString = room.shareURL,
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
                    selectedRoomID = roomID
                }
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
                selectedRoomID = roomID
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
        } detail: {
            if let selectedRoomID {
                RoomView(store: store, roomID: selectedRoomID, selectedRoomID: $selectedRoomID)
            } else {
                ContentUnavailableView("Select a Room", systemImage: "bubble.left.and.bubble.right")
            }
        }
        #if os(macOS)
        .toolbar(removing: .title)
        #endif
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
    let turnIndex: Int  // Message.turnIndex(in:) — the ledger fold

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
        guard case .active = lifecycle.state, !lifecycle.spec.participants.isEmpty else { return nil }
        return turnIndex % lifecycle.spec.participants.count
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
        case .active:
            guard let participant = lifecycle.spec.turnParticipant(at: turnIndex) else { return "Active" }
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

