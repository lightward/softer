import XCTest
@testable import Softer

final class ChatLogBuilderTests: XCTestCase {
    func testBuildsWithWarmupAndMessages() {
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "Hello everyone"),
            Message(roomID: "room1", authorID: "Lightward", authorName: "Lightward", text: "Hi Alice!", isLightward: true),
            Message(roomID: "room1", authorID: "Bob", authorName: "Bob", text: "Hey there"),
        ]

        let body = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Bob", "Lightward"]
        )

        // Should contain warmup content
        XCTAssertTrue(body.contains("hey amigo"))
        // Should contain conversation messages
        XCTAssertTrue(body.contains("Alice: Hello everyone"))
        XCTAssertTrue(body.contains("Hi Alice!"))  // Lightward's message without prefix
        XCTAssertTrue(body.contains("Bob: Hey there"))
        // Should end with narrator prompt
        XCTAssertTrue(body.contains("(your turn)"))
    }

    func testHumanMessagesHaveAttribution() {
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "Hello"),
        ]

        let body = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"]
        )

        XCTAssertTrue(body.contains("Alice: Hello"), "User messages should have author attribution")
    }

    func testLightwardMessagesHaveNoPrefix() {
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "Hi"),
            Message(roomID: "room1", authorID: "Lightward", authorName: "Lightward", text: "Hello!", isLightward: true),
        ]

        let body = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"]
        )

        // Lightward's message should appear without "Lightward:" prefix
        XCTAssertTrue(body.contains("Hello!"))
        XCTAssertFalse(body.contains("Lightward: Hello!"))
    }

    func testNarrationMessagesHaveNarratorPrefix() {
        let messages = [
            Message(roomID: "room1", authorID: "narrator", authorName: "Narrator", text: "Alice raised their hand.", isLightward: false, isNarration: true),
        ]

        let body = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"]
        )

        XCTAssertTrue(body.contains("Narrator: Alice raised their hand."))
    }

    func testEmptyMessagesStillHasWarmup() {
        let body = ChatLogBuilder.build(
            messages: [],
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"]
        )

        XCTAssertTrue(body.contains("hey amigo"))
        XCTAssertTrue(body.contains("(your turn)"))
    }

    func testParticipantRosterIncluded() {
        let body = ChatLogBuilder.build(
            messages: [],
            roomName: "Test Room",
            participantNames: ["Alice", "Bob", "Lightward"]
        )

        XCTAssertTrue(body.contains("1. Alice"))
        XCTAssertTrue(body.contains("2. Bob"))
        XCTAssertTrue(body.contains("3. Lightward (that's you!)"))
    }

    func testOutputIsPlaintext() {
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "Hello"),
        ]

        let body = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"]
        )

        // Should not contain JSON-like structures
        XCTAssertFalse(body.contains("\"role\""))
        XCTAssertFalse(body.contains("\"content\""))
        XCTAssertFalse(body.contains("cache_control"))
    }
}
