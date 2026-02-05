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

    // MARK: - State Transition Helpers

    /// Check if a room needs an automatic state transition.
    /// e.g., pendingHumans with all humans signaled → active.
    private func checkAndTransitionRoom(_ room: PersistedRoom) {
        guard var lifecycle = room.toRoomLifecycle() else { return }

        if case .pendingHumans(let alreadySignaled) = lifecycle.state {
            let allHumans = Set(lifecycle.spec.humanParticipants.map { $0.id })
            let signaled = room.embeddedParticipants().filter { $0.hasSignaledHere }
            print("checkAndTransitionRoom: state=pendingHumans alreadySignaled=\(alreadySignaled) embeddedSignaled=\(signaled.map { $0.id }) allHumans=\(allHumans)")

            for participant in signaled {
                let effects = lifecycle.apply(event: .humanSignaledHere(participantID: participant.id))
                print("checkAndTransitionRoom: applied humanSignaledHere(\(participant.id)) effects=\(effects) newState=\(lifecycle.state)")
                if effects.contains(.capturePayment) {
                    _ = lifecycle.apply(event: .paymentCaptured)
                    print("checkAndTransitionRoom: transitioned to active!")
                    break
                }
            }

            room.apply(lifecycle, mergeStrategy: .remoteWins)
            print("checkAndTransitionRoom: final stateType=\(room.stateType)")
        } else {
            print("checkAndTransitionRoom: room \(room.id) state=\(room.stateType), not pendingHumans — skipping")
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

        // Route to correct engine
        if room.isSharedWithMe {
            print("SofterStore: Saving room \(room.id) to shared database")
            await syncCoordinator.saveShared(record)
        } else {
            print("SofterStore: Saving room \(room.id) to private database")
            await syncCoordinator.save(record)
        }

        await syncCoordinator.sendChanges()
    }

    // MARK: - Public API: Rooms

    /// Refreshes rooms from CloudKit via SyncCoordinator.
    func refreshRooms() async {
        guard let syncCoordinator = syncCoordinator else { return }
        await syncCoordinator.fetchChanges()
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
            let effects = lifecycle.apply(event: .humanSignaledHere(participantID: participantID))

            // If state machine says capture payment, skip to active for now (payment not wired yet)
            if effects.contains(.capturePayment) {
                _ = lifecycle.apply(event: .paymentCaptured)
            }

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

        // Auto-signal only for the originator (they're already present)
        // Other humans will signal when they accept the share and open the room
        try await coordinator.signalHere(participantID: spec.originatorID)

        let lifecycle = await coordinator.lifecycle
        let resolvedParticipants = await coordinator.resolvedParticipants

        // Create opening narration message
        let originatorName = spec.participants.first { $0.id == spec.originatorID }?.nickname ?? "Someone"
        let narrationText = spec.isFirstRoom
            ? "\(originatorName) opened their first room. It's free."
            : "\(originatorName) opened the room at \(spec.tier.displayString)."

        let openingMessage = Message(
            roomID: lifecycle.spec.id,
            authorID: "narrator",
            authorName: "Narrator",
            text: narrationText,
            isLightward: false,
            isNarration: true
        )

        // Save to local DB (participants and messages embedded in room)
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

        // Sync to CloudKit in background
        Task {
            await syncRoomToCloudKit(persistedRoom, resolvedParticipants: resolvedParticipants)

            // Share with other human participants (by email/phone, not userRecordID)
            // Need the CKRecord for sharing — reconstruct it
            let roomRecord = RoomLifecycleRecordConverter.record(
                fromSystemFields: persistedRoom.ckSystemFields,
                recordName: persistedRoom.id,
                fallbackZoneID: zoneID
            )
            let messages = persistedRoom.messages()
            RoomLifecycleRecordConverter.apply(
                lifecycle,
                to: roomRecord,
                messages: messages,
                resolvedParticipants: resolvedParticipants
            )

            let lookupInfos = RoomLifecycleRecordConverter.otherParticipantLookupInfos(from: roomRecord)
            if !lookupInfos.isEmpty {
                do {
                    let shareURL = try await syncCoordinator.shareRoom(roomRecord, withLookupInfos: lookupInfos)
                    print("SofterStore: Shared room with \(lookupInfos.count) other participants")

                    // Store the share URL locally
                    if let shareURL = shareURL {
                        await MainActor.run {
                            if let room = dataStore.room(id: lifecycle.spec.id) {
                                room.shareURL = shareURL.absoluteString
                                dataStore.updateRoom(room)
                            }
                        }
                    }
                } catch {
                    print("SofterStore: Failed to share room: \(error)")
                }
            }
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
            onStreamingText: onStreamingText
        )
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

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "App not fully configured. Please try again."
        }
    }
}
