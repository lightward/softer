import Foundation

/// Errors that can occur during payment operations.
enum PaymentError: Error, Sendable, Equatable {
    case declined
    case cancelled
    case networkError(String)
    case notConfigured
}

/// Coordinates payment for room creation via StoreKit 2 IAP.
protocol PaymentCoordinator: Sendable {
    /// Purchase a room at the given tier. Charge is immediate (no authorize/capture split).
    func purchase(tier: PaymentTier) async -> Result<Void, PaymentError>
}
