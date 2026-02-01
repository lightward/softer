import Foundation
@testable import Softer

/// Mock payment coordinator for testing.
final class MockPaymentCoordinator: PaymentCoordinator, @unchecked Sendable {
    var authorizeResult: Result<PaymentAuthorization, PaymentError> = .success(
        PaymentAuthorization(
            id: "mock-auth",
            cents: 0,
            authorizedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )
    )
    var captureResult: Result<Void, PaymentError> = .success(())

    var authorizeCallCount = 0
    var captureCallCount = 0
    var releaseCallCount = 0
    var lastAuthorizedCents: Int?
    var lastCapturedAuth: PaymentAuthorization?
    var lastReleasedAuth: PaymentAuthorization?

    func authorize(cents: Int) async -> Result<PaymentAuthorization, PaymentError> {
        authorizeCallCount += 1
        lastAuthorizedCents = cents

        // Return configured result with correct cents
        switch authorizeResult {
        case .success(let auth):
            return .success(PaymentAuthorization(
                id: auth.id,
                cents: cents,
                authorizedAt: auth.authorizedAt,
                expiresAt: auth.expiresAt
            ))
        case .failure(let error):
            return .failure(error)
        }
    }

    func capture(_ authorization: PaymentAuthorization) async -> Result<Void, PaymentError> {
        captureCallCount += 1
        lastCapturedAuth = authorization
        return captureResult
    }

    func release(_ authorization: PaymentAuthorization) async {
        releaseCallCount += 1
        lastReleasedAuth = authorization
    }

    /// Configure authorization to fail.
    func setAuthorizationFailure(_ error: PaymentError) {
        authorizeResult = .failure(error)
    }

    /// Configure capture to fail.
    func setCaptureFailure(_ error: PaymentError) {
        captureResult = .failure(error)
    }
}
