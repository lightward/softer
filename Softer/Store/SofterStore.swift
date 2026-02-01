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
    private var storage: RoomLifecycleStorage?
    private var messageStorage: CloudKitMessageStorage?
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
        storage: RoomLifecycleStorage?,
        messageStorage: CloudKitMessageStorage?,
        zoneID: CKRecordZone.ID?
    ) {
        self.apiClient = apiClient
        self.container = container
        self.storage = storage
        self.messageStorage = messageStorage
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

            // Use default zone for simplicity
            let zoneID = CKRecordZone.default().zoneID
            self.zoneID = zoneID

            // Create storage
            self.storage = RoomLifecycleStorage(
                database: ckContainer.privateCloudDatabase,
                zoneID: zoneID
            )
            self.messageStorage = CloudKitMessageStorage(
                database: ckContainer.privateCloudDatabase,
                zoneID: zoneID
            )

            syncStatus = .synced
            await loadRooms()

        } catch {
            syncStatus = .error("Softer requires iCloud. Sign in via Settings to begin.")
        }
    }

    // MARK: - Public API: Rooms

    /// Loads all rooms from CloudKit into the local store.
    func loadRooms() async {
        guard let storage = storage else { return }

        syncStatus = .syncing
        do {
            let allRooms = try await storage.fetchAllRooms()
            await localStore.upsertRooms(allRooms)

            // Update published state
            let filtered = allRooms.filter { !$0.isDefunct }
            rooms = filtered.sorted { $0.spec.createdAt < $1.spec.createdAt }
            syncStatus = .synced
        } catch {
            print("Failed to load rooms: \(error)")
            syncStatus = .error("Failed to load rooms")
        }
        initialLoadCompleted = true
    }

    /// Gets a room by ID. First checks local cache, then CloudKit.
    func room(id: String) async throws -> RoomLifecycle? {
        // Check local cache first
        if let cached = await localStore.room(id: id) {
            return cached
        }

        // Fall back to CloudKit
        guard let storage = storage else {
            throw StoreError.notConfigured
        }
        let fetched = try await storage.fetchRoom(id: id)
        if let fetched = fetched {
            await localStore.upsertRoom(fetched)
        }
        return fetched
    }

    /// Creates a new room with the full lifecycle flow.
    func createRoom(
        participants: [ParticipantSpec],
        tier: PaymentTier,
        originatorNickname: String
    ) async throws -> RoomLifecycle {
        guard let container = container, let storage = storage else {
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

        // Save to CloudKit
        let lifecycle = await coordinator.lifecycle
        let resolvedParticipants = await coordinator.resolvedParticipants
        try await storage.saveRoom(lifecycle: lifecycle, resolvedParticipants: resolvedParticipants)

        // Update local store immediately
        await localStore.upsertRoom(lifecycle)
        rooms = await localStore.allRooms

        return lifecycle
    }

    /// Updates a room's state.
    func updateRoom(_ lifecycle: RoomLifecycle) async throws {
        guard let storage = storage else {
            throw StoreError.notConfigured
        }

        // Update local store immediately
        await localStore.upsertRoom(lifecycle)
        rooms = await localStore.allRooms

        // Persist to CloudKit
        try await storage.updateRoomState(lifecycle)
    }

    /// Deletes a room and all its associated data.
    func deleteRoom(id: String) async throws {
        guard let storage = storage else {
            throw StoreError.notConfigured
        }

        // Update local store immediately
        await localStore.deleteRoom(id: id)
        rooms = await localStore.allRooms

        // Delete from CloudKit
        try await storage.deleteRoom(id: id)
    }

    // MARK: - Public API: Messages

    /// Fetches messages for a room.
    func fetchMessages(roomID: String) async throws -> [Message] {
        guard let messageStorage = messageStorage else {
            throw StoreError.notConfigured
        }
        let messages = try await messageStorage.fetchMessages(roomID: roomID)
        await localStore.setMessages(messages, roomID: roomID)
        return messages
    }

    /// Observes messages for a room.
    /// Returns current messages immediately and a stream for updates.
    func observeMessages(roomID: String) async -> (initial: [Message], token: ObservationToken) {
        guard let messageStorage = messageStorage else {
            return ([], NoOpObservationToken())
        }

        let token = await messageStorage.observeMessages(roomID: roomID) { [weak self] messages in
            Task { @MainActor [weak self] in
                await self?.localStore.setMessages(messages, roomID: roomID)
            }
        }

        let initial = await localStore.messages(roomID: roomID)
        return (initial, token)
    }

    /// Saves a message to storage.
    func saveMessage(_ message: Message) async throws {
        guard let messageStorage = messageStorage else {
            throw StoreError.notConfigured
        }

        // Add to local store immediately
        await localStore.addMessage(message)

        // Persist to CloudKit
        try await messageStorage.save(message, roomID: message.roomID)
    }

    // MARK: - Public API: Conversation Coordinator

    /// Creates a ConversationCoordinator for an active room.
    func conversationCoordinator(
        for lifecycle: RoomLifecycle,
        onTurnChange: @escaping @Sendable (TurnState) -> Void = { _ in },
        onStreamingText: @escaping @Sendable (String) -> Void = { _ in }
    ) -> ConversationCoordinator? {
        guard let messageStorage = messageStorage else { return nil }
        guard let storage = storage else { return nil }
        guard lifecycle.isActive, let turnState = lifecycle.turnState else { return nil }

        // Wrap onTurnChange to also persist and update local store
        let wrappedOnTurnChange: @Sendable (TurnState) -> Void = { [weak self] newTurnState in
            onTurnChange(newTurnState)

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let updatedLifecycle = lifecycle.withTurnState(newTurnState)
                await self.localStore.upsertRoom(updatedLifecycle)
                self.rooms = await self.localStore.allRooms

                // Persist to CloudKit
                do {
                    try await storage.updateRoomState(updatedLifecycle)
                } catch {
                    print("Failed to persist turn state: \(error)")
                }
            }
        }

        return ConversationCoordinator(
            roomID: lifecycle.spec.id,
            spec: lifecycle.spec,
            initialTurnState: turnState,
            messageStorage: messageStorage,
            apiClient: apiClient,
            onTurnChange: wrappedOnTurnChange,
            onStreamingText: onStreamingText
        )
    }

    /// Returns the message storage (for backward compatibility during migration).
    func getMessageStorage() -> CloudKitMessageStorage? {
        messageStorage
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

// MARK: - No-op Token

private final class NoOpObservationToken: ObservationToken, @unchecked Sendable {
    func cancel() {}
}
