import Foundation
import CloudKit

/// Converts between RoomLifecycle domain models and CloudKit records.
/// Uses "Room2" and "Participant2" record types to avoid collision with legacy model.
enum RoomLifecycleRecordConverter {

    // MARK: - Record Type Names

    static let roomRecordType = "Room2"
    static let participantRecordType = "Participant2"

    // MARK: - Room2 Record (RoomSpec + RoomState)

    static func record(from lifecycle: RoomLifecycle, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: lifecycle.spec.id, zoneID: zoneID)
        let record = CKRecord(recordType: roomRecordType, recordID: recordID)
        apply(lifecycle, to: record)
        return record
    }

    static func apply(_ lifecycle: RoomLifecycle, to record: CKRecord) {
        let spec = lifecycle.spec

        // RoomSpec fields
        record["originatorID"] = spec.originatorID as NSString
        record["tier"] = spec.tier.rawValue as NSNumber
        record["isFirstRoom"] = (spec.isFirstRoom ? 1 : 0) as NSNumber
        record["createdAtDate"] = spec.createdAt as NSDate
        record["modifiedAtDate"] = lifecycle.modifiedAt as NSDate

        // RoomState fields
        let encoded = encodeState(lifecycle.state)
        record["stateType"] = encoded.stateType as NSString
        record["defunctReason"] = encoded.defunctReason as NSString?
        record["cenotaph"] = encoded.cenotaph as NSString?

        // TurnState fields (for active/locked states)
        if let turn = encoded.turnState {
            record["currentTurnIndex"] = turn.currentTurnIndex as NSNumber
            if turn.raisedHands.isEmpty {
                record["raisedHands"] = nil
            } else {
                record["raisedHands"] = Array(turn.raisedHands) as NSArray
            }

            // Need state
            if let need = turn.currentNeed {
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
        } else {
            record["currentTurnIndex"] = nil
            record["raisedHands"] = nil
            record["needID"] = nil
            record["needType"] = nil
            record["needClaimedBy"] = nil
            record["needClaimedAt"] = nil
        }
    }

    /// Reconstructs a RoomLifecycle from a Room2 record and participant data.
    /// - Parameters:
    ///   - record: The Room2 CloudKit record
    ///   - participants: Array of ParticipantSpec extracted from Participant2 records
    ///   - signaledParticipantIDs: Set of participant IDs who have signaled "here"
    static func lifecycle(
        from record: CKRecord,
        participants: [ParticipantSpec],
        signaledParticipantIDs: Set<String>
    ) -> RoomLifecycle? {
        guard let originatorID = record["originatorID"] as? String,
              let tierRaw = record["tier"] as? Int,
              let tier = PaymentTier(rawValue: tierRaw),
              let isFirstRoomInt = record["isFirstRoom"] as? Int,
              let stateType = record["stateType"] as? String else {
            return nil
        }

        let spec = RoomSpec(
            id: record.recordID.recordName,
            originatorID: originatorID,
            participants: participants,
            tier: tier,
            isFirstRoom: isFirstRoomInt == 1,
            createdAt: record["createdAtDate"] as? Date ?? record.creationDate ?? Date()
        )

        // Decode TurnState if present
        let turnState = decodeTurnState(from: record)

        let state = decodeState(
            stateType: stateType,
            defunctReason: record["defunctReason"] as? String,
            cenotaph: record["cenotaph"] as? String,
            turnState: turnState,
            signaledParticipantIDs: Array(signaledParticipantIDs)
        )

        let modifiedAt = record["modifiedAtDate"] as? Date ?? record.modificationDate ?? Date()

        return RoomLifecycle(spec: spec, state: state, modifiedAt: modifiedAt)
    }

    // MARK: - State Encoding/Decoding

    private static func encodeState(_ state: RoomState) -> (stateType: String, defunctReason: String?, cenotaph: String?, turnState: TurnState?) {
        switch state {
        case .draft:
            return ("draft", nil, nil, nil)
        case .pendingLightward:
            return ("pendingLightward", nil, nil, nil)
        case .pendingHumans:
            // Signaled participants tracked via Participant2.hasSignaledHere
            return ("pendingHumans", nil, nil, nil)
        case .pendingCapture:
            return ("pendingCapture", nil, nil, nil)
        case .active(let turn):
            return ("active", nil, nil, turn)
        case .locked(let cenotaph, let finalTurn):
            return ("locked", nil, cenotaph, finalTurn)
        case .defunct(let reason):
            return ("defunct", encodeDefunctReason(reason), nil, nil)
        }
    }

    private static func decodeState(
        stateType: String,
        defunctReason: String?,
        cenotaph: String?,
        turnState: TurnState?,
        signaledParticipantIDs: [String]
    ) -> RoomState {
        switch stateType {
        case "draft":
            return .draft
        case "pendingLightward":
            return .pendingLightward
        case "pendingHumans":
            return .pendingHumans(signaled: Set(signaledParticipantIDs))
        case "pendingCapture":
            return .pendingCapture
        case "active":
            return .active(turn: turnState ?? .initial)
        case "locked":
            return .locked(cenotaph: cenotaph ?? "", finalTurn: turnState ?? .initial)
        case "defunct":
            return .defunct(reason: decodeDefunctReason(defunctReason))
        default:
            return .draft
        }
    }

    private static func encodeDefunctReason(_ reason: DefunctReason) -> String {
        switch reason {
        case .resolutionFailed(let participantID):
            return "resolutionFailed:\(participantID)"
        case .lightwardDeclined:
            return "lightwardDeclined"
        case .paymentAuthorizationFailed:
            return "paymentAuthorizationFailed"
        case .paymentCaptureFailed:
            return "paymentCaptureFailed"
        case .cancelled:
            return "cancelled"
        case .expired:
            return "expired"
        }
    }

    private static func decodeTurnState(from record: CKRecord) -> TurnState? {
        guard let turnIndex = record["currentTurnIndex"] as? Int else {
            return nil
        }

        let raisedHands = Set(record["raisedHands"] as? [String] ?? [])

        var currentNeed: Need?
        if let needID = record["needID"] as? String,
           let needTypeRaw = record["needType"] as? String,
           let needType = NeedType(rawValue: needTypeRaw) {
            currentNeed = Need(
                id: needID,
                type: needType,
                claimedBy: record["needClaimedBy"] as? String,
                claimedAt: record["needClaimedAt"] as? Date
            )
        }

        return TurnState(
            currentTurnIndex: turnIndex,
            raisedHands: raisedHands,
            currentNeed: currentNeed
        )
    }

    private static func decodeDefunctReason(_ encoded: String?) -> DefunctReason {
        guard let encoded = encoded else { return .cancelled }

        if encoded.hasPrefix("resolutionFailed:") {
            let participantID = String(encoded.dropFirst("resolutionFailed:".count))
            return .resolutionFailed(participantID: participantID)
        }

        switch encoded {
        case "lightwardDeclined": return .lightwardDeclined
        case "paymentAuthorizationFailed": return .paymentAuthorizationFailed
        case "paymentCaptureFailed": return .paymentCaptureFailed
        case "cancelled": return .cancelled
        case "expired": return .expired
        default: return .cancelled
        }
    }

    // MARK: - Participant2 Record

    static func record(from spec: ParticipantSpec, roomID: String, userRecordID: String?, hasSignaledHere: Bool, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: spec.id, zoneID: zoneID)
        let record = CKRecord(recordType: participantRecordType, recordID: recordID)
        apply(spec: spec, roomID: roomID, userRecordID: userRecordID, hasSignaledHere: hasSignaledHere, to: record)
        return record
    }

    static func apply(spec: ParticipantSpec, roomID: String, userRecordID: String?, hasSignaledHere: Bool, to record: CKRecord) {
        record["roomID"] = roomID as NSString
        record["nickname"] = spec.nickname as NSString

        let (identifierType, identifierValue) = encodeIdentifier(spec.identifier)
        record["identifierType"] = identifierType as NSString
        record["identifierValue"] = identifierValue as NSString?

        record["userRecordID"] = userRecordID as NSString?
        record["hasSignaledHere"] = (hasSignaledHere ? 1 : 0) as NSNumber
    }

    static func participantSpec(from record: CKRecord) -> ParticipantSpec? {
        guard let nickname = record["nickname"] as? String,
              let identifierType = record["identifierType"] as? String else {
            return nil
        }

        let identifier = decodeIdentifier(
            type: identifierType,
            value: record["identifierValue"] as? String
        )

        return ParticipantSpec(
            id: record.recordID.recordName,
            identifier: identifier,
            nickname: nickname
        )
    }

    static func userRecordID(from record: CKRecord) -> String? {
        record["userRecordID"] as? String
    }

    static func hasSignaledHere(from record: CKRecord) -> Bool {
        (record["hasSignaledHere"] as? Int) == 1
    }

    static func roomID(from record: CKRecord) -> String? {
        record["roomID"] as? String
    }

    // MARK: - Identifier Encoding/Decoding

    private static func encodeIdentifier(_ identifier: ParticipantIdentifier) -> (type: String, value: String?) {
        switch identifier {
        case .email(let email):
            return ("email", email)
        case .phone(let phone):
            return ("phone", phone)
        case .lightward:
            return ("lightward", nil)
        case .currentUser:
            return ("currentUser", nil)
        }
    }

    private static func decodeIdentifier(type: String, value: String?) -> ParticipantIdentifier {
        switch type {
        case "email":
            return .email(value ?? "")
        case "phone":
            return .phone(value ?? "")
        case "lightward":
            return .lightward
        case "currentUser":
            return .currentUser
        default:
            return .lightward
        }
    }
}

