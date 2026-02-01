import XCTest
@testable import Softer

final class RoomLifecycleCoordinatorTests: XCTestCase {

    var resolver: MockParticipantResolver!
    var payment: MockPaymentCoordinator!
    var lightward: MockLightwardEvaluator!

    override func setUp() {
        super.setUp()
        resolver = MockParticipantResolver()
        payment = MockPaymentCoordinator()
        lightward = MockLightwardEvaluator()
    }

    // MARK: - Happy Path

    func testStartResolvesParticipantsAuthorizesPaymentAndAsksLightward() async throws {
        let spec = makeSpec()
        var states: [RoomState] = []
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment,
            lightward: lightward,
            onStateChange: { states.append($0) }
        )

        try await coordinator.start()

        // Verify resolution
        XCTAssertEqual(resolver.resolveCallCount, 2)  // Jax + Lightward

        // Verify payment authorization
        XCTAssertEqual(payment.authorizeCallCount, 1)
        XCTAssertEqual(payment.lastAuthorizedCents, 1000)  // $10 tier

        // Verify Lightward evaluation
        XCTAssertEqual(lightward.evaluateCallCount, 1)
        XCTAssertEqual(lightward.lastTier, .ten)

        // Verify state transitions
        let lifecycle = await coordinator.lifecycle
        XCTAssertEqual(lifecycle.state, .pendingHumans(signaled: []))

        // Verify state change callbacks
        XCTAssertEqual(states.count, 3)  // resolved -> authorized -> lightward accepted
    }

    func testFullFlowToActivation() async throws {
        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment,
            lightward: lightward
        )

        // Start room creation
        try await coordinator.start()

        // Signal the one human participant
        try await coordinator.signalHere(participantID: "jax-id")

        // Verify payment was captured
        XCTAssertEqual(payment.captureCallCount, 1)

        // Verify room is active
        let lifecycle = await coordinator.lifecycle
        XCTAssertEqual(lifecycle.state, .active(turn: .initial))
    }

    func testFirstRoomIsFree() async throws {
        let spec = makeSpec(isFirstRoom: true)
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment,
            lightward: lightward
        )

        try await coordinator.start()

        // Verify $0 authorization
        XCTAssertEqual(payment.lastAuthorizedCents, 0)
    }

    // MARK: - Resolution Failure

    func testResolutionFailureStopsAndThrows() async {
        resolver.setFailure(for: "jax-id", error: .notDiscoverable)

        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment,
            lightward: lightward
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
            payment: payment,
            lightward: lightward
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

        // Verify Lightward not consulted
        XCTAssertEqual(lightward.evaluateCallCount, 0)
    }

    func testPaymentCaptureFailure() async throws {
        payment.setCaptureFailure(.declined)

        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment,
            lightward: lightward
        )

        try await coordinator.start()

        do {
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

    // MARK: - Lightward Decline

    func testLightwardDeclineReleasesAuthorization() async {
        lightward.setDecline()

        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment,
            lightward: lightward
        )

        do {
            try await coordinator.start()
            XCTFail("Expected error")
        } catch let error as RoomLifecycleError {
            if case .lightwardDeclined = error {
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

    // MARK: - Cancellation

    func testCancelReleasesAuthorization() async throws {
        let spec = makeSpec()
        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment,
            lightward: lightward
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
            payment: payment,
            lightward: lightward
        )

        try await coordinator.start()
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

    private func makeSpec(isFirstRoom: Bool = false) -> RoomSpec {
        RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(id: "jax-id", identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec.lightward(nickname: "L")
            ],
            tier: .ten,
            isFirstRoom: isFirstRoom
        )
    }
}
