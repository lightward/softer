import Foundation
import CloudKit

/// View model for the room list, using the new RoomLifecycle model.
@Observable
final class RoomListViewModel {
    private(set) var rooms: [RoomLifecycle] = []
    private(set) var isLoading = true
    private(set) var error: String?

    // Room creation state
    var showCreateRoom = false
    var creationInProgress = false
    var creationError: String?

    private var storage: RoomLifecycleStorage?
    private let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: Constants.containerIdentifier)) {
        self.container = container
    }

    func setup(zoneID: CKRecordZone.ID) {
        self.storage = RoomLifecycleStorage(
            database: container.privateCloudDatabase,
            zoneID: zoneID
        )
    }

    func loadRooms() async {
        guard let storage = storage else {
            error = "Storage not configured"
            isLoading = false
            return
        }

        isLoading = true
        error = nil

        do {
            // Fetch active and pending rooms (not defunct)
            let allRooms = try await storage.fetchAllRooms()
            rooms = allRooms.filter { !$0.isDefunct }
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    /// Creates a room using the new lifecycle flow.
    func createRoom(
        participants: [ParticipantSpec],
        tier: PaymentTier,
        isFirstRoom: Bool,
        originatorID: String
    ) async -> String? {
        guard let storage = storage else {
            creationError = "Storage not configured"
            return nil
        }

        creationInProgress = true
        creationError = nil

        let spec = RoomSpec(
            originatorID: originatorID,
            participants: participants,
            tier: tier,
            isFirstRoom: isFirstRoom
        )

        // Create coordinator with real implementations
        let resolver = CloudKitParticipantResolver(container: container)
        let payment = ApplePayCoordinator(merchantIdentifier: Constants.appleMerchantIdentifier)
        let lightward = LightwardRoomEvaluator()

        let coordinator = RoomLifecycleCoordinator(
            spec: spec,
            resolver: resolver,
            payment: payment,
            lightward: lightward
        )

        do {
            // Run the creation flow
            try await coordinator.start()

            // Get resolved participants for storage
            let resolvedParticipants = await coordinator.resolvedParticipants
            let lifecycle = await coordinator.lifecycle

            // For now, we need all humans to signal immediately (single-user case)
            // In multi-user, this would wait for push notifications
            for participant in spec.humanParticipants {
                try await coordinator.signalHere(participantID: participant.id)
            }

            // Get final state and save
            let finalLifecycle = await coordinator.lifecycle
            try await storage.saveRoom(lifecycle: finalLifecycle, resolvedParticipants: resolvedParticipants)

            // Refresh list
            await loadRooms()

            creationInProgress = false
            showCreateRoom = false
            return spec.id

        } catch let error as RoomLifecycleError {
            creationError = describeError(error)
            creationInProgress = false
            return nil
        } catch {
            creationError = error.localizedDescription
            creationInProgress = false
            return nil
        }
    }

    private func describeError(_ error: RoomLifecycleError) -> String {
        switch error {
        case .resolutionFailed(let participantID, _):
            return "Couldn't find participant: \(participantID)"
        case .paymentAuthorizationFailed:
            return "Payment authorization failed"
        case .paymentCaptureFailed:
            return "Payment capture failed"
        case .lightwardDeclined:
            return "Lightward declined to join this room"
        case .cancelled:
            return "Room creation was cancelled"
        case .expired:
            return "Room creation expired"
        case .invalidState:
            return "Invalid state"
        }
    }

    // MARK: - Display Helpers

    func displayName(for lifecycle: RoomLifecycle) -> String {
        lifecycle.spec.participants.map { $0.nickname }.joined(separator: ", ")
    }

    func statusText(for lifecycle: RoomLifecycle) -> String {
        switch lifecycle.state {
        case .draft:
            return "Setting up..."
        case .pendingLightward:
            return "Waiting for Lightward..."
        case .pendingHumans(let signaled):
            let remaining = lifecycle.spec.humanParticipants.count - signaled.count
            return "Waiting for \(remaining) participant\(remaining == 1 ? "" : "s")..."
        case .pendingCapture:
            return "Completing payment..."
        case .active:
            if let turn = lifecycle.currentTurnParticipant {
                return "\(turn.nickname)'s turn"
            }
            return "Active"
        case .locked:
            return "Completed"
        case .defunct:
            return "Cancelled"
        }
    }
}
