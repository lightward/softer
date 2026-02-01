import Foundation
@testable import Softer

/// Mock Lightward API client for testing.
actor MockLightwardAPIClient: LightwardAPI {
    // Configurable responses
    var responseChunks: [String] = ["Hello ", "from ", "Lightward!"]
    var shouldFail = false
    var error: Error = MockAPIError.failed

    // Call tracking
    var streamCallCount = 0
    var lastChatLog: [[String: Any]]?

    func stream(chatLog: [[String: Any]]) -> AsyncThrowingStream<String, Error> {
        streamCallCount += 1
        lastChatLog = chatLog

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
