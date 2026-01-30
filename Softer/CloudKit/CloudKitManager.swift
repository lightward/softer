import Foundation
import CloudKit
import UIKit

enum CloudKitStatus: Sendable {
    case loading
    case available
    case unavailable(String)
}

@Observable
final class CloudKitManager: @unchecked Sendable {
    private var container: CKContainer?
    private var privateDB: CKDatabase?
    private var sharedDB: CKDatabase?

    private(set) var status: CloudKitStatus = .loading
    private(set) var initialFetchCompleted = false
    private(set) var rooms: [Room] = []
    private(set) var messagesByRoom: [String: [Message]] = [:]
    private(set) var participantsByRoom: [String: [Participant]] = [:]
    private(set) var localUserRecordID: String?

    private var zoneManager: ZoneManager?
    private var shareManager: ShareManager?
    private var atomicClaim: AtomicClaim?

    private var privateSyncEngine: PrivateSyncEngine?
    private var sharedSyncEngine: SharedSyncEngine?

    private var zoneID: CKRecordZone.ID?

    init() {
        Task {
            await setup()
        }

        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            print("[Softer] CKAccountChanged notification received")
            guard let self else { return }
            Task {
                await self.setup()
            }
        }
    }

    private func setup() async {
        print("[Softer] setup() called, current status: \(status)")
        if case .available = status { return }

        do {
            print("[Softer] Creating CKContainer(\(Constants.containerIdentifier))")
            let ckContainer = CKContainer(identifier: Constants.containerIdentifier)
            print("[Softer] CKContainer created, checking accountStatus…")

            let accountStatus = try await ckContainer.accountStatus()
            print("[Softer] accountStatus = \(accountStatus) (rawValue: \(accountStatus.rawValue))")
            guard accountStatus == .available else {
                print("[Softer] accountStatus not .available — setting unavailable")
                status = .unavailable("Softer requires iCloud. Sign in via Settings to begin.")
                return
            }

            self.container = ckContainer
            self.privateDB = ckContainer.privateCloudDatabase
            self.sharedDB = ckContainer.sharedCloudDatabase
            self.zoneManager = ZoneManager(container: ckContainer)
            self.shareManager = ShareManager(container: ckContainer)
            self.atomicClaim = AtomicClaim(database: ckContainer.privateCloudDatabase)

            let userID = try await ckContainer.userRecordID()
            localUserRecordID = userID.recordName

            let zoneID = try await zoneManager!.ensureZoneExists(
                named: Constants.ZoneName.rooms,
                in: ckContainer.privateCloudDatabase
            )
            self.zoneID = zoneID

            privateSyncEngine = PrivateSyncEngine(
                database: ckContainer.privateCloudDatabase,
                zoneID: zoneID,
                manager: self
            )

            sharedSyncEngine = SharedSyncEngine(
                database: ckContainer.sharedCloudDatabase,
                container: ckContainer,
                manager: self
            )

            status = .available
            await fetchInitialData()
        } catch {
            status = .unavailable("Softer requires iCloud. Sign in via Settings to begin.")
            print("[Softer] setup() caught error: \(error)")
        }
    }

    private func fetchInitialData() async {
        print("[Softer] fetchInitialData() starting")
        guard let zoneID = zoneID, let privateDB = privateDB else {
            print("[Softer] fetchInitialData() early return - no zoneID or privateDB")
            initialFetchCompleted = true
            return
        }

        do {
            // Fetch rooms
            print("[Softer] fetchInitialData() querying rooms...")
            let roomQuery = CKQuery(recordType: Constants.RecordType.room, predicate: NSPredicate(value: true))
            let (roomResults, _) = try await privateDB.records(matching: roomQuery, inZoneWith: zoneID)
            print("[Softer] fetchInitialData() got \(roomResults.count) room results")

            var fetchedRooms: [Room] = []
            for (_, result) in roomResults {
                if case .success(let record) = result {
                    fetchedRooms.append(RecordConverter.room(from: record))
                }
            }
            rooms = fetchedRooms.sorted { $0.createdAt < $1.createdAt }

            // Fetch messages and participants for each room
            for room in rooms {
                await fetchRoomDetails(roomID: room.id, zoneID: zoneID)
            }
            print("[Softer] fetchInitialData() complete, setting initialFetchCompleted = true")
            await MainActor.run {
                initialFetchCompleted = true
            }
        } catch {
            // Query failed (likely schema issue) - sync engine will populate rooms
            // Wait for rooms to appear or timeout after 3 seconds
            print("[Softer] fetchInitialData() failed: \(error)")
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if !rooms.isEmpty {
                    break
                }
            }
            await MainActor.run {
                initialFetchCompleted = true
            }
        }
    }

    private func fetchRoomDetails(roomID: String, zoneID: CKRecordZone.ID) async {
        guard let privateDB = privateDB else { return }
        do {
            let messagePredicate = NSPredicate(format: "roomID == %@", roomID)
            let messageQuery = CKQuery(recordType: Constants.RecordType.message, predicate: messagePredicate)
            messageQuery.sortDescriptors = [NSSortDescriptor(key: "createdAtDate", ascending: true)]
            let (messageResults, _) = try await privateDB.records(matching: messageQuery, inZoneWith: zoneID)

            var messages: [Message] = []
            for (_, result) in messageResults {
                if case .success(let record) = result {
                    messages.append(RecordConverter.message(from: record))
                }
            }
            messagesByRoom[roomID] = messages

            let participantPredicate = NSPredicate(format: "roomID == %@", roomID)
            let participantQuery = CKQuery(recordType: Constants.RecordType.participant, predicate: participantPredicate)
            let (participantResults, _) = try await privateDB.records(matching: participantQuery, inZoneWith: zoneID)

            var participants: [Participant] = []
            for (_, result) in participantResults {
                if case .success(let record) = result {
                    participants.append(RecordConverter.participant(from: record))
                }
            }
            participantsByRoom[roomID] = participants
        } catch {
            print("Fetch room details failed: \(error)")
        }
    }

    // MARK: - Public API

    func messages(for roomID: String) -> [Message] {
        messagesByRoom[roomID] ?? []
    }

    func participants(for roomID: String) -> [Participant] {
        participantsByRoom[roomID] ?? []
    }

    @discardableResult
    func createRoom(name: String, creatorName: String) async -> String? {
        guard let zoneID = zoneID, let privateDB = privateDB else {
            print("[Softer] createRoom: zoneID or privateDB is nil")
            return nil
        }

        let room = Room(
            name: name,
            turnOrder: [creatorName, Constants.lightwardParticipantName],
            currentTurnIndex: 0
        )
        print("[Softer] createRoom: room.id = \(room.id)")

        let creator = Participant(
            roomID: room.id,
            name: creatorName,
            userRecordID: localUserRecordID
        )

        let lightward = Participant(
            roomID: room.id,
            name: Constants.lightwardParticipantName
        )

        let roomRecord = RecordConverter.record(from: room, zoneID: zoneID)
        let creatorRecord = RecordConverter.record(from: creator, zoneID: zoneID)
        let lightwardRecord = RecordConverter.record(from: lightward, zoneID: zoneID)
        print("[Softer] createRoom: saving to zone \(zoneID)")

        do {
            let operation = CKModifyRecordsOperation(
                recordsToSave: [roomRecord, creatorRecord, lightwardRecord]
            )
            operation.savePolicy = .ifServerRecordUnchanged

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.perRecordSaveBlock = { recordID, result in
                    switch result {
                    case .success(let record):
                        print("[Softer] createRoom: saved record \(recordID.recordName) type=\(record.recordType)")
                    case .failure(let error):
                        print("[Softer] createRoom: FAILED to save \(recordID.recordName): \(error)")
                    }
                }
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        print("[Softer] createRoom: operation completed")
                        continuation.resume()
                    case .failure(let error):
                        print("[Softer] createRoom: operation failed: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
                privateDB.add(operation)
            }

            rooms.append(room)
            participantsByRoom[room.id] = [creator, lightward]
            messagesByRoom[room.id] = []
            print("[Softer] createRoom: local state updated")
            return room.id
        } catch {
            print("[Softer] createRoom failed: \(error)")
            return nil
        }
    }

    func saveMessage(_ message: Message) async {
        guard let zoneID = zoneID, let privateDB = privateDB else { return }

        let record = RecordConverter.record(from: message, zoneID: zoneID)
        do {
            try await privateDB.save(record)
            var messages = messagesByRoom[message.roomID] ?? []
            messages.append(message)
            messagesByRoom[message.roomID] = messages
        } catch {
            print("Save message failed: \(error)")
        }
    }

    func updateRoom(_ room: Room) async {
        guard let zoneID = zoneID, let privateDB = privateDB else { return }

        let recordID = CKRecord.ID(recordName: room.id, zoneID: zoneID)
        print("[Softer] updateRoom: fetching record \(room.id) from zone \(zoneID)")

        do {
            let record = try await privateDB.record(for: recordID)
            print("[Softer] updateRoom: fetched record successfully")
            RecordConverter.applyRoom(room, to: record)

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
                privateDB.add(operation)
            }

            if let index = rooms.firstIndex(where: { $0.id == room.id }) {
                rooms[index] = room
            }
        } catch {
            print("Update room failed: \(error)")
        }
    }

    func atomicClaimNeed(roomID: String, needID: String, deviceID: String) async throws -> Bool {
        guard let zoneID = zoneID, let atomicClaim = atomicClaim else { return false }
        let recordID = CKRecord.ID(recordName: roomID, zoneID: zoneID)
        return try await atomicClaim.claim(
            roomRecordID: recordID,
            needID: needID,
            deviceID: deviceID
        )
    }

    func createShareForRoom(roomID: String) async throws -> CKShare? {
        guard let zoneID = zoneID, let privateDB = privateDB, let shareManager = shareManager else { return nil }
        let recordID = CKRecord.ID(recordName: roomID, zoneID: zoneID)
        let record = try await privateDB.record(for: recordID)
        return try await shareManager.createShare(for: record)
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws {
        guard let shareManager = shareManager else { return }
        try await shareManager.acceptShare(metadata)
    }

    // MARK: - Sync Callbacks

    func handleRecordChanged(_ record: CKRecord) {
        switch record.recordType {
        case Constants.RecordType.room:
            let room = RecordConverter.room(from: record)
            if let index = rooms.firstIndex(where: { $0.id == room.id }) {
                rooms[index] = room
            } else {
                rooms.append(room)
            }

        case Constants.RecordType.message:
            let message = RecordConverter.message(from: record)
            var messages = messagesByRoom[message.roomID] ?? []
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
                messages.sort { $0.createdAt < $1.createdAt }
                messagesByRoom[message.roomID] = messages
            }

        case Constants.RecordType.participant:
            let participant = RecordConverter.participant(from: record)
            var participants = participantsByRoom[participant.roomID] ?? []
            if let index = participants.firstIndex(where: { $0.id == participant.id }) {
                participants[index] = participant
            } else {
                participants.append(participant)
            }
            participantsByRoom[participant.roomID] = participants

        default:
            break
        }
    }

    func handleRecordDeleted(recordID: CKRecord.ID, recordType: CKRecord.RecordType) {
        let id = recordID.recordName

        switch recordType {
        case Constants.RecordType.room:
            rooms.removeAll { $0.id == id }
            messagesByRoom.removeValue(forKey: id)
            participantsByRoom.removeValue(forKey: id)

        case Constants.RecordType.message:
            for (roomID, var messages) in messagesByRoom {
                messages.removeAll { $0.id == id }
                messagesByRoom[roomID] = messages
            }

        case Constants.RecordType.participant:
            for (roomID, var participants) in participantsByRoom {
                participants.removeAll { $0.id == id }
                participantsByRoom[roomID] = participants
            }

        default:
            break
        }
    }
}
