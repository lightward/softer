import Foundation
import CloudKit

enum RecordConverter {
    // MARK: - Room

    static func record(from room: Room, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: room.id, zoneID: zoneID)
        let record = CKRecord(recordType: Constants.RecordType.room, recordID: recordID)
        applyRoom(room, to: record)
        return record
    }

    static func applyRoom(_ room: Room, to record: CKRecord) {
        record["name"] = room.name as NSString
        record["turnOrder"] = room.turnOrder as NSArray
        record["currentTurnIndex"] = room.currentTurnIndex as NSNumber
        // Only set raisedHands if non-empty; empty arrays can't define schema
        if room.raisedHands.isEmpty {
            record["raisedHands"] = nil
        } else {
            record["raisedHands"] = Array(room.raisedHands) as NSArray
        }
        record["createdAtDate"] = room.createdAt as NSDate
        record["modifiedAtDate"] = room.modifiedAt as NSDate

        if let need = room.currentNeed {
            record["needID"] = need.id as NSString
            record["needType"] = need.type.rawValue as NSString
            record["needClaimedBy"] = need.claimedBy as NSString?
            record["needClaimedAt"] = need.claimedAt as NSDate?
        } else {
            record["needID"] = nil
            record["needType"] = nil
            record["needClaimedBy"] = nil
            record["needClaimedAt"] = nil
        }
    }

    static func room(from record: CKRecord) -> Room {
        let needID = record["needID"] as? String
        var currentNeed: Need?
        if let needID = needID, let needTypeRaw = record["needType"] as? String,
           let needType = NeedType(rawValue: needTypeRaw) {
            currentNeed = Need(
                id: needID,
                type: needType,
                claimedBy: record["needClaimedBy"] as? String,
                claimedAt: record["needClaimedAt"] as? Date,
                createdAt: record.creationDate ?? Date()
            )
        }

        return Room(
            id: record.recordID.recordName,
            name: record["name"] as? String ?? "",
            turnOrder: record["turnOrder"] as? [String] ?? [],
            currentTurnIndex: (record["currentTurnIndex"] as? Int) ?? 0,
            raisedHands: Set(record["raisedHands"] as? [String] ?? []),
            currentNeed: currentNeed,
            createdAt: record["createdAtDate"] as? Date ?? record.creationDate ?? Date(),
            modifiedAt: record["modifiedAtDate"] as? Date ?? record.modificationDate ?? Date()
        )
    }

    // MARK: - Message

    static func record(from message: Message, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: message.id, zoneID: zoneID)
        let record = CKRecord(recordType: Constants.RecordType.message, recordID: recordID)
        record["roomID"] = message.roomID as NSString
        record["authorID"] = message.authorID as NSString
        record["authorName"] = message.authorName as NSString
        record["text"] = message.text as NSString
        record["createdAtDate"] = message.createdAt as NSDate
        return record
    }

    static func message(from record: CKRecord) -> Message {
        Message(
            id: record.recordID.recordName,
            roomID: record["roomID"] as? String ?? "",
            authorID: record["authorID"] as? String ?? "",
            authorName: record["authorName"] as? String ?? "",
            text: record["text"] as? String ?? "",
            createdAt: record["createdAtDate"] as? Date ?? record.creationDate ?? Date()
        )
    }

    // MARK: - Participant

    static func record(from participant: Participant, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: participant.id, zoneID: zoneID)
        let record = CKRecord(recordType: Constants.RecordType.participant, recordID: recordID)
        record["roomID"] = participant.roomID as NSString
        record["name"] = participant.name as NSString
        record["userRecordID"] = participant.userRecordID as NSString?
        record["joinedAtDate"] = participant.joinedAt as NSDate
        return record
    }

    static func participant(from record: CKRecord) -> Participant {
        Participant(
            id: record.recordID.recordName,
            roomID: record["roomID"] as? String ?? "",
            name: record["name"] as? String ?? "",
            userRecordID: record["userRecordID"] as? String,
            joinedAt: record["joinedAtDate"] as? Date ?? record.creationDate ?? Date()
        )
    }
}
