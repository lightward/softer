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

    // MARK: - Private State

    private var dataStore: PersistenceStore?
    private var container: CKContainer?
    private var syncCoordinator: SyncCoordinator?
    private var zoneID: CKRecordZone.ID?
    private let apiClient: any LightwardAPI

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
                    _ = self
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

    private func handleRecordFetched(_ record: CKRecord) async {
        guard let dataStore = dataStore else { return }

        print("SofterStore: Fetched record type=\(record.recordType) id=\(record.recordID.recordName)")

        switch record.recordType {
        case RoomLifecycleRecordConverter.roomRecordType:
            // Room3 with embedded participants - simple!
            if let lifecycle = RoomLifecycleRecordConverter.lifecycle(from: record) {
                dataStore.upsertRoom(from: lifecycle)
                print("SofterStore: Room \(record.recordID.recordName) synced from CloudKit")
            }

        case MessageRecordConverter.recordType:
            if let message = MessageRecordConverter.message(from: record) {
                dataStore.upsertMessage(from: message)
            }

        default:
            break
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

    // MARK: - Public API: Rooms

    /// Refreshes rooms from CloudKit via SyncCoordinator.
    func refreshRooms() async {
        guard let syncCoordinator = syncCoordinator else { return }
        await syncCoordinator.fetchChanges()
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

        let originatorSpec = participants.first { !$0.isLightward } ?? ParticipantSpec(
            identifier: .email(""),
            nickname: originatorNickname
        )

        let isFirstRoom = true  // TODO: Check actual room count

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

        try await coordinator.start()

        // Auto-signal for all humans (single-device for now)
        for participant in spec.humanParticipants {
            try await coordinator.signalHere(participantID: participant.id)
        }

        let lifecycle = await coordinator.lifecycle

        // Save to local DB (participants are embedded in lifecycle)
        let persistedRoom = PersistedRoom.from(lifecycle)
        dataStore.saveRoom(persistedRoom)

        // Save opening narration
        let originatorName = spec.participants.first { $0.id == spec.originatorID }?.nickname ?? "Someone"
        let narrationText = spec.isFirstRoom
            ? "\(originatorName) opened their first room."
            : "\(originatorName) opened the room with \(spec.tier.displayString)."

        let openingMessage = PersistedMessage(
            roomID: lifecycle.spec.id,
            authorID: "narrator",
            authorName: "Narrator",
            text: narrationText,
            isLightward: false,
            isNarration: true
        )
        dataStore.saveMessage(openingMessage, to: persistedRoom)

        // Sync to CloudKit in background
        Task {
            // Save single Room3 record (participants embedded)
            let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
            await syncCoordinator.save(roomRecord)

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

    /// Updates a room's turn state.
    func updateTurnState(roomID: String, turnState: TurnState) {
        guard let dataStore = dataStore else { return }

        dataStore.updateTurnState(
            roomID: roomID,
            turnIndex: turnState.currentTurnIndex,
            raisedHands: turnState.raisedHands
        )

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

        if let room = dataStore.room(id: lifecycle.spec.id) {
            room.apply(lifecycle, mergeStrategy: .remoteWins)
            dataStore.updateRoom(room)
        }

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

        let messages = dataStore.messages(roomID: id)

        // Delete from local DB
        dataStore.deleteRoom(id: id)

        // Delete from CloudKit
        let roomRecordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        await syncCoordinator.delete(recordID: roomRecordID)

        for message in messages {
            let messageRecordID = CKRecord.ID(recordName: message.id, zoneID: zoneID)
            await syncCoordinator.delete(recordID: messageRecordID)
        }

        await syncCoordinator.sendChanges()
    }

    // MARK: - Public API: Messages

    func messages(roomID: String) -> [Message] {
        dataStore?.messages(roomID: roomID).map { $0.toMessage() } ?? []
    }

    func saveMessage(_ message: Message) async throws {
        guard let syncCoordinator = syncCoordinator,
              let zoneID = zoneID,
              let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

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

        let messageRecord = MessageRecordConverter.record(from: message, zoneID: zoneID)
        await syncCoordinator.save(messageRecord)
        await syncCoordinator.sendChanges()
    }

    // MARK: - Public API: Conversation Coordinator

    func conversationCoordinator(
        for lifecycle: RoomLifecycle,
        onTurnChange: @escaping @Sendable (TurnState) -> Void = { _ in },
        onStreamingText: @escaping @Sendable (String) -> Void = { _ in }
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
        let messages = dataStore.messages(roomID: roomID).map { $0.toMessage() }
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

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "App not fully configured. Please try again."
        }
    }
}
