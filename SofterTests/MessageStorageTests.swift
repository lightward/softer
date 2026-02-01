import XCTest
@testable import Softer

final class MessageStorageTests: XCTestCase {

    func testSaveAndFetchMessages() async throws {
        let storage = MockMessageStorage()
        let roomID = "room-1"

        let message1 = Message(
            roomID: roomID,
            authorID: "user-1",
            authorName: "Jax",
            text: "Hello"
        )
        let message2 = Message(
            roomID: roomID,
            authorID: "lightward",
            authorName: "Lightward",
            text: "Hi Jax!",
            isLightward: true
        )

        try await storage.save(message1, roomID: roomID)
        try await storage.save(message2, roomID: roomID)

        let fetched = try await storage.fetchMessages(roomID: roomID)

        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(fetched[0].text, "Hello")
        XCTAssertEqual(fetched[1].text, "Hi Jax!")
    }

    func testFetchReturnsEmptyForNewRoom() async throws {
        let storage = MockMessageStorage()

        let messages = try await storage.fetchMessages(roomID: "empty-room")

        XCTAssertTrue(messages.isEmpty)
    }

    func testMessagesAreIsolatedByRoom() async throws {
        let storage = MockMessageStorage()

        let message1 = Message(
            roomID: "room-1",
            authorID: "user-1",
            authorName: "Jax",
            text: "In room 1"
        )
        let message2 = Message(
            roomID: "room-2",
            authorID: "user-2",
            authorName: "Mira",
            text: "In room 2"
        )

        try await storage.save(message1, roomID: "room-1")
        try await storage.save(message2, roomID: "room-2")

        let room1Messages = try await storage.fetchMessages(roomID: "room-1")
        let room2Messages = try await storage.fetchMessages(roomID: "room-2")

        XCTAssertEqual(room1Messages.count, 1)
        XCTAssertEqual(room1Messages[0].text, "In room 1")

        XCTAssertEqual(room2Messages.count, 1)
        XCTAssertEqual(room2Messages[0].text, "In room 2")
    }

    func testSaveFailureThrows() async {
        let storage = MockMessageStorage()
        await storage.setShouldFailSave(true)

        let message = Message(
            roomID: "room-1",
            authorID: "user-1",
            authorName: "Jax",
            text: "This will fail"
        )

        do {
            try await storage.save(message, roomID: "room-1")
            XCTFail("Expected save to throw")
        } catch {
            // Expected
            XCTAssertTrue(error is MockStorageError)
        }
    }

    func testFetchFailureThrows() async {
        let storage = MockMessageStorage()
        await storage.setShouldFailFetch(true)

        do {
            _ = try await storage.fetchMessages(roomID: "room-1")
            XCTFail("Expected fetch to throw")
        } catch {
            // Expected
            XCTAssertTrue(error is MockStorageError)
        }
    }

    func testObserveReceivesInitialMessages() async {
        let storage = MockMessageStorage()
        let roomID = "room-1"

        // Preload some messages
        let existing = Message(
            roomID: roomID,
            authorID: "user-1",
            authorName: "Jax",
            text: "Already here"
        )
        await storage.preloadMessages([existing], roomID: roomID)

        let expectation = XCTestExpectation(description: "Received initial messages")
        var receivedMessages: [Message] = []

        let token = await storage.observeMessages(roomID: roomID) { messages in
            receivedMessages = messages
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(receivedMessages.count, 1)
        XCTAssertEqual(receivedMessages[0].text, "Already here")

        token.cancel()
    }

    func testObserveReceivesNewMessages() async throws {
        let storage = MockMessageStorage()
        let roomID = "room-1"

        var receivedUpdates: [[Message]] = []
        let expectation = XCTestExpectation(description: "Received new message")
        expectation.expectedFulfillmentCount = 2  // Initial + new message

        let token = await storage.observeMessages(roomID: roomID) { messages in
            receivedUpdates.append(messages)
            expectation.fulfill()
        }

        // Save a new message
        let newMessage = Message(
            roomID: roomID,
            authorID: "user-1",
            authorName: "Jax",
            text: "New message"
        )
        try await storage.save(newMessage, roomID: roomID)

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(receivedUpdates.count, 2)
        XCTAssertTrue(receivedUpdates[0].isEmpty)  // Initial - empty room
        XCTAssertEqual(receivedUpdates[1].count, 1)  // After save
        XCTAssertEqual(receivedUpdates[1][0].text, "New message")

        token.cancel()
    }
}

// Extension to make mock properties settable from tests
extension MockMessageStorage {
    func setShouldFailSave(_ value: Bool) {
        shouldFailSave = value
    }

    func setShouldFailFetch(_ value: Bool) {
        shouldFailFetch = value
    }
}
