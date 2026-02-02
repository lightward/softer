import Foundation
import CloudKit

/// Embedded participant data for Room3 records.
/// Stored as JSON in the participantsJSON field.
struct EmbeddedParticipant: Codable {
    let id: String
    let nickname: String
    let identifierType: String
    let identifierValue: String?
    let orderIndex: Int
    var hasSignaledHere: Bool

    init(from spec: ParticipantSpec, orderIndex: Int, hasSignaledHere: Bool) {
        self.id = spec.id
        self.nickname = spec.nickname
        self.orderIndex = orderIndex
        self.hasSignaledHere = hasSignaledHere

        switch spec.identifier {
        case .email(let email):
            self.identifierType = "email"
            self.identifierValue = email
        case .phone(let phone):
            self.identifierType = "phone"
            self.identifierValue = phone
        case .lightward:
            self.identifierType = "lightward"
            self.identifierValue = nil
        case .currentUser:
            self.identifierType = "currentUser"
            self.identifierValue = nil
        }
    }

    func toParticipantSpec() -> ParticipantSpec {
        let identifier: ParticipantIdentifier
        switch identifierType {
        case "email":
            identifier = .email(identifierValue ?? "")
        case "phone":
            identifier = .phone(identifierValue ?? "")
        case "lightward":
            identifier = .lightward
        case "currentUser":
            identifier = .currentUser
        default:
            identifier = .lightward
        }
        return ParticipantSpec(id: id, identifier: identifier, nickname: nickname)
    }
}

/// Converts between RoomLifecycle domain models and CloudKit records.
/// Uses "Room3" record type with embedded participants (no separate Participant records).
enum RoomLifecycleRecordConverter {

    // MARK: - Record Type Name

    static let roomRecordType = "Room3"

    // MARK: - Room3 Record (RoomSpec + RoomState + Participants)

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

        // Embedded participants as JSON
        let embeddedParticipants = spec.participants.enumerated().map { index, participantSpec in
            let hasSignaled = signaledParticipantIDs(from: lifecycle.state).contains(participantSpec.id)
            return EmbeddedParticipant(from: participantSpec, orderIndex: index, hasSignaledHere: hasSignaled)
        }
        if let jsonData = try? JSONEncoder().encode(embeddedParticipants),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            record["participantsJSON"] = jsonString as NSString
        }

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

    /// Reconstructs a RoomLifecycle from a Room3 record (participants embedded).
    static func lifecycle(from record: CKRecord) -> RoomLifecycle? {
        guard let originatorID = record["originatorID"] as? String,
              let tierRaw = record["tier"] as? Int,
              let tier = PaymentTier(rawValue: tierRaw),
              let isFirstRoomInt = record["isFirstRoom"] as? Int,
              let stateType = record["stateType"] as? String,
              let participantsJSON = record["participantsJSON"] as? String,
              let jsonData = participantsJSON.data(using: .utf8),
              let embeddedParticipants = try? JSONDecoder().decode([EmbeddedParticipant].self, from: jsonData) else {
            return nil
        }

        // Convert embedded participants to specs (sorted by orderIndex)
        let sortedParticipants = embeddedParticipants.sorted { $0.orderIndex < $1.orderIndex }
        let participantSpecs = sortedParticipants.map { $0.toParticipantSpec() }
        let signaledIDs = Set(sortedParticipants.filter { $0.hasSignaledHere }.map { $0.id })

        let spec = RoomSpec(
            id: record.recordID.recordName,
            originatorID: originatorID,
            participants: participantSpecs,
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
            signaledParticipantIDs: Array(signaledIDs)
        )

        let modifiedAt = record["modifiedAtDate"] as? Date ?? record.modificationDate ?? Date()

        return RoomLifecycle(spec: spec, state: state, modifiedAt: modifiedAt)
    }

    /// Extract signaled participant IDs from room state (for encoding to record).
    private static func signaledParticipantIDs(from state: RoomState) -> Set<String> {
        switch state {
        case .pendingHumans(let signaled):
            return signaled
        case .active, .locked:
            // In active/locked states, all humans have signaled
            return []  // We track via hasSignaledHere on each participant
        default:
            return []
        }
    }

    // MARK: - State Encoding/Decoding

    private static func encodeState(_ state: RoomState) -> (stateType: String, defunctReason: String?, cenotaph: String?, turnState: TurnState?) {
        switch state {
        case .draft:
            return ("draft", nil, nil, nil)
        case .pendingLightward:
            return ("pendingLightward", nil, nil, nil)
        case .pendingHumans:
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
}
