import Foundation
import CloudKit
import SwiftUI
import SwiftData

/// Main observable store for the app.
/// Provides a simple API for views; all sync logic is internal.
/// Uses SwiftData (PersistenceStore) as single source of truth.
@Observable
@MainActor
final class SofterStore {

    // MARK: - Public State

    /// Current sync status.
    private(set) var syncStatus: SyncStatus = .idle

    /// Whether initial data load has completed.
    private(set) var initialLoadCompleted = false

    /// Local user's CloudKit record ID.
    private(set) var localUserRecordID: String?

    /// Transient composing state per room (not persisted — display-only).
    /// Key: roomID, Value: (participantID, timestamp).
    private(set) var composingByRoom: [String: (participantID: String, timestamp: Date)] = [:]

    // MARK: - Private State

    private var dataStore: PersistenceStore?
    private var container: CKContainer?
    private var syncCoordinator: SyncCoordinator?
    private var zoneID: CKRecordZone.ID?
    private let apiClient: any LightwardAPI

    // MARK: - Polling State

    private var pollingTask: Task<Void, Never>?
    private var lastSyncTime: Date = .distantPast
    private var lastSeenChangeTag: String?

    /// Exposes the SwiftData ModelContainer for @Query in views.
    var modelContainer: ModelContainer? {
        dataStore?.modelContainer
    }

    // MARK: - Initialization

    init(apiClient: any LightwardAPI = LightwardAPIClient()) {
        self.apiClient = apiClient
        // Initialize SwiftData synchronously - required for .modelContainer() modifier
        do {
            self.dataStore = try PersistenceStore()
        } catch {
            print("SofterStore: Failed to initialize PersistenceStore: \(error)")
        }
        Task {
            await setupCloudKit()
        }
    }

    /// Initialize with dependencies (for testing).
    init(
        apiClient: any LightwardAPI,
        dataStore: PersistenceStore?,
        container: CKContainer?,
        syncCoordinator: SyncCoordinator?,
        zoneID: CKRecordZone.ID?
    ) {
        self.apiClient = apiClient
        self.dataStore = dataStore
        self.container = container
        self.syncCoordinator = syncCoordinator
        self.zoneID = zoneID
        if container != nil {
            syncStatus = .synced
        }
    }

    // MARK: - Setup

    private func setupCloudKit() async {
        guard dataStore != nil else {
            syncStatus = .error("Failed to initialize local storage")
            initialLoadCompleted = true
            return
        }

        do {
            let ckContainer = CKContainer(identifier: Constants.containerIdentifier)

            let accountStatus = try await ckContainer.accountStatus()
            guard accountStatus == .available else {
                syncStatus = .error("Softer requires iCloud. Sign in via Settings to begin.")
                initialLoadCompleted = true
                return
            }

            self.container = ckContainer

            let userID = try await ckContainer.userRecordID()
            localUserRecordID = userID.recordName

            // Use custom zone (required for CKSyncEngine to track changes)
            let zoneID = CKRecordZone.ID(zoneName: "SofterZone", ownerName: CKCurrentUserDefaultName)
            self.zoneID = zoneID

            let coordinator = SyncCoordinator(
                container: ckContainer,
                database: ckContainer.privateCloudDatabase,
                zoneID: zoneID
            )
            self.syncCoordinator = coordinator

            await coordinator.start(
                onRecordFetched: { [weak self] record, isShared in
                    await self?.handleRecordFetched(record, isShared: isShared)
                },
                onRecordDeleted: { [weak self] recordID in
                    await self?.handleRecordDeleted(recordID)
                },
                onStatusChange: { [weak self] status in
                    await self?.handleStatusChange(status)
                },
                onBatchComplete: { [weak self] in
                    _ = self
                },
                onRecordSaved: { [weak self] record, isShared in
                    await self?.handleRecordSaved(record, isShared: isShared)
                }
            )

            await coordinator.fetchChanges()
            initialLoadCompleted = true

        } catch {
            print("SofterStore: Setup failed with error: \(error)")
            syncStatus = .error("Failed to initialize: \(error.localizedDescription)")
            initialLoadCompleted = true
        }
    }

    // MARK: - SyncCoordinator Handlers

    private func handleRecordFetched(_ record: CKRecord, isShared: Bool) async {
        guard let dataStore = dataStore else { return }

        print("SofterStore: Fetched record type=\(record.recordType) id=\(record.recordID.recordName) shared=\(isShared)")

        switch record.recordType {
        case RoomLifecycleRecordConverter.roomRecordType:
            // Room3 with embedded participants and messages
            if let lifecycle = RoomLifecycleRecordConverter.lifecycle(from: record) {
                let participantsJSON = record["participantsJSON"] as? String
                let messagesJSON = record["messagesJSON"] as? String
                dataStore.upsertRoom(from: lifecycle, remoteParticipantsJSON: participantsJSON, remoteMessagesJSON: messagesJSON)

                // Persist CKRecord system fields and shared flag
                if let room = dataStore.room(id: record.recordID.recordName) {
                    room.ckSystemFields = RoomLifecycleRecordConverter.encodeSystemFields(of: record)
                    room.isSharedWithMe = isShared

                    // Read composing state from remote record
                    let roomID = record.recordID.recordName
                    if let composingID = record["composingParticipantID"] as? String,
                       let composingTime = record["composingTimestamp"] as? Date {
                        composingByRoom[roomID] = (participantID: composingID, timestamp: composingTime)
                    } else {
                        composingByRoom.removeValue(forKey: roomID)
                    }

                    // For shared rooms, populate local user's identity from the CKShare
                    if isShared, let syncCoordinator = syncCoordinator {
                        await populateLocalUserIdentity(in: room, from: record, using: syncCoordinator)
                    }

                    // Check if room needs state transition (e.g., all humans signaled → active)
                    checkAndTransitionRoom(room)

                    dataStore.updateRoom(room)
                }

                print("SofterStore: Room \(record.recordID.recordName) synced from CloudKit (shared=\(isShared))")
            }

        default:
            break
        }
    }

    /// Called after a record is successfully saved to CloudKit.
    /// Updates stored system fields with the server's latest change tag.
    private func handleRecordSaved(_ record: CKRecord, isShared: Bool) async {
        guard let dataStore = dataStore else { return }

        if record.recordType == RoomLifecycleRecordConverter.roomRecordType {
            if let room = dataStore.room(id: record.recordID.recordName) {
                room.ckSystemFields = RoomLifecycleRecordConverter.encodeSystemFields(of: record)
                dataStore.updateRoom(room)
                print("SofterStore: Updated system fields for room \(record.recordID.recordName) after save")
            }
        }
    }

    private func handleRecordDeleted(_ recordID: CKRecord.ID) async {
        guard let dataStore = dataStore else { return }
        let id = recordID.recordName
        if dataStore.room(id: id) != nil {
            dataStore.deleteRoom(id: id)
        }
    }

    @MainActor
    private func handleStatusChange(_ status: SyncStatus) async {
        self.syncStatus = status
    }

    // MARK: - Shared Room Identity

    /// For shared rooms, use the CKShare to identify which embedded participant
    /// is the local user, and populate their userRecordID if missing.
    private func populateLocalUserIdentity(in room: PersistedRoom, from record: CKRecord, using syncCoordinator: SyncCoordinator) async {
        guard let localUserRecordID = localUserRecordID else { return }

        let embedded = room.embeddedParticipants()

        // Already matched? Skip the share fetch.
        if embedded.contains(where: { $0.userRecordID == localUserRecordID }) { return }

        // Ask the CKShare who we are
        guard let shareUserRecordID = await syncCoordinator.currentUserRecordID(forShareOf: record) else { return }

        let updated = ParticipantIdentity.populateUserRecordID(
            in: embedded,
            shareUserRecordID: shareUserRecordID,
            localUserRecordID: localUserRecordID
        )

        if updated != embedded {
            for p in updated where p.userRecordID == shareUserRecordID {
                let wasAlreadySet = embedded.first(where: { $0.id == p.id })?.userRecordID == shareUserRecordID
                if !wasAlreadySet {
                    print("SofterStore: Populated userRecordID for \(p.nickname) from CKShare")
                }
            }
            room.setParticipants(updated)
        }
    }

    // MARK: - State Transition Helpers

    /// Check if a room needs an automatic state transition.
    /// e.g., pendingParticipants with all signaled → active.
    private func checkAndTransitionRoom(_ room: PersistedRoom) {
        guard var lifecycle = room.toRoomLifecycle() else { return }

        if case .pendingParticipants = lifecycle.state {
            let signaled = room.embeddedParticipants().filter { $0.hasSignaledHere }
            for participant in signaled {
                _ = lifecycle.apply(event: .signaled(participantID: participant.id))
            }
            room.apply(lifecycle, mergeStrategy: .remoteWins)
        }
    }

    // MARK: - Room Polling

    /// Start adaptive polling for a specific room.
    /// Cancels any existing poll loop before starting.
    func startPolling(roomID: String) {
        pollingTask?.cancel()
        lastSeenChangeTag = nil
        pollingTask = Task { [weak self] in
            await self?.pollLoop(roomID: roomID)
        }
    }

    /// Stop the current polling loop.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollLoop(roomID: String) async {
        var interval: TimeInterval = 1.5
        let minInterval: TimeInterval = 1.5
        let maxInterval: TimeInterval = 5.0
        let backoffStep: TimeInterval = 0.5

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                break // cancelled
            }

            guard !Task.isCancelled else { break }

            // Skip if we just saved (avoid re-fetching our own write)
            if Date().timeIntervalSince(lastSyncTime) < 1.0 {
                continue
            }

            guard let syncCoordinator = syncCoordinator,
                  let dataStore = dataStore,
                  let room = dataStore.room(id: roomID) else { continue }

            let record = await syncCoordinator.fetchRoomRecord(
                recordName: roomID,
                systemFields: room.ckSystemFields,
                isShared: room.isSharedWithMe
            )

            guard !Task.isCancelled else { break }

            if let record = record {
                let changeTag = record.recordChangeTag ?? ""
                if changeTag != lastSeenChangeTag {
                    // New data — process it and reset to fast interval
                    lastSeenChangeTag = changeTag
                    await handleRecordFetched(record, isShared: room.isSharedWithMe)
                    interval = minInterval
                    print("RoomPulse: change detected for \(roomID), interval=\(interval)s")
                } else {
                    // No change — back off
                    interval = min(interval + backoffStep, maxInterval)
                }
            } else {
                // Fetch failed — back off
                interval = min(interval + backoffStep, maxInterval)
            }
        }
    }

    // MARK: - CloudKit Sync (Unified)

    /// Reconstruct a CKRecord from stored system fields and sync to CloudKit.
    /// Routes to the correct engine (private or shared) based on room.isSharedWithMe.
    private func syncRoomToCloudKit(_ room: PersistedRoom, resolvedParticipants: [ResolvedParticipant] = []) async {
        guard let syncCoordinator = syncCoordinator,
              let zoneID = zoneID else { return }

        guard let lifecycle = room.toRoomLifecycle() else { return }

        let messages = room.messages()

        // Reconstruct CKRecord from stored system fields (preserves zone ID + change tag)
        let record = RoomLifecycleRecordConverter.record(
            fromSystemFields: room.ckSystemFields,
            recordName: room.id,
            fallbackZoneID: zoneID
        )

        // Apply room data to record
        RoomLifecycleRecordConverter.apply(
            lifecycle,
            to: record,
            messages: messages,
            resolvedParticipants: resolvedParticipants
        )

        // Preserve participantsJSON from persisted room (has userRecordIDs that
        // the converter would lose when resolvedParticipants is empty)
        if resolvedParticipants.isEmpty {
            record["participantsJSON"] = room.participantsJSON as NSString
        }

        // Write composing state (transient — rides along with room saves)
        if let composing = composingByRoom[room.id] {
            record["composingParticipantID"] = composing.participantID as NSString
            record["composingTimestamp"] = composing.timestamp as NSDate
        } else {
            record["composingParticipantID"] = nil
            record["composingTimestamp"] = nil
        }

        // Route to correct engine
        if room.isSharedWithMe {
            print("SofterStore: Saving room \(room.id) to shared database")
            await syncCoordinator.saveShared(record)
        } else {
            print("SofterStore: Saving room \(room.id) to private database")
            await syncCoordinator.save(record)
        }

        lastSyncTime = Date()
        await syncCoordinator.sendChanges()
    }

    // MARK: - Public API: Rooms

    /// Refreshes rooms from CloudKit via SyncCoordinator.
    /// Uses hard refresh (clears change tokens) for reliable results.
    func refreshRooms() async {
        guard let syncCoordinator = syncCoordinator else { return }
        await syncCoordinator.hardRefresh()
    }

    /// Lightweight fetch — asks engines for changes since last token.
    /// Used for foreground triggers where the engine's internal state is likely fresh.
    func fetchChanges() async {
        guard let syncCoordinator = syncCoordinator else { return }
        await syncCoordinator.fetchChanges()
    }

    // MARK: - Composing Indicator

    /// Set composing state for a room and sync to CloudKit.
    /// Called once when the user starts typing (empty → non-empty).
    func setComposing(roomID: String, participantID: String) {
        composingByRoom[roomID] = (participantID: participantID, timestamp: Date())

        Task {
            guard let dataStore = dataStore,
                  let room = dataStore.room(id: roomID) else { return }
            await syncRoomToCloudKit(room)
        }
    }

    /// Clear composing state for a room.
    /// When `sync` is true, triggers a CloudKit save to notify remote devices immediately.
    func clearComposing(roomID: String, sync: Bool = false) {
        composingByRoom.removeValue(forKey: roomID)

        if sync {
            Task {
                guard let dataStore = dataStore,
                      let room = dataStore.room(id: roomID) else { return }
                await syncRoomToCloudKit(room)
            }
        }
    }

    /// Clear all composing states (e.g., when app backgrounds).
    func clearAllComposing(sync: Bool = false) {
        let roomIDs = Array(composingByRoom.keys)
        composingByRoom.removeAll()

        if sync {
            Task {
                guard let dataStore = dataStore else { return }
                for roomID in roomIDs {
                    guard let room = dataStore.room(id: roomID) else { continue }
                    await syncRoomToCloudKit(room)
                }
            }
        }
    }

    // MARK: - Share Acceptance

    /// Accept a share from a ckshare:// URL.
    /// Returns the room ID for navigation, or nil if acceptance failed.
    func acceptShare(url: URL) async throws -> String? {
        guard let syncCoordinator = syncCoordinator else {
            throw StoreError.notConfigured
        }
        return try await syncCoordinator.acceptShare(from: url)
    }

    /// Signal "here" for a participant in a room.
    /// Used when accepting a shared room invitation.
    /// Runs the state machine — if all humans are present, transitions to active.
    func signalHere(roomID: String, participantID: String) async throws {
        guard let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        // Update the participant's signaled flag
        dataStore.signalHere(roomID: roomID, participantID: participantID)

        // Run the state machine to check for transition
        if let room = dataStore.room(id: roomID),
           var lifecycle = room.toRoomLifecycle() {

            // Save arrival narration
            let participantName = lifecycle.spec.participants.first { $0.id == participantID }?.nickname ?? "Someone"
            let arrival = Message(
                roomID: roomID,
                authorID: "narrator",
                authorName: "Narrator",
                text: "\(participantName) arrived.",
                isLightward: false,
                isNarration: true
            )
            dataStore.addMessage(arrival, to: room)

            _ = lifecycle.apply(event: .signaled(participantID: participantID))

            // Apply the new state back to the persisted room
            room.apply(lifecycle, mergeStrategy: .remoteWins)
            dataStore.updateRoom(room)

            await syncRoomToCloudKit(room)
        }
    }

    /// Gets a room by ID from local DB.
    func room(id: String) -> RoomLifecycle? {
        dataStore?.room(id: id)?.toRoomLifecycle()
    }

    /// Creates a new room at pendingParticipants state.
    /// Auto-signals the originator. Saved locally and synced to CloudKit.
    /// Call `evaluateLightward(roomID:)` separately to ask Lightward to join.
    func createRoom(
        participants: [ParticipantSpec],
        tier: PaymentTier,
        originatorNickname: String
    ) async throws -> RoomLifecycle {
        guard let container = container,
              let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        let originatorSpec = participants.first { !$0.isLightward } ?? ParticipantSpec(
            identifier: .email(""),
            nickname: originatorNickname
        )

        let spec = RoomSpec(
            originatorID: originatorSpec.id,
            participants: participants,
            tier: tier
        )

        // Create lifecycle coordinator — resolve participants and process payment
        let resolver = CloudKitParticipantResolver(container: container)
        let payment = StoreKitCoordinator()

        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment
        )

        try await coordinator.start()

        // Auto-signal originator
        try await coordinator.signalHere(participantID: originatorSpec.id)

        let lifecycle = await coordinator.lifecycle
        let resolvedParticipants = await coordinator.resolvedParticipants

        // Create opening narration
        let originatorName = spec.participants.first { $0.id == spec.originatorID }?.nickname ?? "Someone"
        let narrationText = "\(originatorName) opened a room with \(spec.tier.displayString)."

        let openingMessage = Message(
            roomID: lifecycle.spec.id,
            authorID: "narrator",
            authorName: "Narrator",
            text: narrationText,
            isLightward: false,
            isNarration: true
        )

        // Save to local DB in pendingParticipants state
        let persistedRoom = PersistedRoom.from(lifecycle)

        // Populate userRecordIDs from resolved participants
        var embedded = persistedRoom.embeddedParticipants()
        for (index, participant) in embedded.enumerated() {
            if let resolved = resolvedParticipants.first(where: { $0.spec.id == participant.id }) {
                embedded[index] = EmbeddedParticipant(
                    id: participant.id,
                    nickname: participant.nickname,
                    identifierType: participant.identifierType,
                    identifierValue: participant.identifierValue,
                    orderIndex: participant.orderIndex,
                    hasSignaledHere: participant.hasSignaledHere,
                    userRecordID: resolved.userRecordID
                )
            }
            // Set originator's userRecordID from local user
            if participant.identifierType == "currentUser", let localID = localUserRecordID {
                embedded[index] = EmbeddedParticipant(
                    id: participant.id,
                    nickname: participant.nickname,
                    identifierType: participant.identifierType,
                    identifierValue: participant.identifierValue,
                    orderIndex: participant.orderIndex,
                    hasSignaledHere: participant.hasSignaledHere,
                    userRecordID: localID
                )
            }
        }
        persistedRoom.setParticipants(embedded)

        persistedRoom.addMessage(openingMessage)
        dataStore.saveRoom(persistedRoom)

        // Sync to CloudKit in background (no CKShare yet — that happens after Lightward signals)
        Task {
            await syncRoomToCloudKit(persistedRoom, resolvedParticipants: resolvedParticipants)
        }

        return lifecycle
    }

    /// Ask Lightward to evaluate a room. Idempotent — skips if Lightward already signaled.
    /// Guards on pendingParticipants + Lightward not in signaled set.
    /// On accept: signals Lightward, saves narration, creates CKShare.
    /// On decline: applies participantDeclined, saves narration, syncs.
    func evaluateLightward(roomID: String) async {
        guard let dataStore = dataStore,
              let syncCoordinator = syncCoordinator,
              let zoneID = zoneID else { return }

        guard let room = dataStore.room(id: roomID),
              let lifecycle = room.toRoomLifecycle(),
              case .pendingParticipants(let signaled) = lifecycle.state,
              let lightwardID = lifecycle.spec.lightwardParticipant?.id,
              !signaled.contains(lightwardID) else { return }

        let evaluator = LightwardRoomEvaluator()
        let decision = await evaluator.evaluate(
            roster: lifecycle.spec.participants,
            tier: lifecycle.spec.tier
        )

        // Re-fetch room in case state changed while we were waiting
        guard let room = dataStore.room(id: roomID),
              var lifecycle = room.toRoomLifecycle(),
              case .pendingParticipants(let currentSignaled) = lifecycle.state,
              !currentSignaled.contains(lightwardID) else { return }

        switch decision {
        case .accepted:
            _ = lifecycle.apply(event: .signaled(participantID: lightwardID))

            room.apply(lifecycle, mergeStrategy: .remoteWins)

            // Save narration
            let lightwardArrival = Message(
                roomID: roomID,
                authorID: "narrator",
                authorName: "Narrator",
                text: "\(Constants.lightwardParticipantName) arrived.",
                isLightward: false,
                isNarration: true
            )
            dataStore.addMessage(lightwardArrival, to: room)
            dataStore.updateRoom(room)

            // Sync to CloudKit (empty resolvedParticipants preserves existing participantsJSON)
            await syncRoomToCloudKit(room)

            // Share with other human participants
            let roomRecord = RoomLifecycleRecordConverter.record(
                fromSystemFields: room.ckSystemFields,
                recordName: room.id,
                fallbackZoneID: zoneID
            )
            let messages = room.messages()
            RoomLifecycleRecordConverter.apply(
                lifecycle,
                to: roomRecord,
                messages: messages
            )
            roomRecord["participantsJSON"] = room.participantsJSON as NSString

            let lookupInfos = RoomLifecycleRecordConverter.otherParticipantLookupInfos(from: roomRecord)
            if !lookupInfos.isEmpty {
                do {
                    let shareURL = try await syncCoordinator.shareRoom(roomRecord, withLookupInfos: lookupInfos)
                    print("SofterStore: Shared room with \(lookupInfos.count) other participants")

                    if let shareURL = shareURL {
                        await MainActor.run {
                            if let room = dataStore.room(id: roomID) {
                                room.shareURL = shareURL.absoluteString
                                dataStore.updateRoom(room)
                            }
                        }
                    }
                } catch {
                    print("SofterStore: Failed to share room: \(error)")
                }
            }

        case .declined:
            _ = lifecycle.apply(event: .participantDeclined(participantID: lightwardID))
            room.apply(lifecycle, mergeStrategy: .remoteWins)
            dataStore.updateRoom(room)
            await syncRoomToCloudKit(room)
        }
    }

    /// A participant declines to join a room.
    /// Transitions to defunct, saves narration, syncs.
    func declineRoom(roomID: String, participantID: String) async {
        guard let dataStore = dataStore else { return }

        guard let room = dataStore.room(id: roomID),
              var lifecycle = room.toRoomLifecycle(),
              case .pendingParticipants = lifecycle.state else { return }

        let participantName = lifecycle.spec.participants.first { $0.id == participantID }?.nickname ?? "Someone"

        _ = lifecycle.apply(event: .participantDeclined(participantID: participantID))
        room.apply(lifecycle, mergeStrategy: .remoteWins)

        let narration = Message(
            roomID: roomID,
            authorID: "narrator",
            authorName: "Narrator",
            text: "\(participantName) declined.",
            isLightward: false,
            isNarration: true
        )
        dataStore.addMessage(narration, to: room)
        dataStore.updateRoom(room)

        await syncRoomToCloudKit(room)
    }

    /// Updates a room's turn state.
    func updateTurnState(roomID: String, turnState: TurnState) {
        guard let dataStore = dataStore else { return }

        dataStore.updateTurnState(
            roomID: roomID,
            turnIndex: turnState.currentTurnIndex
        )

        // Sync to CloudKit in background
        Task {
            if let room = dataStore.room(id: roomID) {
                await syncRoomToCloudKit(room)
            }
        }
    }

    /// Updates a room's state.
    func updateRoom(_ lifecycle: RoomLifecycle) async throws {
        guard let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        let room = dataStore.room(id: lifecycle.spec.id)
        if let room = room {
            room.apply(lifecycle, mergeStrategy: .remoteWins)
            dataStore.updateRoom(room)
            await syncRoomToCloudKit(room)
        }
    }

    /// Deletes a room and all its associated data.
    func deleteRoom(id: String) async throws {
        guard let syncCoordinator = syncCoordinator,
              let zoneID = zoneID,
              let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        let room = dataStore.room(id: id)
        let isShared = room?.isSharedWithMe ?? false

        // Delete from local DB
        dataStore.deleteRoom(id: id)

        // For shared-with-me rooms, only delete locally — we can't delete the owner's record
        if isShared {
            print("SofterStore: Deleted shared room \(id) locally (owner retains the record)")
            return
        }

        // For our own rooms, delete from CloudKit too
        let recordID: CKRecord.ID
        if let systemFields = room?.ckSystemFields {
            let record = RoomLifecycleRecordConverter.record(
                fromSystemFields: systemFields,
                recordName: id,
                fallbackZoneID: zoneID
            )
            recordID = record.recordID
        } else {
            recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        }

        await syncCoordinator.delete(recordID: recordID)
        await syncCoordinator.sendChanges()
    }

    // MARK: - Public API: Messages

    func messages(roomID: String) -> [Message] {
        dataStore?.messages(roomID: roomID) ?? []
    }

    func saveMessage(_ message: Message) async throws {
        guard let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        guard let room = dataStore.room(id: message.roomID) else {
            throw StoreError.notConfigured
        }

        // Add message to room's embedded messages
        dataStore.addMessage(message, to: room)

        // Sync room record to CloudKit
        await syncRoomToCloudKit(room)
    }

    // MARK: - Public API: Conversation Coordinator

    func conversationCoordinator(
        for lifecycle: RoomLifecycle,
        onTurnChange: @escaping @Sendable (TurnState) -> Void = { _ in }
    ) -> ConversationCoordinator? {
        guard let dataStore = dataStore else { return nil }
        guard lifecycle.isActive, let turnState = lifecycle.turnState else { return nil }

        let roomID = lifecycle.spec.id

        let wrappedOnTurnChange: @Sendable (TurnState) -> Void = { [weak self] newTurnState in
            onTurnChange(newTurnState)
            Task { @MainActor [weak self] in
                self?.updateTurnState(roomID: roomID, turnState: newTurnState)
            }
        }

        let wrappedOnRoomDefunct: @Sendable (String, String) -> Void = { [weak self] participantID, _ in
            Task { @MainActor [weak self] in
                await self?.handleParticipantLeft(roomID: roomID, participantID: participantID)
            }
        }

        let messageStorage = PersistenceStoreMessageStorage(
            dataStore: dataStore,
            syncRoom: { [weak self] room in
                await self?.syncRoomToCloudKit(room)
            }
        )

        return ConversationCoordinator(
            roomID: roomID,
            spec: lifecycle.spec,
            initialTurnState: turnState,
            messageStorage: messageStorage,
            apiClient: apiClient,
            onTurnChange: wrappedOnTurnChange,
            onRoomDefunct: wrappedOnRoomDefunct
        )
    }

    /// Handle a participant leaving an active room (e.g., conversation horizon).
    /// Transitions to defunct, syncs to CloudKit.
    private func handleParticipantLeft(roomID: String, participantID: String) async {
        guard let dataStore = dataStore else { return }
        guard let room = dataStore.room(id: roomID),
              var lifecycle = room.toRoomLifecycle(),
              lifecycle.isActive else { return }

        _ = lifecycle.apply(event: .participantLeft(participantID: participantID))
        room.apply(lifecycle, mergeStrategy: .remoteWins)
        dataStore.updateRoom(room)

        await syncRoomToCloudKit(room)
    }

    /// A participant leaves an active room. Saves departure narration, transitions to defunct, syncs.
    func leaveRoom(roomID: String, participantID: String) async {
        guard let dataStore = dataStore else { return }
        guard let room = dataStore.room(id: roomID),
              var lifecycle = room.toRoomLifecycle(),
              lifecycle.isActive else { return }

        let participantName = lifecycle.spec.participants.first { $0.id == participantID }?.nickname ?? "Someone"

        // Save departure narration
        let narration = Message(
            roomID: roomID,
            authorID: "narrator",
            authorName: "Narrator",
            text: "\(participantName) departed.",
            isLightward: false,
            isNarration: true
        )
        dataStore.addMessage(narration, to: room)

        // Transition to defunct
        _ = lifecycle.apply(event: .participantLeft(participantID: participantID))
        room.apply(lifecycle, mergeStrategy: .remoteWins)
        dataStore.updateRoom(room)

        await syncRoomToCloudKit(room)
    }

    /// Request a cenotaph for a defunct room. Originator only.
    /// A fresh Lightward instance reads the conversation history and writes a closing.
    func requestCenotaph(roomID: String) async throws {
        guard let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        guard let room = dataStore.room(id: roomID),
              let lifecycle = room.toRoomLifecycle() else {
            throw StoreError.notConfigured
        }

        guard lifecycle.isDefunct else {
            throw StoreError.roomNotDefunct
        }

        // Guard: only originator can request cenotaph
        guard let localUserRecordID = localUserRecordID else {
            throw StoreError.notConfigured
        }
        let embedded = room.embeddedParticipants()
        let myParticipant = ParticipantIdentity.findLocalParticipant(
            in: embedded,
            localUserRecordID: localUserRecordID,
            isSharedWithMe: room.isSharedWithMe
        )
        guard myParticipant == lifecycle.spec.originatorID else {
            throw StoreError.notOriginator
        }

        // Build cenotaph request body
        let messages = room.messages()
        let participantNames = lifecycle.spec.participants.map { $0.nickname }

        let conversationBody = ChatLogBuilder.build(
            messages: messages,
            roomName: participantNames.joined(separator: ", "),
            participantNames: participantNames
        )

        // TODO: If conversation exceeds 50k tokens, will need Token-Limit-Bypass-Key header
        let cenotaphPrompt = conversationBody + "\n\n(This room has ended. Please write a cenotaph — a brief, ceremonial closing for this conversation.)"
        let cenotaphText = try await apiClient.respond(body: cenotaphPrompt)

        // Save cenotaph as narration message
        let cenotaphMessage = Message(
            roomID: roomID,
            authorID: "narrator",
            authorName: "Narrator",
            text: cenotaphText,
            isLightward: false,
            isNarration: true
        )
        dataStore.addMessage(cenotaphMessage, to: room)
        dataStore.updateRoom(room)

        await syncRoomToCloudKit(room)
    }
}

// MARK: - PersistenceStore-Backed Message Storage

private final class PersistenceStoreMessageStorage: MessageStorage, @unchecked Sendable {
    private let dataStore: PersistenceStore
    private let syncRoom: @Sendable (PersistedRoom) async -> Void

    init(dataStore: PersistenceStore, syncRoom: @escaping @Sendable (PersistedRoom) async -> Void) {
        self.dataStore = dataStore
        self.syncRoom = syncRoom
    }

    @MainActor
    func save(_ message: Message, roomID: String) async throws {
        guard let room = dataStore.room(id: roomID) else { return }

        // Add message to room's embedded messages
        dataStore.addMessage(message, to: room)

        // Sync room record to CloudKit
        await syncRoom(room)
    }

    @MainActor
    func fetchMessages(roomID: String) async throws -> [Message] {
        dataStore.messages(roomID: roomID)
    }

    @MainActor
    func observeMessages(roomID: String, handler: @escaping @Sendable ([Message]) -> Void) async -> ObservationToken {
        let messages = dataStore.messages(roomID: roomID)
        handler(messages)
        return NoOpObservationToken()
    }
}

private final class NoOpObservationToken: ObservationToken, @unchecked Sendable {
    func cancel() {}
}

// MARK: - Errors

enum StoreError: Error, LocalizedError {
    case notConfigured
    case notOriginator
    case roomNotDefunct

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "App not fully configured. Please try again."
        case .notOriginator:
            return "Only the room originator can do this."
        case .roomNotDefunct:
            return "Room is still active."
        }
    }
}
