import Foundation

/// Single source of truth for in-memory data.
/// Applies local writes immediately and receives remote changes from SyncCoordinator.
actor LocalStore {
    // MARK: - Data Storage

    private var rooms: [String: RoomLifecycle] = [:]
    private var messages: [String: [Message]] = [:]  // roomID -> messages

    // MARK: - Observation

    private var roomObservers: [UUID: @Sendable ([RoomLifecycle]) -> Void] = [:]
    private var messageObservers: [String: [UUID: @Sendable ([Message]) -> Void]] = [:]  // roomID -> observers

    // MARK: - Room Operations

    /// Get all rooms as an array, sorted by creation date.
    var allRooms: [RoomLifecycle] {
        rooms.values
            .filter { !$0.isDefunct }
            .sorted { $0.spec.createdAt < $1.spec.createdAt }
    }

    /// Get a specific room by ID.
    func room(id: String) -> RoomLifecycle? {
        rooms[id]
    }

    /// Insert or update a room. Applies merge logic for conflicts.
    func upsertRoom(_ lifecycle: RoomLifecycle) {
        let id = lifecycle.spec.id

        if let existing = rooms[id] {
            // Merge conflict resolution
            rooms[id] = mergeRooms(local: existing, remote: lifecycle)
        } else {
            rooms[id] = lifecycle
        }

        notifyRoomObservers()
    }

    /// Insert or update multiple rooms.
    func upsertRooms(_ lifecycles: [RoomLifecycle]) {
        for lifecycle in lifecycles {
            let id = lifecycle.spec.id
            if let existing = rooms[id] {
                rooms[id] = mergeRooms(local: existing, remote: lifecycle)
            } else {
                rooms[id] = lifecycle
            }
        }
        notifyRoomObservers()
    }

    /// Delete a room by ID.
    func deleteRoom(id: String) {
        rooms.removeValue(forKey: id)
        messages.removeValue(forKey: id)
        notifyRoomObservers()
        notifyMessageObservers(roomID: id, messages: [])
    }

    // MARK: - Message Operations

    /// Get all messages for a room, sorted by creation date.
    func messages(roomID: String) -> [Message] {
        (messages[roomID] ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    /// Add a message. Deduplicates by ID.
    func addMessage(_ message: Message) {
        let roomID = message.roomID
        var roomMessages = messages[roomID] ?? []

        // Deduplicate by ID
        if !roomMessages.contains(where: { $0.id == message.id }) {
            roomMessages.append(message)
            roomMessages.sort { $0.createdAt < $1.createdAt }
            messages[roomID] = roomMessages
            notifyMessageObservers(roomID: roomID, messages: roomMessages)
        }
    }

    /// Add multiple messages for a room. Deduplicates by ID.
    func addMessages(_ newMessages: [Message], roomID: String) {
        guard !newMessages.isEmpty else { return }

        var roomMessages = messages[roomID] ?? []
        let existingIDs = Set(roomMessages.map { $0.id })

        for message in newMessages {
            if !existingIDs.contains(message.id) {
                roomMessages.append(message)
            }
        }

        roomMessages.sort { $0.createdAt < $1.createdAt }
        messages[roomID] = roomMessages
        notifyMessageObservers(roomID: roomID, messages: roomMessages)
    }

    /// Replace all messages for a room (used for initial sync).
    func setMessages(_ newMessages: [Message], roomID: String) {
        let sorted = newMessages.sorted { $0.createdAt < $1.createdAt }
        messages[roomID] = sorted
        notifyMessageObservers(roomID: roomID, messages: sorted)
    }

    // MARK: - Room Observation

    /// Observe all rooms. Returns current rooms immediately, then on changes.
    func observeRooms() -> (initial: [RoomLifecycle], stream: AsyncStream<[RoomLifecycle]>) {
        let initial = allRooms

        let stream = AsyncStream<[RoomLifecycle]> { continuation in
            let id = UUID()

            self.roomObservers[id] = { rooms in
                continuation.yield(rooms)
            }

            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeRoomObserver(id: id)
                }
            }
        }

        return (initial, stream)
    }

    private func removeRoomObserver(id: UUID) {
        roomObservers.removeValue(forKey: id)
    }

    private func notifyRoomObservers() {
        let currentRooms = allRooms
        for observer in roomObservers.values {
            observer(currentRooms)
        }
    }

    // MARK: - Message Observation

    /// Observe messages for a specific room. Returns current messages immediately, then on changes.
    func observeMessages(roomID: String) -> (initial: [Message], stream: AsyncStream<[Message]>) {
        let initial = messages(roomID: roomID)

        let stream = AsyncStream<[Message]> { continuation in
            let id = UUID()

            if self.messageObservers[roomID] == nil {
                self.messageObservers[roomID] = [:]
            }
            self.messageObservers[roomID]?[id] = { messages in
                continuation.yield(messages)
            }

            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeMessageObserver(id: id, roomID: roomID)
                }
            }
        }

        return (initial, stream)
    }

    private func removeMessageObserver(id: UUID, roomID: String) {
        messageObservers[roomID]?.removeValue(forKey: id)
    }

    private func notifyMessageObservers(roomID: String, messages: [Message]) {
        guard let observers = messageObservers[roomID] else { return }
        for observer in observers.values {
            observer(messages)
        }
    }

    // MARK: - Conflict Resolution

    /// Merge two room states according to defined policies.
    private func mergeRooms(local: RoomLifecycle, remote: RoomLifecycle) -> RoomLifecycle {
        // Use server (remote) timestamp to determine winner for basic state
        // But apply specific merge policies for nested data

        // If remote is newer, use it as base
        if remote.modifiedAt > local.modifiedAt {
            return applyLocalOverrides(base: remote, local: local)
        } else {
            return applyLocalOverrides(base: local, local: local)
        }
    }

    /// Apply local overrides that should win regardless of timestamp.
    private func applyLocalOverrides(base: RoomLifecycle, local: RoomLifecycle) -> RoomLifecycle {
        // Extract turn states for merging
        guard let baseTurn = base.turnState, let localTurn = local.turnState else {
            return base
        }

        // Apply merge policies:
        // - Turn index: higher wins (turns only advance)
        // - Raised hands: union merge
        let mergedTurnIndex = max(baseTurn.currentTurnIndex, localTurn.currentTurnIndex)
        let mergedRaisedHands = baseTurn.raisedHands.union(localTurn.raisedHands)

        // Need is trickier - use base's need if present
        let mergedNeed = baseTurn.currentNeed ?? localTurn.currentNeed

        let mergedTurn = TurnState(
            currentTurnIndex: mergedTurnIndex,
            raisedHands: mergedRaisedHands,
            currentNeed: mergedNeed
        )

        return base.withTurnState(mergedTurn)
    }

    // MARK: - Reset (for testing)

    func reset() {
        rooms = [:]
        messages = [:]
        roomObservers = [:]
        messageObservers = [:]
    }
}
