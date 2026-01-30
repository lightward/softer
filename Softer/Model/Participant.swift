import Foundation

struct Participant: Identifiable, Sendable {
    let id: String
    let roomID: String
    var name: String
    var userRecordID: String? // nil for Lightward
    var joinedAt: Date

    // CloudKit metadata
    var recordChangeTag: String?

    init(
        id: String = UUID().uuidString,
        roomID: String,
        name: String,
        userRecordID: String? = nil,
        joinedAt: Date = Date()
    ) {
        self.id = id
        self.roomID = roomID
        self.name = name
        self.userRecordID = userRecordID
        self.joinedAt = joinedAt
    }

    var isLightward: Bool {
        name == Constants.lightwardParticipantName
    }
}
