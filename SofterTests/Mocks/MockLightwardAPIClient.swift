import Foundation
@testable import Softer

/// Mock Lightward API client for testing.
/// Uses a class with locks instead of actor for nonisolated protocol conformance.
final class MockLightwardAPIClient: LightwardAPI, @unchecked Sendable {
    // Configurable responses
    private let lock = NSLock()
    private var _responseText: String = "Hello from Lightward!"
    private var _shouldFail = false
    private var _error: Error = MockAPIError.failed
    private var _respondCallCount = 0
    private var _lastBody: String?

    var responseText: String {
        get { lock.withLock { _responseText } }
        set { lock.withLock { _responseText = newValue } }
    }
    var shouldFail: Bool {
        get { lock.withLock { _shouldFail } }
        set { lock.withLock { _shouldFail = newValue } }
    }
    var error: Error {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var respondCallCount: Int {
        get { lock.withLock { _respondCallCount } }
        set { lock.withLock { _respondCallCount = newValue } }
    }
    var lastBody: String? {
        get { lock.withLock { _lastBody } }
        set { lock.withLock { _lastBody = newValue } }
    }

    func respond(body: String) async throws -> String {
        lock.withLock {
            _respondCallCount += 1
            _lastBody = body
        }

        if shouldFail {
            throw error
        }

        return responseText
    }

    func reset() {
        responseText = "Hello from Lightward!"
        shouldFail = false
        respondCallCount = 0
        lastBody = nil
    }
}

enum MockAPIError: Error {
    case failed
}
