import Foundation
import CloudKit

/// Wraps CKSyncEngine for automatic sync orchestration.
/// Handles batching, retries, conflict resolution, and push notifications.
actor SyncCoordinator {

    // MARK: - Types

    /// Callback for when records are fetched from the server.
    /// Parameters: (record, isShared) — isShared is true when fetched from shared database.
    typealias RecordHandler = @Sendable (CKRecord, Bool) async -> Void

    /// Callback for when records are deleted on the server.
    typealias DeletionHandler = @Sendable (CKRecord.ID) async -> Void

    /// Callback for sync status changes.
    typealias StatusHandler = @Sendable (SyncStatus) async -> Void

    /// Callback for when a batch of records has been processed.
    typealias BatchCompleteHandler = @Sendable () async -> Void

    /// Callback for when a record has been successfully saved to CloudKit.
    /// Parameters: (savedRecord, isShared) — the server's version with updated change tag.
    typealias RecordSavedHandler = @Sendable (CKRecord, Bool) async -> Void

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
    private var onRecordSaved: RecordSavedHandler?

    /// Records pending save to private database, keyed by record ID.
    private var privatePendingRecords: [CKRecord.ID: CKRecord] = [:]

    /// Records pending save to shared database, keyed by record ID.
    private var sharedPendingRecords: [CKRecord.ID: CKRecord] = [:]

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
        onBatchComplete: @escaping BatchCompleteHandler = {},
        onRecordSaved: @escaping RecordSavedHandler = { _, _ in }
    ) async {
        self.onRecordFetched = onRecordFetched
        self.onRecordDeleted = onRecordDeleted
        self.onStatusChange = onStatusChange
        self.onBatchComplete = onBatchComplete
        self.onRecordSaved = onRecordSaved

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

    /// Hard refresh: stop engines, clear change tokens, restart, and fetch everything.
    /// Use for pull-to-refresh when the normal change token-based fetch returns stale data.
    func hardRefresh() async {
        guard onRecordFetched != nil else { return }

        stop()
        clearPersistedState()

        // Recreate engines with no persisted state (nil = full fetch)
        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: nil,
            delegate: delegate
        )
        let engine = CKSyncEngine(configuration)
        self.syncEngine = engine
        delegate.coordinator = self

        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

        let sharedConfiguration = CKSyncEngine.Configuration(
            database: sharedDatabase,
            stateSerialization: nil,
            delegate: sharedDelegate
        )
        let sharedEngine = CKSyncEngine(sharedConfiguration)
        self.sharedSyncEngine = sharedEngine
        sharedDelegate.coordinator = self
        sharedDelegate.isShared = true

        await fetchChanges()
    }

    // MARK: - Direct Record Fetch

    /// Fetch a Room3 record directly by ID, bypassing CKSyncEngine's change tokens.
    /// Uses stored system fields to reconstruct the correct record ID (preserves zone for shared rooms).
    func fetchRoomRecord(recordName: String, systemFields: Data?, isShared: Bool) async -> CKRecord? {
        let db = isShared ? sharedDatabase : database

        // Reconstruct record ID from system fields (preserves zone ID for shared rooms)
        let recordID: CKRecord.ID
        if let systemFields = systemFields {
            do {
                let coder = try NSKeyedUnarchiver(forReadingFrom: systemFields)
                coder.requiresSecureCoding = true
                if let record = CKRecord(coder: coder) {
                    coder.finishDecoding()
                    recordID = record.recordID
                } else {
                    coder.finishDecoding()
                    recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
                }
            } catch {
                recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            }
        } else {
            recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        }

        do {
            return try await db.record(for: recordID)
        } catch {
            print("SyncCoordinator.fetchRoomRecord: Failed to fetch \(recordName) - \(error)")
            return nil
        }
    }

    /// Fetch the current user's record ID from a CKShare associated with a record.
    /// Returns the userRecordID string, or nil if unavailable.
    func currentUserRecordID(forShareOf record: CKRecord) async -> String? {
        guard let shareRef = record.share else { return nil }

        do {
            let share = try await sharedDatabase.record(for: shareRef.recordID) as? CKShare
            let userRecordID = share?.currentUserParticipant?.userIdentity.userRecordID?.recordName
            print("SyncCoordinator: Share currentUser recordID = \(userRecordID ?? "nil")")
            return userRecordID
        } catch {
            print("SyncCoordinator: Failed to fetch share: \(error)")
            return nil
        }
    }

    // MARK: - Record Operations

    /// Queue a record to be saved to CloudKit (private database).
    func save(_ record: CKRecord) {
        guard let engine = syncEngine else { return }

        privatePendingRecords[record.recordID] = record
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    }

    /// Queue a record to be saved to CloudKit (shared database).
    func saveShared(_ record: CKRecord) {
        guard let engine = sharedSyncEngine else { return }

        sharedPendingRecords[record.recordID] = record
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    }

    /// Queue multiple records to be saved (private database).
    func save(_ records: [CKRecord]) {
        guard let engine = syncEngine else { return }

        for record in records {
            privatePendingRecords[record.recordID] = record
        }
        let changes = records.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0.recordID) }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    /// Queue a record to be deleted from CloudKit (private database).
    func delete(recordID: CKRecord.ID) {
        guard let engine = syncEngine else { return }

        privatePendingRecords.removeValue(forKey: recordID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }

    /// Queue a record to be deleted from CloudKit (shared database).
    func deleteShared(recordID: CKRecord.ID) {
        guard let engine = sharedSyncEngine else { return }

        sharedPendingRecords.removeValue(forKey: recordID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }

    /// Queue multiple records to be deleted (private database).
    func delete(recordIDs: [CKRecord.ID]) {
        guard let engine = syncEngine else { return }

        for id in recordIDs {
            privatePendingRecords.removeValue(forKey: id)
        }
        let changes = recordIDs.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord($0) }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    // MARK: - Sharing

    /// Share a room record with participants identified by email/phone.
    /// Creates a CKShare if one doesn't exist, adds participants.
    /// Returns the share URL if successful.
    @discardableResult
    func shareRoom(_ roomRecord: CKRecord, withLookupInfos lookupInfos: [CKUserIdentity.LookupInfo]) async throws -> URL? {
        guard !lookupInfos.isEmpty else { return nil }

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
                    let shareURL = share.url
                    if let shareURL = shareURL {
                        print("SyncCoordinator: Share URL: \(shareURL)")
                    }
                    continuation.resume(returning: shareURL)
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

    // MARK: - Share Acceptance

    /// Accept a share from a ckshare:// URL.
    /// Returns the root record ID (room ID) for navigation, or nil if acceptance failed.
    func acceptShare(from url: URL) async throws -> String? {
        print("SyncCoordinator: Accepting share from URL: \(url)")

        // Fetch share metadata from URL
        let metadata: CKShare.Metadata
        do {
            metadata = try await container.shareMetadata(for: url)
            print("SyncCoordinator: Got share metadata, rootRecordID: \(metadata.rootRecordID.recordName)")
        } catch {
            print("SyncCoordinator: Failed to fetch share metadata: \(error)")
            throw error
        }

        // Accept the share
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])

            operation.perShareResultBlock = { metadata, result in
                switch result {
                case .success:
                    print("SyncCoordinator: Share accepted successfully")
                case .failure(let error):
                    print("SyncCoordinator: Share acceptance failed: \(error)")
                }
            }

            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            container.add(operation)
        }

        // Fetch changes from shared database to get the room
        if let sharedEngine = sharedSyncEngine {
            do {
                try await sharedEngine.fetchChanges()
                print("SyncCoordinator: Fetched shared changes after accepting share")
            } catch {
                print("SyncCoordinator: Failed to fetch shared changes: \(error)")
            }
        }

        return metadata.rootRecordID.recordName
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

    /// Send pending changes to the server (both private and shared engines).
    func sendChanges() async {
        await updateStatus(.syncing)

        // Send private changes
        if let engine = syncEngine {
            do {
                try await engine.sendChanges()
            } catch let error as CKError {
                await handleSendError(error)
                return
            } catch {
                print("SyncCoordinator: Non-CK error (private): \(error)")
                await updateStatus(.error("Sync failed"))
                return
            }
        }

        // Send shared changes
        if let sharedEngine = sharedSyncEngine {
            do {
                try await sharedEngine.sendChanges()
            } catch let error as CKError {
                await handleSendError(error)
                return
            } catch {
                print("SyncCoordinator: Non-CK error (shared): \(error)")
                await updateStatus(.error("Sync failed"))
                return
            }
        }

        await updateStatus(.synced)
    }

    private func handleSendError(_ error: CKError) async {
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
                print("SyncCoordinator: All errors are serverRecordChanged conflicts, will retry automatically")
                await updateStatus(.syncing)
                return
            }
        }
        if error.code == .networkUnavailable || error.code == .networkFailure {
            await updateStatus(.offline)
        } else {
            await updateStatus(.error("Sync failed: \(error.code.rawValue)"))
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
            await handleFetchedRecordZoneChanges(changes, isShared: isShared)

        case .sentDatabaseChanges(let sentChanges):
            handleSentDatabaseChanges(sentChanges)

        case .sentRecordZoneChanges(let sentChanges):
            await handleSentRecordZoneChanges(sentChanges, isShared: isShared)

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            // Progress events - could update UI
            break

        @unknown default:
            print("Unknown sync engine event: \(event)")
        }
    }

    /// Called by delegate to get the record for a pending save.
    func record(for recordID: CKRecord.ID, isShared: Bool) -> CKRecord? {
        isShared ? sharedPendingRecords[recordID] : privatePendingRecords[recordID]
    }

    /// Called by delegate after a record was successfully saved.
    func recordSaved(_ record: CKRecord, isShared: Bool) {
        if isShared {
            sharedPendingRecords.removeValue(forKey: record.recordID)
        } else {
            privatePendingRecords.removeValue(forKey: record.recordID)
        }
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

    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, isShared: Bool) async {
        // Process fetched records
        for modification in changes.modifications {
            await onRecordFetched?(modification.record, isShared)
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

    private func handleSentRecordZoneChanges(_ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges, isShared: Bool) async {
        // Handle successful saves
        for savedRecord in sentChanges.savedRecords {
            print("Saved record [\(isShared ? "shared" : "private")]: \(savedRecord.recordID.recordName)")
            recordSaved(savedRecord, isShared: isShared)
            await onRecordSaved?(savedRecord, isShared)
        }

        // Handle failed saves with conflict resolution
        for failedSave in sentChanges.failedRecordSaves {
            await handleFailedSave(failedSave, isShared: isShared)
        }

        // Handle deletions
        for deletedID in sentChanges.deletedRecordIDs {
            print("Deleted record: \(deletedID.recordName)")
        }
    }

    private func handleFailedSave(_ failedSave: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave, isShared: Bool) async {
        let recordID = failedSave.record.recordID
        let error = failedSave.error

        if let ckError = error as? CKError {
            switch ckError.code {
            case .serverRecordChanged:
                // Conflict! Apply merge policy
                if let serverRecord = ckError.serverRecord {
                    let merged = mergeRecords(local: failedSave.record, server: serverRecord)
                    if isShared {
                        saveShared(merged)
                    } else {
                        save(merged)
                    }
                }

            case .zoneNotFound:
                // Zone was deleted - recreate it (only for private)
                if !isShared {
                    Task {
                        try? await ensureZoneExists()
                        save(failedSave.record)
                    }
                }

            case .networkUnavailable, .networkFailure:
                await updateStatus(.offline)

            default:
                print("Failed to save \(recordID.recordName) [\(isShared ? "shared" : "private")]: \(error)")
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
                if let record = await coordinator?.record(for: recordID, isShared: isShared) {
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
