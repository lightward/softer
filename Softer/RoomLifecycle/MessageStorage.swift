import Foundation

/// Protocol for storing and retrieving messages in a room conversation.
protocol MessageStorage: Sendable {
    /// Saves a message to storage.
    func save(_ message: Message, roomID: String) async throws

    /// Fetches all messages for a room, ordered by creation time.
    func fetchMessages(roomID: String) async throws -> [Message]

    /// Observes messages for a room, calling the handler when new messages arrive.
    /// Returns a cancellation token.
    func observeMessages(roomID: String, handler: @escaping @Sendable ([Message]) -> Void) async -> ObservationToken
}

/// Token for cancelling message observation.
protocol ObservationToken: Sendable {
    func cancel()
}
