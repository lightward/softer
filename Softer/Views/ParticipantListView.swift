import SwiftUI
import CloudKit

struct ParticipantListView: View {
    let roomID: String
    let cloudKitManager: CloudKitManager
    @State private var showInvite = false
    @State private var existingShare: CKShare?
    @State private var roomRecord: CKRecord?
    @State private var isLoading = false
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
                Button {
                    Task { await prepareInvite() }
                } label: {
                    HStack {
                        Image(systemName: "person.badge.plus")
                        Text(existingShare != nil ? "Manage Sharing" : "Invite Someone")
                        if isLoading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isLoading)
            }

            if let errorMessage = errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Participants")
        .task {
            await loadShareStatus()
        }
        .sheet(isPresented: $showInvite) {
            if let existingShare = existingShare {
                InviteView.forExistingShare(share: existingShare)
            } else if let roomRecord = roomRecord {
                InviteView.forNewShare(roomRecord: roomRecord) { share in
                    self.existingShare = share
                }
            }
        }
    }

    private var participants: [Participant] {
        cloudKitManager.participants(for: roomID)
    }

    private func loadShareStatus() async {
        do {
            // Fetch the room record
            roomRecord = try await cloudKitManager.fetchRoomRecord(roomID: roomID)

            // Check if a share already exists
            if let record = roomRecord {
                existingShare = try await cloudKitManager.fetchExistingShare(for: record)
            }
        } catch {
            print("Failed to load share status: \(error)")
        }
    }

    private func prepareInvite() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Make sure we have the room record
            if roomRecord == nil {
                roomRecord = try await cloudKitManager.fetchRoomRecord(roomID: roomID)
            }

            guard roomRecord != nil || existingShare != nil else {
                errorMessage = "Could not load room data"
                return
            }

            showInvite = true
        } catch {
            errorMessage = "Failed to prepare invite: \(error.localizedDescription)"
            print("Failed to prepare invite: \(error)")
        }
    }
}
