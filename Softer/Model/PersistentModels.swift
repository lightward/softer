import SwiftData
import Foundation

/// Persisted room data. Single source of truth for room state.
/// Participants are embedded as JSON (no separate Participant records).
@available(iOS 18, *)
@Model
final class PersistedRoom {
    @Attribute(.unique) var id: String
    var originatorID: String
    var tierRawValue: Int
    var isFirstRoom: Bool

    // State
    var stateType: String  // "draft", "pendingLightward", "pendingHumans", "pendingCapture", "active", "locked", "defunct"
    var currentTurnIndex: Int?
    var raisedHands: [String]  // participant IDs with raised hands
    var defunctReason: String?
    var cenotaph: String?

    // Embedded participants as JSON (uses EmbeddedParticipant from RoomLifecycleRecordConverter)
    var participantsJSON: String

    // Timestamps
    var createdAt: Date
    var modifiedAt: Date

    // Messages relationship
    @Relationship(deleteRule: .cascade)
    var messages: [PersistedMessage] = []

    init(
        id: String = UUID().uuidString,
        originatorID: String,
        tierRawValue: Int,
        isFirstRoom: Bool,
        participantsJSON: String = "[]"
    ) {
        self.id = id
        self.originatorID = originatorID
        self.tierRawValue = tierRawValue
        self.isFirstRoom = isFirstRoom
        self.participantsJSON = participantsJSON
        self.stateType = "draft"
        self.raisedHands = []
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    /// Decode embedded participants from JSON.
    func embeddedParticipants() -> [EmbeddedParticipant] {
        guard let data = participantsJSON.data(using: .utf8),
              let participants = try? JSONDecoder().decode([EmbeddedParticipant].self, from: data) else {
            return []
        }
        return participants.sorted { $0.orderIndex < $1.orderIndex }
    }

    /// Encode participants to JSON and save.
    func setParticipants(_ participants: [EmbeddedParticipant]) {
        if let data = try? JSONEncoder().encode(participants),
           let json = String(data: data, encoding: .utf8) {
            self.participantsJSON = json
        }
    }

    /// Get signaled participant IDs from embedded data.
    func signaledParticipantIDs() -> Set<String> {
        Set(embeddedParticipants().filter { $0.hasSignaledHere }.map { $0.id })
    }
}

/// Persisted message data.
@available(iOS 18, *)
@Model
final class PersistedMessage {
    @Attribute(.unique) var id: String
    var roomID: String  // denormalized for queries
    var authorID: String
    var authorName: String
    var text: String
    var isLightward: Bool
    var isNarration: Bool
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        roomID: String,
        authorID: String,
        authorName: String,
        text: String,
        isLightward: Bool,
        isNarration: Bool
    ) {
        self.id = id
        self.roomID = roomID
        self.authorID = authorID
        self.authorName = authorName
        self.text = text
        self.isLightward = isLightward
        self.isNarration = isNarration
        self.createdAt = Date()
    }
}
