import Foundation

/// Errors that can occur during room lifecycle coordination.
enum RoomLifecycleError: Error, Sendable {
    case resolutionFailed(participantID: String, error: ResolutionError)
    case paymentAuthorizationFailed(PaymentError)
    case paymentCaptureFailed(PaymentError)
    case lightwardDeclined
    case cancelled
    case expired
    case invalidState(String)
}

/// Coordinates the room lifecycle by executing effects and feeding events back.
actor RoomLifecycleCoordinator {
    private(set) var lifecycle: RoomLifecycle
    private(set) var resolvedParticipants: [ResolvedParticipant] = []
    private var paymentAuthorization: PaymentAuthorization?

    private let resolver: ParticipantResolver
    private let payment: PaymentCoordinator
    private let lightward: LightwardEvaluator
    private let onStateChange: @Sendable (RoomState) -> Void

    init(
        spec: RoomSpec,
        resolver: ParticipantResolver,
        payment: PaymentCoordinator,
        lightward: LightwardEvaluator,
        onStateChange: @escaping @Sendable (RoomState) -> Void = { _ in }
    ) {
        self.lifecycle = RoomLifecycle(spec: spec)
        self.resolver = resolver
        self.payment = payment
        self.lightward = lightward
        self.onStateChange = onStateChange
    }

    /// Start the room creation process.
    /// Resolves participants, authorizes payment, asks Lightward, dispatches invites.
    func start() async throws {
        // Resolve all participants
        let result = await resolver.resolveAll(lifecycle.spec.participants)
        switch result {
        case .success(let resolved):
            resolvedParticipants = resolved
            applyEvent(.participantsResolved)
        case .failure(let resolutionError):
            applyEvent(.resolutionFailed(participantID: resolutionError.participantSpec.id))
            throw RoomLifecycleError.resolutionFailed(participantID: resolutionError.participantSpec.id, error: resolutionError.error)
        }

        // Authorize payment
        let paymentResult = await payment.authorize(cents: lifecycle.spec.effectiveAmountCents)
        switch paymentResult {
        case .success(let auth):
            paymentAuthorization = auth
            applyEvent(.paymentAuthorized)
        case .failure(let error):
            applyEvent(.paymentAuthorizationFailed)
            throw RoomLifecycleError.paymentAuthorizationFailed(error)
        }

        // Ask Lightward
        let decision = await lightward.evaluate(
            roster: lifecycle.spec.participants,
            tier: lifecycle.spec.tier
        )
        switch decision {
        case .accepted:
            applyEvent(.lightwardAccepted)
        case .declined:
            applyEvent(.lightwardDeclined)
            throw RoomLifecycleError.lightwardDeclined
        }

        // Room is now pending humans - invites dispatched via the effect
    }

    /// Signal that a human participant is present.
    func signalHere(participantID: String) async throws {
        guard case .pendingHumans = lifecycle.state else {
            throw RoomLifecycleError.invalidState("Cannot signal here in state \(lifecycle.state)")
        }

        applyEvent(.humanSignaledHere(participantID: participantID))

        // If all humans are present, we moved to pendingCapture and need to capture
        if case .pendingCapture = lifecycle.state {
            try await capturePayment()
        }
    }

    /// Cancel the room creation.
    func cancel() async {
        applyEvent(.cancelled)
        if let auth = paymentAuthorization {
            await payment.release(auth)
            paymentAuthorization = nil
        }
    }

    /// Mark the room as expired (authorization timeout).
    func expire() async {
        applyEvent(.expired)
        if let auth = paymentAuthorization {
            await payment.release(auth)
            paymentAuthorization = nil
        }
    }

    /// Lock the room with a cenotaph.
    func lock(cenotaph: String) {
        applyEvent(.cenotaphWritten(text: cenotaph))
    }

    // MARK: - Private

    private func capturePayment() async throws {
        guard let auth = paymentAuthorization else {
            applyEvent(.paymentCaptureFailed)
            throw RoomLifecycleError.paymentCaptureFailed(.notConfigured)
        }

        let result = await payment.capture(auth)
        switch result {
        case .success:
            applyEvent(.paymentCaptured)
        case .failure(let error):
            applyEvent(.paymentCaptureFailed)
            throw RoomLifecycleError.paymentCaptureFailed(error)
        }
    }

    private func applyEvent(_ event: RoomEvent) {
        let _ = lifecycle.apply(event: event)
        onStateChange(lifecycle.state)
    }
}
