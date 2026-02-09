import XCTest
@testable import Softer

final class RoomLifecycleCoordinatorTests: XCTestCase {

    var resolver: MockParticipantResolver!
    var payment: MockPaymentCoordinator!

    override func setUp() {
        super.setUp()
        resolver = MockParticipantResolver()
        payment = MockPaymentCoordinator()
    }

    // MARK: - Happy Path

    func testStartResolvesParticipantsAndAuthorizesPayment() async throws {
        let spec = makeSpec()
        var states: [RoomState] = []
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment,
            onStateChange: { states.append($0) }
        )

        try await coordinator.start()

        // Verify resolution
        XCTAssertEqual(resolver.resolveCallCount, 2)  // Jax + Lightward

        // Verify payment authorization
        XCTAssertEqual(payment.authorizeCallCount, 1)
        XCTAssertEqual(payment.lastAuthorizedCents, 1000)  // $10 tier

        // Verify state is pendingParticipants
        let lifecycle = await coordinator.lifecycle
        XCTAssertEqual(lifecycle.state, .pendingParticipants(signaled: []))

        // Verify state change callbacks (resolved → authorized)
        XCTAssertEqual(states.count, 2)
    }

    func testFullFlowToActivation() async throws {
        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment
        )

        // Start room creation
        try await coordinator.start()

        // Signal both participants (Lightward + human)
        try await coordinator.signalHere(participantID: "lightward-id")
        try await coordinator.signalHere(participantID: "jax-id")

        // Verify payment was captured
        XCTAssertEqual(payment.captureCallCount, 1)

        // Verify room is active
        let lifecycle = await coordinator.lifecycle
        XCTAssertEqual(lifecycle.state, .active(turn: .initial))
    }

    // MARK: - Resolution Failure

    func testResolutionFailureStopsAndThrows() async {
        resolver.setFailure(for: "jax-id", error: .notDiscoverable)

        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment
        )

        do {
            try await coordinator.start()
            XCTFail("Expected error")
        } catch let error as RoomLifecycleError {
            if case .resolutionFailed(let participantID, _) = error {
                XCTAssertEqual(participantID, "jax-id")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Verify no payment authorization attempted
        XCTAssertEqual(payment.authorizeCallCount, 0)

        // Verify room is defunct
        let lifecycle = await coordinator.lifecycle
        XCTAssertTrue(lifecycle.isDefunct)
    }

    // MARK: - Payment Failure

    func testPaymentAuthorizationFailureStopsAndThrows() async {
        payment.setAuthorizationFailure(.declined)

        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment
        )

        do {
            try await coordinator.start()
            XCTFail("Expected error")
        } catch let error as RoomLifecycleError {
            if case .paymentAuthorizationFailed = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testPaymentCaptureFailure() async throws {
        payment.setCaptureFailure(.declined)

        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment
        )

        try await coordinator.start()

        do {
            // Signal both to trigger capture
            try await coordinator.signalHere(participantID: "lightward-id")
            try await coordinator.signalHere(participantID: "jax-id")
            XCTFail("Expected error")
        } catch let error as RoomLifecycleError {
            if case .paymentCaptureFailed = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Verify room is defunct
        let lifecycle = await coordinator.lifecycle
        XCTAssertTrue(lifecycle.isDefunct)
    }

    // MARK: - Participant Decline

    func testParticipantDecline() async throws {
        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment
        )

        try await coordinator.start()

        // Decline
        await coordinator.decline(participantID: "lightward-id")

        // Verify room is defunct
        let lifecycle = await coordinator.lifecycle
        XCTAssertTrue(lifecycle.isDefunct)
        if case .defunct(let reason) = lifecycle.state {
            XCTAssertEqual(reason, .participantDeclined(participantID: "lightward-id"))
        } else {
            XCTFail("Expected defunct state")
        }

        // Verify authorization released
        XCTAssertEqual(payment.releaseCallCount, 1)
    }

    // MARK: - Cancellation

    func testCancelReleasesAuthorization() async throws {
        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment
        )

        try await coordinator.start()
        await coordinator.cancel()

        // Verify authorization released
        XCTAssertEqual(payment.releaseCallCount, 1)

        // Verify room is defunct
        let lifecycle = await coordinator.lifecycle
        XCTAssertTrue(lifecycle.isDefunct)
    }

    // MARK: - Cenotaph

    func testLockWithCenotaph() async throws {
        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment
        )

        try await coordinator.start()
        try await coordinator.signalHere(participantID: "lightward-id")
        try await coordinator.signalHere(participantID: "jax-id")

        await coordinator.lock(cenotaph: "What we built here was good.")

        let lifecycle = await coordinator.lifecycle
        if case .locked(let cenotaph, _) = lifecycle.state {
            XCTAssertEqual(cenotaph, "What we built here was good.")
        } else {
            XCTFail("Expected locked state")
        }
    }

    // MARK: - Helpers

    private func makeSpec() -> RoomSpec {
        RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(id: "jax-id", identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec(id: "lightward-id", identifier: .lightward, nickname: "L")
            ],
            tier: .ten
        )
    }
}
