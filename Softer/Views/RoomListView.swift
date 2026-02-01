import SwiftUI

struct RoomListView: View {
    let coordinator: AppCoordinator
    @State private var showCreateRoom = false

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.rooms.isEmpty {
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
                    List(coordinator.rooms, id: \.spec.id) { lifecycle in
                        NavigationLink(value: lifecycle.spec.id) {
                            RoomRow(lifecycle: lifecycle)
                        }
                    }
                }
            }
            .navigationTitle("Softer")
            .toolbar {
                if !coordinator.rooms.isEmpty {
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
                CreateRoomView(coordinator: coordinator, isPresented: $showCreateRoom)
            }
            .navigationDestination(for: String.self) { roomID in
                RoomView(coordinator: coordinator, roomID: roomID)
            }
            .refreshable {
                await coordinator.loadRooms()
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
