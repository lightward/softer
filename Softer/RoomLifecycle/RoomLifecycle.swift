import Foundation

/// Manages the lifecycle of a room from creation to activation to lock.
/// This is a pure state machine - all side effects are returned as RoomEffect values.
struct RoomLifecycle: Sendable {
    let spec: RoomSpec
    private(set) var state: RoomState
    private(set) var modifiedAt: Date

    init(spec: RoomSpec, state: RoomState = .draft, modifiedAt: Date = Date()) {
        self.spec = spec
        self.state = state
        self.modifiedAt = modifiedAt
    }

    /// Creates a copy with the specified turn state. Only valid for active rooms.
    func withTurnState(_ newTurn: TurnState) -> RoomLifecycle {
        guard case .active = state else { return self }
        return RoomLifecycle(spec: spec, state: .active(turn: newTurn), modifiedAt: Date())
    }

    /// Apply an event to the lifecycle, returning any effects that should be executed.
    mutating func apply(event: RoomEvent) -> [RoomEffect] {
        modifiedAt = Date()

        switch (state, event) {

        // MARK: - Draft state transitions

        case (.draft, .participantsResolved):
            return [.authorizePayment]

        case (.draft, .resolutionFailed(let participantID)):
            state = .defunct(reason: .resolutionFailed(participantID: participantID))
            return []

        case (.draft, .paymentAuthorized):
            state = .pendingLightward
            return [.requestLightwardPresence]

        case (.draft, .paymentAuthorizationFailed):
            state = .defunct(reason: .paymentAuthorizationFailed)
            return []

        // MARK: - Pending Lightward state transitions

        case (.pendingLightward, .lightwardAccepted):
            state = .pendingHumans(signaled: [])
            return [.dispatchInvites]

        case (.pendingLightward, .lightwardDeclined):
            state = .defunct(reason: .lightwardDeclined)
            return [.releasePaymentAuthorization]

        // MARK: - Pending Humans state transitions

        case (.pendingHumans(var signaled), .humanSignaledHere(let participantID)):
            signaled.insert(participantID)
            let allHumans = Set(spec.humanParticipants.map { $0.id })
            if signaled == allHumans {
                state = .pendingCapture
                return [.capturePayment]
            } else {
                state = .pendingHumans(signaled: signaled)
                return []
            }

        case (.pendingHumans, .expired):
            state = .defunct(reason: .expired)
            return [.releasePaymentAuthorization]

        case (.pendingHumans, .cancelled):
            state = .defunct(reason: .cancelled)
            return [.releasePaymentAuthorization]

        // MARK: - Pending Capture state transitions

        case (.pendingCapture, .paymentCaptured):
            state = .active(turn: .initial)
            return [.activateRoom]

        case (.pendingCapture, .paymentCaptureFailed):
            state = .defunct(reason: .paymentCaptureFailed)
            return []  // Payment was already attempted, no auth to release

        // MARK: - Active state transitions (turn management)

        case (.active(var turn), .messageSent):
            turn.advanceTurn(participantCount: spec.participants.count)
            state = .active(turn: turn)
            return []

        case (.active(var turn), .handRaised(let participantID)):
            turn.raiseHand(participantID: participantID)
            state = .active(turn: turn)
            return []

        case (.active(var turn), .needCreated(let need)):
            turn.currentNeed = need
            state = .active(turn: turn)
            return []

        case (.active(var turn), .needClaimed(let deviceID)):
            if var need = turn.currentNeed {
                need.claimedBy = deviceID
                need.claimedAt = Date()
                turn.currentNeed = need
                state = .active(turn: turn)
            }
            return []

        case (.active(var turn), .needCompleted):
            turn.currentNeed = nil
            state = .active(turn: turn)
            return []

        case (.active(let turn), .cenotaphWritten(let text)):
            state = .locked(cenotaph: text, finalTurn: turn)
            return []

        // MARK: - Cancellation from any pre-active state

        case (.draft, .cancelled):
            state = .defunct(reason: .cancelled)
            return []

        case (.pendingLightward, .cancelled):
            state = .defunct(reason: .cancelled)
            return [.releasePaymentAuthorization]

        case (.pendingCapture, .cancelled):
            state = .defunct(reason: .cancelled)
            return [.releasePaymentAuthorization]

        // MARK: - Invalid transitions (no-op)

        default:
            // Invalid transition - log for debugging but don't crash
            print("RoomLifecycle: Invalid transition from \(state) with event \(event)")
            return []
        }
    }

    // MARK: - State queries

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    var isLocked: Bool {
        if case .locked = state { return true }
        return false
    }

    var isDefunct: Bool {
        if case .defunct = state { return true }
        return false
    }

    var isPending: Bool {
        switch state {
        case .draft, .pendingLightward, .pendingHumans, .pendingCapture:
            return true
        default:
            return false
        }
    }

    /// Returns the set of human participant IDs who have signaled "here".
    var signaledParticipants: Set<String> {
        if case .pendingHumans(let signaled) = state {
            return signaled
        }
        return []
    }

    /// Returns the set of human participant IDs who have NOT yet signaled.
    var pendingParticipants: Set<String> {
        let allHumans = Set(spec.humanParticipants.map { $0.id })
        return allHumans.subtracting(signaledParticipants)
    }

    // MARK: - Turn queries (active rooms only)

    /// The turn state, if the room is active or locked.
    var turnState: TurnState? {
        switch state {
        case .active(let turn): return turn
        case .locked(_, let finalTurn): return finalTurn
        default: return nil
        }
    }

    /// The participant whose turn it currently is.
    var currentTurnParticipant: ParticipantSpec? {
        guard let turn = turnState, !spec.participants.isEmpty else { return nil }
        let index = turn.currentTurnIndex % spec.participants.count
        return spec.participants[index]
    }

    /// Whether it's currently Lightward's turn.
    var isLightwardTurn: Bool {
        currentTurnParticipant?.isLightward ?? false
    }

    /// The current need, if any.
    var currentNeed: Need? {
        turnState?.currentNeed
    }

    /// Participants who have raised their hand this turn.
    var raisedHands: Set<String> {
        turnState?.raisedHands ?? []
    }
}
