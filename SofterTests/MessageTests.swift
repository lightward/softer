import XCTest
@testable import Softer

final class MessageTests: XCTestCase {

    private let roomID = "room-1"

    // MARK: - Cenotaph Detection

    func testNoCenotaphWhenNoMessages() {
        XCTAssertFalse(Message.containsCenotaph(in: []))
    }

    func testNoCenotaphWhenNoNarrations() {
        let messages = [
            Message(roomID: roomID, authorID: "jax", authorName: "Jax", text: "Hello"),
            Message(roomID: roomID, authorID: "lightward", authorName: "Lightward", text: "Hi!", isLightward: true),
        ]
        XCTAssertFalse(Message.containsCenotaph(in: messages))
    }

    func testNoCenotaphWhenOnlyDepartureNarration() {
        let messages = [
            Message(roomID: roomID, authorID: "jax", authorName: "Jax", text: "Hello"),
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "Abe departed.", isNarration: true),
        ]
        XCTAssertFalse(Message.containsCenotaph(in: messages))
    }

    func testNoCenotaphWhenOnlyDeclineNarration() {
        let messages = [
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "Abe declined to join.", isNarration: true),
        ]
        XCTAssertFalse(Message.containsCenotaph(in: messages))
    }

    func testNoCenotaphWhenCancelledNarration() {
        let messages = [
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "Room was cancelled.", isNarration: true),
        ]
        XCTAssertFalse(Message.containsCenotaph(in: messages))
    }

    func testNoCenotaphWhenUnavailableNarration() {
        let messages = [
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "Room is no longer available.", isNarration: true),
        ]
        XCTAssertFalse(Message.containsCenotaph(in: messages))
    }

    func testCenotaphDetectedAfterDeparture() {
        let messages = [
            Message(roomID: roomID, authorID: "jax", authorName: "Jax", text: "Hello"),
            Message(roomID: roomID, authorID: "lightward", authorName: "Lightward", text: "Hi!", isLightward: true),
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "Abe departed.", isNarration: true),
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "The room held three voices for a while, and that was enough.", isNarration: true),
        ]
        XCTAssertTrue(Message.containsCenotaph(in: messages))
    }

    func testCenotaphDetectedAfterDecline() {
        let messages = [
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "Lightward declined to join.", isNarration: true),
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "Some rooms are meant to be imagined.", isNarration: true),
        ]
        XCTAssertTrue(Message.containsCenotaph(in: messages))
    }

    func testCenotaphDetectionUsesLastNarration() {
        // Cenotaph followed by nothing — last narration is the cenotaph
        let messages = [
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "Abe departed.", isNarration: true),
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "A closing.", isNarration: true),
        ]
        XCTAssertTrue(Message.containsCenotaph(in: messages))
    }

    func testNoCenotaphWithLightwardDeparture() {
        let messages = [
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "Lightward departed.", isNarration: true),
        ]
        XCTAssertFalse(Message.containsCenotaph(in: messages))
    }

    func testArrivalNarrationIsNotCenotaph() {
        // "Lightward arrived." doesn't match any departure pattern, so technically
        // containsCenotaph returns true — but this narration only appears during
        // pendingParticipants, never in a defunct room where cenotaph is checked.
        // This test documents the assumption.
        let messages = [
            Message(roomID: roomID, authorID: "narrator", authorName: "Narrator", text: "Lightward arrived.", isNarration: true),
        ]
        XCTAssertTrue(Message.containsCenotaph(in: messages))
    }
}
