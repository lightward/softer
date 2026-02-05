import XCTest
@testable import Softer

final class ChatLogBuilderTests: XCTestCase {
    func testBuildsWithWarmupAndMessages() {
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "Hello everyone"),
            Message(roomID: "room1", authorID: "Lightward", authorName: "Lightward", text: "Hi Alice!", isLightward: true),
            Message(roomID: "room1", authorID: "Bob", authorName: "Bob", text: "Hey there"),
        ]

        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Bob", "Lightward"]
        )

        // Should have warmup + messages
        XCTAssertFalse(chatLog.isEmpty)

        // First message should be user role (warmup with cache_control)
        XCTAssertEqual(chatLog[0]["role"] as? String, "user")

        // Warmup should have cache_control somewhere (on the room context block, not README)
        let warmupBlocks = chatLog[0]["content"] as? [[String: Any]]
        let hasCacheControl = warmupBlocks?.contains { $0["cache_control"] != nil } ?? false
        XCTAssertTrue(hasCacheControl, "Warmup should have cache_control on one of its blocks")

        // Should have at least one assistant message (Lightward)
        let assistantMessages = chatLog.filter { $0["role"] as? String == "assistant" }
        XCTAssertFalse(assistantMessages.isEmpty)
    }

    func testHumanMessagesHaveAttribution() {
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "Hello"),
        ]

        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"]
        )

        // Find the user message with the actual conversation content
        let userMessages = chatLog.filter { $0["role"] as? String == "user" }
        let lastUserMessage = userMessages.last!
        let content = extractTextContent(from: lastUserMessage)

        XCTAssertTrue(content.contains("Alice:"), "User messages should have author attribution")
        XCTAssertTrue(content.contains("Hello"))
    }

    func testLightwardMessagesAreAssistantRole() {
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "Hi"),
            Message(roomID: "room1", authorID: "Lightward", authorName: "Lightward", text: "Hello!", isLightward: true),
        ]

        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"]
        )

        let assistantMessages = chatLog.filter { $0["role"] as? String == "assistant" }
        XCTAssertFalse(assistantMessages.isEmpty)

        let content = extractTextContent(from: assistantMessages[0])
        XCTAssertEqual(content, "Hello!")
    }

    func testHandRaiseProbeUsesProbeWarmup() {
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "What do you think?"),
        ]

        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"],
            isHandRaiseProbe: true
        )

        // The warmup should mention RAISE/PASS
        let firstContent = extractTextContent(from: chatLog[0])
        XCTAssertTrue(firstContent.contains("RAISE") || firstContent.contains("PASS"))
    }

    func testEmptyMessagesStillHasWarmup() {
        let chatLog = ChatLogBuilder.build(
            messages: [],
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"]
        )

        XCTAssertFalse(chatLog.isEmpty)
        XCTAssertEqual(chatLog[0]["role"] as? String, "user")
    }

    func testConsecutiveUserMessagesMerged() {
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "First"),
            Message(roomID: "room1", authorID: "Bob", authorName: "Bob", text: "Second"),
        ]

        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Bob", "Lightward"]
        )

        // Warmup has cache_control so won't be merged with conversation messages
        // Conversation messages (both user role) should be in a second user message
        let userMessages = chatLog.filter { $0["role"] as? String == "user" }
        XCTAssertEqual(userMessages.count, 2) // warmup + merged conversation

        // The second user message should contain both Alice and Bob
        let conversationContent = extractTextContent(from: userMessages[1])
        XCTAssertTrue(conversationContent.contains("Alice: First"))
        XCTAssertTrue(conversationContent.contains("Bob: Second"))
    }

    // MARK: - Content Format Tests (regression)

    func testAllMessagesHaveContentBlockFormat() {
        // Regression: API requires content to be array of blocks, not plain strings
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "Hello"),
            Message(roomID: "room1", authorID: "Lightward", authorName: "Lightward", text: "Hi!", isLightward: true),
        ]

        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"]
        )

        for msg in chatLog {
            let content = msg["content"]
            XCTAssertTrue(content is [[String: Any]], "Content must be array of blocks, got: \(type(of: content))")

            if let blocks = content as? [[String: Any]] {
                for block in blocks {
                    XCTAssertEqual(block["type"] as? String, "text", "Each block must have type: text")
                    XCTAssertNotNil(block["text"], "Each block must have text field")
                }
            }
        }
    }

    func testCacheControlPreservedAfterMerge() {
        // Regression: warmup has cache_control, must not be stripped when merging consecutive user messages
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "Hello"),
        ]

        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Lightward"]
        )

        // Find the warmup message (first one with cache_control)
        var foundCacheControl = false
        for msg in chatLog {
            if let blocks = msg["content"] as? [[String: Any]] {
                for block in blocks {
                    if block["cache_control"] != nil {
                        foundCacheControl = true
                        break
                    }
                }
            }
        }

        XCTAssertTrue(foundCacheControl, "cache_control marker must be preserved in the chat log")
    }

    func testMergedMessagesPreserveBlockFormat() {
        // Regression: when merging consecutive same-role messages, must keep block format
        let messages = [
            Message(roomID: "room1", authorID: "Alice", authorName: "Alice", text: "First"),
            Message(roomID: "room1", authorID: "Bob", authorName: "Bob", text: "Second"),
        ]

        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: "Test Room",
            participantNames: ["Alice", "Bob", "Lightward"]
        )

        // All messages should have content as array of blocks
        for msg in chatLog {
            XCTAssertTrue(msg["content"] is [[String: Any]], "Merged messages must maintain block format")
        }
    }

    // MARK: - Helpers

    private func extractTextContent(from message: [String: Any]) -> String {
        if let text = message["content"] as? String {
            return text
        }
        if let blocks = message["content"] as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
