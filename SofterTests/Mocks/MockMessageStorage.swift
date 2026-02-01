import Foundation
@testable import Softer

/// Mock message storage for testing.
actor MockMessageStorage: MessageStorage {
    private var messages: [String: [Message]] = [:]  // roomID -> messages
    private var observers: [String: [@Sendable ([Message]) -> Void]] = [:]

    // For test assertions
    var savedMessages: [Message] = []
    var saveCallCount = 0
    var fetchCallCount = 0

    // Configurable behavior
    var shouldFailSave = false
    var shouldFailFetch = false
    var saveError: Error = MockStorageError.saveFailed
    var fetchError: Error = MockStorageError.fetchFailed

    func save(_ message: Message, roomID: String) async throws {
        saveCallCount += 1
        savedMessages.append(message)

        if shouldFailSave {
            throw saveError
        }

        var roomMessages = messages[roomID] ?? []
        roomMessages.append(message)
        messages[roomID] = roomMessages

        // Notify observers
        if let handlers = observers[roomID] {
            let allMessages = roomMessages
            for handler in handlers {
                handler(allMessages)
            }
        }
    }

    func fetchMessages(roomID: String) async throws -> [Message] {
        fetchCallCount += 1

        if shouldFailFetch {
            throw fetchError
        }

        return messages[roomID] ?? []
    }

    func observeMessages(roomID: String, handler: @escaping @Sendable ([Message]) -> Void) async -> ObservationToken {
        var roomObservers = observers[roomID] ?? []
        roomObservers.append(handler)
        observers[roomID] = roomObservers

        // Immediately call with current messages
        let current = messages[roomID] ?? []
        handler(current)

        return MockObservationToken { [weak self] in
            Task {
                await self?.removeObserver(roomID: roomID, handler: handler)
            }
        }
    }

    private func removeObserver(roomID: String, handler: @escaping @Sendable ([Message]) -> Void) {
        // Note: In real code we'd need a better way to identify handlers
        // For testing, we just clear all observers for simplicity
        observers[roomID] = []
    }

    // Test helpers
    func reset() {
        messages = [:]
        observers = [:]
        savedMessages = []
        saveCallCount = 0
        fetchCallCount = 0
        shouldFailSave = false
        shouldFailFetch = false
    }

    func preloadMessages(_ messages: [Message], roomID: String) {
        self.messages[roomID] = messages
    }
}

final class MockObservationToken: ObservationToken, @unchecked Sendable {
    private let onCancel: () -> Void
    private var cancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onCancel()
    }
}

enum MockStorageError: Error {
    case saveFailed
    case fetchFailed
}
