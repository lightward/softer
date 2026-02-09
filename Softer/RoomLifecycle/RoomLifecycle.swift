import Foundation

/// Manages the lifecycle of a room from creation to activation to defunct.
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
            return [.processPayment]

        case (.draft, .resolutionFailed(let participantID)):
            state = .defunct(reason: .resolutionFailed(participantID: participantID))
            return []

        case (.draft, .paymentCompleted):
            state = .pendingParticipants(signaled: [])
            return []

        case (.draft, .paymentFailed):
            state = .defunct(reason: .paymentFailed)
            return []

        // MARK: - Pending Participants state transitions

        case (.pendingParticipants(var signaled), .signaled(let participantID)):
            signaled.insert(participantID)
            let allParticipants = Set(spec.participants.map { $0.id })
            if signaled == allParticipants {
                state = .active(turn: .initial)
                return []
            } else {
                state = .pendingParticipants(signaled: signaled)
                return []
            }

        case (.pendingParticipants, .participantDeclined(let participantID)):
            state = .defunct(reason: .participantDeclined(participantID: participantID))
            return []

        case (.pendingParticipants, .expired):
            state = .defunct(reason: .expired)
            return []

        case (.pendingParticipants, .cancelled):
            state = .defunct(reason: .cancelled)
            return []

        // MARK: - Active state transitions (turn management)

        case (.active(var turn), .messageSent):
            turn.advanceTurn(participantCount: spec.participants.count)
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

        case (.active, .participantLeft(let participantID)):
            state = .defunct(reason: .participantLeft(participantID: participantID))
            return []

        // MARK: - Cancellation from any pre-active state

        case (.draft, .cancelled):
            state = .defunct(reason: .cancelled)
            return []

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

    var isDefunct: Bool {
        if case .defunct = state { return true }
        return false
    }

    var isPending: Bool {
        switch state {
        case .draft, .pendingParticipants:
            return true
        default:
            return false
        }
    }

    /// Returns the set of participant IDs who have signaled "here".
    var signaledParticipants: Set<String> {
        if case .pendingParticipants(let signaled) = state {
            return signaled
        }
        return []
    }

    /// Returns the set of participant IDs who have NOT yet signaled.
    var unsignaledParticipants: Set<String> {
        let all = Set(spec.participants.map { $0.id })
        return all.subtracting(signaledParticipants)
    }

    // MARK: - Turn queries (active rooms only)

    /// The turn state, if the room is active.
    var turnState: TurnState? {
        switch state {
        case .active(let turn): return turn
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
}
