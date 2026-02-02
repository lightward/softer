import Foundation
import CloudKit

/// Wraps CKSyncEngine for automatic sync orchestration.
/// Handles batching, retries, conflict resolution, and push notifications.
actor SyncCoordinator {

    // MARK: - Types

    /// Callback for when records are fetched from the server.
    typealias RecordHandler = @Sendable (CKRecord) async -> Void

    /// Callback for when records are deleted on the server.
    typealias DeletionHandler = @Sendable (CKRecord.ID) async -> Void

    /// Callback for sync status changes.
    typealias StatusHandler = @Sendable (SyncStatus) async -> Void

    /// Callback for when a batch of records has been processed.
    typealias BatchCompleteHandler = @Sendable () async -> Void

    // MARK: - Properties

    private let container: CKContainer
    private let database: CKDatabase
    private let sharedDatabase: CKDatabase
    private let zoneID: CKRecordZone.ID
    private var syncEngine: CKSyncEngine?
    private var sharedSyncEngine: CKSyncEngine?
    private let delegate: SyncEngineDelegate
    private let sharedDelegate: SyncEngineDelegate

    private var onRecordFetched: RecordHandler?
    private var onRecordDeleted: DeletionHandler?
    private var onStatusChange: StatusHandler?
    private var onBatchComplete: BatchCompleteHandler?

    /// Records pending save, keyed by record ID.
    /// CKSyncEngine calls back to get these when sending changes.
    private var pendingRecords: [CKRecord.ID: CKRecord] = [:]

    /// Shares pending save, keyed by the root record ID.
    private var pendingShares: [CKRecord.ID: CKShare] = [:]

    private(set) var status: SyncStatus = .idle

    // MARK: - Initialization

    init(container: CKContainer, database: CKDatabase, zoneID: CKRecordZone.ID) {
        self.container = container
        self.database = database
        self.sharedDatabase = container.sharedCloudDatabase
        self.zoneID = zoneID
        self.delegate = SyncEngineDelegate()
        self.sharedDelegate = SyncEngineDelegate()
    }

    // MARK: - Setup

    /// Start the sync engine with the given handlers.
    func start(
        onRecordFetched: @escaping RecordHandler,
        onRecordDeleted: @escaping DeletionHandler,
        onStatusChange: @escaping StatusHandler,
        onBatchComplete: @escaping BatchCompleteHandler = {}
    ) async {
        self.onRecordFetched = onRecordFetched
        self.onRecordDeleted = onRecordDeleted
        self.onStatusChange = onStatusChange
        self.onBatchComplete = onBatchComplete

        // Load persisted state if available
        let state = loadPersistedState()

        // Configure sync engine for private database
        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: state,
            delegate: delegate
        )

        let engine = CKSyncEngine(configuration)
        self.syncEngine = engine

        // Wire up delegate callbacks
        delegate.coordinator = self

        await updateStatus(.syncing)

        // Tell sync engine to track our zone
        // This is required for CKSyncEngine to fetch changes from the zone
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

        // Ensure zone exists
        do {
            try await ensureZoneExists()
        } catch {
            await updateStatus(.error("Failed to set up sync: \(error.localizedDescription)"))
            return
        }

        // Configure sync engine for shared database (to receive shared rooms)
        let sharedState = loadPersistedState(forShared: true)
        let sharedConfiguration = CKSyncEngine.Configuration(
            database: sharedDatabase,
            stateSerialization: sharedState,
            delegate: sharedDelegate
        )

        let sharedEngine = CKSyncEngine(sharedConfiguration)
        self.sharedSyncEngine = sharedEngine

        // Wire up shared delegate
        sharedDelegate.coordinator = self
        sharedDelegate.isShared = true

        await updateStatus(.synced)
    }

    /// Stop the sync engines.
    func stop() {
        syncEngine = nil
        sharedSyncEngine = nil
        delegate.coordinator = nil
        sharedDelegate.coordinator = nil
    }

    // MARK: - Record Operations

    /// Queue a record to be saved to CloudKit.
    func save(_ record: CKRecord) {
        guard let engine = syncEngine else { return }

        pendingRecords[record.recordID] = record
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    }

    /// Queue multiple records to be saved.
    func save(_ records: [CKRecord]) {
        guard let engine = syncEngine else { return }

        for record in records {
            pendingRecords[record.recordID] = record
        }
        let changes = records.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0.recordID) }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    /// Queue a record to be deleted from CloudKit.
    func delete(recordID: CKRecord.ID) {
        guard let engine = syncEngine else { return }

        pendingRecords.removeValue(forKey: recordID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }

    /// Queue multiple records to be deleted.
    func delete(recordIDs: [CKRecord.ID]) {
        guard let engine = syncEngine else { return }

        for id in recordIDs {
            pendingRecords.removeValue(forKey: id)
        }
        let changes = recordIDs.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    // MARK: - Sharing

    /// Share a room record with participants identified by email/phone.
    /// Creates a CKShare if one doesn't exist, adds participants.
    func shareRoom(_ roomRecord: CKRecord, withLookupInfos lookupInfos: [CKUserIdentity.LookupInfo]) async throws {
        guard !lookupInfos.isEmpty else { return }

        print("SyncCoordinator: Sharing room \(roomRecord.recordID.recordName) with \(lookupInfos.count) participants")

        // Create or fetch existing share
        let share: CKShare
        if let existingShare = roomRecord.share {
            // Fetch the existing share to modify it
            do {
                share = try await database.record(for: existingShare.recordID) as! CKShare
            } catch {
                print("SyncCoordinator: Failed to fetch existing share: \(error)")
                throw error
            }
        } else {
            // Create new share
            share = CKShare(rootRecord: roomRecord)
            share[CKShare.SystemFieldKey.title] = "Softer Room" as CKRecordValue
            share.publicPermission = .none  // Only invited participants
        }

        // Fetch share participants
        let participants = try await fetchShareParticipants(lookupInfos: lookupInfos)

        // Add participants to share
        for participant in participants {
            participant.permission = .readWrite
            participant.role = .privateUser
            share.addParticipant(participant)
        }

        // Save both the room record and share together
        let operation = CKModifyRecordsOperation(recordsToSave: [roomRecord, share], recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.isAtomic = true

        return try await withCheckedThrowingContinuation { continuation in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    print("SyncCoordinator: Share created/updated successfully")
                    continuation.resume()
                case .failure(let error):
                    print("SyncCoordinator: Failed to save share: \(error)")
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    /// Fetch CKShare.Participant objects for the given lookup infos.
    private func fetchShareParticipants(lookupInfos: [CKUserIdentity.LookupInfo]) async throws -> [CKShare.Participant] {
        try await withCheckedThrowingContinuation { continuation in
            var participants: [CKShare.Participant] = []

            let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: lookupInfos)

            operation.perShareParticipantResultBlock = { _, result in
                switch result {
                case .success(let participant):
                    participants.append(participant)
                case .failure(let error):
                    print("SyncCoordinator: Failed to fetch participant: \(error)")
                }
            }

            operation.fetchShareParticipantsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: participants)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            container.add(operation)
        }
    }

    /// Trigger a fetch of changes from the server (both private and shared).
    func fetchChanges() async {
        print("SyncCoordinator.fetchChanges: Starting fetch...")
        await updateStatus(.syncing)

        // Fetch from private database
        if let engine = syncEngine {
            do {
                try await engine.fetchChanges()
                print("SyncCoordinator.fetchChanges: Private fetch completed")
            } catch {
                print("SyncCoordinator.fetchChanges: Private fetch failed - \(error)")
            }
        }

        // Fetch from shared database (rooms shared with us)
        if let sharedEngine = sharedSyncEngine {
            do {
                try await sharedEngine.fetchChanges()
                print("SyncCoordinator.fetchChanges: Shared fetch completed")
            } catch {
                print("SyncCoordinator.fetchChanges: Shared fetch failed - \(error)")
            }
        }

        await updateStatus(.synced)
    }

    /// Send pending changes to the server.
    func sendChanges() async {
        guard let engine = syncEngine else {
            print("SyncCoordinator: No sync engine available")
            return
        }

        await updateStatus(.syncing)

        do {
            try await engine.sendChanges()
            await updateStatus(.synced)
        } catch let error as CKError {
            print("SyncCoordinator: CKError \(error.code.rawValue): \(error.localizedDescription)")
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
                print("SyncCoordinator: Underlying error: \(underlying)")
            }
            // Log partial failure details
            if error.code == .partialFailure, let partialErrors = error.partialErrorsByItemID {
                for (itemID, itemError) in partialErrors {
                    print("SyncCoordinator: Partial error for \(itemID): \(itemError)")
                }
                // Check if all failures are just serverRecordChanged - these are handled automatically
                let hasRealErrors = partialErrors.values.contains { itemError in
                    guard let ckError = itemError as? CKError else { return true }
                    return ckError.code != .serverRecordChanged
                }
                if !hasRealErrors {
                    // All errors are conflicts that CKSyncEngine will retry - not a real failure
                    print("SyncCoordinator: All errors are serverRecordChanged conflicts, will retry automatically")
                    await updateStatus(.syncing)
                    return
                }
            }
            // Don't set error status for transient failures - let individual record handlers deal with it
            if error.code == .networkUnavailable || error.code == .networkFailure {
                await updateStatus(.offline)
            } else {
                await updateStatus(.error("Sync failed: \(error.code.rawValue)"))
            }
        } catch {
            print("SyncCoordinator: Non-CK error: \(error)")
            await updateStatus(.error("Sync failed"))
        }
    }

    // MARK: - Internal: Delegate Callbacks

    /// Called by delegate when the sync engine has events.
    func handleEvent(_ event: CKSyncEngine.Event, isShared: Bool = false) async {
        let source = isShared ? "shared" : "private"
        print("SyncCoordinator [\(source)]: Received event: \(event)")
        switch event {
        case .stateUpdate(let stateUpdate):
            handleStateUpdate(stateUpdate, isShared: isShared)

        case .accountChange(let accountChange):
            await handleAccountChange(accountChange)

        case .fetchedDatabaseChanges(let changes):
            print("SyncCoordinator [\(source)]: Fetched database changes - \(changes.modifications.count) zones modified")
            await handleFetchedDatabaseChanges(changes)

        case .fetchedRecordZoneChanges(let changes):
            print("SyncCoordinator [\(source)]: Fetched record zone changes - \(changes.modifications.count) records, \(changes.deletions.count) deletions")
            await handleFetchedRecordZoneChanges(changes)

        case .sentDatabaseChanges(let sentChanges):
            handleSentDatabaseChanges(sentChanges)

        case .sentRecordZoneChanges(let sentChanges):
            await handleSentRecordZoneChanges(sentChanges)

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .willSendChanges, .didSendChanges:
            // Progress events - could update UI
            break

        @unknown default:
            print("Unknown sync engine event: \(event)")
        }
    }

    /// Called by delegate to get the record for a pending save.
    func record(for recordID: CKRecord.ID) -> CKRecord? {
        pendingRecords[recordID]
    }

    /// Called by delegate after a record was successfully saved.
    func recordSaved(_ recordID: CKRecord.ID) {
        pendingRecords.removeValue(forKey: recordID)
    }

    // MARK: - Private: Event Handlers

    private func handleStateUpdate(_ stateUpdate: CKSyncEngine.Event.StateUpdate, isShared: Bool = false) {
        // Persist the state for next launch
        persistState(stateUpdate.stateSerialization, forShared: isShared)
    }

    private func handleAccountChange(_ accountChange: CKSyncEngine.Event.AccountChange) async {
        switch accountChange.changeType {
        case .signIn:
            await updateStatus(.syncing)
        case .signOut:
            await updateStatus(.error("Signed out of iCloud"))
        case .switchAccounts:
            await updateStatus(.syncing)
        @unknown default:
            break
        }
    }

    private func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) async {
        // Database-level changes (zone creations/deletions)
        for deletion in changes.deletions {
            print("Zone deleted: \(deletion.zoneID)")
        }
    }

    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        // Process fetched records
        for modification in changes.modifications {
            await onRecordFetched?(modification.record)
        }

        // Process deletions
        for deletion in changes.deletions {
            await onRecordDeleted?(deletion.recordID)
        }

        // Notify that batch is complete (for finalizing pending rooms, etc.)
        await onBatchComplete?()
    }

    private func handleSentDatabaseChanges(_ sentChanges: CKSyncEngine.Event.SentDatabaseChanges) {
        // Handle any failed zone saves
        for failedSave in sentChanges.failedZoneSaves {
            print("Failed zone save: \(failedSave)")
        }
    }

    private func handleSentRecordZoneChanges(_ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges) async {
        // Handle successful saves
        for savedRecord in sentChanges.savedRecords {
            print("Saved record: \(savedRecord.recordID.recordName)")
            recordSaved(savedRecord.recordID)
        }

        // Handle failed saves with conflict resolution
        for failedSave in sentChanges.failedRecordSaves {
            await handleFailedSave(failedSave)
        }

        // Handle deletions
        for deletedID in sentChanges.deletedRecordIDs {
            print("Deleted record: \(deletedID.recordName)")
        }
    }

    private func handleFailedSave(_ failedSave: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) async {
        let recordID = failedSave.record.recordID
        let error = failedSave.error

        if let ckError = error as? CKError {
            switch ckError.code {
            case .serverRecordChanged:
                // Conflict! Apply merge policy
                if let serverRecord = ckError.serverRecord {
                    let merged = mergeRecords(local: failedSave.record, server: serverRecord)
                    save(merged)
                }

            case .zoneNotFound:
                // Zone was deleted - recreate it
                Task {
                    try? await ensureZoneExists()
                    save(failedSave.record)
                }

            case .networkUnavailable, .networkFailure:
                await updateStatus(.offline)

            default:
                print("Failed to save \(recordID.recordName): \(error)")
            }
        }
    }

    // MARK: - Private: Conflict Resolution

    /// Merge local and server records according to defined policies.
    private func mergeRecords(local: CKRecord, server: CKRecord) -> CKRecord {
        // Use server as base, apply local overrides based on type
        let merged = server

        switch local.recordType {
        case "Room3":
            // Turn index: higher wins
            if let localTurn = local["currentTurnIndex"] as? Int,
               let serverTurn = server["currentTurnIndex"] as? Int {
                merged["currentTurnIndex"] = max(localTurn, serverTurn) as NSNumber
            }

            // Raised hands: union merge (stored as array)
            let localHands = Set(local["raisedHands"] as? [String] ?? [])
            let serverHands = Set(server["raisedHands"] as? [String] ?? [])
            let handsUnion = localHands.union(serverHands)
            if handsUnion.isEmpty {
                merged["raisedHands"] = nil
            } else {
                merged["raisedHands"] = Array(handsUnion) as NSArray
            }

            // Messages: union by ID, sorted by createdAt
            let localMessagesJSON = local["messagesJSON"] as? String ?? "[]"
            let serverMessagesJSON = server["messagesJSON"] as? String ?? "[]"
            let roomID = local.recordID.recordName
            let localMessages = RoomLifecycleRecordConverter.decodeMessages(from: localMessagesJSON, roomID: roomID)
            let serverMessages = RoomLifecycleRecordConverter.decodeMessages(from: serverMessagesJSON, roomID: roomID)
            let mergedMessages = RoomLifecycleRecordConverter.mergeMessages(local: localMessages, remote: serverMessages)
            merged["messagesJSON"] = RoomLifecycleRecordConverter.encodeMessages(mergedMessages) as NSString

        default:
            break
        }

        return merged
    }

    // MARK: - Private: Zone Management

    private func ensureZoneExists() async throws {
        // Default zone always exists, but for custom zones:
        if zoneID != CKRecordZone.default().zoneID {
            let zone = CKRecordZone(zoneID: zoneID)
            _ = try await database.save(zone)
        }
    }

    // MARK: - Private: State Persistence

    private var stateKey: String {
        // Use zone-specific key so switching zones starts fresh
        "SyncCoordinatorState-\(zoneID.zoneName)"
    }

    private var sharedStateKey: String {
        "SyncCoordinatorState-shared"
    }

    private func loadPersistedState(forShared: Bool = false) -> CKSyncEngine.State.Serialization? {
        let key = forShared ? sharedStateKey : stateKey
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            print("Failed to load sync state: \(error)")
            return nil
        }
    }

    /// Clear persisted state to force a full re-fetch on next start.
    func clearPersistedState() {
        UserDefaults.standard.removeObject(forKey: stateKey)
        UserDefaults.standard.removeObject(forKey: sharedStateKey)
        print("SyncCoordinator: Cleared persisted state for zone \(zoneID.zoneName) and shared")
    }

    private func persistState(_ state: CKSyncEngine.State.Serialization, forShared: Bool = false) {
        let key = forShared ? sharedStateKey : stateKey
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(state)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            print("Failed to persist sync state: \(error)")
        }
    }

    // MARK: - Private: Status Updates

    private func updateStatus(_ newStatus: SyncStatus) async {
        status = newStatus
        await onStatusChange?(newStatus)
    }
}

// MARK: - Sync Engine Delegate

/// Delegate for CKSyncEngine events.
/// Must be a class (not actor) to conform to CKSyncEngineDelegate.
private final class SyncEngineDelegate: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    weak var coordinator: SyncCoordinator?
    var isShared: Bool = false

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await coordinator?.handleEvent(event, isShared: isShared)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges

        guard !pendingChanges.isEmpty else { return nil }

        // Collect records to save and IDs to delete
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        for change in pendingChanges {
            switch change {
            case .saveRecord(let recordID):
                if let record = await coordinator?.record(for: recordID) {
                    recordsToSave.append(record)
                }
            case .deleteRecord(let recordID):
                recordIDsToDelete.append(recordID)
            @unknown default:
                break
            }
        }

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }

        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete,
            atomicByZone: true
        )
    }
}
