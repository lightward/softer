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

    init(
        id: String = UUID().uuidString,
        roomID: String,
        authorID: String,
        authorName: String,
        text: String,
        createdAt: Date = Date(),
        isLightward: Bool = false
    ) {
        self.id = id
        self.roomID = roomID
        self.authorID = authorID
        self.authorName = authorName
        self.text = text
        self.createdAt = createdAt
        self.isLightward = isLightward
    }
}
