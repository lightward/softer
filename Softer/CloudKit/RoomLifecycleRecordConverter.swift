import Foundation
import CloudKit

/// Embedded participant data for Room3 records.
/// Stored as JSON in the participantsJSON field.
struct EmbeddedParticipant: Codable, Equatable {
    let id: String
    let nickname: String
    let identifierType: String
    let identifierValue: String?
    let orderIndex: Int
    var hasSignaledHere: Bool
    let userRecordID: String?  // Resolved CloudKit identity (nil for Lightward)

    init(from spec: ParticipantSpec, orderIndex: Int, hasSignaledHere: Bool, userRecordID: String? = nil) {
        self.id = spec.id
        self.nickname = spec.nickname
        self.orderIndex = orderIndex
        self.hasSignaledHere = hasSignaledHere
        self.userRecordID = userRecordID

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

    /// Memberwise initializer for all fields.
    init(id: String, nickname: String, identifierType: String, identifierValue: String?, orderIndex: Int, hasSignaledHere: Bool, userRecordID: String?) {
        self.id = id
        self.nickname = nickname
        self.identifierType = identifierType
        self.identifierValue = identifierValue
        self.orderIndex = orderIndex
        self.hasSignaledHere = hasSignaledHere
        self.userRecordID = userRecordID
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

/// Embedded message data for Room3 records.
/// Stored as JSON in the messagesJSON field.
struct EmbeddedMessage: Codable, Equatable {
    let id: String
    let authorID: String
    let authorName: String
    let text: String
    let createdAt: Date
    let isLightward: Bool
    let isNarration: Bool

    init(from message: Message) {
        self.id = message.id
        self.authorID = message.authorID
        self.authorName = message.authorName
        self.text = message.text
        self.createdAt = message.createdAt
        self.isLightward = message.isLightward
        self.isNarration = message.isNarration
    }

    func toMessage(roomID: String) -> Message {
        Message(
            id: id,
            roomID: roomID,
            authorID: authorID,
            authorName: authorName,
            text: text,
            createdAt: createdAt,
            isLightward: isLightward,
            isNarration: isNarration
        )
    }
}

/// Converts between RoomLifecycle domain models and CloudKit records.
/// Uses "Room3" record type with embedded participants (no separate Participant records).
enum RoomLifecycleRecordConverter {

    // MARK: - Record Type Name

    static let roomRecordType = "Room3"

    // MARK: - CKRecord System Fields

    /// Encode a CKRecord's system fields (zone ID, change tag, share reference) to Data.
    static func encodeSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// Reconstruct a CKRecord from stored system fields, preserving zone ID and change tag.
    /// Falls back to a fresh record if systemFields is nil.
    static func record(fromSystemFields systemFields: Data?, recordName: String, fallbackZoneID: CKRecordZone.ID) -> CKRecord {
        if let systemFields = systemFields {
            do {
                let coder = try NSKeyedUnarchiver(forReadingFrom: systemFields)
                coder.requiresSecureCoding = true
                if let record = CKRecord(coder: coder) {
                    coder.finishDecoding()
                    return record
                }
                coder.finishDecoding()
            } catch {
                print("RoomLifecycleRecordConverter: Failed to decode system fields: \(error)")
            }
        }
        // Fallback: fresh record
        let recordID = CKRecord.ID(recordName: recordName, zoneID: fallbackZoneID)
        return CKRecord(recordType: roomRecordType, recordID: recordID)
    }

    // MARK: - Room3 Record (RoomSpec + RoomState + Participants)

    static func record(from lifecycle: RoomLifecycle, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: lifecycle.spec.id, zoneID: zoneID)
        let record = CKRecord(recordType: roomRecordType, recordID: recordID)
        apply(lifecycle, to: record)
        return record
    }

    static func apply(
        _ lifecycle: RoomLifecycle,
        to record: CKRecord,
        messages: [Message] = [],
        resolvedParticipants: [ResolvedParticipant] = []
    ) {
        let spec = lifecycle.spec

        // Build lookup of participantID -> userRecordID
        let userRecordIDsByParticipant = Dictionary(
            uniqueKeysWithValues: resolvedParticipants.compactMap { resolved -> (String, String)? in
                guard let userRecordID = resolved.userRecordID else { return nil }
                return (resolved.spec.id, userRecordID)
            }
        )

        // RoomSpec fields
        record["originatorID"] = spec.originatorID as NSString
        record["tier"] = spec.tier.rawValue as NSNumber
        record["createdAtDate"] = spec.createdAt as NSDate
        record["modifiedAtDate"] = lifecycle.modifiedAt as NSDate

        // Embedded participants as JSON (now includes resolved userRecordID)
        let embeddedParticipants = spec.participants.enumerated().map { index, participantSpec in
            let hasSignaled = signaledParticipantIDs(from: lifecycle.state).contains(participantSpec.id)
            let userRecordID = userRecordIDsByParticipant[participantSpec.id]
            return EmbeddedParticipant(
                from: participantSpec,
                orderIndex: index,
                hasSignaledHere: hasSignaled,
                userRecordID: userRecordID
            )
        }
        if let jsonData = try? JSONEncoder().encode(embeddedParticipants),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            record["participantsJSON"] = jsonString as NSString
        }

        // Embedded messages as JSON
        record["messagesJSON"] = encodeMessages(messages) as NSString

        // RoomState fields
        let encoded = encodeState(lifecycle.state)
        record["stateType"] = encoded.stateType as NSString
        record["defunctReason"] = encoded.defunctReason as NSString?
        record["cenotaph"] = encoded.cenotaph as NSString?

        // TurnState fields (for active/locked states)
        if let turn = encoded.turnState {
            record["currentTurnIndex"] = turn.currentTurnIndex as NSNumber

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
        case .pendingParticipants(let signaled):
            return signaled
        case .active, .locked:
            // In active/locked states, all participants have signaled
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
        case .pendingParticipants:
            return ("pendingParticipants", nil, nil, nil)
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
        case "pendingParticipants":
            return .pendingParticipants(signaled: Set(signaledParticipantIDs))
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
        case .participantDeclined(let participantID):
            return "participantDeclined:\(participantID)"
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
            currentNeed: currentNeed
        )
    }

    private static func decodeDefunctReason(_ encoded: String?) -> DefunctReason {
        guard let encoded = encoded else { return .cancelled }

        if encoded.hasPrefix("resolutionFailed:") {
            let participantID = String(encoded.dropFirst("resolutionFailed:".count))
            return .resolutionFailed(participantID: participantID)
        }
        if encoded.hasPrefix("participantDeclined:") {
            let participantID = String(encoded.dropFirst("participantDeclined:".count))
            return .participantDeclined(participantID: participantID)
        }

        switch encoded {
        case "paymentAuthorizationFailed": return .paymentAuthorizationFailed
        case "paymentCaptureFailed": return .paymentCaptureFailed
        case "cancelled": return .cancelled
        case "expired": return .expired
        default: return .cancelled
        }
    }

    // MARK: - Message Encoding/Decoding

    /// Encode messages to JSON string for storage in CKRecord.
    static func encodeMessages(_ messages: [Message]) -> String {
        let embedded = messages.map { EmbeddedMessage(from: $0) }
        if let data = try? JSONEncoder().encode(embedded),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "[]"
    }

    /// Decode messages from JSON string in CKRecord.
    static func decodeMessages(from json: String, roomID: String) -> [Message] {
        guard let data = json.data(using: .utf8),
              let embedded = try? JSONDecoder().decode([EmbeddedMessage].self, from: data) else {
            return []
        }
        return embedded
            .map { $0.toMessage(roomID: roomID) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Merge local and remote messages by union on ID, sorted by createdAt.
    static func mergeMessages(local: [Message], remote: [Message]) -> [Message] {
        var byID: [String: Message] = [:]
        for message in local {
            byID[message.id] = message
        }
        for message in remote {
            byID[message.id] = message
        }
        return byID.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Sharing Helpers

    /// Extract lookup infos for other human participants (not currentUser, not Lightward).
    /// Returns (email/phone type, value) tuples for sharing.
    static func otherParticipantLookupInfos(from record: CKRecord) -> [CKUserIdentity.LookupInfo] {
        guard let participantsJSON = record["participantsJSON"] as? String,
              let jsonData = participantsJSON.data(using: .utf8),
              let embedded = try? JSONDecoder().decode([EmbeddedParticipant].self, from: jsonData) else {
            return []
        }

        return embedded.compactMap { participant -> CKUserIdentity.LookupInfo? in
            // Skip Lightward and currentUser
            guard participant.identifierType == "email" || participant.identifierType == "phone",
                  let value = participant.identifierValue else {
                return nil
            }

            switch participant.identifierType {
            case "email":
                return CKUserIdentity.LookupInfo(emailAddress: value)
            case "phone":
                return CKUserIdentity.LookupInfo(phoneNumber: value)
            default:
                return nil
            }
        }
    }
}
