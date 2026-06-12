import Foundation

/// Coordinates conversation flow within an active room.
/// Handles message sending and Lightward responses.
///
/// Turn state is never stored: the current turn index is a fold over the
/// message ledger (`Message.turnIndex(in:)`) — the count of turn-consuming
/// messages. Devices that share a ledger agree on the turn with no merge
/// policy and nothing to repair, and every machine-generated write is keyed
/// by causal position, so settling twice (or from two devices at once)
/// collapses in the union-by-ID merge.
actor ConversationCoordinator {
    private let roomID: String
    private let spec: RoomSpec

    private let messageStorage: MessageStorage
    private let apiClient: any LightwardAPI

    private let onRoomDefunct: @Sendable (String, String) -> Void  // (participantID, departureMessage)

    init(
        roomID: String,
        spec: RoomSpec,
        messageStorage: MessageStorage,
        apiClient: any LightwardAPI,
        onRoomDefunct: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) {
        self.roomID = roomID
        self.spec = spec
        self.messageStorage = messageStorage
        self.apiClient = apiClient
        self.onRoomDefunct = onRoomDefunct
    }

    /// Send a message from a human participant, then settle the turn.
    func sendMessage(authorID: String, authorName: String, text: String) async throws {
        let message = Message(
            roomID: roomID,
            authorID: authorID,
            authorName: authorName,
            text: text,
            isLightward: false
        )
        try await messageStorage.save(message, roomID: roomID)
        try await settle()
    }

    /// Human participant yields their turn: the narration consumes the slot.
    func humanYieldTurn(authorID: String, authorName: String) async throws {
        let turnIndex = try await currentTurnIndex()
        let narrationMessage = Message(
            id: Message.StableID.yieldNarration(roomID: roomID, turnIndex: turnIndex),
            roomID: roomID,
            authorID: "narrator",
            authorName: "Narrator",
            text: "\(authorName) is listening.",
            isLightward: false,
            isNarration: true
        )
        try await messageStorage.save(narrationMessage, roomID: roomID)
        try await settle()
    }

    /// Read the ledger and do whatever the turn now requires: orient the
    /// first round, and generate Lightward's response if the ledger points
    /// at them. Idempotent — safe to call on entering a room, after any
    /// send, or from multiple devices.
    func settle() async throws {
        let index = try await currentTurnIndex()

        // During the first round, narrate turn changes to orient participants
        if index > 0 && index < spec.participants.count,
           let next = spec.turnParticipant(at: index) {
            let narration = Message(
                id: Message.StableID.turnIntro(roomID: roomID, turnIndex: index),
                roomID: roomID,
                authorID: "narrator",
                authorName: "Narrator",
                text: "\(next.nickname), it's your turn.",
                isLightward: false,
                isNarration: true
            )
            try await messageStorage.save(narration, roomID: roomID)
        }

        if spec.turnParticipant(at: index)?.isLightward == true {
            try await generateLightwardResponse()
        }
    }

    // MARK: - Private

    private func currentTurnIndex() async throws -> Int {
        Message.turnIndex(in: try await messageStorage.fetchMessages(roomID: roomID))
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

        // The turn slot being settled. Stable message IDs are keyed to it so
        // racing devices generating this same turn mint the same IDs and the
        // union-by-ID merge collapses the duplicates — exactly one outcome
        // per slot survives.
        let turnIndex = Message.turnIndex(in: messages)

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
                    id: Message.StableID.lightwardSpeech(roomID: roomID, turnIndex: turnIndex),
                    roomID: roomID,
                    authorID: "lightward",
                    authorName: lightwardNickname,
                    text: horizonMessage,
                    isLightward: true
                )
                try await messageStorage.save(horizonSpeech, roomID: roomID)

                // Save departure narration
                let departure = Message(
                    id: Message.StableID.departure(roomID: roomID, participantID: lightwardID),
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
            // Lightward yielded - save narration message (consumes the slot)
            let narrationMessage = Message(
                id: Message.StableID.yieldNarration(roomID: roomID, turnIndex: turnIndex),
                roomID: roomID,
                authorID: "narrator",
                authorName: "Narrator",
                text: "\(lightwardNickname) is listening.",
                isLightward: false,
                isNarration: true
            )
            try await messageStorage.save(narrationMessage, roomID: roomID)
            try await settle()
        } else if didDepart {
            // Lightward is voluntarily departing
            // Extract farewell text after "DEPART." if present
            let originalResponse = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if originalResponse.count > 7, originalResponse.uppercased().hasPrefix("DEPART.") {
                // Has farewell text — save as Lightward speech
                let farewell = String(originalResponse.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !farewell.isEmpty {
                    let farewellMessage = Message(
                        id: Message.StableID.lightwardSpeech(roomID: roomID, turnIndex: turnIndex),
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
                id: Message.StableID.departure(roomID: roomID, participantID: lightwardID),
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
            // Save Lightward's message (consumes the slot)
            let lightwardMessage = Message(
                id: Message.StableID.lightwardSpeech(roomID: roomID, turnIndex: turnIndex),
                roomID: roomID,
                authorID: "lightward",
                authorName: lightwardNickname,
                text: fullResponse,
                isLightward: true
            )
            try await messageStorage.save(lightwardMessage, roomID: roomID)
            try await settle()
        }
    }
}
