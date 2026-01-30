import XCTest
@testable import Softer

final class TurnStateMachineTests: XCTestCase {
    func testAdvanceTurnAfterMessage() {
        var room = makeRoom(turnOrder: ["Alice", "Lightward", "Bob"], currentTurnIndex: 0)
        var machine = TurnStateMachine(room: room)

        let effects = machine.apply(event: .messageSent(authorID: "Alice"))

        XCTAssertEqual(machine.room.currentTurnIndex, 1)
        XCTAssertTrue(machine.room.raisedHands.isEmpty)
        // Next turn is Lightward, so should generate a lightwardTurn need
        XCTAssertEqual(effects, [.generateNeed(type: .lightwardTurn)])
    }

    func testAdvanceTurnToHuman() {
        var room = makeRoom(turnOrder: ["Alice", "Lightward", "Bob"], currentTurnIndex: 1)
        var machine = TurnStateMachine(room: room)

        let effects = machine.apply(event: .lightwardResponseCompleted(text: "Hello!"))

        XCTAssertEqual(machine.room.currentTurnIndex, 2)
        // Next turn is Bob (human), so should check hand raise
        XCTAssertEqual(effects, [.generateNeed(type: .handRaiseCheck)])
    }

    func testHandRaiseResult() {
        var room = makeRoom(turnOrder: ["Alice", "Lightward"], currentTurnIndex: 0)
        room.currentNeed = Need(type: .handRaiseCheck)
        var machine = TurnStateMachine(room: room)

        let _ = machine.apply(event: .handRaiseResult(participantID: "Lightward", wantsToSpeak: true))

        XCTAssertTrue(machine.room.raisedHands.contains("Lightward"))
        XCTAssertNil(machine.room.currentNeed)
    }

    func testHandRaisePassResult() {
        var room = makeRoom(turnOrder: ["Alice", "Lightward"], currentTurnIndex: 0)
        room.currentNeed = Need(type: .handRaiseCheck)
        var machine = TurnStateMachine(room: room)

        let _ = machine.apply(event: .handRaiseResult(participantID: "Lightward", wantsToSpeak: false))

        XCTAssertTrue(machine.room.raisedHands.isEmpty)
        XCTAssertNil(machine.room.currentNeed)
    }

    func testYieldTurnAdvances() {
        var room = makeRoom(turnOrder: ["Alice", "Lightward", "Bob"], currentTurnIndex: 0)
        var machine = TurnStateMachine(room: room)

        let effects = machine.apply(event: .turnYielded)

        XCTAssertEqual(machine.room.currentTurnIndex, 1)
        // Lightward's turn after yield
        XCTAssertEqual(effects, [.generateNeed(type: .lightwardTurn)])
    }

    func testPhaseForLocalUser() {
        let room = makeRoom(turnOrder: ["Alice", "Bob"], currentTurnIndex: 0)
        let machine = TurnStateMachine(room: room)

        XCTAssertEqual(machine.phase(for: "Alice"), .myTurn)
        XCTAssertEqual(machine.phase(for: "Bob"), .waitingForTurn)
    }

    func testPhaseForLightwardTurn() {
        let room = makeRoom(turnOrder: ["Alice", "Lightward"], currentTurnIndex: 1)
        let machine = TurnStateMachine(room: room)

        XCTAssertEqual(machine.phase(for: "Alice"), .lightwardThinking)
    }

    func testTurnWrapsAround() {
        var room = makeRoom(turnOrder: ["Alice", "Bob"], currentTurnIndex: 1)
        var machine = TurnStateMachine(room: room)

        let _ = machine.apply(event: .messageSent(authorID: "Bob"))

        XCTAssertEqual(machine.room.currentTurnIndex, 0)
    }

    func testNeedClaimedUpdatesRoom() {
        var room = makeRoom(turnOrder: ["Alice", "Lightward"], currentTurnIndex: 1)
        room.currentNeed = Need(type: .lightwardTurn)
        var machine = TurnStateMachine(room: room)

        let _ = machine.apply(event: .needClaimed(deviceID: "device-123"))

        XCTAssertEqual(machine.room.currentNeed?.claimedBy, "device-123")
        XCTAssertNotNil(machine.room.currentNeed?.claimedAt)
    }

    // MARK: - Helpers

    private func makeRoom(turnOrder: [String], currentTurnIndex: Int) -> Room {
        Room(
            name: "Test Room",
            turnOrder: turnOrder,
            currentTurnIndex: currentTurnIndex
        )
    }
}
