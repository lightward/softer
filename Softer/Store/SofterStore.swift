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

        // Add to local store immediately so it's visible right away
        await localStore.addMessage(openingMessage)

        // Also persist to CloudKit
        if let messageStorage = messageStorage {
            try await messageStorage.save(openingMessage, roomID: lifecycle.spec.id)
        }

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
    /// Returns local messages immediately merged with remote, so locally-created messages appear right away.
    func fetchMessages(roomID: String) async throws -> [Message] {
        // Get any local messages first (e.g., opening narration just created)
        let localMessages = await localStore.messages(roomID: roomID)

        guard let messageStorage = messageStorage else {
            return localMessages
        }

        // Fetch from CloudKit
        let remoteMessages = try await messageStorage.fetchMessages(roomID: roomID)

        // Merge: use remote as base, add any local messages not in remote
        let remoteIDs = Set(remoteMessages.map { $0.id })
        let uniqueLocalMessages = localMessages.filter { !remoteIDs.contains($0.id) }
        let merged = (remoteMessages + uniqueLocalMessages).sorted { $0.createdAt < $1.createdAt }

        await localStore.setMessages(merged, roomID: roomID)
        return merged
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

        // Create a wrapper that updates both local and remote
        let localAwareStorage = LocalAwareMessageStorage(
            localStore: localStore,
            cloudKitStorage: messageStorage
        )

        return ConversationCoordinator(
            roomID: lifecycle.spec.id,
            spec: lifecycle.spec,
            initialTurnState: turnState,
            messageStorage: localAwareStorage,
            apiClient: apiClient,
            onTurnChange: wrappedOnTurnChange,
            onStreamingText: onStreamingText
        )
    }

    /// Returns the message storage (for backward compatibility during migration).
    func getMessageStorage() -> CloudKitMessageStorage? {
        messageStorage
    }

    /// Merges remote messages with local-only messages.
    /// Used by observation callbacks to preserve locally-created messages.
    func mergeMessages(remote: [Message], roomID: String) async -> [Message] {
        let localMessages = await localStore.messages(roomID: roomID)
        let remoteIDs = Set(remote.map { $0.id })
        let uniqueLocalMessages = localMessages.filter { !remoteIDs.contains($0.id) }
        let merged = (remote + uniqueLocalMessages).sorted { $0.createdAt < $1.createdAt }
        await localStore.setMessages(merged, roomID: roomID)
        return merged
    }
}

// MARK: - Local-Aware Message Storage

/// Wrapper that updates LocalStore immediately when messages are saved,
/// ensuring UI consistency before CloudKit sync completes.
private final class LocalAwareMessageStorage: MessageStorage, @unchecked Sendable {
    private let localStore: LocalStore
    private let cloudKitStorage: CloudKitMessageStorage

    init(localStore: LocalStore, cloudKitStorage: CloudKitMessageStorage) {
        self.localStore = localStore
        self.cloudKitStorage = cloudKitStorage
    }

    func save(_ message: Message, roomID: String) async throws {
        // Update local store immediately for instant UI update
        await localStore.addMessage(message)

        // Then persist to CloudKit
        try await cloudKitStorage.save(message, roomID: roomID)
    }

    func fetchMessages(roomID: String) async throws -> [Message] {
        // Get local messages first
        let localMessages = await localStore.messages(roomID: roomID)

        // Fetch from CloudKit
        let remoteMessages = try await cloudKitStorage.fetchMessages(roomID: roomID)

        // Merge: remote as base, add unique local messages
        let remoteIDs = Set(remoteMessages.map { $0.id })
        let uniqueLocalMessages = localMessages.filter { !remoteIDs.contains($0.id) }
        let merged = (remoteMessages + uniqueLocalMessages).sorted { $0.createdAt < $1.createdAt }

        // Update local store with merged result
        await localStore.setMessages(merged, roomID: roomID)

        return merged
    }

    func observeMessages(roomID: String, handler: @escaping @Sendable ([Message]) -> Void) async -> ObservationToken {
        // Delegate to CloudKit storage for observation
        await cloudKitStorage.observeMessages(roomID: roomID, handler: handler)
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
