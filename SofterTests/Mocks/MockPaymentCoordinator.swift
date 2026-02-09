import Foundation
@testable import Softer

/// Mock payment coordinator for testing.
final class MockPaymentCoordinator: PaymentCoordinator, @unchecked Sendable {
    var purchaseResult: Result<Void, PaymentError> = .success(())
    var purchaseCallCount = 0
    var lastPurchasedTier: PaymentTier?

    func purchase(tier: PaymentTier) async -> Result<Void, PaymentError> {
        purchaseCallCount += 1
        lastPurchasedTier = tier
        return purchaseResult
    }

    /// Configure purchase to fail.
    func setPurchaseFailure(_ error: PaymentError) {
        purchaseResult = .failure(error)
    }
}
