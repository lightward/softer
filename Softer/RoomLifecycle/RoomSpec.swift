import Foundation

/// The complete specification for a room, as provided by the originator.
/// This is the input to room creation.
struct RoomSpec: Sendable, Codable, Equatable {
    let id: String
    let originatorID: String  // The participant ID of the person creating the room
    let participants: [ParticipantSpec]
    let tier: PaymentTier
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        originatorID: String,
        participants: [ParticipantSpec],
        tier: PaymentTier,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.originatorID = originatorID
        self.participants = participants
        self.tier = tier
        self.createdAt = createdAt
    }

    /// The payment amount in cents for this room.
    var effectiveAmountCents: Int {
        tier.cents
    }

    /// All human participants (excluding Lightward).
    var humanParticipants: [ParticipantSpec] {
        participants.filter { !$0.isLightward }
    }

    /// The Lightward participant, if present.
    var lightwardParticipant: ParticipantSpec? {
        participants.first { $0.isLightward }
    }

    /// Display string for the room: "Jax, Eve, Art (15, Eve)"
    func displayString(depth: Int, lastSpeaker: String?) -> String {
        let names = participants.map { $0.nickname }.joined(separator: ", ")
        if let speaker = lastSpeaker {
            return "\(names) (\(depth), \(speaker))"
        } else {
            return "\(names) (\(depth))"
        }
    }
}
