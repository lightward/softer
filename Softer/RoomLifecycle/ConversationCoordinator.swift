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
        try await advanceTurn()

        // If it's now Lightward's turn, generate response
        if isLightwardTurn {
            try await generateLightwardResponse()
        }
    }

    /// Yield turn without sending a message (for programmatic use).
    func yieldTurn() async throws {
        try await advanceTurn()

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

        try await advanceTurn()

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
            try await advanceTurn()
            return
        }

        try await generateLightwardResponse()
    }

    // MARK: - Private

    private func advanceTurn() async throws {
        turnState.advanceTurn(participantCount: spec.participants.count)
        onTurnChange(turnState)

        // During first round, narrate turn changes to orient participants
        let newIndex = turnState.currentTurnIndex
        if newIndex > 0 && newIndex < spec.participants.count {
            let nextParticipant = spec.participants[newIndex % spec.participants.count]
            let narration = Message(
                roomID: roomID,
                authorID: "narrator",
                authorName: "Narrator",
                text: "\(nextParticipant.nickname), it's your turn.",
                isLightward: false,
                isNarration: true
            )
            try await messageStorage.save(narration, roomID: roomID)
        }
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

        // Response detection order matters:
        // 1. Conversation horizon (API error with body) — caught before we have a response string
        // 2. YIELD — Lightward passes their turn, stays in the room
        // 3. DEPART — Lightward voluntarily leaves, room goes defunct
        // 4. Normal response — saved as speech
        // YIELD must precede DEPART so "I'll listen" isn't mistaken for departure.
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

        // Check for signal words in response
        let trimmed = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let didYield = trimmed == "YIELD" || trimmed.hasPrefix("YIELD.")
        let didDepart = trimmed == "DEPART" || trimmed.hasPrefix("DEPART.")

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
            try await advanceTurn()
        } else if didDepart {
            // Lightward is voluntarily departing
            // Extract farewell text after "DEPART." if present
            let originalResponse = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if originalResponse.count > 7, originalResponse.uppercased().hasPrefix("DEPART.") {
                // Has farewell text — save as Lightward speech
                let farewell = String(originalResponse.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !farewell.isEmpty {
                    let farewellMessage = Message(
                        roomID: roomID,
                        authorID: "lightward",
                        authorName: lightwardNickname,
                        text: farewell,
                        isLightward: true
                    )
                    try await messageStorage.save(farewellMessage, roomID: roomID)
                }
            }

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

            onRoomDefunct(lightwardID, "")
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
            try await advanceTurn()
        }
    }
}
