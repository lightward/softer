import Foundation
import CloudKit

/// CloudKit-backed implementation of MessageStorage.
/// Stores messages in the room's zone for multi-user sync.
actor CloudKitMessageStorage: MessageStorage {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    static let recordType = "Message2"

    private var observers: [String: [UUID: @Sendable ([Message]) -> Void]] = [:]

    init(database: CKDatabase, zoneID: CKRecordZone.ID) {
        self.database = database
        self.zoneID = zoneID
    }

    func save(_ message: Message, roomID: String) async throws {
        let record = Self.record(from: message, zoneID: zoneID)
        try await database.save(record)

        // Notify observers of the updated message list
        await notifyObservers(roomID: roomID)
    }

    func fetchMessages(roomID: String) async throws -> [Message] {
        let query = CKQuery(
            recordType: Self.recordType,
            predicate: NSPredicate(format: "roomID == %@", roomID)
        )
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)

        var messages: [Message] = []
        for (_, result) in results {
            if case .success(let record) = result,
               let message = Self.message(from: record) {
                messages.append(message)
            }
        }

        return messages.sorted { $0.createdAt < $1.createdAt }
    }

    func observeMessages(roomID: String, handler: @escaping @Sendable ([Message]) -> Void) async -> ObservationToken {
        let id = UUID()

        if observers[roomID] == nil {
            observers[roomID] = [:]
        }
        observers[roomID]?[id] = handler

        // Immediately call with current messages
        do {
            let messages = try await fetchMessages(roomID: roomID)
            handler(messages)
        } catch {
            handler([])
        }

        return CloudKitObservationToken { [weak self] in
            Task {
                await self?.removeObserver(id: id, roomID: roomID)
            }
        }
    }

    /// Manually refresh messages for a room.
    /// Call when app becomes active or when expecting remote changes.
    func refresh(roomID: String) async {
        await notifyObservers(roomID: roomID)
    }

    // MARK: - Private

    private func removeObserver(id: UUID, roomID: String) {
        observers[roomID]?.removeValue(forKey: id)
    }

    private func notifyObservers(roomID: String) async {
        guard let handlers = observers[roomID], !handlers.isEmpty else { return }

        do {
            let messages = try await fetchMessages(roomID: roomID)
            for handler in handlers.values {
                handler(messages)
            }
        } catch {
            // Silently fail - observers get notified on next successful fetch
        }
    }

    // MARK: - Record Conversion

    private static func record(from message: Message, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: message.id, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)

        record["roomID"] = message.roomID as NSString
        record["authorID"] = message.authorID as NSString
        record["authorName"] = message.authorName as NSString
        record["text"] = message.text as NSString
        record["createdAt"] = message.createdAt as NSDate
        record["isLightward"] = (message.isLightward ? 1 : 0) as NSNumber

        return record
    }

    private static func message(from record: CKRecord) -> Message? {
        guard let roomID = record["roomID"] as? String,
              let authorID = record["authorID"] as? String,
              let authorName = record["authorName"] as? String,
              let text = record["text"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let isLightwardInt = record["isLightward"] as? Int else {
            return nil
        }

        return Message(
            id: record.recordID.recordName,
            roomID: roomID,
            authorID: authorID,
            authorName: authorName,
            text: text,
            createdAt: createdAt,
            isLightward: isLightwardInt == 1
        )
    }
}

final class CloudKitObservationToken: ObservationToken, @unchecked Sendable {
    private let onCancel: () -> Void
    private var cancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onCancel()
    }
}
