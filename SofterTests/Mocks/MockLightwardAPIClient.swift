import Foundation
@testable import Softer

/// Mock Lightward API client for testing.
/// Uses a class with locks instead of actor for nonisolated protocol conformance.
final class MockLightwardAPIClient: LightwardAPI, @unchecked Sendable {
    // Configurable responses
    private let lock = NSLock()
    private var _responseChunks: [String] = ["Hello ", "from ", "Lightward!"]
    private var _shouldFail = false
    private var _error: Error = MockAPIError.failed
    private var _streamCallCount = 0
    private var _lastChatLog: [[String: Any]]?

    var responseChunks: [String] {
        get { lock.withLock { _responseChunks } }
        set { lock.withLock { _responseChunks = newValue } }
    }
    var shouldFail: Bool {
        get { lock.withLock { _shouldFail } }
        set { lock.withLock { _shouldFail = newValue } }
    }
    var error: Error {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var streamCallCount: Int {
        get { lock.withLock { _streamCallCount } }
        set { lock.withLock { _streamCallCount = newValue } }
    }
    var lastChatLog: [[String: Any]]? {
        get { lock.withLock { _lastChatLog } }
        set { lock.withLock { _lastChatLog = newValue } }
    }

    func stream(chatLog: [[String: Any]]) -> AsyncThrowingStream<String, Error> {
        lock.withLock {
            _streamCallCount += 1
            _lastChatLog = chatLog
        }

        let chunks = responseChunks
        let shouldFail = self.shouldFail
        let error = self.error

        return AsyncThrowingStream { continuation in
            Task {
                if shouldFail {
                    continuation.finish(throwing: error)
                    return
                }

                for chunk in chunks {
                    continuation.yield(chunk)
                    // Small delay to simulate streaming
                    try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
                }
                continuation.finish()
            }
        }
    }

    func reset() {
        responseChunks = ["Hello ", "from ", "Lightward!"]
        shouldFail = false
        streamCallCount = 0
        lastChatLog = nil
    }
}

enum MockAPIError: Error {
    case failed
}
