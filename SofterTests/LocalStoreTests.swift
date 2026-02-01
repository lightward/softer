import XCTest
@testable import Softer

final class LocalStoreTests: XCTestCase {

    // MARK: - Room Tests

    func testAllRoomsInitiallyEmpty() async {
        let store = LocalStore()
        let rooms = await store.allRooms
        XCTAssertTrue(rooms.isEmpty)
    }

    func testUpsertRoomAddsNewRoom() async {
        let store = LocalStore()
        let lifecycle = makeLifecycle(id: "room1")

        await store.upsertRoom(lifecycle)

        let rooms = await store.allRooms
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms.first?.spec.id, "room1")
    }

    func testUpsertRoomUpdatesExistingRoom() async {
        let store = LocalStore()
        let original = makeLifecycle(id: "room1", turnIndex: 0)
        let updated = makeLifecycle(id: "room1", turnIndex: 2)

        await store.upsertRoom(original)
        await store.upsertRoom(updated)

        let room = await store.room(id: "room1")
        XCTAssertEqual(room?.turnState?.currentTurnIndex, 2)
    }

    func testUpsertRoomsAddsMultiple() async {
        let store = LocalStore()
        let rooms = [
            makeLifecycle(id: "room1"),
            makeLifecycle(id: "room2"),
            makeLifecycle(id: "room3")
        ]

        await store.upsertRooms(rooms)

        let allRooms = await store.allRooms
        XCTAssertEqual(allRooms.count, 3)
    }

    func testDeleteRoomRemovesRoom() async {
        let store = LocalStore()
        await store.upsertRoom(makeLifecycle(id: "room1"))
        await store.upsertRoom(makeLifecycle(id: "room2"))

        await store.deleteRoom(id: "room1")

        let rooms = await store.allRooms
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms.first?.spec.id, "room2")
    }

    func testDefunctRoomsExcludedFromAllRooms() async {
        let store = LocalStore()
        let active = makeLifecycle(id: "room1", state: .active(turn: .initial))
        let defunct = makeDefunctLifecycle(id: "room2")

        await store.upsertRoom(active)
        await store.upsertRoom(defunct)

        let rooms = await store.allRooms
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms.first?.spec.id, "room1")
    }

    // MARK: - Message Tests

    func testMessagesInitiallyEmpty() async {
        let store = LocalStore()
        let messages = await store.messages(roomID: "room1")
        XCTAssertTrue(messages.isEmpty)
    }

    func testAddMessageStoresMessage() async {
        let store = LocalStore()
        let message = makeMessage(id: "msg1", roomID: "room1")

        await store.addMessage(message)

        let messages = await store.messages(roomID: "room1")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, "msg1")
    }

    func testAddMessageDeduplicates() async {
        let store = LocalStore()
        let message = makeMessage(id: "msg1", roomID: "room1")

        await store.addMessage(message)
        await store.addMessage(message)

        let messages = await store.messages(roomID: "room1")
        XCTAssertEqual(messages.count, 1)
    }

    func testAddMessagesSortsChronologically() async {
        let store = LocalStore()
        let older = makeMessage(id: "msg1", roomID: "room1", createdAt: Date(timeIntervalSince1970: 100))
        let newer = makeMessage(id: "msg2", roomID: "room1", createdAt: Date(timeIntervalSince1970: 200))

        await store.addMessage(newer)
        await store.addMessage(older)

        let messages = await store.messages(roomID: "room1")
        XCTAssertEqual(messages.map { $0.id }, ["msg1", "msg2"])
    }

    func testSetMessagesReplacesAll() async {
        let store = LocalStore()
        await store.addMessage(makeMessage(id: "msg1", roomID: "room1"))

        let newMessages = [
            makeMessage(id: "msg2", roomID: "room1"),
            makeMessage(id: "msg3", roomID: "room1")
        ]
        await store.setMessages(newMessages, roomID: "room1")

        let messages = await store.messages(roomID: "room1")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(Set(messages.map { $0.id }), ["msg2", "msg3"])
    }

    func testDeleteRoomRemovesMessages() async {
        let store = LocalStore()
        await store.upsertRoom(makeLifecycle(id: "room1"))
        await store.addMessage(makeMessage(id: "msg1", roomID: "room1"))

        await store.deleteRoom(id: "room1")

        let messages = await store.messages(roomID: "room1")
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - Merge Tests

    func testMergeUsesHigherTurnIndex() async {
        let store = LocalStore()
        let local = makeLifecycle(id: "room1", turnIndex: 3, modifiedAt: Date(timeIntervalSince1970: 100))
        let remote = makeLifecycle(id: "room1", turnIndex: 2, modifiedAt: Date(timeIntervalSince1970: 200))

        await store.upsertRoom(local)
        await store.upsertRoom(remote)

        let room = await store.room(id: "room1")
        // Higher turn index wins (3 > 2)
        XCTAssertEqual(room?.turnState?.currentTurnIndex, 3)
    }

    func testMergeUnionsRaisedHands() async {
        let store = LocalStore()
        let local = makeLifecycle(id: "room1", raisedHands: ["user1"], modifiedAt: Date(timeIntervalSince1970: 100))
        let remote = makeLifecycle(id: "room1", raisedHands: ["user2"], modifiedAt: Date(timeIntervalSince1970: 200))

        await store.upsertRoom(local)
        await store.upsertRoom(remote)

        let room = await store.room(id: "room1")
        // Union of raised hands
        XCTAssertEqual(room?.turnState?.raisedHands, ["user1", "user2"])
    }

    // MARK: - Observation Tests

    func testObserveRoomsReturnsInitialRooms() async {
        let store = LocalStore()
        await store.upsertRoom(makeLifecycle(id: "room1"))

        let (initial, _) = await store.observeRooms()

        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial.first?.spec.id, "room1")
    }

    func testObserveRoomsStreamsChanges() async {
        let store = LocalStore()

        let (_, stream) = await store.observeRooms()

        // Start listening
        let expectation = XCTestExpectation(description: "Received room update")
        let task = Task {
            for await rooms in stream {
                if rooms.count == 1 {
                    expectation.fulfill()
                    break
                }
            }
        }

        // Add a room
        await store.upsertRoom(makeLifecycle(id: "room1"))

        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()
    }

    func testObserveMessagesReturnsInitialMessages() async {
        let store = LocalStore()
        await store.addMessage(makeMessage(id: "msg1", roomID: "room1"))

        let (initial, _) = await store.observeMessages(roomID: "room1")

        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial.first?.id, "msg1")
    }

    func testObserveMessagesStreamsNewMessages() async {
        let store = LocalStore()

        let (_, stream) = await store.observeMessages(roomID: "room1")

        let expectation = XCTestExpectation(description: "Received message update")
        let task = Task {
            for await messages in stream {
                if messages.count == 1 {
                    expectation.fulfill()
                    break
                }
            }
        }

        await store.addMessage(makeMessage(id: "msg1", roomID: "room1"))

        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()
    }

    // MARK: - Reset Test

    func testResetClearsAllData() async {
        let store = LocalStore()
        await store.upsertRoom(makeLifecycle(id: "room1"))
        await store.addMessage(makeMessage(id: "msg1", roomID: "room1"))

        await store.reset()

        let rooms = await store.allRooms
        let messages = await store.messages(roomID: "room1")
        XCTAssertTrue(rooms.isEmpty)
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - Helpers

    private func makeLifecycle(
        id: String,
        state: RoomState = .active(turn: .initial),
        turnIndex: Int = 0,
        raisedHands: Set<String> = [],
        modifiedAt: Date = Date()
    ) -> RoomLifecycle {
        let spec = RoomSpec(
            id: id,
            originatorID: "originator",
            participants: [
                ParticipantSpec(identifier: .currentUser, nickname: "Me"),
                ParticipantSpec.lightward(nickname: "Lightward")
            ],
            tier: .ten,
            isFirstRoom: true
        )

        let finalState: RoomState
        switch state {
        case .active:
            let turn = TurnState(currentTurnIndex: turnIndex, raisedHands: raisedHands, currentNeed: nil)
            finalState = .active(turn: turn)
        default:
            finalState = state
        }

        return RoomLifecycle(spec: spec, state: finalState, modifiedAt: modifiedAt)
    }

    private func makeDefunctLifecycle(id: String) -> RoomLifecycle {
        let spec = RoomSpec(
            id: id,
            originatorID: "originator",
            participants: [ParticipantSpec.lightward(nickname: "Lightward")],
            tier: .ten,
            isFirstRoom: true
        )
        return RoomLifecycle(spec: spec, state: .defunct(reason: .cancelled))
    }

    private func makeMessage(
        id: String,
        roomID: String,
        createdAt: Date = Date()
    ) -> Message {
        Message(
            id: id,
            roomID: roomID,
            authorID: "author1",
            authorName: "Author",
            text: "Test message",
            createdAt: createdAt
        )
    }
}
