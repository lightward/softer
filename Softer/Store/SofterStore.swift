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

    /// Triggers view updates when SwiftData content changes.
    /// Increment this to force views to re-read `rooms`.
    private(set) var dataVersion: Int = 0

    /// All active rooms, sorted by creation date.
    /// Computed from SwiftData - always fresh.
    var rooms: [RoomLifecycle] {
        // Touch dataVersion so @Observable knows to re-evaluate when it changes
        _ = dataVersion
        return dataStore?.allRooms().compactMap { $0.toRoomLifecycle() } ?? []
    }

    /// Whether initial data load has completed.
    private(set) var initialLoadCompleted = false

    /// Local user's CloudKit record ID.
    private(set) var localUserRecordID: String?

    // MARK: - Private State

    private var dataStore: PersistenceStore?
    private var container: CKContainer?
    private var syncCoordinator: SyncCoordinator?
    private var zoneID: CKRecordZone.ID?
    private let apiClient: any LightwardAPI

    // MARK: - Initialization

    init(apiClient: any LightwardAPI = LightwardAPIClient()) {
        self.apiClient = apiClient
        Task {
            await setup()
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

    private func setup() async {
        do {
            // Initialize SwiftData first - this is our source of truth
            print("SofterStore: Initializing PersistenceStore...")
            let dataStore = try PersistenceStore()
            self.dataStore = dataStore
            print("SofterStore: PersistenceStore initialized successfully")

            let ckContainer = CKContainer(identifier: Constants.containerIdentifier)

            let accountStatus = try await ckContainer.accountStatus()
            guard accountStatus == .available else {
                syncStatus = .error("Softer requires iCloud. Sign in via Settings to begin.")
                // Still mark as loaded - we have local data
                initialLoadCompleted = true
                return
            }

            self.container = ckContainer

            // Get user ID
            let userID = try await ckContainer.userRecordID()
            localUserRecordID = userID.recordName

            // Use custom zone (required for CKSyncEngine to track changes)
            let zoneID = CKRecordZone.ID(zoneName: "SofterZone", ownerName: CKCurrentUserDefaultName)
            self.zoneID = zoneID

            // Create and start SyncCoordinator
            let coordinator = SyncCoordinator(
                database: ckContainer.privateCloudDatabase,
                zoneID: zoneID
            )
            self.syncCoordinator = coordinator

            await coordinator.start(
                onRecordFetched: { [weak self] record in
                    await self?.handleRecordFetched(record)
                },
                onRecordDeleted: { [weak self] recordID in
                    await self?.handleRecordDeleted(recordID)
                },
                onStatusChange: { [weak self] status in
                    await self?.handleStatusChange(status)
                },
                onBatchComplete: { [weak self] in
                    // No longer needed - PersistenceStore handles persistence
                    _ = self
                }
            )

            // Fetch changes from CloudKit and merge into local DB
            await coordinator.fetchChanges()
            initialLoadCompleted = true

        } catch {
            print("SofterStore: Setup failed with error: \(error)")
            print("SofterStore: Error type: \(type(of: error))")
            syncStatus = .error("Failed to initialize: \(error.localizedDescription)")
            initialLoadCompleted = true
        }
    }

    // MARK: - SyncCoordinator Handlers

    private func handleRecordFetched(_ record: CKRecord) async {
        guard let dataStore = dataStore else { return }

        print("SofterStore: Fetched record type=\(record.recordType) id=\(record.recordID.recordName)")

        switch record.recordType {
        case RoomLifecycleRecordConverter.roomRecordType:
            await handleRoomRecordFetched(record, dataStore: dataStore)

        case RoomLifecycleRecordConverter.participantRecordType:
            await handleParticipantRecordFetched(record, dataStore: dataStore)

        case MessageRecordConverter.recordType:
            if let message = MessageRecordConverter.message(from: record) {
                dataStore.upsertMessage(from: message)
            }

        default:
            break
        }
    }

    private func handleRoomRecordFetched(_ record: CKRecord, dataStore: PersistenceStore) async {
        let roomID = record.recordID.recordName

        // Get participants from local DB
        let participants = dataStore.participants(roomID: roomID)

        guard !participants.isEmpty else {
            print("SofterStore: Room \(roomID) has no participants yet, skipping")
            return
        }

        let specs = participants.map { $0.toParticipantSpec() }
        let signaledIDs = Set(participants.filter(\.hasSignaledHere).map(\.id))

        if let lifecycle = RoomLifecycleRecordConverter.lifecycle(
            from: record,
            participants: specs,
            signaledParticipantIDs: signaledIDs
        ) {
            // upsertRoom handles merging (higher turn index wins)
            dataStore.upsertRoom(from: lifecycle, participants: specs)
            print("SofterStore: Room \(roomID) synced from CloudKit")
        }
    }

    private func handleParticipantRecordFetched(_ record: CKRecord, dataStore: PersistenceStore) async {
        guard let roomID = RoomLifecycleRecordConverter.roomID(from: record),
              let spec = RoomLifecycleRecordConverter.participantSpec(from: record) else {
            print("SofterStore: Failed to parse Participant2 record")
            return
        }

        let orderIndex = RoomLifecycleRecordConverter.orderIndex(from: record)
        let hasSignaled = RoomLifecycleRecordConverter.hasSignaledHere(from: record)

        // Check if participant already exists
        if let existing = dataStore.participant(id: spec.id) {
            existing.hasSignaledHere = existing.hasSignaledHere || hasSignaled
            if let room = dataStore.room(id: roomID) {
                dataStore.updateRoom(room)
            }
        } else {
            // Create new participant - need to attach to room
            if let room = dataStore.room(id: roomID) {
                let participant = PersistedParticipant.from(spec, roomID: roomID, orderIndex: orderIndex)
                participant.hasSignaledHere = hasSignaled
                dataStore.saveParticipant(participant, to: room)
            }
        }

        print("SofterStore: Synced participant \(spec.nickname) for room \(roomID)")
    }

    private func handleRecordDeleted(_ recordID: CKRecord.ID) async {
        guard let dataStore = dataStore else { return }
        let id = recordID.recordName
        // Only delete and update UI if the room actually exists
        if dataStore.room(id: id) != nil {
            dataStore.deleteRoom(id: id)
            dataVersion += 1
        }
    }

    @MainActor
    private func handleStatusChange(_ status: SyncStatus) async {
        self.syncStatus = status
    }

    // MARK: - Public API: Rooms

    /// Refreshes rooms from CloudKit via SyncCoordinator.
    func refreshRooms() async {
        guard let syncCoordinator = syncCoordinator else { return }
        await syncCoordinator.fetchChanges()
        // Trigger view update after sync
        dataVersion += 1
    }

    /// Gets a room by ID from local DB.
    func room(id: String) -> RoomLifecycle? {
        dataStore?.room(id: id)?.toRoomLifecycle()
    }

    /// Creates a new room with the full lifecycle flow.
    func createRoom(
        participants: [ParticipantSpec],
        tier: PaymentTier,
        originatorNickname: String
    ) async throws -> RoomLifecycle {
        guard let container = container,
              let syncCoordinator = syncCoordinator,
              let zoneID = zoneID,
              let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        // Find or create originator spec
        let originatorSpec = participants.first { !$0.isLightward } ?? ParticipantSpec(
            identifier: .email(""),
            nickname: originatorNickname
        )

        // For now, always treat as first room (free) to test save flow
        let isFirstRoom = true

        let spec = RoomSpec(
            originatorID: originatorSpec.id,
            participants: participants,
            tier: tier,
            isFirstRoom: isFirstRoom
        )

        // Create lifecycle coordinator
        let resolver = CloudKitParticipantResolver(container: container)
        let payment = ApplePayCoordinator(merchantIdentifier: Constants.appleMerchantIdentifier)
        let lightward = LightwardRoomEvaluator()

        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment,
            lightward: lightward
        )

        // Start creation flow
        try await coordinator.start()

        // Auto-signal for all humans (single-device for now)
        for participant in spec.humanParticipants {
            try await coordinator.signalHere(participantID: participant.id)
        }

        let lifecycle = await coordinator.lifecycle
        let resolvedParticipants = await coordinator.resolvedParticipants

        // Save to local DB FIRST (synchronous, immediate)
        let persistedRoom = PersistedRoom.from(lifecycle)
        dataStore.saveRoom(persistedRoom)

        // Add participants to local DB
        for (index, resolved) in resolvedParticipants.enumerated() {
            let participant = PersistedParticipant.from(resolved.spec, roomID: lifecycle.spec.id, orderIndex: index)
            participant.hasSignaledHere = true
            dataStore.saveParticipant(participant, to: persistedRoom)
        }

        // Save opening narration to local DB
        let originatorName = spec.participants.first { $0.id == spec.originatorID }?.nickname ?? "Someone"
        let narrationText: String
        if spec.isFirstRoom {
            narrationText = "\(originatorName) opened their first room."
        } else {
            narrationText = "\(originatorName) opened the room with \(spec.tier.displayString)."
        }

        let openingMessage = PersistedMessage(
            roomID: lifecycle.spec.id,
            authorID: "narrator",
            authorName: "Narrator",
            text: narrationText,
            isLightward: false,
            isNarration: true
        )
        dataStore.saveMessage(openingMessage, to: persistedRoom)

        // Trigger view update
        dataVersion += 1

        // NOW sync to CloudKit (async, fire-and-forget)
        Task {
            // Save room record
            let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
            await syncCoordinator.save(roomRecord)

            // Save participant records
            for (index, resolved) in resolvedParticipants.enumerated() {
                let participantRecord = RoomLifecycleRecordConverter.record(
                    from: resolved.spec,
                    roomID: lifecycle.spec.id,
                    userRecordID: resolved.userRecordID,
                    hasSignaledHere: true,
                    orderIndex: index,
                    zoneID: zoneID
                )
                await syncCoordinator.save(participantRecord)
            }

            // Save message record
            let messageRecord = MessageRecordConverter.record(
                from: Message(
                    id: openingMessage.id,
                    roomID: openingMessage.roomID,
                    authorID: openingMessage.authorID,
                    authorName: openingMessage.authorName,
                    text: openingMessage.text,
                    createdAt: openingMessage.createdAt,
                    isLightward: openingMessage.isLightward,
                    isNarration: openingMessage.isNarration
                ),
                zoneID: zoneID
            )
            await syncCoordinator.save(messageRecord)

            await syncCoordinator.sendChanges()
        }

        return lifecycle
    }

    /// Updates a room's turn state. SYNCHRONOUS local update.
    func updateTurnState(roomID: String, turnState: TurnState) {
        guard let dataStore = dataStore else { return }

        // Update local DB immediately (THIS IS THE KEY FIX)
        dataStore.updateTurnState(
            roomID: roomID,
            turnIndex: turnState.currentTurnIndex,
            raisedHands: turnState.raisedHands
        )

        // Trigger view update
        dataVersion += 1

        // Sync to CloudKit in background
        Task {
            guard let syncCoordinator = syncCoordinator, let zoneID = zoneID else { return }
            if let room = dataStore.room(id: roomID),
               let lifecycle = room.toRoomLifecycle() {
                let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
                await syncCoordinator.save(roomRecord)
                await syncCoordinator.sendChanges()
            }
        }
    }

    /// Updates a room's state.
    func updateRoom(_ lifecycle: RoomLifecycle) async throws {
        guard let syncCoordinator = syncCoordinator,
              let zoneID = zoneID,
              let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        // Update local DB immediately
        if let room = dataStore.room(id: lifecycle.spec.id) {
            room.apply(lifecycle, mergeStrategy: .remoteWins)
            dataStore.updateRoom(room)
        }

        // Sync to CloudKit
        let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
        await syncCoordinator.save(roomRecord)
        await syncCoordinator.sendChanges()
    }

    /// Deletes a room and all its associated data.
    func deleteRoom(id: String) async throws {
        guard let syncCoordinator = syncCoordinator,
              let zoneID = zoneID,
              let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        // Get data for CloudKit deletion
        let participants = dataStore.participants(roomID: id)
        let messages = dataStore.messages(roomID: id)

        // Delete from local DB immediately
        dataStore.deleteRoom(id: id)

        // Trigger view update
        dataVersion += 1

        // Delete from CloudKit
        let roomRecordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        await syncCoordinator.delete(recordID: roomRecordID)

        for participant in participants {
            let participantRecordID = CKRecord.ID(recordName: participant.id, zoneID: zoneID)
            await syncCoordinator.delete(recordID: participantRecordID)
        }

        for message in messages {
            let messageRecordID = CKRecord.ID(recordName: message.id, zoneID: zoneID)
            await syncCoordinator.delete(recordID: messageRecordID)
        }

        await syncCoordinator.sendChanges()
    }

    // MARK: - Public API: Messages

    /// Gets messages for a room from local DB.
    func messages(roomID: String) -> [Message] {
        dataStore?.messages(roomID: roomID).map { $0.toMessage() } ?? []
    }

    /// Observes messages for a room.
    /// Returns current messages immediately and a stream for updates.
    func observeMessages(roomID: String) async -> (initial: [Message], stream: AsyncStream<[Message]>) {
        let initial = messages(roomID: roomID)

        // Create a stream that polls for changes
        // TODO: Replace with proper SwiftData observation when available
        let stream = AsyncStream<[Message]> { continuation in
            let task = Task {
                var lastCount = initial.count
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    let current = self.messages(roomID: roomID)
                    if current.count != lastCount {
                        lastCount = current.count
                        continuation.yield(current)
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return (initial, stream)
    }

    /// Saves a message to storage.
    func saveMessage(_ message: Message) async throws {
        guard let syncCoordinator = syncCoordinator,
              let zoneID = zoneID,
              let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        // Save to local DB immediately
        if let room = dataStore.room(id: message.roomID) {
            let persisted = PersistedMessage(
                id: message.id,
                roomID: message.roomID,
                authorID: message.authorID,
                authorName: message.authorName,
                text: message.text,
                isLightward: message.isLightward,
                isNarration: message.isNarration
            )
            dataStore.saveMessage(persisted, to: room)
        }

        // Sync to CloudKit
        let messageRecord = MessageRecordConverter.record(from: message, zoneID: zoneID)
        await syncCoordinator.save(messageRecord)
        await syncCoordinator.sendChanges()
    }

    // MARK: - Public API: Conversation Coordinator

    /// Creates a ConversationCoordinator for an active room.
    func conversationCoordinator(
        for lifecycle: RoomLifecycle,
        onTurnChange: @escaping @Sendable (TurnState) -> Void = { _ in },
        onStreamingText: @escaping @Sendable (String) -> Void = { _ in }
    ) -> ConversationCoordinator? {
        guard let dataStore = dataStore else { return nil }
        guard lifecycle.isActive, let turnState = lifecycle.turnState else { return nil }

        let roomID = lifecycle.spec.id

        // Wrap onTurnChange to update local DB SYNCHRONOUSLY
        let wrappedOnTurnChange: @Sendable (TurnState) -> Void = { [weak self] newTurnState in
            // Call the view's callback first
            onTurnChange(newTurnState)

            // Update local DB synchronously (on main actor)
            Task { @MainActor [weak self] in
                self?.updateTurnState(roomID: roomID, turnState: newTurnState)
            }
        }

        // Create message storage backed by PersistenceStore
        let messageStorage = PersistenceStoreMessageStorage(
            dataStore: dataStore,
            syncCoordinator: syncCoordinator,
            zoneID: zoneID
        )

        return ConversationCoordinator(
            roomID: roomID,
            spec: lifecycle.spec,
            initialTurnState: turnState,
            messageStorage: messageStorage,
            apiClient: apiClient,
            onTurnChange: wrappedOnTurnChange,
            onStreamingText: onStreamingText
        )
    }
}

// MARK: - PersistenceStore-Backed Message Storage

/// MessageStorage implementation that uses PersistenceStore for persistence.
private final class PersistenceStoreMessageStorage: MessageStorage, @unchecked Sendable {
    private let dataStore: PersistenceStore
    private let syncCoordinator: SyncCoordinator?
    private let zoneID: CKRecordZone.ID?

    init(dataStore: PersistenceStore, syncCoordinator: SyncCoordinator?, zoneID: CKRecordZone.ID?) {
        self.dataStore = dataStore
        self.syncCoordinator = syncCoordinator
        self.zoneID = zoneID
    }

    @MainActor
    func save(_ message: Message, roomID: String) async throws {
        // Save to local DB immediately
        if let room = dataStore.room(id: roomID) {
            let persisted = PersistedMessage(
                id: message.id,
                roomID: message.roomID,
                authorID: message.authorID,
                authorName: message.authorName,
                text: message.text,
                isLightward: message.isLightward,
                isNarration: message.isNarration
            )
            dataStore.saveMessage(persisted, to: room)
        }

        // Sync to CloudKit
        if let syncCoordinator = syncCoordinator, let zoneID = zoneID {
            let messageRecord = MessageRecordConverter.record(from: message, zoneID: zoneID)
            await syncCoordinator.save(messageRecord)
            await syncCoordinator.sendChanges()
        }
    }

    @MainActor
    func fetchMessages(roomID: String) async throws -> [Message] {
        dataStore.messages(roomID: roomID).map { $0.toMessage() }
    }

    @MainActor
    func observeMessages(roomID: String, handler: @escaping @Sendable ([Message]) -> Void) async -> ObservationToken {
        // For now, just return current messages and poll
        // TODO: Use SwiftData's @Query for reactive updates
        let messages = dataStore.messages(roomID: roomID).map { $0.toMessage() }
        handler(messages)

        // Return a no-op token for now
        return NoOpObservationToken()
    }
}

/// No-op observation token.
private final class NoOpObservationToken: ObservationToken, @unchecked Sendable {
    func cancel() {}
}

// MARK: - Errors

enum StoreError: Error, LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "App not fully configured. Please try again."
        }
    }
}
