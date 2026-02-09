import XCTest
@testable import Softer

final class RoomLifecycleTests: XCTestCase {

    // MARK: - Happy Path

    func testHappyPathToActivation() {
        var lifecycle = makeLifecycle()

        // Start in draft
        XCTAssertEqual(lifecycle.state, .draft)

        // Resolve participants -> should request payment
        var effects = lifecycle.apply(event: .participantsResolved)
        XCTAssertEqual(effects, [.processPayment])

        // Payment completed -> move to pendingParticipants
        effects = lifecycle.apply(event: .paymentCompleted)
        XCTAssertEqual(lifecycle.state, .pendingParticipants(signaled: []))
        XCTAssertEqual(effects, [])

        // Lightward signals
        effects = lifecycle.apply(event: .signaled(participantID: "lightward-id"))
        XCTAssertEqual(lifecycle.state, .pendingParticipants(signaled: ["lightward-id"]))
        XCTAssertEqual(effects, [])

        // First human signals
        effects = lifecycle.apply(event: .signaled(participantID: "jax-id"))
        XCTAssertEqual(lifecycle.state, .pendingParticipants(signaled: ["lightward-id", "jax-id"]))
        XCTAssertEqual(effects, [])

        // Second human signals -> all present, directly active
        effects = lifecycle.apply(event: .signaled(participantID: "mira-id"))
        XCTAssertEqual(lifecycle.state, .active(turn: .initial))
        XCTAssertEqual(effects, [])
    }

    func testParticipantLeftFromActive() {
        var lifecycle = makeActiveLifecycle()

        let effects = lifecycle.apply(event: .participantLeft(participantID: "lightward-id"))

        XCTAssertEqual(lifecycle.state, .defunct(reason: .participantLeft(participantID: "lightward-id")))
        XCTAssertEqual(effects, [])
        XCTAssertTrue(lifecycle.isDefunct)
    }

    // MARK: - Participant Decline

    func testParticipantDeclineFromPendingParticipants() {
        var lifecycle = makeLifecycle()

        _ = lifecycle.apply(event: .participantsResolved)
        _ = lifecycle.apply(event: .paymentCompleted)

        let effects = lifecycle.apply(event: .participantDeclined(participantID: "lightward-id"))

        XCTAssertEqual(lifecycle.state, .defunct(reason: .participantDeclined(participantID: "lightward-id")))
        // No release effect — payment already completed (IAP is immediate)
        XCTAssertEqual(effects, [])
        XCTAssertTrue(lifecycle.isDefunct)
    }

    func testHumanDeclineFromPendingParticipants() {
        var lifecycle = makeLifecycleAtPendingParticipants()

        let effects = lifecycle.apply(event: .participantDeclined(participantID: "mira-id"))

        XCTAssertEqual(lifecycle.state, .defunct(reason: .participantDeclined(participantID: "mira-id")))
        XCTAssertEqual(effects, [])
    }

    // MARK: - Resolution Failure

    func testResolutionFailureStopsLifecycle() {
        var lifecycle = makeLifecycle()

        let effects = lifecycle.apply(event: .resolutionFailed(participantID: "unknown-person"))

        XCTAssertEqual(lifecycle.state, .defunct(reason: .resolutionFailed(participantID: "unknown-person")))
        XCTAssertEqual(effects, [])
    }

    // MARK: - Payment Failure

    func testPaymentFailure() {
        var lifecycle = makeLifecycle()

        _ = lifecycle.apply(event: .participantsResolved)
        let effects = lifecycle.apply(event: .paymentFailed)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .paymentFailed))
        XCTAssertEqual(effects, [])
    }

    // MARK: - Expiration

    func testExpirationDuringPendingParticipants() {
        var lifecycle = makeLifecycleAtPendingParticipants()

        let effects = lifecycle.apply(event: .expired)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .expired))
        // No release effect — payment already completed
        XCTAssertEqual(effects, [])
    }

    // MARK: - Cancellation

    func testCancellationFromDraft() {
        var lifecycle = makeLifecycle()

        let effects = lifecycle.apply(event: .cancelled)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .cancelled))
        XCTAssertEqual(effects, [])
    }

    func testCancellationFromPendingParticipants() {
        var lifecycle = makeLifecycleAtPendingParticipants()

        let effects = lifecycle.apply(event: .cancelled)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .cancelled))
        // No release effect — payment already completed
        XCTAssertEqual(effects, [])
    }

    // MARK: - State Queries

    func testUnsignaledParticipantsQuery() {
        var lifecycle = makeLifecycleAtPendingParticipants()

        XCTAssertEqual(lifecycle.unsignaledParticipants, ["jax-id", "mira-id", "lightward-id"])
        XCTAssertEqual(lifecycle.signaledParticipants, [])

        _ = lifecycle.apply(event: .signaled(participantID: "jax-id"))

        XCTAssertEqual(lifecycle.unsignaledParticipants, ["mira-id", "lightward-id"])
        XCTAssertEqual(lifecycle.signaledParticipants, ["jax-id"])
    }

    // MARK: - Helpers

    private func makeLifecycle() -> RoomLifecycle {
        let spec = RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(id: "jax-id", identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec(id: "mira-id", identifier: .email("mira@example.com"), nickname: "Mira"),
                ParticipantSpec(id: "lightward-id", identifier: .lightward, nickname: "Lightward")
            ],
            tier: .ten
        )
        return RoomLifecycle(spec: spec)
    }

    private func makeActiveLifecycle() -> RoomLifecycle {
        let spec = RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(id: "jax-id", identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec(id: "lightward-id", identifier: .lightward, nickname: "Lightward")
            ],
            tier: .one
        )
        return RoomLifecycle(spec: spec, state: .active(turn: .initial))
    }

    private func makeLifecycleAtPendingParticipants() -> RoomLifecycle {
        let spec = RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(id: "jax-id", identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec(id: "mira-id", identifier: .email("mira@example.com"), nickname: "Mira"),
                ParticipantSpec(id: "lightward-id", identifier: .lightward, nickname: "Lightward")
            ],
            tier: .ten
        )
        return RoomLifecycle(spec: spec, state: .pendingParticipants(signaled: []))
    }

    // MARK: - Turn State Tests

    func testTurnIndexGrowsWithoutWrapping() {
        // This test documents the fix: turn index must grow (not wrap with modulo)
        // so that higherTurnWins merge strategy works correctly with CloudKit sync
        var turn = TurnState.initial
        let participantCount = 2

        XCTAssertEqual(turn.currentTurnIndex, 0)

        turn.advanceTurn(participantCount: participantCount)
        XCTAssertEqual(turn.currentTurnIndex, 1)

        turn.advanceTurn(participantCount: participantCount)
        XCTAssertEqual(turn.currentTurnIndex, 2)  // NOT 0 - must grow for sync

        turn.advanceTurn(participantCount: participantCount)
        XCTAssertEqual(turn.currentTurnIndex, 3)  // NOT 1 - must grow for sync

        // Verify display logic still works via modulo
        XCTAssertEqual(turn.currentTurnIndex % participantCount, 1)
    }

    func testTurnIndexHigherWinsMergeScenario() {
        // Simulates the sync conflict that was causing "wrong turn" bug:
        // 1. Local advances turn 1→2 (back to first participant)
        // 2. Remote still has turn 1 from before the advance
        // 3. higherTurnWins should pick 2, not 1
        let participantCount = 2

        // Local state: just advanced from 1 to 2
        var localTurn = TurnState(currentTurnIndex: 1, currentNeed: nil)
        localTurn.advanceTurn(participantCount: participantCount)

        // Remote state: still at 1 (hasn't synced yet)
        let remoteTurn = TurnState(currentTurnIndex: 1, currentNeed: nil)

        // higherTurnWins merge
        let mergedIndex = max(localTurn.currentTurnIndex, remoteTurn.currentTurnIndex)

        XCTAssertEqual(localTurn.currentTurnIndex, 2)
        XCTAssertEqual(mergedIndex, 2)  // Should pick local's 2, not remote's 1
        XCTAssertEqual(mergedIndex % participantCount, 0)  // First participant's turn
    }
}
