import Foundation
import CloudKit

/// Manages CloudKit storage for the new RoomLifecycle model.
/// Handles Room2 and Participant2 record types.
actor RoomLifecycleStorage {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    init(database: CKDatabase, zoneID: CKRecordZone.ID) {
        self.database = database
        self.zoneID = zoneID
    }

    // MARK: - Save Operations

    /// Saves a new room with its participants.
    /// Used when creating a room from draft state.
    func saveRoom(
        lifecycle: RoomLifecycle,
        resolvedParticipants: [ResolvedParticipant]
    ) async throws {
        let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)

        var participantRecords: [CKRecord] = []
        for (index, resolved) in resolvedParticipants.enumerated() {
            let record = RoomLifecycleRecordConverter.record(
                from: resolved.spec,
                roomID: lifecycle.spec.id,
                userRecordID: resolved.userRecordID,
                hasSignaledHere: false,
                orderIndex: index,
                zoneID: zoneID
            )
            participantRecords.append(record)
        }

        let allRecords = [roomRecord] + participantRecords

        let operation = CKModifyRecordsOperation(recordsToSave: allRecords)
        operation.savePolicy = .ifServerRecordUnchanged

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    /// Updates the room state.
    func updateRoomState(_ lifecycle: RoomLifecycle) async throws {
        let recordID = CKRecord.ID(recordName: lifecycle.spec.id, zoneID: zoneID)
        let record = try await database.record(for: recordID)
        RoomLifecycleRecordConverter.apply(lifecycle, to: record)

        let operation = CKModifyRecordsOperation(recordsToSave: [record])
        operation.savePolicy = .ifServerRecordUnchanged

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    /// Marks a participant as having signaled "here".
    func markParticipantSignaled(participantID: String) async throws {
        let recordID = CKRecord.ID(recordName: participantID, zoneID: zoneID)
        let record = try await database.record(for: recordID)
        record["hasSignaledHere"] = 1 as NSNumber

        let operation = CKModifyRecordsOperation(recordsToSave: [record])
        operation.savePolicy = .ifServerRecordUnchanged

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    // MARK: - Fetch Operations

    /// Fetches a room lifecycle by ID.
    func fetchRoom(id: String) async throws -> RoomLifecycle? {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)

        let roomRecord: CKRecord
        do {
            roomRecord = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }

        // Fetch participants for this room
        let (participants, signaledIDs) = try await fetchParticipants(roomID: id)

        return RoomLifecycleRecordConverter.lifecycle(
            from: roomRecord,
            participants: participants,
            signaledParticipantIDs: signaledIDs
        )
    }

    /// Fetches all rooms (for room list).
    func fetchAllRooms() async throws -> [RoomLifecycle] {
        let query = CKQuery(
            recordType: RoomLifecycleRecordConverter.roomRecordType,
            predicate: NSPredicate(value: true)
        )

        let results: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
        } catch let error as CKError where error.code == .unknownItem {
            // Record type doesn't exist yet — no rooms
            return []
        }

        var lifecycles: [RoomLifecycle] = []
        for (_, result) in results {
            if case .success(let record) = result {
                let roomID = record.recordID.recordName
                let (participants, signaledIDs) = try await fetchParticipants(roomID: roomID)
                if let lifecycle = RoomLifecycleRecordConverter.lifecycle(
                    from: record,
                    participants: participants,
                    signaledParticipantIDs: signaledIDs
                ) {
                    lifecycles.append(lifecycle)
                }
            }
        }

        return lifecycles.sorted { $0.spec.createdAt < $1.spec.createdAt }
    }

    /// Fetches active rooms only (for room list display).
    func fetchActiveRooms() async throws -> [RoomLifecycle] {
        let query = CKQuery(
            recordType: RoomLifecycleRecordConverter.roomRecordType,
            predicate: NSPredicate(format: "stateType == %@", "active")
        )

        let results: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
        } catch let error as CKError where error.code == .unknownItem {
            // Record type doesn't exist yet — no rooms
            return []
        }

        var lifecycles: [RoomLifecycle] = []
        for (_, result) in results {
            if case .success(let record) = result {
                let roomID = record.recordID.recordName
                let (participants, signaledIDs) = try await fetchParticipants(roomID: roomID)
                if let lifecycle = RoomLifecycleRecordConverter.lifecycle(
                    from: record,
                    participants: participants,
                    signaledParticipantIDs: signaledIDs
                ) {
                    lifecycles.append(lifecycle)
                }
            }
        }

        return lifecycles.sorted { $0.spec.createdAt < $1.spec.createdAt }
    }

    /// Fetches participants for a room.
    private func fetchParticipants(roomID: String) async throws -> (participants: [ParticipantSpec], signaledIDs: Set<String>) {
        let query = CKQuery(
            recordType: RoomLifecycleRecordConverter.participantRecordType,
            predicate: NSPredicate(format: "roomID == %@", roomID)
        )

        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)

        var participantsWithOrder: [(spec: ParticipantSpec, order: Int)] = []
        var signaledIDs: Set<String> = []

        for (_, result) in results {
            if case .success(let record) = result {
                if let spec = RoomLifecycleRecordConverter.participantSpec(from: record) {
                    let order = RoomLifecycleRecordConverter.orderIndex(from: record)
                    participantsWithOrder.append((spec, order))
                    if RoomLifecycleRecordConverter.hasSignaledHere(from: record) {
                        signaledIDs.insert(spec.id)
                    }
                }
            }
        }

        // Sort by orderIndex to preserve original creation order
        let participants = participantsWithOrder.sorted { $0.order < $1.order }.map { $0.spec }

        return (participants, signaledIDs)
    }

    // MARK: - Delete Operations

    /// Deletes a room and all its participants and messages.
    func deleteRoom(id: String) async throws {
        // Fetch participant IDs
        let (participants, _) = try await fetchParticipants(roomID: id)

        // Fetch message IDs
        let messageIDs = try await fetchMessageIDs(roomID: id)

        var recordIDsToDelete: [CKRecord.ID] = []

        // Room record
        recordIDsToDelete.append(CKRecord.ID(recordName: id, zoneID: zoneID))

        // Participant records
        for participant in participants {
            recordIDsToDelete.append(CKRecord.ID(recordName: participant.id, zoneID: zoneID))
        }

        // Message records
        for messageID in messageIDs {
            recordIDsToDelete.append(CKRecord.ID(recordName: messageID, zoneID: zoneID))
        }

        let operation = CKModifyRecordsOperation(recordIDsToDelete: recordIDsToDelete)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    /// Fetches message record IDs for a room.
    private func fetchMessageIDs(roomID: String) async throws -> [String] {
        let query = CKQuery(
            recordType: "Message2",
            predicate: NSPredicate(format: "roomID == %@", roomID)
        )

        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)

        return results.compactMap { (recordID, result) -> String? in
            if case .success = result {
                return recordID.recordName
            }
            return nil
        }
    }
}
