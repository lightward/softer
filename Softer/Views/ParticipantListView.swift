import SwiftUI
import CloudKit

struct ParticipantListView: View {
    let roomID: String
    let cloudKitManager: CloudKitManager
    @State private var existingShare: CKShare?
    @State private var roomRecord: CKRecord?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Participants") {
                ForEach(participants) { participant in
                    HStack {
                        Image(systemName: participant.isLightward ? "sparkle" : "person.circle")
                            .foregroundStyle(participant.isLightward ? .blue : .primary)
                        VStack(alignment: .leading) {
                            Text(participant.name)
                                .font(.body)
                            if participant.isLightward {
                                Text("AI Participant")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                if isLoading {
                    HStack {
                        Text("Loading...")
                        Spacer()
                        ProgressView()
                    }
                } else if let existingShare = existingShare {
                    ManageShareButton(
                        share: existingShare,
                        container: CKContainer(identifier: Constants.containerIdentifier),
                        roomName: roomRecord?["name"] as? String ?? "a Softer room"
                    )
                } else if let roomRecord = roomRecord {
                    InviteButton(
                        roomRecord: roomRecord,
                        container: CKContainer(identifier: Constants.containerIdentifier)
                    ) { share in
                        self.existingShare = share
                    }
                } else {
                    Text("Unable to load sharing options")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            #if DEBUG
            Section("Debug") {
                Text("Room ID: \(roomID)")
                    .font(.caption)
                Text("Room record: \(roomRecord != nil ? "loaded" : "nil")")
                    .font(.caption)
                Text("Existing share: \(existingShare != nil ? "yes" : "no")")
                    .font(.caption)
            }
            #endif
        }
        .navigationTitle("Participants")
        .task {
            await loadShareStatus()
        }
    }

    private var participants: [Participant] {
        cloudKitManager.participants(for: roomID)
    }

    private func loadShareStatus() async {
        print("[ParticipantListView] Loading share status for room: \(roomID)")
        isLoading = true
        defer { isLoading = false }

        do {
            roomRecord = try await cloudKitManager.fetchRoomRecord(roomID: roomID)
            print("[ParticipantListView] Room record loaded: \(roomRecord != nil)")

            if let record = roomRecord {
                existingShare = try await cloudKitManager.fetchExistingShare(for: record)
                print("[ParticipantListView] Existing share: \(existingShare != nil)")
            }
        } catch {
            print("[ParticipantListView] Failed to load share status: \(error)")
            errorMessage = "Failed to load room: \(error.localizedDescription)"
        }
    }
}
