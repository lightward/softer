import SwiftUI
import CloudKit

struct ParticipantListView: View {
    let roomID: String
    let cloudKitManager: CloudKitManager
    @State private var showInvite = false
    @State private var share: CKShare?
    @State private var isLoadingShare = false

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
                    Task { await prepareShare() }
                } label: {
                    HStack {
                        Image(systemName: "person.badge.plus")
                        Text("Invite Someone")
                        if isLoadingShare {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isLoadingShare)
            }
        }
        .navigationTitle("Participants")
        .sheet(isPresented: $showInvite) {
            if let share = share {
                InviteView(
                    share: share,
                    container: CKContainer(identifier: Constants.containerIdentifier)
                )
            }
        }
    }

    private var participants: [Participant] {
        cloudKitManager.participants(for: roomID)
    }

    private func prepareShare() async {
        isLoadingShare = true
        defer { isLoadingShare = false }

        do {
            if let existingShare = share {
                self.share = existingShare
            } else {
                self.share = try await cloudKitManager.createShareForRoom(roomID: roomID)
            }
            showInvite = true
        } catch {
            print("Failed to create share: \(error)")
        }
    }
}
