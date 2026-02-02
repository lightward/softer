import Foundation
import CloudKit
import SwiftUI

/// Main observable store for the app.
/// Provides a simple API for views; all sync logic is internal.
@Observable
@MainActor
final class SofterStore {

    // MARK: - Public State

    /// Current sync status.
    private(set) var syncStatus: SyncStatus = .idle

    /// All active rooms, sorted by creation date.
    private(set) var rooms: [RoomLifecycle] = []

    /// Whether initial data load has completed.
    private(set) var initialLoadCompleted = false

    /// Local user's CloudKit record ID.
    private(set) var localUserRecordID: String?

    // MARK: - Private State

    private let localStore = LocalStore()
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
        container: CKContainer?,
        syncCoordinator: SyncCoordinator?,
        zoneID: CKRecordZone.ID?
    ) {
        self.apiClient = apiClient
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
            let ckContainer = CKContainer(identifier: Constants.containerIdentifier)

            let accountStatus = try await ckContainer.accountStatus()
            guard accountStatus == .available else {
                syncStatus = .error("Softer requires iCloud. Sign in via Settings to begin.")
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

            // Clear persisted sync state on startup since LocalStore is in-memory.
            // This ensures we always fetch all records from CloudKit.
            // TODO: Remove this once LocalStore persists data.
            await coordinator.clearPersistedState()

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
                    await self?.finalizePendingRooms()
                }
            )

            // Fetch initial changes
            await coordinator.fetchChanges()
            initialLoadCompleted = true

        } catch {
            syncStatus = .error("Softer requires iCloud. Sign in via Settings to begin.")
        }
    }

    // MARK: - SyncCoordinator Handlers

    private func handleRecordFetched(_ record: CKRecord) async {
        print("SofterStore: Fetched record type=\(record.recordType) id=\(record.recordID.recordName)")
        switch record.recordType {
        case RoomLifecycleRecordConverter.roomRecordType:
            await handleRoomRecordFetched(record)

        case RoomLifecycleRecordConverter.participantRecordType:
            await handleParticipantRecordFetched(record)

        case MessageRecordConverter.recordType:
            if let message = MessageRecordConverter.message(from: record) {
                await localStore.addMessage(message)
            }

        default:
            break
        }
    }

    private func handleRoomRecordFetched(_ record: CKRecord) async {
        let roomID = record.recordID.recordName

        // Check if we have participants cached
        if let storedParticipants = await localStore.participantsForRoom(roomID) {
            print("SofterStore: Room \(roomID) has \(storedParticipants.count) cached participants, reconstructing")
            // Reconstruct full lifecycle
            let sorted = storedParticipants.sorted { $0.orderIndex < $1.orderIndex }
            let specs = sorted.map(\.spec)
            let signaledIDs = Set(sorted.filter(\.hasSignaledHere).map(\.spec.id))

            if let lifecycle = RoomLifecycleRecordConverter.lifecycle(
                from: record,
                participants: specs,
                signaledParticipantIDs: signaledIDs
            ) {
                await localStore.upsertRoom(lifecycle)
                rooms = await localStore.allRooms
                print("SofterStore: Room \(roomID) reconstructed, now have \(rooms.count) rooms")
            } else {
                print("SofterStore: Failed to reconstruct room \(roomID)")
            }
        } else {
            // Store as pending, wait for participants
            print("SofterStore: Room \(roomID) has no cached participants, storing as pending")
            await localStore.storePendingRoom(record)
        }
    }

    private func handleParticipantRecordFetched(_ record: CKRecord) async {
        guard let roomID = RoomLifecycleRecordConverter.roomID(from: record),
              let spec = RoomLifecycleRecordConverter.participantSpec(from: record) else {
            print("SofterStore: Failed to parse Participant2 record")
            return
        }

        print("SofterStore: Caching participant \(spec.nickname) for room \(roomID)")
        let stored = LocalStore.StoredParticipant(
            spec: spec,
            orderIndex: RoomLifecycleRecordConverter.orderIndex(from: record),
            hasSignaledHere: RoomLifecycleRecordConverter.hasSignaledHere(from: record)
        )
        await localStore.upsertParticipant(stored, roomID: roomID)
        // Don't try to complete pending rooms here - wait for batch complete
    }

    private func handleRecordDeleted(_ recordID: CKRecord.ID) async {
        let id = recordID.recordName

        // Try to delete as room first
        await localStore.deleteRoom(id: id)
        await localStore.removePendingRoom(id)

        // Update rooms list
        rooms = await localStore.allRooms
    }

    @MainActor
    private func handleStatusChange(_ status: SyncStatus) async {
        self.syncStatus = status
    }

    private func finalizePendingRooms() async {
        print("SofterStore: Finalizing pending rooms...")
        let completedRooms = await localStore.completeAllPendingRooms()
        print("SofterStore: Completed \(completedRooms.count) pending rooms")
        if !completedRooms.isEmpty {
            for lifecycle in completedRooms {
                await localStore.upsertRoom(lifecycle)
            }
            rooms = await localStore.allRooms
            print("SofterStore: Now have \(rooms.count) rooms total")
        }
    }

    // MARK: - Public API: Rooms

    /// Refreshes rooms from CloudKit via SyncCoordinator.
    func refreshRooms() async {
        guard let syncCoordinator = syncCoordinator else { return }
        await syncCoordinator.fetchChanges()
        rooms = await localStore.allRooms
    }

    /// Gets a room by ID from local cache.
    func room(id: String) async -> RoomLifecycle? {
        await localStore.room(id: id)
    }

    /// Creates a new room with the full lifecycle flow.
    func createRoom(
        participants: [ParticipantSpec],
        tier: PaymentTier,
        originatorNickname: String
    ) async throws -> RoomLifecycle {
        guard let container = container, let syncCoordinator = syncCoordinator, let zoneID = zoneID else {
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

        // Create coordinator
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

        // Save room record via SyncCoordinator
        let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
        await syncCoordinator.save(roomRecord)

        // Save participant records
        for (index, resolved) in resolvedParticipants.enumerated() {
            let participantRecord = RoomLifecycleRecordConverter.record(
                from: resolved.spec,
                roomID: lifecycle.spec.id,
                userRecordID: resolved.userRecordID,
                hasSignaledHere: true,  // Auto-signaled for now
                orderIndex: index,
                zoneID: zoneID
            )
            await syncCoordinator.save(participantRecord)

            // Also cache in LocalStore
            let stored = LocalStore.StoredParticipant(
                spec: resolved.spec,
                orderIndex: index,
                hasSignaledHere: true
            )
            await localStore.upsertParticipant(stored, roomID: lifecycle.spec.id)
        }

        // Update local store immediately
        await localStore.upsertRoom(lifecycle)
        rooms = await localStore.allRooms

        // Save opening narration
        let originatorName = spec.participants.first { $0.id == spec.originatorID }?.nickname ?? "Someone"
        let narrationText: String
        if spec.isFirstRoom {
            narrationText = "\(originatorName) opened their first room."
        } else {
            narrationText = "\(originatorName) opened the room with \(spec.tier.displayString)."
        }

        let openingMessage = Message(
            roomID: lifecycle.spec.id,
            authorID: "narrator",
            authorName: "Narrator",
            text: narrationText,
            isLightward: false,
            isNarration: true
        )

        // Add to local store immediately
        await localStore.addMessage(openingMessage)

        // Save message record via SyncCoordinator
        let messageRecord = MessageRecordConverter.record(from: openingMessage, zoneID: zoneID)
        await syncCoordinator.save(messageRecord)

        // Push all changes to CloudKit
        await syncCoordinator.sendChanges()

        return lifecycle
    }

    /// Updates a room's state.
    func updateRoom(_ lifecycle: RoomLifecycle) async throws {
        guard let syncCoordinator = syncCoordinator, let zoneID = zoneID else {
            throw StoreError.notConfigured
        }

        // Update local store immediately
        await localStore.upsertRoom(lifecycle)
        rooms = await localStore.allRooms

        // Save room record via SyncCoordinator
        let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
        await syncCoordinator.save(roomRecord)
        await syncCoordinator.sendChanges()
    }

    /// Deletes a room and all its associated data.
    func deleteRoom(id: String) async throws {
        guard let syncCoordinator = syncCoordinator, let zoneID = zoneID else {
            throw StoreError.notConfigured
        }

        // Get participants and messages to delete
        let storedParticipants = await localStore.participantsForRoom(id) ?? []
        let messages = await localStore.messages(roomID: id)

        // Update local store immediately
        await localStore.deleteRoom(id: id)
        await localStore.clearParticipants(roomID: id)
        rooms = await localStore.allRooms

        // Delete room record
        let roomRecordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        await syncCoordinator.delete(recordID: roomRecordID)

        // Delete participant records
        for participant in storedParticipants {
            let participantRecordID = CKRecord.ID(recordName: participant.spec.id, zoneID: zoneID)
            await syncCoordinator.delete(recordID: participantRecordID)
        }

        // Delete message records
        for message in messages {
            let messageRecordID = CKRecord.ID(recordName: message.id, zoneID: zoneID)
            await syncCoordinator.delete(recordID: messageRecordID)
        }

        await syncCoordinator.sendChanges()
    }

    // MARK: - Public API: Messages

    /// Gets messages for a room from local store.
    /// Call refreshRooms() first if you need latest from CloudKit.
    func messages(roomID: String) async -> [Message] {
        await localStore.messages(roomID: roomID)
    }

    /// Observes messages for a room via LocalStore.
    /// Returns current messages immediately and a stream for updates.
    func observeMessages(roomID: String) async -> (initial: [Message], stream: AsyncStream<[Message]>) {
        await localStore.observeMessages(roomID: roomID)
    }

    /// Saves a message to storage.
    func saveMessage(_ message: Message) async throws {
        guard let syncCoordinator = syncCoordinator, let zoneID = zoneID else {
            throw StoreError.notConfigured
        }

        // Add to local store immediately
        await localStore.addMessage(message)

        // Save via SyncCoordinator
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
        guard let syncCoordinator = syncCoordinator, let zoneID = zoneID else { return nil }
        guard lifecycle.isActive, let turnState = lifecycle.turnState else { return nil }

        // Wrap onTurnChange to also persist and update local store
        let wrappedOnTurnChange: @Sendable (TurnState) -> Void = { [weak self] newTurnState in
            onTurnChange(newTurnState)

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let updatedLifecycle = lifecycle.withTurnState(newTurnState)
                await self.localStore.upsertRoom(updatedLifecycle)
                self.rooms = await self.localStore.allRooms

                // Persist to CloudKit via SyncCoordinator
                guard let syncCoordinator = self.syncCoordinator, let zoneID = self.zoneID else { return }
                let roomRecord = RoomLifecycleRecordConverter.record(from: updatedLifecycle, zoneID: zoneID)
                await syncCoordinator.save(roomRecord)
                await syncCoordinator.sendChanges()
            }
        }

        // Create message storage backed by SyncCoordinator
        let syncBackedStorage = SyncBackedMessageStorage(
            localStore: localStore,
            syncCoordinator: syncCoordinator,
            zoneID: zoneID
        )

        return ConversationCoordinator(
            roomID: lifecycle.spec.id,
            spec: lifecycle.spec,
            initialTurnState: turnState,
            messageStorage: syncBackedStorage,
            apiClient: apiClient,
            onTurnChange: wrappedOnTurnChange,
            onStreamingText: onStreamingText
        )
    }
}

// MARK: - SyncCoordinator-Backed Message Storage

/// MessageStorage implementation that uses SyncCoordinator for persistence.
private final class SyncBackedMessageStorage: MessageStorage, @unchecked Sendable {
    private let localStore: LocalStore
    private let syncCoordinator: SyncCoordinator
    private let zoneID: CKRecordZone.ID

    init(localStore: LocalStore, syncCoordinator: SyncCoordinator, zoneID: CKRecordZone.ID) {
        self.localStore = localStore
        self.syncCoordinator = syncCoordinator
        self.zoneID = zoneID
    }

    func save(_ message: Message, roomID: String) async throws {
        // Update local store immediately
        await localStore.addMessage(message)

        // Save via SyncCoordinator
        let messageRecord = MessageRecordConverter.record(from: message, zoneID: zoneID)
        await syncCoordinator.save(messageRecord)
        await syncCoordinator.sendChanges()
    }

    func fetchMessages(roomID: String) async throws -> [Message] {
        // Return from local store (SyncCoordinator handles remote fetch)
        await localStore.messages(roomID: roomID)
    }

    func observeMessages(roomID: String, handler: @escaping @Sendable ([Message]) -> Void) async -> ObservationToken {
        // Observe via LocalStore
        let (initial, stream) = await localStore.observeMessages(roomID: roomID)

        // Call handler with initial value
        handler(initial)

        // Set up stream observation
        let task = Task {
            for await messages in stream {
                handler(messages)
            }
        }

        return TaskObservationToken(task: task)
    }
}

/// ObservationToken backed by a Task.
private final class TaskObservationToken: ObservationToken, @unchecked Sendable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
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
