import SwiftUI

struct CreateRoomView: View {
    let coordinator: AppCoordinator
    @Binding var isPresented: Bool

    // Form state
    @State private var myNickname = ""
    @State private var lightwardNickname = "Lightward"
    @State private var otherParticipants: [ParticipantEntry] = []
    @State private var selectedTier: PaymentTier = .ten

    // Creation state
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    TextField("Your nickname", text: $myNickname)
                        .textContentType(.name)
                }

                Section("Lightward") {
                    TextField("Lightward's nickname", text: $lightwardNickname)
                }

                Section("Other Participants") {
                    ForEach($otherParticipants) { $entry in
                        ParticipantEntryRow(entry: $entry) {
                            otherParticipants.removeAll { $0.id == entry.id }
                        }
                    }

                    Button {
                        otherParticipants.append(ParticipantEntry())
                    } label: {
                        Label("Add Participant", systemImage: "plus")
                    }
                }

                Section("Payment") {
                    Picker("Amount", selection: $selectedTier) {
                        ForEach(PaymentTier.allCases, id: \.self) { tier in
                            Text(tier.displayString).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)

                    if isFirstRoom {
                        Text("First room is free!")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .disabled(isCreating)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task {
                                await createRoom()
                            }
                        }
                        .disabled(!isValid)
                    }
                }
            }
        }
    }

    private var isFirstRoom: Bool {
        coordinator.rooms.filter { $0.isActive || $0.isLocked }.isEmpty
    }

    private var isValid: Bool {
        !myNickname.trimmingCharacters(in: .whitespaces).isEmpty &&
        !lightwardNickname.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func createRoom() async {
        isCreating = true
        errorMessage = nil

        // Build participant list
        var participants: [ParticipantSpec] = []

        // Add self (will resolve from local user)
        // For now, using a placeholder identifier - in production would use actual user email/phone
        let selfSpec = ParticipantSpec(
            identifier: .email("placeholder@local"),  // Will be resolved from CloudKit user
            nickname: myNickname.trimmingCharacters(in: .whitespaces)
        )
        participants.append(selfSpec)

        // Add Lightward
        participants.append(ParticipantSpec.lightward(
            nickname: lightwardNickname.trimmingCharacters(in: .whitespaces)
        ))

        // Add other participants
        for entry in otherParticipants {
            guard !entry.identifier.isEmpty, !entry.nickname.isEmpty else { continue }

            let identifier: ParticipantIdentifier
            if entry.identifier.contains("@") {
                identifier = .email(entry.identifier)
            } else {
                identifier = .phone(entry.identifier)
            }

            participants.append(ParticipantSpec(
                identifier: identifier,
                nickname: entry.nickname.trimmingCharacters(in: .whitespaces)
            ))
        }

        do {
            _ = try await coordinator.createRoom(
                participants: participants,
                tier: selectedTier,
                originatorNickname: myNickname
            )
            isPresented = false
        } catch let error as RoomLifecycleError {
            errorMessage = describeError(error)
        } catch {
            errorMessage = error.localizedDescription
        }

        isCreating = false
    }

    private func describeError(_ error: RoomLifecycleError) -> String {
        switch error {
        case .resolutionFailed(let participantID, _):
            return "Couldn't find participant: \(participantID)"
        case .paymentAuthorizationFailed:
            return "Payment authorization failed"
        case .paymentCaptureFailed:
            return "Payment capture failed"
        case .lightwardDeclined:
            return "Lightward chose not to join this room"
        case .cancelled:
            return "Room creation was cancelled"
        case .expired:
            return "Room creation expired"
        case .invalidState:
            return "Something went wrong. Please try again."
        }
    }
}

// MARK: - Supporting Types

struct ParticipantEntry: Identifiable {
    let id = UUID()
    var identifier = ""  // email or phone
    var nickname = ""
}

struct ParticipantEntryRow: View {
    @Binding var entry: ParticipantEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            TextField("Email or phone", text: $entry.identifier)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)

            TextField("Nickname", text: $entry.nickname)
                .textContentType(.name)
        }
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
