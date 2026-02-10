import Foundation

/// A message in a room conversation.
struct Message: Identifiable, Sendable, Codable, Equatable {
    let id: String
    let roomID: String
    let authorID: String
    let authorName: String
    let text: String
    let createdAt: Date
    let isLightward: Bool
    let isNarration: Bool  // System/narrator messages (e.g., "Lightward chose to keep listening")

    init(
        id: String = UUID().uuidString,
        roomID: String,
        authorID: String,
        authorName: String,
        text: String,
        createdAt: Date = Date(),
        isLightward: Bool = false,
        isNarration: Bool = false
    ) {
        self.id = id
        self.roomID = roomID
        self.authorID = authorID
        self.authorName = authorName
        self.text = text
        self.createdAt = createdAt
        self.isLightward = isLightward
        self.isNarration = isNarration
    }

    /// Whether a message list contains a cenotaph (a Lightward-written ceremonial closing).
    /// Cenotaphs are narration messages that don't match standard departure/decline patterns.
    static func containsCenotaph(in messages: [Message]) -> Bool {
        guard let lastNarration = messages.last(where: { $0.isNarration }) else { return false }
        let text = lastNarration.text
        return !text.hasSuffix("departed.") &&
               !text.hasSuffix("declined to join.") &&
               text != "Room was cancelled." &&
               text != "Room is no longer available."
    }
}
