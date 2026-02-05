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
            PersistedRoom.self
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
        return (try? modelContext.fetch(descriptor)) ?? []
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

    // MARK: - Participant State

    func signalHere(roomID: String, participantID: String) {
        guard let room = room(id: roomID) else { return }
        var participants = room.embeddedParticipants()
        if let index = participants.firstIndex(where: { $0.id == participantID }) {
            participants[index].hasSignaledHere = true
            room.setParticipants(participants)
            room.modifiedAt = Date()
            try? modelContext.save()
        }
    }

    // MARK: - Turn State

    func updateTurnState(roomID: String, turnIndex: Int, raisedHands: Set<String>) {
        guard let room = room(id: roomID) else { return }
        room.currentTurnIndex = turnIndex
        room.raisedHands = Array(raisedHands)
        room.modifiedAt = Date()
        try? modelContext.save()
    }

    // MARK: - Messages

    func messages(roomID: String) -> [Message] {
        room(id: roomID)?.messages() ?? []
    }

    func addMessage(_ message: Message, to room: PersistedRoom) {
        room.addMessage(message)
        room.modifiedAt = Date()
        try? modelContext.save()
    }

    func message(id: String, roomID: String) -> Message? {
        room(id: roomID)?.messages().first { $0.id == id }
    }

    // MARK: - Sync Operations

    func upsertRoom(from lifecycle: RoomLifecycle, remoteParticipantsJSON: String? = nil, remoteMessagesJSON: String? = nil) {
        if let existing = room(id: lifecycle.spec.id) {
            // Update existing - merge turn state (higher wins)
            existing.apply(lifecycle, mergeStrategy: .higherTurnWins)
            // Preserve participantsJSON from CKRecord (has userRecordIDs that RoomLifecycle strips)
            if let json = remoteParticipantsJSON {
                existing.participantsJSON = json
            }
            // Merge messages if provided
            if let json = remoteMessagesJSON {
                existing.mergeMessages(from: json)
            }
        } else {
            // Insert new
            let newRoom = PersistedRoom.from(lifecycle)
            // Preserve participantsJSON from CKRecord (has userRecordIDs)
            if let json = remoteParticipantsJSON {
                newRoom.participantsJSON = json
            }
            // Apply remote messages if provided
            if let json = remoteMessagesJSON {
                newRoom.messagesJSON = json
            }
            modelContext.insert(newRoom)
        }
        try? modelContext.save()
    }
}

// MARK: - Merge Strategy

enum MergeStrategy {
    case higherTurnWins  // For turn state: max(local, remote)
    case remoteWins      // For state transitions: trust server
}

// MARK: - Converters: PersistedRoom <-> RoomLifecycle

extension PersistedRoom {
    /// Create a PersistedRoom from a RoomLifecycle (participants embedded as JSON)
    static func from(_ lifecycle: RoomLifecycle) -> PersistedRoom {
        // Build embedded participants
        let embedded = lifecycle.spec.participants.enumerated().map { index, spec in
            let hasSignaled = signaledIDs(from: lifecycle.state).contains(spec.id)
            return EmbeddedParticipant(from: spec, orderIndex: index, hasSignaledHere: hasSignaled)
        }
        let participantsJSON: String
        if let data = try? JSONEncoder().encode(embedded),
           let json = String(data: data, encoding: .utf8) {
            participantsJSON = json
        } else {
            participantsJSON = "[]"
        }

        let room = PersistedRoom(
            id: lifecycle.spec.id,
            originatorID: lifecycle.spec.originatorID,
            tierRawValue: lifecycle.spec.tier.rawValue,
            isFirstRoom: lifecycle.spec.isFirstRoom,
            participantsJSON: participantsJSON
        )
        room.createdAt = lifecycle.spec.createdAt
        room.modifiedAt = lifecycle.modifiedAt
        room.apply(lifecycle, mergeStrategy: .remoteWins)
        return room
    }

    private static func signaledIDs(from state: RoomState) -> Set<String> {
        if case .pendingHumans(let signaled) = state {
            return signaled
        }
        return []
    }

    /// Update this room from a RoomLifecycle with merge strategy
    func apply(_ lifecycle: RoomLifecycle, mergeStrategy: MergeStrategy) {
        // Update participants JSON
        let embedded = lifecycle.spec.participants.enumerated().map { index, spec in
            let hasSignaled = Self.signaledIDs(from: lifecycle.state).contains(spec.id)
            return EmbeddedParticipant(from: spec, orderIndex: index, hasSignaledHere: hasSignaled)
        }
        setParticipants(embedded)

        // Update state fields
        self.defunctReason = encodeDefunctReason(lifecycle.state)
        self.cenotaph = encodeCenotaph(lifecycle.state)

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
        let embedded = embeddedParticipants()
        guard !embedded.isEmpty else { return nil }

        let specs = embedded.map { $0.toParticipantSpec() }
        let signaledIDs = Set(embedded.filter { $0.hasSignaledHere }.map { $0.id })

        let roomSpec = RoomSpec(
            id: id,
            originatorID: originatorID,
            participants: specs,
            tier: PaymentTier(rawValue: tierRawValue) ?? .one,
            isFirstRoom: isFirstRoom,
            createdAt: createdAt
        )

        let state = decodeState(signaledIDs: signaledIDs)
        return RoomLifecycle(spec: roomSpec, state: state, modifiedAt: modifiedAt)
    }

    private func decodeState(signaledIDs: Set<String>) -> RoomState {
        switch stateType {
        case "draft":
            return .draft
        case "pendingLightward":
            return .pendingLightward
        case "pendingHumans":
            return .pendingHumans(signaled: signaledIDs)
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
}
