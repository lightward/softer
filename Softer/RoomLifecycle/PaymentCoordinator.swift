import Foundation

/// An authorized payment that hasn't been captured yet.
struct PaymentAuthorization: Sendable, Equatable {
    let id: String
    let cents: Int
    let authorizedAt: Date
    let expiresAt: Date

    var isExpired: Bool {
        Date() > expiresAt
    }
}

/// Errors that can occur during payment operations.
enum PaymentError: Error, Sendable, Equatable {
    case declined
    case cancelled
    case expired
    case networkError(String)
    case notConfigured
}

/// Coordinates Apple Pay authorization and capture.
protocol PaymentCoordinator: Sendable {
    /// Authorize a payment amount. The amount is held but not captured.
    /// For first room (cents == 0), returns a "free" authorization.
    func authorize(cents: Int) async -> Result<PaymentAuthorization, PaymentError>

    /// Capture a previously authorized payment.
    func capture(_ authorization: PaymentAuthorization) async -> Result<Void, PaymentError>

    /// Release a payment authorization without capturing.
    func release(_ authorization: PaymentAuthorization) async
}
