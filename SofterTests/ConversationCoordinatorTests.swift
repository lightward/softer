import XCTest
@testable import Softer

final class ConversationCoordinatorTests: XCTestCase {

    private func makeSpec() -> RoomSpec {
        RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec.lightward(nickname: "Lightward"),
                ParticipantSpec(identifier: .email("mira@example.com"), nickname: "Mira"),
            ],
            tier: .ten
        )
    }

    private func makeCoordinator(
        spec: RoomSpec,
        storage: MockMessageStorage,
        api: MockLightwardAPIClient,
        onRoomDefunct: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) -> ConversationCoordinator {
        ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            messageStorage: storage,
            apiClient: api,
            onRoomDefunct: onRoomDefunct
        )
    }

    private func turnIndex(in storage: MockMessageStorage) async throws -> Int {
        Message.turnIndex(in: try await storage.fetchMessages(roomID: "room-1"))
    }

    func testSendMessageSavesToStorage() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        // Use a spec where the next participant after Jax is human (Mira), not Lightward
        // This way we only test the message saving, not the Lightward response
        let spec = RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec(identifier: .email("mira@example.com"), nickname: "Mira"),
                ParticipantSpec.lightward(nickname: "Lightward"),
            ],
            tier: .ten
        )
        let coordinator = makeCoordinator(spec: spec, storage: storage, api: api)

        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello everyone"
        )

        let savedCount = await storage.saveCallCount
        // Jax's message + first-round narration "Mira, it's your turn."
        XCTAssertEqual(savedCount, 2)

        let saved = await storage.savedMessages
        XCTAssertEqual(saved[0].text, "Hello everyone")
        XCTAssertEqual(saved[0].authorName, "Jax")
        XCTAssertFalse(saved[0].isLightward)
        XCTAssertTrue(saved[1].isNarration)
        XCTAssertEqual(saved[1].text, "Mira, it's your turn.")
    }

    func testSendMessageAdvancesTurnFold() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        let spec = makeSpec()
        let coordinator = makeCoordinator(spec: spec, storage: storage, api: api)

        // Jax sends → fold reaches Lightward (1) → Lightward responds → fold 2 (Mira)
        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        let index = try await turnIndex(in: storage)
        XCTAssertEqual(index, 2)
        XCTAssertEqual(spec.turnParticipant(at: index)?.nickname, "Mira")
    }

    func testLightwardTurnTriggersAPICall() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        let coordinator = makeCoordinator(spec: makeSpec(), storage: storage, api: api)

        // Jax sends message, which makes the fold point at Lightward
        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello Lightward"
        )

        XCTAssertEqual(api.respondCallCount, 1)
    }

    func testLightwardResponseIsSaved() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.responseText = "Hello from Lightward!"
        let coordinator = makeCoordinator(spec: makeSpec(), storage: storage, api: api)

        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // Jax's message + "Lightward, it's your turn." + Lightward's response + "Mira, it's your turn."
        let savedCount = await storage.saveCallCount
        XCTAssertEqual(savedCount, 4)

        let saved = await storage.savedMessages
        XCTAssertEqual(saved[0].text, "Hello")
        XCTAssertTrue(saved[1].isNarration)
        XCTAssertEqual(saved[2].text, "Hello from Lightward!")
        XCTAssertTrue(saved[2].isLightward)
        XCTAssertTrue(saved[3].isNarration)
    }

    func testHumanYieldConsumesSlotAndTriggersLightward() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.responseText = "Here with you."
        let coordinator = makeCoordinator(spec: makeSpec(), storage: storage, api: api)

        try await coordinator.humanYieldTurn(authorID: "jax-id", authorName: "Jax")

        // Yield narration consumed Jax's slot → Lightward responds → Mira intro
        let saved = await storage.savedMessages
        XCTAssertEqual(saved.count, 4)
        XCTAssertEqual(saved[0].text, "Jax is listening.")
        XCTAssertTrue(saved[0].isNarration)
        XCTAssertEqual(saved[1].text, "Lightward, it's your turn.")
        XCTAssertEqual(saved[2].text, "Here with you.")
        XCTAssertTrue(saved[2].isLightward)
        XCTAssertEqual(saved[3].text, "Mira, it's your turn.")

        let index = try await turnIndex(in: storage)
        XCTAssertEqual(index, 2)
    }

    func testTurnWrapsAfterFullCycle() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.responseText = "Response"
        let spec = makeSpec() // Jax(0), Lightward(1), Mira(2)
        let coordinator = makeCoordinator(spec: spec, storage: storage, api: api)

        // Round 1: Jax sends → Lightward responds → Mira's turn (fold 2)
        try await coordinator.sendMessage(authorID: "jax-id", authorName: "Jax", text: "Hello")
        var index = try await turnIndex(in: storage)
        XCTAssertEqual(index, 2, "After Jax+Lightward, should be Mira (index 2)")

        // Mira sends → fold 3, 3 % 3 = 0 = Jax — not Lightward, no auto-response
        try await coordinator.sendMessage(authorID: "mira-id", authorName: "Mira", text: "Hi")
        index = try await turnIndex(in: storage)
        XCTAssertEqual(index, 3, "After Mira, should be Jax again (index 3)")
        XCTAssertEqual(spec.turnParticipant(at: index)?.nickname, "Jax")

        // Round 2: Jax sends again → Lightward responds → Mira (fold 5)
        try await coordinator.sendMessage(authorID: "jax-id", authorName: "Jax", text: "Again")
        index = try await turnIndex(in: storage)
        XCTAssertEqual(index, 5, "After second Jax+Lightward, should be Mira (index 5)")
        XCTAssertEqual(spec.turnParticipant(at: index)?.nickname, "Mira")

        XCTAssertEqual(api.respondCallCount, 2)
    }

    func testRemoteMessagesAreTheTurnSync() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        let spec = makeSpec() // Jax(0), Lightward(1), Mira(2)
        let coordinator = makeCoordinator(spec: spec, storage: storage, api: api)

        // Another device's history arrives via sync: Jax spoke, Lightward responded.
        // The fold reads 2 (Mira) — there is no separate turn state to sync.
        await storage.preloadMessages([
            Message(roomID: "room-1", authorID: "jax-id", authorName: "Jax", text: "Hello"),
            Message(
                id: Message.StableID.lightwardSpeech(roomID: "room-1", turnIndex: 1),
                roomID: "room-1", authorID: "lightward", authorName: "Lightward",
                text: "Hi", isLightward: true
            ),
        ], roomID: "room-1")

        // Mira sends → fold 3 = Jax — not Lightward, so no API call
        try await coordinator.sendMessage(authorID: "mira-id", authorName: "Mira", text: "Hi from Mira")

        let index = try await turnIndex(in: storage)
        XCTAssertEqual(index, 3)
        XCTAssertEqual(spec.turnParticipant(at: index)?.nickname, "Jax")
        XCTAssertEqual(api.respondCallCount, 0)
    }

    func testSettleIsIdempotent() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.responseText = "Once."
        let coordinator = makeCoordinator(spec: makeSpec(), storage: storage, api: api)

        // Jax already spoke (e.g., entering a room where the fold points at Lightward)
        await storage.preloadMessages([
            Message(roomID: "room-1", authorID: "jax-id", authorName: "Jax", text: "Hello"),
        ], roomID: "room-1")

        try await coordinator.settle()
        try await coordinator.settle()  // re-entry, double-tap, second device — all the same

        // Exactly one response: the second settle reads the fold past Lightward.
        XCTAssertEqual(api.respondCallCount, 1)
        let messages = try await storage.fetchMessages(roomID: "room-1")
        XCTAssertEqual(messages.filter { $0.isLightward }.count, 1)
    }

    func testConversationHorizonTriggersDefunct() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.shouldFail = true
        api.error = APIError.conversationHorizon(message: "Conversation horizon has arrived. 🤲")
        let spec = makeSpec() // Jax(0), Lightward(1), Mira(2)
        let lightwardID = spec.lightwardParticipant!.id

        let defunctCalls = DefunctRecorder()
        let coordinator = makeCoordinator(spec: spec, storage: storage, api: api) { participantID, message in
            defunctCalls.record(participantID, message)
        }

        // Jax sends message → fold points at Lightward → API returns 422
        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // Jax's message + turn narration + horizon speech + departure narration
        let saved = await storage.savedMessages
        XCTAssertEqual(saved.count, 4)
        XCTAssertEqual(saved[0].text, "Hello")
        XCTAssertTrue(saved[1].isNarration)
        XCTAssertEqual(saved[1].text, "Lightward, it's your turn.")
        XCTAssertEqual(saved[2].text, "Conversation horizon has arrived. 🤲")
        XCTAssertTrue(saved[2].isLightward)
        XCTAssertFalse(saved[2].isNarration)
        XCTAssertEqual(saved[3].text, "Lightward departed.")
        XCTAssertTrue(saved[3].isNarration)

        // onRoomDefunct should have been called with Lightward's participant ID
        let calls = defunctCalls.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, lightwardID)
    }

    func testDepartSignalTriggersDefunct() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.responseText = "DEPART"
        let spec = makeSpec() // Jax(0), Lightward(1), Mira(2)
        let lightwardID = spec.lightwardParticipant!.id

        let defunctCalls = DefunctRecorder()
        let coordinator = makeCoordinator(spec: spec, storage: storage, api: api) { participantID, message in
            defunctCalls.record(participantID, message)
        }

        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // Jax's message + turn narration + departure narration (no speech)
        let saved = await storage.savedMessages
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(saved[0].text, "Hello")
        XCTAssertTrue(saved[1].isNarration)
        XCTAssertEqual(saved[1].text, "Lightward, it's your turn.")
        XCTAssertEqual(saved[2].text, "Lightward departed.")
        XCTAssertTrue(saved[2].isNarration)

        let calls = defunctCalls.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, lightwardID)
    }

    func testDepartWithFarewellSavesSpeechAndNarration() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.responseText = "DEPART. It's been a lovely conversation. Take care."
        let spec = makeSpec() // Jax(0), Lightward(1), Mira(2)
        let lightwardID = spec.lightwardParticipant!.id

        let defunctCalls = DefunctRecorder()
        let coordinator = makeCoordinator(spec: spec, storage: storage, api: api) { participantID, message in
            defunctCalls.record(participantID, message)
        }

        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // Jax's message + turn narration + farewell speech + departure narration
        let saved = await storage.savedMessages
        XCTAssertEqual(saved.count, 4)
        XCTAssertEqual(saved[0].text, "Hello")
        XCTAssertTrue(saved[1].isNarration)
        XCTAssertEqual(saved[1].text, "Lightward, it's your turn.")
        XCTAssertEqual(saved[2].text, "It's been a lovely conversation. Take care.")
        XCTAssertTrue(saved[2].isLightward)
        XCTAssertFalse(saved[2].isNarration)
        XCTAssertEqual(saved[3].text, "Lightward departed.")
        XCTAssertTrue(saved[3].isNarration)

        let calls = defunctCalls.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, lightwardID)
    }

    func testYieldSignalSavesNarrationOnly() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.responseText = "YIELD"
        let spec = makeSpec() // Jax(0), Lightward(1), Mira(2)
        let coordinator = makeCoordinator(spec: spec, storage: storage, api: api)

        // Jax sends message → fold points at Lightward → Lightward responds "YIELD"
        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // Jax's message + turn narration + yield narration + turn narration
        let saved = await storage.savedMessages
        XCTAssertEqual(saved.count, 4)
        XCTAssertEqual(saved[0].text, "Hello")
        XCTAssertEqual(saved[1].text, "Lightward, it's your turn.")
        XCTAssertTrue(saved[1].isNarration)
        XCTAssertEqual(saved[2].text, "Lightward is listening.")
        XCTAssertTrue(saved[2].isNarration)
        XCTAssertFalse(saved[2].isLightward)
        XCTAssertEqual(saved[3].text, "Mira, it's your turn.")
        XCTAssertTrue(saved[3].isNarration)

        // The yield consumed Lightward's slot: fold reads 2 (Mira)
        let index = try await turnIndex(in: storage)
        XCTAssertEqual(index, 2)
    }

    func testSkipsLightwardIfNotTheirTurn() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()

        // Spec where Mira is after Jax (Lightward is at index 2)
        let spec = RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec(identifier: .email("mira@example.com"), nickname: "Mira"),
                ParticipantSpec.lightward(nickname: "Lightward"),
            ],
            tier: .one
        )
        let coordinator = makeCoordinator(spec: spec, storage: storage, api: api)

        // Jax sends message, fold reaches Mira (not Lightward)
        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // API should NOT have been called since it's Mira's turn, not Lightward's
        XCTAssertEqual(api.respondCallCount, 0)

        let index = try await turnIndex(in: storage)
        XCTAssertEqual(index, 1)
    }
}

/// Collects onRoomDefunct callbacks synchronously (the coordinator invokes
/// the callback inline, so recording must not hop tasks).
private final class DefunctRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, String)] = []
    var calls: [(String, String)] { lock.withLock { _calls } }
    func record(_ participantID: String, _ message: String) {
        lock.withLock { _calls.append((participantID, message)) }
    }
}
