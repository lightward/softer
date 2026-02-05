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

            // Fetch pending invitations from public database
            await fetchInvitations()

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
            // Room3 with embedded participants and messages
            if let lifecycle = RoomLifecycleRecordConverter.lifecycle(from: record) {
                let messagesJSON = record["messagesJSON"] as? String
                dataStore.upsertRoom(from: lifecycle, remoteMessagesJSON: messagesJSON)
                print("SofterStore: Room \(record.recordID.recordName) synced from CloudKit")
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

    // MARK: - Share Acceptance

    /// Accept a share from a ckshare:// URL.
    /// Returns the room ID for navigation, or nil if acceptance failed.
    func acceptShare(url: URL) async throws -> String? {
        guard let syncCoordinator = syncCoordinator else {
            throw StoreError.notConfigured
        }
        return try await syncCoordinator.acceptShare(from: url)
    }

    // MARK: - Invitations

    /// Pending invitations from other users (fetched from public database).
    private(set) var pendingInvitations: [Invitation] = []

    /// Fetch pending invitations for the current user.
    func fetchInvitations() async {
        guard let syncCoordinator = syncCoordinator else { return }
        do {
            let invitations = try await syncCoordinator.fetchInvitations()
            await MainActor.run {
                self.pendingInvitations = invitations
            }
        } catch {
            print("SofterStore: Failed to fetch invitations: \(error)")
        }
    }

    /// Accept an invitation and navigate to the room.
    func acceptInvitation(_ invitation: Invitation) async throws -> String? {
        guard let syncCoordinator = syncCoordinator else {
            throw StoreError.notConfigured
        }

        let roomID = try await syncCoordinator.acceptShareFromInvitation(invitation)

        // Remove from local list
        await MainActor.run {
            pendingInvitations.removeAll { $0.id == invitation.id }
        }

        // Refresh to get the shared room
        await refreshRooms()

        return roomID
    }

    /// Signal "here" for a participant in a room.
    /// Used when accepting a shared room invitation.
    func signalHere(roomID: String, participantID: String) async throws {
        guard let syncCoordinator = syncCoordinator,
              let zoneID = zoneID,
              let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        // Update local state
        dataStore.signalHere(roomID: roomID, participantID: participantID)

        // Sync to CloudKit
        if let room = dataStore.room(id: roomID),
           let lifecycle = room.toRoomLifecycle() {
            let messages = room.messages()

            // Check if this is a shared room (we're not the originator)
            let isSharedWithUs = !isRoomOwner(room)

            if isSharedWithUs {
                // For shared rooms, we need to fetch the existing record and modify it
                // Use the owner's zone (from the room's originatorID or stored zone info)
                // For now, try to save directly to shared database
                print("SofterStore: Saving signal to shared database")
                do {
                    // Fetch the existing record from shared database
                    let recordID = CKRecord.ID(recordName: roomID)
                    let existingRecord = try await syncCoordinator.fetchRecordFromSharedDatabase(recordID: recordID)
                    RoomLifecycleRecordConverter.apply(lifecycle, to: existingRecord, messages: messages)
                    try await syncCoordinator.saveToSharedDatabase(existingRecord)
                } catch {
                    print("SofterStore: Failed to save signal to shared database: \(error)")
                    throw error
                }
            } else {
                // For our own rooms, use the normal sync flow
                let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
                RoomLifecycleRecordConverter.apply(lifecycle, to: roomRecord, messages: messages)
                await syncCoordinator.save(roomRecord)
                await syncCoordinator.sendChanges()
            }
        }
    }

    /// Check if we own a room (we're the originator).
    private func isRoomOwner(_ room: PersistedRoom) -> Bool {
        guard let localUserRecordID = localUserRecordID else { return false }
        let embedded = room.embeddedParticipants()
        // Check if we're the currentUser participant (originator)
        if embedded.first(where: { $0.identifierType == "currentUser" && $0.userRecordID == localUserRecordID }) != nil {
            return true
        }
        // Also check if first human participant is us
        if let first = embedded.first(where: { $0.identifierType == "currentUser" }) {
            return first.userRecordID == localUserRecordID || first.userRecordID == nil
        }
        return false
    }

    /// Claim participant identity in a shared room.
    /// Matches by email and sets the participant's userRecordID to our local ID.
    /// This is called after accepting a share to establish identity.
    func claimParticipantIdentity(roomID: String) async {
        guard let localUserRecordID = localUserRecordID,
              let dataStore = dataStore,
              let room = dataStore.room(id: roomID) else {
            print("SofterStore: Cannot claim identity - missing prerequisites")
            return
        }

        // Get stored email (from CloudKit discoverability or workaround)
        guard let myEmail = UserDefaults.standard.string(forKey: "SofterUserEmail")?.lowercased() else {
            print("SofterStore: Cannot claim identity - no stored email")
            return
        }

        // Find and update matching participant
        var embedded = room.embeddedParticipants()
        var updated = false

        for i in embedded.indices {
            if embedded[i].identifierType == "email",
               embedded[i].identifierValue?.lowercased() == myEmail,
               embedded[i].userRecordID == nil {
                embedded[i] = embedded[i].withUserRecordID(localUserRecordID)
                updated = true
                print("SofterStore: Claimed identity for participant \(embedded[i].id) with userRecordID \(localUserRecordID)")
                break
            }
        }

        if updated {
            room.setParticipants(embedded)
            dataStore.updateRoom(room)

            // Sync to CloudKit
            if let syncCoordinator = syncCoordinator, let zoneID = zoneID {
                if let lifecycle = room.toRoomLifecycle() {
                    let messages = room.messages()
                    let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
                    RoomLifecycleRecordConverter.apply(lifecycle, to: roomRecord, messages: messages)
                    await syncCoordinator.save(roomRecord)
                    await syncCoordinator.sendChanges()
                }
            }
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
        persistedRoom.addMessage(openingMessage)
        dataStore.saveRoom(persistedRoom)

        // Sync to CloudKit in background
        Task {
            // Save single Room3 record (participants and messages embedded)
            let messages = persistedRoom.messages()
            let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
            RoomLifecycleRecordConverter.apply(
                lifecycle,
                to: roomRecord,
                messages: messages,
                resolvedParticipants: resolvedParticipants
            )
            await syncCoordinator.save(roomRecord)
            await syncCoordinator.sendChanges()

            // Share with other human participants (by email/phone, not userRecordID)
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

                        // Create invitations in public database for in-app discovery
                        // Use the email addresses from participant specs (what was used to invite them)
                        let otherParticipantEmails = spec.participants
                            .filter { $0.id != spec.originatorID && !$0.isLightward }
                            .compactMap { participant -> String? in
                                if case .email(let email) = participant.identifier {
                                    return email
                                }
                                return nil
                            }

                        if !otherParticipantEmails.isEmpty, let fromUserRecordID = localUserRecordID {
                            let senderName = spec.participants.first { $0.id == spec.originatorID }?.nickname ?? "Someone"
                            do {
                                try await syncCoordinator.createInvitations(
                                    for: otherParticipantEmails,
                                    shareURL: shareURL,
                                    roomID: lifecycle.spec.id,
                                    senderName: senderName,
                                    fromUserRecordID: fromUserRecordID
                                )
                                print("SofterStore: Created invitations for \(otherParticipantEmails.count) participant(s)")
                            } catch {
                                print("SofterStore: Failed to create invitations: \(error)")
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
            guard let syncCoordinator = syncCoordinator, let zoneID = zoneID else { return }
            if let room = dataStore.room(id: roomID),
               let lifecycle = room.toRoomLifecycle() {
                let messages = room.messages()
                let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
                RoomLifecycleRecordConverter.apply(lifecycle, to: roomRecord, messages: messages)
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

        let room = dataStore.room(id: lifecycle.spec.id)
        if let room = room {
            room.apply(lifecycle, mergeStrategy: .remoteWins)
            dataStore.updateRoom(room)
        }

        let messages = room?.messages() ?? []
        let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
        RoomLifecycleRecordConverter.apply(lifecycle, to: roomRecord, messages: messages)
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

        // Delete from local DB
        dataStore.deleteRoom(id: id)

        // Delete from CloudKit (single Room3 record - messages are embedded)
        let roomRecordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        await syncCoordinator.delete(recordID: roomRecordID)
        await syncCoordinator.sendChanges()
    }

    // MARK: - Public API: Messages

    func messages(roomID: String) -> [Message] {
        dataStore?.messages(roomID: roomID) ?? []
    }

    func saveMessage(_ message: Message) async throws {
        guard let syncCoordinator = syncCoordinator,
              let zoneID = zoneID,
              let dataStore = dataStore else {
            throw StoreError.notConfigured
        }

        guard let room = dataStore.room(id: message.roomID) else {
            throw StoreError.notConfigured
        }

        // Add message to room's embedded messages
        dataStore.addMessage(message, to: room)

        // Sync room record to CloudKit (messages are embedded)
        if let lifecycle = room.toRoomLifecycle() {
            let messages = room.messages()
            let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
            RoomLifecycleRecordConverter.apply(lifecycle, to: roomRecord, messages: messages)
            await syncCoordinator.save(roomRecord)
            await syncCoordinator.sendChanges()
        }
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
        guard let room = dataStore.room(id: roomID) else { return }

        // Add message to room's embedded messages
        dataStore.addMessage(message, to: room)

        // Sync room record to CloudKit (messages are embedded)
        if let syncCoordinator = syncCoordinator, let zoneID = zoneID {
            if let lifecycle = room.toRoomLifecycle() {
                let messages = room.messages()
                let roomRecord = RoomLifecycleRecordConverter.record(from: lifecycle, zoneID: zoneID)
                RoomLifecycleRecordConverter.apply(lifecycle, to: roomRecord, messages: messages)
                await syncCoordinator.save(roomRecord)
                await syncCoordinator.sendChanges()
            }
        }
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
