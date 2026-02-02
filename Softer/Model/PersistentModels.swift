import SwiftData
import Foundation

/// Persisted room data. Single source of truth for room state.
/// Participants and messages are embedded as JSON (single record type).
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

    // Embedded messages as JSON (uses EmbeddedMessage from RoomLifecycleRecordConverter)
    var messagesJSON: String

    // Timestamps
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: String = UUID().uuidString,
        originatorID: String,
        tierRawValue: Int,
        isFirstRoom: Bool,
        participantsJSON: String = "[]",
        messagesJSON: String = "[]"
    ) {
        self.id = id
        self.originatorID = originatorID
        self.tierRawValue = tierRawValue
        self.isFirstRoom = isFirstRoom
        self.participantsJSON = participantsJSON
        self.messagesJSON = messagesJSON
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

    // MARK: - Message Accessors

    /// Decode embedded messages from JSON.
    func embeddedMessages() -> [EmbeddedMessage] {
        guard let data = messagesJSON.data(using: .utf8),
              let messages = try? JSONDecoder().decode([EmbeddedMessage].self, from: data) else {
            return []
        }
        return messages.sorted { $0.createdAt < $1.createdAt }
    }

    /// Get messages as domain models.
    func messages() -> [Message] {
        embeddedMessages().map { $0.toMessage(roomID: id) }
    }

    /// Add a message to the room.
    func addMessage(_ message: Message) {
        var current = embeddedMessages()
        // Avoid duplicates
        if !current.contains(where: { $0.id == message.id }) {
            current.append(EmbeddedMessage(from: message))
            setMessages(current)
        }
    }

    /// Set messages from embedded message array.
    func setMessages(_ messages: [EmbeddedMessage]) {
        if let data = try? JSONEncoder().encode(messages),
           let json = String(data: data, encoding: .utf8) {
            self.messagesJSON = json
        }
    }

    /// Merge remote messages with local messages (union by ID, sorted by createdAt).
    func mergeMessages(from remoteJSON: String) {
        let remote = RoomLifecycleRecordConverter.decodeMessages(from: remoteJSON, roomID: id)
        let local = messages()
        let merged = RoomLifecycleRecordConverter.mergeMessages(local: local, remote: remote)
        let embedded = merged.map { EmbeddedMessage(from: $0) }
        setMessages(embedded)
    }
}
