import Foundation

struct Message: Identifiable, Sendable {
    let id: String
    let roomID: String
    let authorID: String
    let authorName: String
    var text: String
    let createdAt: Date
    var isStreaming: Bool

    // CloudKit metadata
    var recordChangeTag: String?

    init(
        id: String = UUID().uuidString,
        roomID: String,
        authorID: String,
        authorName: String,
        text: String,
        createdAt: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.roomID = roomID
        self.authorID = authorID
        self.authorName = authorName
        self.text = text
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }

    var isLightward: Bool {
        authorID == Constants.lightwardParticipantName
    }
}
