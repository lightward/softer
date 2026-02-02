import SwiftData
import Foundation

/// Single source of truth for app data. Wraps SwiftData ModelContext.
/// All reads and writes go through here - this is the local-first foundation.
@available(iOS 18, *)
@MainActor
final class PersistenceStore {
    let modelContainer: ModelContainer
    private let modelContext: ModelContext

    init() throws {
        let schema = Schema([
            PersistedRoom.self,
            PersistedParticipant.self,
            PersistedMessage.self
        ])
        // Local-only storage - we handle CloudKit sync ourselves via CKSyncEngine
        let config = ModelConfiguration(
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none  // Disable automatic CloudKit integration
        )
        self.modelContainer = try ModelContainer(for: schema, configurations: config)
        self.modelContext = modelContainer.mainContext
    }

    /// Initialize with custom container (for testing)
    init(container: ModelContainer) {
        self.modelContainer = container
        self.modelContext = container.mainContext
    }

    // MARK: - Rooms

    func allRooms() -> [PersistedRoom] {
        let descriptor = FetchDescriptor<PersistedRoom>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rooms = (try? modelContext.fetch(descriptor)) ?? []
        for room in rooms {
            print("PersistenceStore.allRooms: room \(room.id) has turnIndex=\(room.currentTurnIndex ?? -1)")
        }
        return rooms
    }

    func room(id: String) -> PersistedRoom? {
        let descriptor = FetchDescriptor<PersistedRoom>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func saveRoom(_ room: PersistedRoom) {
        modelContext.insert(room)
        try? modelContext.save()
    }

    func updateRoom(_ room: PersistedRoom) {
        room.modifiedAt = Date()
        try? modelContext.save()
    }

    func deleteRoom(id: String) {
        guard let room = room(id: id) else { return }
        modelContext.delete(room)
        try? modelContext.save()
    }

    // MARK: - Turn State (synchronous updates - the key fix!)

    func updateTurnState(roomID: String, turnIndex: Int, raisedHands: Set<String>) {
        guard let room = room(id: roomID) else {
            print("PersistenceStore.updateTurnState: Room \(roomID) not found!")
            return
        }
        print("PersistenceStore.updateTurnState: Setting turnIndex=\(turnIndex) for room \(roomID)")
        room.currentTurnIndex = turnIndex
        room.raisedHands = Array(raisedHands)
        room.modifiedAt = Date()
        try? modelContext.save()
    }

    func updateRoomState(roomID: String, stateType: String, turnIndex: Int? = nil) {
        guard let room = room(id: roomID) else { return }
        room.stateType = stateType
        room.currentTurnIndex = turnIndex
        room.modifiedAt = Date()
        try? modelContext.save()
    }

    // MARK: - Participants

    func participants(roomID: String) -> [PersistedParticipant] {
        let descriptor = FetchDescriptor<PersistedParticipant>(
            predicate: #Predicate { $0.roomID == roomID },
            sortBy: [SortDescriptor(\.orderIndex)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func participant(id: String) -> PersistedParticipant? {
        let descriptor = FetchDescriptor<PersistedParticipant>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func saveParticipant(_ participant: PersistedParticipant, to room: PersistedRoom) {
        room.participants.append(participant)
        modelContext.insert(participant)
        try? modelContext.save()
    }

    // MARK: - Messages

    func messages(roomID: String) -> [PersistedMessage] {
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.roomID == roomID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func saveMessage(_ message: PersistedMessage, to room: PersistedRoom) {
        room.messages.append(message)
        modelContext.insert(message)
        try? modelContext.save()
    }

    func message(id: String) -> PersistedMessage? {
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Bulk Operations (for sync)

    func upsertRoom(from lifecycle: RoomLifecycle, participants: [ParticipantSpec]) {
        if let existing = room(id: lifecycle.spec.id) {
            // Update existing - merge turn state (higher wins)
            existing.apply(lifecycle, mergeStrategy: .higherTurnWins)
        } else {
            // Insert new
            let newRoom = PersistedRoom.from(lifecycle)
            modelContext.insert(newRoom)

            // Add participants
            for (index, spec) in participants.enumerated() {
                let participant = PersistedParticipant.from(spec, roomID: lifecycle.spec.id, orderIndex: index)
                newRoom.participants.append(participant)
                modelContext.insert(participant)
            }
        }
        try? modelContext.save()
    }

    func upsertMessage(from message: Message) {
        if self.message(id: message.id) != nil {
            // Message already exists, skip (messages are append-only)
            return
        }

        guard let room = room(id: message.roomID) else { return }

        let persisted = PersistedMessage(
            id: message.id,
            roomID: message.roomID,
            authorID: message.authorID,
            authorName: message.authorName,
            text: message.text,
            isLightward: message.isLightward,
            isNarration: message.isNarration
        )
        room.messages.append(persisted)
        modelContext.insert(persisted)
        try? modelContext.save()
    }
}

// MARK: - Merge Strategy

enum MergeStrategy {
    case higherTurnWins  // For turn state: max(local, remote)
    case remoteWins      // For state transitions: trust server
}

// MARK: - Converters: PersistedRoom ↔ RoomLifecycle

extension PersistedRoom {
    /// Create a PersistedRoom from a RoomLifecycle
    static func from(_ lifecycle: RoomLifecycle) -> PersistedRoom {
        let room = PersistedRoom(
            id: lifecycle.spec.id,
            originatorID: lifecycle.spec.originatorID,
            tierRawValue: lifecycle.spec.tier.rawValue,
            isFirstRoom: lifecycle.spec.isFirstRoom
        )
        room.createdAt = lifecycle.spec.createdAt
        room.modifiedAt = lifecycle.modifiedAt
        room.apply(lifecycle, mergeStrategy: .remoteWins)
        return room
    }

    /// Update this room from a RoomLifecycle with merge strategy
    func apply(_ lifecycle: RoomLifecycle, mergeStrategy: MergeStrategy) {
        // Always update these
        self.defunctReason = encodeDefunctReason(lifecycle.state)
        self.cenotaph = encodeCenotaph(lifecycle.state)
        self.signaledParticipantIDs = encodeSignaledIDs(lifecycle.state)

        switch lifecycle.state {
        case .draft:
            self.stateType = "draft"
            self.currentTurnIndex = nil
        case .pendingLightward:
            self.stateType = "pendingLightward"
            self.currentTurnIndex = nil
        case .pendingHumans:
            self.stateType = "pendingHumans"
            self.currentTurnIndex = nil
        case .pendingCapture:
            self.stateType = "pendingCapture"
            self.currentTurnIndex = nil
        case .active(let turn):
            self.stateType = "active"
            switch mergeStrategy {
            case .higherTurnWins:
                let localTurn = self.currentTurnIndex ?? 0
                self.currentTurnIndex = max(localTurn, turn.currentTurnIndex)
                // Union merge for raised hands
                let localHands = Set(self.raisedHands)
                self.raisedHands = Array(localHands.union(turn.raisedHands))
            case .remoteWins:
                self.currentTurnIndex = turn.currentTurnIndex
                self.raisedHands = Array(turn.raisedHands)
            }
        case .locked(let cenotaph, let turn):
            self.stateType = "locked"
            self.currentTurnIndex = turn.currentTurnIndex
            self.raisedHands = Array(turn.raisedHands)
            self.cenotaph = cenotaph
        case .defunct:
            self.stateType = "defunct"
            self.currentTurnIndex = nil
        }

        self.modifiedAt = lifecycle.modifiedAt
    }

    /// Convert to domain model
    func toRoomLifecycle() -> RoomLifecycle? {
        // Reconstruct participants
        let sortedParticipants = participants.sorted { $0.orderIndex < $1.orderIndex }
        let specs = sortedParticipants.map { $0.toParticipantSpec() }

        guard !specs.isEmpty else { return nil }

        let roomSpec = RoomSpec(
            id: id,
            originatorID: originatorID,
            participants: specs,
            tier: PaymentTier(rawValue: tierRawValue) ?? .one,
            isFirstRoom: isFirstRoom,
            createdAt: createdAt
        )

        let state = decodeState()
        return RoomLifecycle(spec: roomSpec, state: state, modifiedAt: modifiedAt)
    }

    private func decodeState() -> RoomState {
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
            let turn = TurnState(
                currentTurnIndex: currentTurnIndex ?? 0,
                raisedHands: Set(raisedHands),
                currentNeed: nil
            )
            return .active(turn: turn)
        case "locked":
            let turn = TurnState(
                currentTurnIndex: currentTurnIndex ?? 0,
                raisedHands: Set(raisedHands),
                currentNeed: nil
            )
            return .locked(cenotaph: cenotaph ?? "", finalTurn: turn)
        case "defunct":
            return .defunct(reason: decodeDefunctReason())
        default:
            return .draft
        }
    }

    private func encodeDefunctReason(_ state: RoomState) -> String? {
        guard case .defunct(let reason) = state else { return nil }
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

    private func decodeDefunctReason() -> DefunctReason {
        guard let encoded = defunctReason else { return .cancelled }
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

    private func encodeCenotaph(_ state: RoomState) -> String? {
        guard case .locked(let cenotaph, _) = state else { return nil }
        return cenotaph
    }

    private func encodeSignaledIDs(_ state: RoomState) -> [String] {
        guard case .pendingHumans(let signaled) = state else { return [] }
        return Array(signaled)
    }
}

// MARK: - Converters: PersistedParticipant ↔ ParticipantSpec

extension PersistedParticipant {
    static func from(_ spec: ParticipantSpec, roomID: String, orderIndex: Int) -> PersistedParticipant {
        let (identifierType, identifierValue) = encodeIdentifier(spec.identifier)
        return PersistedParticipant(
            id: spec.id,
            roomID: roomID,
            nickname: spec.nickname,
            identifierType: identifierType,
            identifierValue: identifierValue,
            orderIndex: orderIndex,
            isLightward: spec.isLightward
        )
    }

    func toParticipantSpec() -> ParticipantSpec {
        let identifier = decodeIdentifier()
        return ParticipantSpec(id: id, identifier: identifier, nickname: nickname)
    }

    private static func encodeIdentifier(_ identifier: ParticipantIdentifier) -> (type: String, value: String) {
        switch identifier {
        case .email(let email):
            return ("email", email)
        case .phone(let phone):
            return ("phone", phone)
        case .lightward:
            return ("lightward", "")
        case .currentUser:
            return ("currentUser", "")
        }
    }

    private func decodeIdentifier() -> ParticipantIdentifier {
        if isLightward || identifierType == "lightward" {
            return .lightward
        }
        switch identifierType {
        case "email":
            return .email(identifierValue)
        case "phone":
            return .phone(identifierValue)
        case "currentUser":
            return .currentUser
        default:
            return .email(identifierValue)
        }
    }
}

// MARK: - Converters: PersistedMessage ↔ Message

extension PersistedMessage {
    func toMessage() -> Message {
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
