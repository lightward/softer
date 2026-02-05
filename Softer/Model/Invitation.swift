import Foundation

/// An invitation to join a shared room, stored in CloudKit public database.
/// NOTE: This is legacy code from the invitation hub approach. Now using CKShare URLs directly.
/// TODO: Remove this file and all references in the next cleanup session.
struct Invitation: Identifiable, Equatable {
    let id: String
    let toEmail: String
    let fromUserRecordID: String
    let shareURL: String
    let roomID: String
    let senderName: String
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        toEmail: String,
        fromUserRecordID: String,
        shareURL: String,
        roomID: String,
        senderName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.toEmail = toEmail
        self.fromUserRecordID = fromUserRecordID
        self.shareURL = shareURL
        self.roomID = roomID
        self.senderName = senderName
        self.createdAt = createdAt
    }
}
