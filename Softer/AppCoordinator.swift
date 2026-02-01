import Foundation
import CloudKit
import SwiftUI

/// Central coordinator for app state and CloudKit setup.
@Observable
final class AppCoordinator {
    enum Status {
        case loading
        case available
        case unavailable(String)
    }

    private(set) var status: Status = .loading
    private(set) var rooms: [RoomLifecycle] = []
    private(set) var localUserRecordID: String?

    private var container: CKContainer?
    private var storage: RoomLifecycleStorage?
    private var messageStorage: CloudKitMessageStorage?
    private var zoneID: CKRecordZone.ID?
    private let apiClient: any LightwardAPI = LightwardAPIClient()

    init() {
        Task {
            await setup()
        }
    }

    private func setup() async {
        do {
            let ckContainer = CKContainer(identifier: Constants.containerIdentifier)

            let accountStatus = try await ckContainer.accountStatus()
            guard accountStatus == .available else {
                status = .unavailable("Softer requires iCloud. Sign in via Settings to begin.")
                return
            }

            self.container = ckContainer

            // Get user ID
            let userID = try await ckContainer.userRecordID()
            localUserRecordID = userID.recordName

            // Ensure zone exists
            let zoneManager = ZoneManager(container: ckContainer)
            let zoneID = try await zoneManager.ensureZoneExists(
                named: Constants.ZoneName.rooms,
                in: ckContainer.privateCloudDatabase
            )
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

            status = .available
            await loadRooms()

        } catch {
            status = .unavailable("Softer requires iCloud. Sign in via Settings to begin.")
        }
    }

    func loadRooms() async {
        guard let storage = storage else { return }

        do {
            let allRooms = try await storage.fetchAllRooms()
            // Show active and pending rooms, not defunct
            rooms = allRooms.filter { !$0.isDefunct }
        } catch {
            print("Failed to load rooms: \(error)")
        }
    }

    /// Creates a room with the full lifecycle flow.
    func createRoom(
        participants: [ParticipantSpec],
        tier: PaymentTier,
        originatorNickname: String
    ) async throws -> RoomLifecycle {
        guard let container = container, let storage = storage else {
            throw AppError.notConfigured
        }

        // Find or create originator spec
        let originatorSpec = participants.first { !$0.isLightward } ?? ParticipantSpec(
            identifier: .email(""),  // Will be resolved from local user
            nickname: originatorNickname
        )

        // Check if this is user's first room
        let existingRooms = try await storage.fetchAllRooms()
        let isFirstRoom = existingRooms.filter { $0.isActive || $0.isLocked }.isEmpty

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

        // Refresh list
        await loadRooms()

        return lifecycle
    }

    /// Updates room state after a turn event.
    func updateRoom(_ lifecycle: RoomLifecycle) async throws {
        guard let storage = storage else {
            throw AppError.notConfigured
        }
        try await storage.updateRoomState(lifecycle)
        await loadRooms()
    }

    /// Marks a participant as present.
    func signalHere(roomID: String, participantID: String) async throws {
        guard let storage = storage else {
            throw AppError.notConfigured
        }
        try await storage.markParticipantSignaled(participantID: participantID)
        await loadRooms()
    }

    /// Fetches a specific room by ID.
    func room(id: String) async throws -> RoomLifecycle? {
        guard let storage = storage else {
            throw AppError.notConfigured
        }
        return try await storage.fetchRoom(id: id)
    }

    /// Creates a ConversationCoordinator for an active room.
    /// The coordinator handles message sending, turn management, and Lightward responses.
    func conversationCoordinator(
        for lifecycle: RoomLifecycle,
        onTurnChange: @escaping @Sendable (TurnState) -> Void = { _ in },
        onStreamingText: @escaping @Sendable (String) -> Void = { _ in }
    ) -> ConversationCoordinator? {
        guard let messageStorage = messageStorage else { return nil }
        guard lifecycle.isActive, let turnState = lifecycle.turnState else { return nil }

        return ConversationCoordinator(
            roomID: lifecycle.spec.id,
            spec: lifecycle.spec,
            initialTurnState: turnState,
            messageStorage: messageStorage,
            apiClient: apiClient,
            onTurnChange: onTurnChange,
            onStreamingText: onStreamingText
        )
    }

    /// Returns the message storage for observing messages.
    func getMessageStorage() -> CloudKitMessageStorage? {
        messageStorage
    }
}

enum AppError: Error, LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "App not fully configured. Please try again."
        }
    }
}
