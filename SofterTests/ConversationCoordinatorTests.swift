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
            tier: .ten,
            isFirstRoom: false
        )
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
            tier: .ten,
            isFirstRoom: false
        )

        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            messageStorage: storage,
            apiClient: api
        )

        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello everyone"
        )

        let savedCount = await storage.saveCallCount
        XCTAssertEqual(savedCount, 1)

        let saved = await storage.savedMessages
        XCTAssertEqual(saved[0].text, "Hello everyone")
        XCTAssertEqual(saved[0].authorName, "Jax")
        XCTAssertFalse(saved[0].isLightward)
    }

    func testSendMessageAdvancesTurn() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        let spec = makeSpec()

        var turnChanges: [TurnState] = []
        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 0, raisedHands: [], currentNeed: nil),
            messageStorage: storage,
            apiClient: api,
            onTurnChange: { turn in
                turnChanges.append(turn)
            }
        )

        // Jax sends message, turn should advance to Lightward (index 1)
        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // Turn advanced to Lightward, then Lightward responded, then advanced to Mira
        // So we should end at index 2 (Mira)
        let finalTurn = await coordinator.currentTurnState
        XCTAssertEqual(finalTurn.currentTurnIndex, 2)
    }

    func testLightwardTurnTriggersAPICall() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        let spec = makeSpec()

        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 0, raisedHands: [], currentNeed: nil),
            messageStorage: storage,
            apiClient: api
        )

        // Jax sends message, which advances to Lightward's turn
        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello Lightward"
        )

        XCTAssertEqual(api.streamCallCount, 1)
    }

    func testLightwardResponseIsSaved() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.responseChunks = ["Hello from Lightward!"]
        let spec = makeSpec()

        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 0, raisedHands: [], currentNeed: nil),
            messageStorage: storage,
            apiClient: api
        )

        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // Should have saved 2 messages: Jax's and Lightward's response
        let savedCount = await storage.saveCallCount
        XCTAssertEqual(savedCount, 2)

        let saved = await storage.savedMessages
        XCTAssertEqual(saved[1].text, "Hello from Lightward!")
        XCTAssertTrue(saved[1].isLightward)
    }

    func testStreamingTextUpdates() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.responseChunks = ["Hello ", "world!"]
        let spec = makeSpec()

        // Thread-safe collector (no Task spawning needed)
        let collector = StreamingCollector()
        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 0, raisedHands: [], currentNeed: nil),
            messageStorage: storage,
            apiClient: api,
            onStreamingText: { text in
                collector.append(text)
            }
        )

        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // Should have received streaming updates: "Hello " then "Hello world!"
        let updates = collector.updates
        XCTAssertTrue(updates.contains("Hello "))
        XCTAssertTrue(updates.contains("Hello world!"))
    }

    func testYieldTurnWithoutMessage() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        let spec = makeSpec()

        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 0, raisedHands: [], currentNeed: nil),
            messageStorage: storage,
            apiClient: api
        )

        try await coordinator.yieldTurn()

        // Should not have saved any human message
        let saveCount = await storage.saveCallCount
        // But Lightward responded, so should have 1 save
        XCTAssertEqual(saveCount, 1)

        let saved = await storage.savedMessages
        XCTAssertTrue(saved[0].isLightward)
    }

    func testRaiseHand() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        let spec = makeSpec()

        var lastTurnState: TurnState?
        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            messageStorage: storage,
            apiClient: api,
            onTurnChange: { turn in
                lastTurnState = turn
            }
        )

        await coordinator.raiseHand(participantID: "mira-id")

        XCTAssertNotNil(lastTurnState)
        XCTAssertTrue(lastTurnState!.raisedHands.contains("mira-id"))
    }

    func testLowerHand() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        let spec = makeSpec()

        var lastTurnState: TurnState?
        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 0, raisedHands: ["mira-id"], currentNeed: nil),
            messageStorage: storage,
            apiClient: api,
            onTurnChange: { turn in
                lastTurnState = turn
            }
        )

        await coordinator.lowerHand(participantID: "mira-id")

        XCTAssertNotNil(lastTurnState)
        XCTAssertFalse(lastTurnState!.raisedHands.contains("mira-id"))
    }

    func testTurnWrapsAfterFullCycle() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        api.responseChunks = ["Response"]
        let spec = makeSpec() // Jax(0), Lightward(1), Mira(2)

        var turnChanges: [TurnState] = []
        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 0, raisedHands: [], currentNeed: nil),
            messageStorage: storage,
            apiClient: api,
            onTurnChange: { turn in
                turnChanges.append(turn)
            }
        )

        // Round 1: Jax sends → Lightward responds → Mira's turn (index 2)
        try await coordinator.sendMessage(authorID: "jax-id", authorName: "Jax", text: "Hello")
        var turn = await coordinator.currentTurnState
        XCTAssertEqual(turn.currentTurnIndex, 2, "After Jax+Lightward, should be Mira (index 2)")

        // Mira sends → Lightward's turn again (index 3 % 3 = 0... no, index 3 = Jax)
        // Wait: Jax(0), Lightward(1), Mira(2) — index 3 % 3 = Jax
        try await coordinator.sendMessage(authorID: "mira-id", authorName: "Mira", text: "Hi")
        turn = await coordinator.currentTurnState
        // Mira sent (index 2→3), index 3 % 3 = 0 = Jax — not Lightward, so no auto-response
        XCTAssertEqual(turn.currentTurnIndex, 3, "After Mira, should be Jax again (index 3)")

        // Verify it's Jax's turn (wrapping works)
        let current = await coordinator.currentTurnParticipant
        XCTAssertEqual(current?.nickname, "Jax")

        // Round 2: Jax sends again → Lightward responds → Mira
        try await coordinator.sendMessage(authorID: "jax-id", authorName: "Jax", text: "Again")
        turn = await coordinator.currentTurnState
        XCTAssertEqual(turn.currentTurnIndex, 5, "After second Jax+Lightward, should be Mira (index 5)")

        let current2 = await coordinator.currentTurnParticipant
        XCTAssertEqual(current2?.nickname, "Mira")
    }

    func testSyncTurnStateFromRemote() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        let spec = makeSpec() // Jax(0), Lightward(1), Mira(2)

        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 0, raisedHands: [], currentNeed: nil),
            messageStorage: storage,
            apiClient: api
        )

        // Simulate remote sync: another device advanced to turn 2 (Mira)
        await coordinator.syncTurnState(TurnState(currentTurnIndex: 2, raisedHands: [], currentNeed: nil))

        // Mira sends → should advance from 2 to 3 (Jax), NOT from 0 to 1 (Lightward)
        try await coordinator.sendMessage(authorID: "mira-id", authorName: "Mira", text: "Hi from Mira")

        let turn = await coordinator.currentTurnState
        // turn 2→3, 3%3=0=Jax — not Lightward, so no auto-response
        XCTAssertEqual(turn.currentTurnIndex, 3)
        let current = await coordinator.currentTurnParticipant
        XCTAssertEqual(current?.nickname, "Jax")
        // Lightward API should NOT have been called
        XCTAssertEqual(api.streamCallCount, 0)
    }

    func testSyncTurnStateNeverGoesBackward() async throws {
        let storage = MockMessageStorage()
        let api = MockLightwardAPIClient()
        let spec = makeSpec()

        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 5, raisedHands: [], currentNeed: nil),
            messageStorage: storage,
            apiClient: api
        )

        // Stale remote data with lower turn index should be ignored
        await coordinator.syncTurnState(TurnState(currentTurnIndex: 2, raisedHands: [], currentNeed: nil))

        let turn = await coordinator.currentTurnState
        XCTAssertEqual(turn.currentTurnIndex, 5, "Should not go backward")
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
            tier: .one,
            isFirstRoom: true
        )

        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 0, raisedHands: [], currentNeed: nil),
            messageStorage: storage,
            apiClient: api
        )

        // Jax sends message, turn advances to Mira (not Lightward)
        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // API should NOT have been called since it's Mira's turn, not Lightward's
        XCTAssertEqual(api.streamCallCount, 0)

        // Should be Mira's turn
        let finalTurn = await coordinator.currentTurnState
        XCTAssertEqual(finalTurn.currentTurnIndex, 1)
    }
}

// MARK: - Test Helpers

/// Thread-safe collector for streaming text updates.
/// Uses a lock instead of actor to avoid Task spawning in callbacks.
private final class StreamingCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _updates: [String] = []

    var updates: [String] {
        lock.withLock { _updates }
    }

    func append(_ text: String) {
        lock.withLock { _updates.append(text) }
    }
}
