import SwiftUI

struct CreateRoomView: View {
    let store: SofterStore
    @Binding var isPresented: Bool
    var onCreated: ((String) -> Void)? = nil

    // Form state
    @State private var myNickname = ""
    @State private var otherParticipants: [ParticipantEntry] = []
    @State private var selectedTier: PaymentTier = .ten

    // Creation state
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var cachedIsFirstRoom: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your nickname", text: $myNickname)
                        .textContentType(.givenName)

                    // Lightward is always present
                    HStack {
                        Text("Lightward")
                        Spacer()
                        Image(systemName: "sparkles")
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)

                    ForEach($otherParticipants) { $entry in
                        ParticipantEntryRow(entry: $entry) {
                            otherParticipants.removeAll { $0.id == entry.id }
                        }
                    }

                    Button {
                        otherParticipants.append(ParticipantEntry())
                    } label: {
                        Label("Add someone else", systemImage: "plus")
                    }
                } header: {
                    Text("Participants")
                }

                Section {
                    if cachedIsFirstRoom ?? isFirstRoom {
                        Text("Your first room is free")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    } else {
                        Picker("Amount", selection: $selectedTier) {
                            ForEach(PaymentTier.allCases, id: \.self) { tier in
                                Text(tier.displayString).tag(tier)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: {
                    Text("Payment")
                }
                .onAppear {
                    if cachedIsFirstRoom == nil {
                        cachedIsFirstRoom = isFirstRoom
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
        store.rooms.filter { $0.isActive || $0.isLocked }.isEmpty
    }

    private var isValid: Bool {
        !myNickname.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func createRoom() async {
        isCreating = true
        errorMessage = nil

        // Build participant list
        var participants: [ParticipantSpec] = []

        // Add self (resolves to current user's CloudKit record ID)
        let selfSpec = ParticipantSpec(
            identifier: .currentUser,
            nickname: myNickname.trimmingCharacters(in: .whitespaces)
        )
        participants.append(selfSpec)

        // Add Lightward (always "Lightward")
        participants.append(ParticipantSpec.lightward(nickname: "Lightward"))

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
            let lifecycle = try await store.createRoom(
                participants: participants,
                tier: selectedTier,
                originatorNickname: myNickname
            )
            isPresented = false
            onCreated?(lifecycle.spec.id)
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

struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    init(_ text: String, action: @escaping () -> Void) {
        self.text = text
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
