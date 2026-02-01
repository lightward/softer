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

        var streamingUpdates: [String] = []
        let coordinator = ConversationCoordinator(
            roomID: "room-1",
            spec: spec,
            initialTurnState: TurnState(currentTurnIndex: 0, raisedHands: [], currentNeed: nil),
            messageStorage: storage,
            apiClient: api,
            onStreamingText: { text in
                streamingUpdates.append(text)
            }
        )

        try await coordinator.sendMessage(
            authorID: "jax-id",
            authorName: "Jax",
            text: "Hello"
        )

        // Should have received streaming updates and then cleared
        XCTAssertTrue(streamingUpdates.contains("Hello "))
        XCTAssertTrue(streamingUpdates.contains("Hello world!"))
        XCTAssertEqual(streamingUpdates.last, "")  // Cleared at end
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
