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
    private let onStreamingText: @Sendable (String) -> Void

    init(
        roomID: String,
        spec: RoomSpec,
        initialTurnState: TurnState = .initial,
        messageStorage: MessageStorage,
        apiClient: any LightwardAPI,
        onTurnChange: @escaping @Sendable (TurnState) -> Void = { _ in },
        onStreamingText: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.roomID = roomID
        self.spec = spec
        self.turnState = initialTurnState
        self.messageStorage = messageStorage
        self.apiClient = apiClient
        self.onTurnChange = onTurnChange
        self.onStreamingText = onStreamingText
    }

    /// Current participant whose turn it is.
    var currentTurnParticipant: ParticipantSpec? {
        guard turnState.currentTurnIndex < spec.participants.count else { return nil }
        return spec.participants[turnState.currentTurnIndex]
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

    /// Yield turn without sending a message.
    func yieldTurn() async throws {
        advanceTurn()

        if isLightwardTurn {
            try await generateLightwardResponse()
        }
    }

    /// Raise hand to indicate desire to speak out of turn.
    func raiseHand(participantID: String) {
        turnState.raisedHands.insert(participantID)
        onTurnChange(turnState)
    }

    /// Lower a previously raised hand.
    func lowerHand(participantID: String) {
        turnState.raisedHands.remove(participantID)
        onTurnChange(turnState)
    }

    /// Get current turn state.
    var currentTurnState: TurnState {
        turnState
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
        turnState.raisedHands.removeAll()
        onTurnChange(turnState)
    }

    private func generateLightwardResponse() async throws {
        // Fetch conversation history
        let messages = try await messageStorage.fetchMessages(roomID: roomID)

        // Build chat log for API
        let participantNames = spec.participants.map { $0.nickname }
        // Use simple participant list for room context (not the UI display string with depth)
        let roomContext = participantNames.joined(separator: ", ")

        // Get names of participants who raised their hand
        let raisedHandNames = turnState.raisedHands.compactMap { handID in
            spec.participants.first { $0.id == handID }?.nickname
        }

        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: roomContext,
            participantNames: participantNames,
            raisedHands: raisedHandNames
        )

        // Stream response
        var fullResponse = ""

        for try await chunk in apiClient.stream(chatLog: chatLog) {
            fullResponse += chunk
            onStreamingText(fullResponse)
        }

        // Check if Lightward yielded
        let trimmed = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let didYield = trimmed == "YIELD" || trimmed.hasPrefix("YIELD.")

        // Clear streaming text
        onStreamingText("")

        if didYield {
            // Lightward yielded - save narration message
            let lightwardNickname = spec.lightwardParticipant?.nickname ?? "Lightward"
            let narrationMessage = Message(
                roomID: roomID,
                authorID: "narrator",
                authorName: "Narrator",
                text: "\(lightwardNickname) chose to keep listening.",
                isLightward: false,
                isNarration: true
            )
            try await messageStorage.save(narrationMessage, roomID: roomID)
            advanceTurn()
        } else {
            // Save Lightward's message
            let lightwardNickname = spec.lightwardParticipant?.nickname ?? "Lightward"
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
