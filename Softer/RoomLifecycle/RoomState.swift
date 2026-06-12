import Foundation

/// The lifecycle state of a room.
/// Each state transition is explicit; invalid transitions don't exist.
/// Turn state is not part of room state: the current turn is a fold over the
/// message ledger (`Message.turnIndex(in:)`), derived wherever it's read.
enum RoomState: Sendable, Codable, Equatable {
    /// Room specification created, participants not yet resolved via CloudKit.
    case draft

    /// All participants resolved. Payment completed. Awaiting all participants to signal presence.
    case pendingParticipants(signaled: Set<String>)  // participant IDs who have signaled

    /// Room is live. Conversation can proceed.
    case active

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
    case participantLeft(participantID: String)
}

/// Effects that the room lifecycle can request.
enum RoomEffect: Sendable, Equatable {
    case resolveParticipants
    case processPayment
    case dispatchInvites
}
