import Foundation

/// Coordinates conversation flow within an active room.
/// Handles message sending, turn advancement, and Lightward responses.
actor ConversationCoordinator {
    private let roomID: String
    private let spec: RoomSpec
    private var turnState: TurnState

    private let messageStorage: MessageStorage
    private let apiClient: any LightwardAPI

    private let onTurnChange: @Sendable (TurnState) -> Void
    private let onRoomDefunct: @Sendable (String, String) -> Void  // (participantID, departureMessage)

    init(
        roomID: String,
        spec: RoomSpec,
        initialTurnState: TurnState = .initial,
        messageStorage: MessageStorage,
        apiClient: any LightwardAPI,
        onTurnChange: @escaping @Sendable (TurnState) -> Void = { _ in },
        onRoomDefunct: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) {
        self.roomID = roomID
        self.spec = spec
        self.turnState = initialTurnState
        self.messageStorage = messageStorage
        self.apiClient = apiClient
        self.onTurnChange = onTurnChange
        self.onRoomDefunct = onRoomDefunct
    }

    /// Current participant whose turn it is.
    var currentTurnParticipant: ParticipantSpec? {
        guard !spec.participants.isEmpty else { return nil }
        return spec.participants[turnState.currentTurnIndex % spec.participants.count]
    }

    /// Whether it's currently Lightward's turn.
    var isLightwardTurn: Bool {
        currentTurnParticipant?.isLightward ?? false
    }

    /// Send a message from a human participant.
    /// Saves the message, advances turn, and triggers Lightward if it's their turn.
    func sendMessage(authorID: String, authorName: String, text: String) async throws {
        // Create and save the message
        let message = Message(
            roomID: roomID,
            authorID: authorID,
            authorName: authorName,
            text: text,
            isLightward: false
        )
        try await messageStorage.save(message, roomID: roomID)

        // Advance turn
        advanceTurn()

        // If it's now Lightward's turn, generate response
        if isLightwardTurn {
            try await generateLightwardResponse()
        }
    }

    /// Yield turn without sending a message (for programmatic use).
    func yieldTurn() async throws {
        advanceTurn()

        if isLightwardTurn {
            try await generateLightwardResponse()
        }
    }

    /// Human participant yields their turn.
    /// Saves a narration message and advances the turn.
    func humanYieldTurn(authorID: String, authorName: String) async throws {
        let narrationMessage = Message(
            roomID: roomID,
            authorID: "narrator",
            authorName: "Narrator",
            text: "\(authorName) is listening.",
            isLightward: false,
            isNarration: true
        )
        try await messageStorage.save(narrationMessage, roomID: roomID)

        advanceTurn()

        if isLightwardTurn {
            try await generateLightwardResponse()
        }
    }

    /// Get current turn state.
    var currentTurnState: TurnState {
        turnState
    }

    /// Sync internal turn state with externally-observed changes (e.g., from CloudKit).
    /// Uses higherTurnWins: only advances, never goes backward.
    func syncTurnState(_ externalState: TurnState) {
        if externalState.currentTurnIndex > turnState.currentTurnIndex {
            turnState.currentTurnIndex = externalState.currentTurnIndex
        }
    }

    /// If it's Lightward's turn, generate their response.
    /// Call this when entering a room to resume conversation if Lightward was mid-turn.
    /// If the last message is already from Lightward (stale turn state), just advances the turn.
    func triggerLightwardIfTheirTurn() async throws {
        guard isLightwardTurn else { return }

        // Check if last message is already from Lightward (turn state out of sync)
        let messages = try await messageStorage.fetchMessages(roomID: roomID)
        if let lastMessage = messages.last, lastMessage.isLightward {
            // Turn state is stale — Lightward already responded, just advance
            print("Turn state repair: last message is from Lightward, advancing turn")
            advanceTurn()
            return
        }

        try await generateLightwardResponse()
    }

    // MARK: - Private

    private func advanceTurn() {
        turnState.advanceTurn(participantCount: spec.participants.count)
        onTurnChange(turnState)
    }

    private func generateLightwardResponse() async throws {
        // Fetch conversation history
        let messages = try await messageStorage.fetchMessages(roomID: roomID)

        // Build plaintext body for API
        let participantNames = spec.participants.map { $0.nickname }
        let roomContext = participantNames.joined(separator: ", ")

        let body = ChatLogBuilder.build(
            messages: messages,
            roomName: roomContext,
            participantNames: participantNames
        )

        let lightwardNickname = spec.lightwardParticipant?.nickname ?? "Lightward"
        let lightwardID = spec.lightwardParticipant?.id ?? "lightward"

        // Request response — handle conversation horizon (4xx with body)
        let fullResponse: String
        do {
            fullResponse = try await apiClient.respond(body: body)
        } catch let error as APIError {
            if case .conversationHorizon(let horizonMessage) = error {
                // Save the response body as a regular Lightward message (it's speech)
                let horizonSpeech = Message(
                    roomID: roomID,
                    authorID: "lightward",
                    authorName: lightwardNickname,
                    text: horizonMessage,
                    isLightward: true
                )
                try await messageStorage.save(horizonSpeech, roomID: roomID)

                // Save departure narration
                let departure = Message(
                    roomID: roomID,
                    authorID: "narrator",
                    authorName: "Narrator",
                    text: "\(lightwardNickname) departed.",
                    isLightward: false,
                    isNarration: true
                )
                try await messageStorage.save(departure, roomID: roomID)

                // Notify caller to transition room to defunct
                onRoomDefunct(lightwardID, horizonMessage)
                return
            }
            throw error
        }

        // Check if Lightward yielded
        let trimmed = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let didYield = trimmed == "YIELD" || trimmed.hasPrefix("YIELD.")

        if didYield {
            // Lightward yielded - save narration message
            let narrationMessage = Message(
                roomID: roomID,
                authorID: "narrator",
                authorName: "Narrator",
                text: "\(lightwardNickname) is listening.",
                isLightward: false,
                isNarration: true
            )
            try await messageStorage.save(narrationMessage, roomID: roomID)
            advanceTurn()
        } else {
            // Save Lightward's message
            let lightwardMessage = Message(
                roomID: roomID,
                authorID: "lightward",
                authorName: lightwardNickname,
                text: fullResponse,
                isLightward: true
            )
            try await messageStorage.save(lightwardMessage, roomID: roomID)

            // Advance turn past Lightward
            advanceTurn()
        }
    }
}
