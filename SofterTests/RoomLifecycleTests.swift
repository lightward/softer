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
        XCTAssertEqual(lifecycle.state, .active)
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
        return RoomLifecycle(spec: spec, state: .active)
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

    // MARK: - Turn Fold Tests

    func testTurnIndexIsAFoldOverConsumingMessages() {
        // Speech (human or Lightward) and yields consume a turn slot;
        // intros, hand raises, and other narrations are commentary.
        let roomID = "room-1"
        let messages = [
            Message(roomID: roomID, authorID: "jax-id", authorName: "Jax", text: "Hello"),
            Message(
                id: Message.StableID.turnIntro(roomID: roomID, turnIndex: 1),
                roomID: roomID, authorID: "narrator", authorName: "Narrator",
                text: "Lightward, it's your turn.", isNarration: true
            ),
            Message(
                id: Message.StableID.lightwardSpeech(roomID: roomID, turnIndex: 1),
                roomID: roomID, authorID: "lightward", authorName: "Lightward",
                text: "Hi", isLightward: true
            ),
            Message(
                id: Message.StableID.yieldNarration(roomID: roomID, turnIndex: 2),
                roomID: roomID, authorID: "narrator", authorName: "Narrator",
                text: "Mira is listening.", isNarration: true
            ),
            Message(
                id: Message.StableID.handRaise(roomID: roomID, participantID: "jax-id", turnIndex: 3),
                roomID: roomID, authorID: "narrator", authorName: "Narrator",
                text: "Jax raised a hand.", isNarration: true
            ),
        ]
        XCTAssertEqual(Message.turnIndex(in: messages), 3)
    }

    func testTurnFoldAgreesAcrossDevicesAfterUnion() {
        // Two devices observing the same ledger derive the same turn — the
        // message union IS the turn merge; there is no separate turn state.
        let a = Message(roomID: "r", authorID: "jax", authorName: "Jax", text: "Hi")
        let b = Message(
            id: Message.StableID.lightwardSpeech(roomID: "r", turnIndex: 1),
            roomID: "r", authorID: "lightward", authorName: "Lightward",
            text: "Hello", isLightward: true
        )
        let deviceA = RoomLifecycleRecordConverter.mergeMessages(local: [a], remote: [b])
        let deviceB = RoomLifecycleRecordConverter.mergeMessages(local: [b], remote: [a])
        XCTAssertEqual(Message.turnIndex(in: deviceA), Message.turnIndex(in: deviceB))
        XCTAssertEqual(Message.turnIndex(in: deviceA), 2)
    }
}
