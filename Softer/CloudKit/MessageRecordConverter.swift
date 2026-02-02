import Foundation
import CloudKit

/// Converts between Message domain models and CloudKit records.
enum MessageRecordConverter {

    static let recordType = "Message2"

    // MARK: - To CKRecord

    static func record(from message: Message, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: message.id, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)

        record["roomID"] = message.roomID as NSString
        record["authorID"] = message.authorID as NSString
        record["authorName"] = message.authorName as NSString
        record["text"] = message.text as NSString
        record["createdAt"] = message.createdAt as NSDate
        record["isLightward"] = (message.isLightward ? 1 : 0) as NSNumber
        record["isNarration"] = (message.isNarration ? 1 : 0) as NSNumber

        return record
    }

    // MARK: - From CKRecord

    static func message(from record: CKRecord) -> Message? {
        guard let roomID = record["roomID"] as? String,
              let authorID = record["authorID"] as? String,
              let authorName = record["authorName"] as? String,
              let text = record["text"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let isLightwardInt = record["isLightward"] as? Int else {
            return nil
        }

        let isNarrationInt = record["isNarration"] as? Int ?? 0

        return Message(
            id: record.recordID.recordName,
            roomID: roomID,
            authorID: authorID,
            authorName: authorName,
            text: text,
            createdAt: createdAt,
            isLightward: isLightwardInt == 1,
            isNarration: isNarrationInt == 1
        )
    }

    // MARK: - Helpers

    static func roomID(from record: CKRecord) -> String? {
        record["roomID"] as? String
    }
}
