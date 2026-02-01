import Foundation

/// Represents the current synchronization state of the store.
enum SyncStatus: Equatable, Sendable {
    /// Initial state, haven't attempted sync yet.
    case idle

    /// Actively syncing with CloudKit.
    case syncing

    /// Successfully synced and up to date.
    case synced

    /// Device is offline, working with local data.
    case offline

    /// Sync encountered an error.
    case error(String)

    var isAvailable: Bool {
        switch self {
        case .synced, .syncing, .offline:
            return true
        case .idle, .error:
            return false
        }
    }

    var displayText: String {
        switch self {
        case .idle:
            return "Connecting..."
        case .syncing:
            return "Syncing..."
        case .synced:
            return "Up to date"
        case .offline:
            return "Offline"
        case .error(let message):
            return message
        }
    }
}
