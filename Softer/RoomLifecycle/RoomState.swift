import Foundation

/// Turn state for an active room conversation.
struct TurnState: Sendable, Codable, Equatable {
    var currentTurnIndex: Int
    var currentNeed: Need?

    static let initial = TurnState(currentTurnIndex: 0, currentNeed: nil)

    mutating func advanceTurn(participantCount: Int) {
        guard participantCount > 0 else { return }
        // Don't modulo here - let index grow for higherTurnWins merge strategy
        // Display code does % participantCount when showing whose turn
        currentTurnIndex += 1
    }
}

/// The lifecycle state of a room.
/// Each state transition is explicit; invalid transitions don't exist.
enum RoomState: Sendable, Codable, Equatable {
    /// Room specification created, participants not yet resolved via CloudKit.
    case draft

    /// All participants resolved. Payment completed. Awaiting all participants to signal presence.
    case pendingParticipants(signaled: Set<String>)  // participant IDs who have signaled

    /// Room is live. Conversation can proceed.
    /// Turn state is tracked here: current turn index, raised hands, and any pending need.
    case active(turn: TurnState)

    /// Room is no longer active. Creation failed, cancelled, or a participant departed.
    case defunct(reason: DefunctReason)
}

enum DefunctReason: Sendable, Codable, Equatable {
    case resolutionFailed(participantID: String)
    case participantDeclined(participantID: String)  // Refused to join (during pendingParticipants)
    case participantLeft(participantID: String)       // Departed after room was active (includes horizon)
    case paymentFailed
    case cancelled
    case expired
}

/// Events that can occur during room lifecycle.
enum RoomEvent: Sendable, Equatable {
    // Creation flow events
    case participantsResolved
    case resolutionFailed(participantID: String)
    case paymentCompleted
    case paymentFailed
    case signaled(participantID: String)
    case participantDeclined(participantID: String)
    case cancelled
    case expired

    // Active room events
    case messageSent  // Advances turn
    case needCreated(Need)
    case needClaimed(deviceID: String)
    case needCompleted
    case participantLeft(participantID: String)
}

/// Effects that the room lifecycle can request.
enum RoomEffect: Sendable, Equatable {
    case resolveParticipants
    case processPayment
    case dispatchInvites
}
