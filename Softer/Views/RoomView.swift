import SwiftUI

struct RoomView: View {
    let coordinator: AppCoordinator
    let roomID: String

    @State private var lifecycle: RoomLifecycle?
    @State private var messages: [Message] = []
    @State private var composeText = ""
    @State private var streamingText = ""
    @State private var isLoading = true
    @State private var turnState: TurnState?
    @State private var conversationCoordinator: ConversationCoordinator?
    @State private var observationToken: ObservationToken?
    @State private var isSending = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let lifecycle = lifecycle {
                conversationView(lifecycle: lifecycle)
            } else {
                ContentUnavailableView("Room not found", systemImage: "exclamationmark.triangle")
            }
        }
        .task {
            await loadRoom()
        }
        .onDisappear {
            observationToken?.cancel()
        }
    }

    @ViewBuilder
    private func conversationView(lifecycle: RoomLifecycle) -> some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(
                                message: message,
                                isLightward: message.authorName == Constants.lightwardParticipantName
                            )
                            .id(message.id)
                        }

                        // Streaming text from Lightward
                        if !streamingText.isEmpty {
                            MessageBubble(
                                text: streamingText,
                                authorName: lifecycle.spec.lightwardParticipant?.nickname ?? "Lightward",
                                isLightward: true,
                                isStreaming: true
                            )
                            .id("streaming")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: streamingText) {
                    if !streamingText.isEmpty {
                        withAnimation {
                            proxy.scrollTo("streaming", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Compose area
            if lifecycle.isActive {
                composeArea(lifecycle: lifecycle)
            } else if lifecycle.isLocked {
                lockedBanner(lifecycle: lifecycle)
            }
        }
        .navigationTitle(navigationTitle(for: lifecycle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func navigationTitle(for lifecycle: RoomLifecycle) -> String {
        lifecycle.spec.participants.map { $0.nickname }.joined(separator: ", ")
    }

    @ViewBuilder
    private func composeArea(lifecycle: RoomLifecycle) -> some View {
        VStack(spacing: 8) {
            // Turn indicator
            if let turnIdx = turnState?.currentTurnIndex,
               turnIdx < lifecycle.spec.participants.count {
                let current = lifecycle.spec.participants[turnIdx]
                Text("\(current.nickname)'s turn")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                TextField("Message...", text: $composeText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .disabled(!isMyTurn(lifecycle: lifecycle) || isSending)

                Button {
                    Task {
                        await sendMessage(lifecycle: lifecycle)
                    }
                } label: {
                    Image(systemName: isSending ? "ellipsis.circle" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isMyTurn(lifecycle: lifecycle) || isSending)
            }
            .padding()
        }
        .background(.bar)
    }

    @ViewBuilder
    private func lockedBanner(lifecycle: RoomLifecycle) -> some View {
        if case .locked(let cenotaph, _) = lifecycle.state {
            VStack(spacing: 8) {
                Text("Room Complete")
                    .font(.headline)
                if !cenotaph.isEmpty {
                    Text(cenotaph)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func isMyTurn(lifecycle: RoomLifecycle) -> Bool {
        guard let turnIdx = turnState?.currentTurnIndex,
              turnIdx < lifecycle.spec.participants.count else { return false }

        let current = lifecycle.spec.participants[turnIdx]
        // For now, assume local user is the first human participant
        // In production, would match against actual CloudKit user
        let localParticipant = lifecycle.spec.humanParticipants.first
        return current.id == localParticipant?.id
    }

    private func loadRoom() async {
        isLoading = true
        do {
            lifecycle = try await coordinator.room(id: roomID)

            // Set up conversation coordinator if room is active
            if let lifecycle = lifecycle {
                let convCoord = coordinator.conversationCoordinator(
                    for: lifecycle,
                    onTurnChange: { [self] newState in
                        Task { @MainActor in
                            turnState = newState
                        }
                    },
                    onStreamingText: { [self] text in
                        Task { @MainActor in
                            streamingText = text
                        }
                    }
                )
                conversationCoordinator = convCoord
                turnState = lifecycle.turnState

                // Observe messages
                if let storage = coordinator.getMessageStorage() {
                    let token = await storage.observeMessages(roomID: roomID) { msgs in
                        Task { @MainActor in
                            messages = msgs
                        }
                    }
                    observationToken = token
                }
            }
        } catch {
            print("Failed to load room: \(error)")
        }
        isLoading = false
    }

    private func sendMessage(lifecycle: RoomLifecycle) async {
        guard let convCoord = conversationCoordinator else { return }

        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let authorName = lifecycle.spec.humanParticipants.first?.nickname ?? "Me"
        let authorID = lifecycle.spec.humanParticipants.first?.id ?? "unknown"

        composeText = ""
        isSending = true

        do {
            try await convCoord.sendMessage(
                authorID: authorID,
                authorName: authorName,
                text: text
            )
        } catch {
            print("Failed to send message: \(error)")
        }

        isSending = false
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let text: String
    let authorName: String
    let isLightward: Bool
    var isStreaming: Bool = false

    init(message: Message, isLightward: Bool) {
        self.text = message.text
        self.authorName = message.authorName
        self.isLightward = isLightward
        self.isStreaming = false
    }

    init(text: String, authorName: String, isLightward: Bool, isStreaming: Bool = false) {
        self.text = text
        self.authorName = authorName
        self.isLightward = isLightward
        self.isStreaming = isStreaming
    }

    var body: some View {
        HStack {
            if !isLightward { Spacer(minLength: 40) }

            VStack(alignment: isLightward ? .leading : .trailing, spacing: 4) {
                Text(authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isLightward ? Color(.systemGray5) : Color.accentColor)
                    .foregroundColor(isLightward ? .primary : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if isStreaming {
                    HStack(spacing: 4) {
                        Circle().frame(width: 4, height: 4)
                        Circle().frame(width: 4, height: 4)
                        Circle().frame(width: 4, height: 4)
                    }
                    .foregroundStyle(.secondary)
                    .opacity(0.5)
                }
            }

            if isLightward { Spacer(minLength: 40) }
        }
    }
}
