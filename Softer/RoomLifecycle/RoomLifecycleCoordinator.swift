import Foundation

/// Errors that can occur during room lifecycle coordination.
enum RoomLifecycleError: Error, Sendable {
    case resolutionFailed(participantID: String, error: ResolutionError)
    case paymentFailed(PaymentError)
    case cancelled
    case expired
    case invalidState(String)
}

/// Coordinates the room lifecycle by executing effects and feeding events back.
actor RoomLifecycleCoordinator {
    private(set) var lifecycle: RoomLifecycle
    private(set) var resolvedParticipants: [ResolvedParticipant] = []

    private let resolver: ParticipantResolver
    private let payment: PaymentCoordinator
    private let onStateChange: @Sendable (RoomState) -> Void

    init(
        spec: RoomSpec,
        resolver: ParticipantResolver,
        payment: PaymentCoordinator,
        onStateChange: @escaping @Sendable (RoomState) -> Void = { _ in }
    ) {
        self.lifecycle = RoomLifecycle(spec: spec)
        self.resolver = resolver
        self.payment = payment
        self.onStateChange = onStateChange
    }

    /// Start the room creation process: resolve participants and process payment.
    /// Room arrives at pendingParticipants(signaled: []).
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

        // Process payment (immediate charge via StoreKit IAP)
        let paymentResult = await payment.purchase(tier: lifecycle.spec.tier)
        switch paymentResult {
        case .success:
            applyEvent(.paymentCompleted)
        case .failure(let error):
            applyEvent(.paymentFailed)
            throw RoomLifecycleError.paymentFailed(error)
        }

        // Room is now pendingParticipants(signaled: [])
    }

    /// Signal that a participant is present.
    func signalHere(participantID: String) async throws {
        guard case .pendingParticipants = lifecycle.state else {
            throw RoomLifecycleError.invalidState("Cannot signal here in state \(lifecycle.state)")
        }

        applyEvent(.signaled(participantID: participantID))
    }

    /// Record that a participant declined to join.
    func decline(participantID: String) {
        applyEvent(.participantDeclined(participantID: participantID))
    }

    /// Cancel the room creation.
    func cancel() {
        applyEvent(.cancelled)
    }

    /// Mark the room as expired.
    func expire() {
        applyEvent(.expired)
    }

    /// Lock the room with a cenotaph.
    func lock(cenotaph: String) {
        applyEvent(.cenotaphWritten(text: cenotaph))
    }

    // MARK: - Private

    private func applyEvent(_ event: RoomEvent) {
        let _ = lifecycle.apply(event: event)
        onStateChange(lifecycle.state)
    }
}
