import SwiftData
import Foundation

/// Persisted room data. Single source of truth for room state.
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

    // Signaled participants (for pendingHumans state)
    var signaledParticipantIDs: [String]

    // Timestamps
    var createdAt: Date
    var modifiedAt: Date

    // Relationships (simplified - no inverse for now)
    @Relationship(deleteRule: .cascade)
    var participants: [PersistedParticipant] = []

    @Relationship(deleteRule: .cascade)
    var messages: [PersistedMessage] = []

    init(
        id: String = UUID().uuidString,
        originatorID: String,
        tierRawValue: Int,
        isFirstRoom: Bool
    ) {
        self.id = id
        self.originatorID = originatorID
        self.tierRawValue = tierRawValue
        self.isFirstRoom = isFirstRoom
        self.stateType = "draft"
        self.signaledParticipantIDs = []
        self.raisedHands = []
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}

/// Persisted participant data.
@available(iOS 18, *)
@Model
final class PersistedParticipant {
    @Attribute(.unique) var id: String
    var roomID: String  // denormalized for queries
    var nickname: String
    var identifierType: String  // "email" or "phone"
    var identifierValue: String
    var orderIndex: Int
    var hasSignaledHere: Bool
    var isLightward: Bool

    init(
        id: String = UUID().uuidString,
        roomID: String,
        nickname: String,
        identifierType: String,
        identifierValue: String,
        orderIndex: Int,
        isLightward: Bool = false
    ) {
        self.id = id
        self.roomID = roomID
        self.nickname = nickname
        self.identifierType = identifierType
        self.identifierValue = identifierValue
        self.orderIndex = orderIndex
        self.hasSignaledHere = false
        self.isLightward = isLightward
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
