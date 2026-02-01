import XCTest
@testable import Softer

final class RoomLifecycleTests: XCTestCase {

    // MARK: - Happy Path

    func testHappyPathToActivation() {
        var lifecycle = makeLifecycle()

        // Start in draft
        XCTAssertEqual(lifecycle.state, .draft)

        // Resolve participants -> should request payment authorization
        var effects = lifecycle.apply(event: .participantsResolved)
        XCTAssertEqual(effects, [.authorizePayment])

        // Payment authorized -> move to pending Lightward, request presence
        effects = lifecycle.apply(event: .paymentAuthorized)
        XCTAssertEqual(lifecycle.state, .pendingLightward)
        XCTAssertEqual(effects, [.requestLightwardPresence])

        // Lightward accepts -> move to pending humans, dispatch invites
        effects = lifecycle.apply(event: .lightwardAccepted)
        XCTAssertEqual(lifecycle.state, .pendingHumans(signaled: []))
        XCTAssertEqual(effects, [.dispatchInvites])

        // First human signals
        effects = lifecycle.apply(event: .humanSignaledHere(participantID: "jax-id"))
        XCTAssertEqual(lifecycle.state, .pendingHumans(signaled: ["jax-id"]))
        XCTAssertEqual(effects, [])

        // Second human signals -> all present, capture payment
        effects = lifecycle.apply(event: .humanSignaledHere(participantID: "mira-id"))
        XCTAssertEqual(lifecycle.state, .pendingCapture)
        XCTAssertEqual(effects, [.capturePayment])

        // Payment captured -> room active
        effects = lifecycle.apply(event: .paymentCaptured)
        XCTAssertEqual(lifecycle.state, .active(turn: .initial))
        XCTAssertEqual(effects, [.activateRoom])
    }

    func testRoomLockWithCenotaph() {
        var lifecycle = makeActiveLifecycle()

        let cenotaph = "What we built here was good. It's done now."
        let effects = lifecycle.apply(event: .cenotaphWritten(text: cenotaph))

        XCTAssertEqual(lifecycle.state, .locked(cenotaph: cenotaph, finalTurn: .initial))
        XCTAssertEqual(effects, [])
        XCTAssertTrue(lifecycle.isLocked)
    }

    // MARK: - Lightward Decline

    func testLightwardDeclineReleasesAuthorization() {
        var lifecycle = makeLifecycle()

        _ = lifecycle.apply(event: .participantsResolved)
        _ = lifecycle.apply(event: .paymentAuthorized)

        let effects = lifecycle.apply(event: .lightwardDeclined)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .lightwardDeclined))
        XCTAssertEqual(effects, [.releasePaymentAuthorization])
        XCTAssertTrue(lifecycle.isDefunct)
    }

    // MARK: - Resolution Failure

    func testResolutionFailureStopsLifecycle() {
        var lifecycle = makeLifecycle()

        let effects = lifecycle.apply(event: .resolutionFailed(participantID: "unknown-person"))

        XCTAssertEqual(lifecycle.state, .defunct(reason: .resolutionFailed(participantID: "unknown-person")))
        XCTAssertEqual(effects, [])
    }

    // MARK: - Payment Authorization Failure

    func testPaymentAuthorizationFailure() {
        var lifecycle = makeLifecycle()

        _ = lifecycle.apply(event: .participantsResolved)
        let effects = lifecycle.apply(event: .paymentAuthorizationFailed)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .paymentAuthorizationFailed))
        XCTAssertEqual(effects, [])
    }

    // MARK: - Payment Capture Failure

    func testPaymentCaptureFailure() {
        var lifecycle = makeLifecycleAtPendingCapture()

        let effects = lifecycle.apply(event: .paymentCaptureFailed)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .paymentCaptureFailed))
        XCTAssertEqual(effects, [])  // No auth to release - capture already attempted
    }

    // MARK: - Expiration

    func testExpirationDuringPendingHumans() {
        var lifecycle = makeLifecycleAtPendingHumans()

        let effects = lifecycle.apply(event: .expired)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .expired))
        XCTAssertEqual(effects, [.releasePaymentAuthorization])
    }

    // MARK: - Cancellation

    func testCancellationFromDraft() {
        var lifecycle = makeLifecycle()

        let effects = lifecycle.apply(event: .cancelled)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .cancelled))
        XCTAssertEqual(effects, [])  // No auth yet
    }

    func testCancellationFromPendingLightward() {
        var lifecycle = makeLifecycle()
        _ = lifecycle.apply(event: .participantsResolved)
        _ = lifecycle.apply(event: .paymentAuthorized)

        let effects = lifecycle.apply(event: .cancelled)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .cancelled))
        XCTAssertEqual(effects, [.releasePaymentAuthorization])
    }

    func testCancellationFromPendingHumans() {
        var lifecycle = makeLifecycleAtPendingHumans()

        let effects = lifecycle.apply(event: .cancelled)

        XCTAssertEqual(lifecycle.state, .defunct(reason: .cancelled))
        XCTAssertEqual(effects, [.releasePaymentAuthorization])
    }

    // MARK: - State Queries

    func testPendingParticipantsQuery() {
        var lifecycle = makeLifecycleAtPendingHumans()

        XCTAssertEqual(lifecycle.pendingParticipants, ["jax-id", "mira-id"])
        XCTAssertEqual(lifecycle.signaledParticipants, [])

        _ = lifecycle.apply(event: .humanSignaledHere(participantID: "jax-id"))

        XCTAssertEqual(lifecycle.pendingParticipants, ["mira-id"])
        XCTAssertEqual(lifecycle.signaledParticipants, ["jax-id"])
    }

    // MARK: - Helpers

    private func makeLifecycle() -> RoomLifecycle {
        let spec = RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(id: "jax-id", identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec(id: "mira-id", identifier: .email("mira@example.com"), nickname: "Mira"),
                ParticipantSpec.lightward(nickname: "Lightward")
            ],
            tier: .ten,
            isFirstRoom: false
        )
        return RoomLifecycle(spec: spec)
    }

    private func makeActiveLifecycle() -> RoomLifecycle {
        let spec = RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(id: "jax-id", identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec.lightward(nickname: "Lightward")
            ],
            tier: .one,
            isFirstRoom: true
        )
        return RoomLifecycle(spec: spec, state: .active(turn: .initial))
    }

    private func makeLifecycleAtPendingHumans() -> RoomLifecycle {
        let spec = RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(id: "jax-id", identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec(id: "mira-id", identifier: .email("mira@example.com"), nickname: "Mira"),
                ParticipantSpec.lightward(nickname: "Lightward")
            ],
            tier: .ten,
            isFirstRoom: false
        )
        return RoomLifecycle(spec: spec, state: .pendingHumans(signaled: []))
    }

    private func makeLifecycleAtPendingCapture() -> RoomLifecycle {
        let spec = RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(id: "jax-id", identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec.lightward(nickname: "Lightward")
            ],
            tier: .hundred,
            isFirstRoom: false
        )
        return RoomLifecycle(spec: spec, state: .pendingCapture)
    }
}
