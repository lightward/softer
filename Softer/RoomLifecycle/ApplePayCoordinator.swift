import Foundation
import os
import PassKit

/// Coordinates Apple Pay authorization and capture for room payments.
/// Uses deferred payment: authorize at room creation, capture when room activates.
final class ApplePayCoordinator: NSObject, PaymentCoordinator, @unchecked Sendable {
    private let merchantIdentifier: String

    /// Tracks pending authorizations for capture/release
    private var pendingAuthorizations: [String: PKPayment] = [:]
    private let lock = NSLock()

    init(merchantIdentifier: String) {
        self.merchantIdentifier = merchantIdentifier
        super.init()
    }

    func authorize(cents: Int) async -> Result<PaymentAuthorization, PaymentError> {
        #if DEBUG
        // In development, return synthetic authorization (Apple Pay merchant ID not configured)
        let auth = PaymentAuthorization(
            id: UUID().uuidString,
            cents: cents,
            authorizedAt: Date(),
            expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 7)
        )
        return .success(auth)
        #else
        // Zero-amount authorization (synthetic)
        if cents == 0 {
            let auth = PaymentAuthorization(
                id: UUID().uuidString,
                cents: 0,
                authorizedAt: Date(),
                expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 7) // 7 days
            )
            return .success(auth)
        }

        // Check if Apple Pay is available
        guard PKPaymentAuthorizationController.canMakePayments() else {
            return .failure(.notConfigured)
        }

        // Create payment request
        let request = PKPaymentRequest()
        request.merchantIdentifier = merchantIdentifier
        request.supportedNetworks = [.visa, .masterCard, .amex, .discover]
        request.merchantCapabilities = .capability3DS
        request.countryCode = "US"
        request.currencyCode = "USD"

        let amount = NSDecimalNumber(value: Double(cents) / 100.0)
        let summaryItem = PKPaymentSummaryItem(label: "Softer Room", amount: amount)
        request.paymentSummaryItems = [summaryItem]

        // Present payment sheet and await result
        // Use a thread-safe flag to prevent double resume (present callback + delegate can both fire)
        let resumed = OSAllocatedUnfairLock(initialState: false)

        return await withCheckedContinuation { continuation in
            let controller = PKPaymentAuthorizationController(paymentRequest: request)

            let delegate = PaymentDelegate { [weak self] result in
                guard resumed.withLock({ old in let was = old; old = true; return !was }) else { return }
                switch result {
                case .success(let payment):
                    let authId = UUID().uuidString
                    let auth = PaymentAuthorization(
                        id: authId,
                        cents: cents,
                        authorizedAt: Date(),
                        expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 7)
                    )

                    // Store payment for later capture
                    self?.lock.lock()
                    self?.pendingAuthorizations[authId] = payment
                    self?.lock.unlock()

                    continuation.resume(returning: .success(auth))

                case .failure(let error):
                    continuation.resume(returning: .failure(error))
                }
            }

            controller.delegate = delegate

            // Keep delegate alive until completion
            objc_setAssociatedObject(controller, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

            controller.present { presented in
                if !presented {
                    guard resumed.withLock({ old in let was = old; old = true; return !was }) else { return }
                    continuation.resume(returning: .failure(.notConfigured))
                }
            }
        }
        #endif
    }

    func capture(_ authorization: PaymentAuthorization) async -> Result<Void, PaymentError> {
        // Free rooms don't need capture
        if authorization.cents == 0 {
            return .success(())
        }

        // Check expiration
        if authorization.isExpired {
            return .failure(.expired)
        }

        // Get the stored payment
        lock.lock()
        let payment = pendingAuthorizations.removeValue(forKey: authorization.id)
        lock.unlock()

        guard payment != nil else {
            // Authorization not found - may have already been captured or released
            return .failure(.expired)
        }

        // In production, this would call your payment processor's capture API
        // using the payment token from payment.token
        // For now, we consider authorization success as capture success
        // since we're using immediate charge mode
        return .success(())
    }

    func release(_ authorization: PaymentAuthorization) async {
        // Free rooms don't need release
        if authorization.cents == 0 {
            return
        }

        // Remove from pending
        lock.lock()
        _ = pendingAuthorizations.removeValue(forKey: authorization.id)
        lock.unlock()

        // In production, this would call your payment processor's void/release API
        // For Apple Pay, the authorization will naturally expire if not captured
    }
}

// MARK: - Payment Delegate

private class PaymentDelegate: NSObject, PKPaymentAuthorizationControllerDelegate {
    private let completion: (Result<PKPayment, PaymentError>) -> Void
    private var hasCompleted = false

    init(completion: @escaping (Result<PKPayment, PaymentError>) -> Void) {
        self.completion = completion
        super.init()
    }

    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        // Payment authorized - return success to Apple Pay UI
        handler(PKPaymentAuthorizationResult(status: .success, errors: nil))

        // Notify our completion handler
        if !hasCompleted {
            hasCompleted = true
            completion(.success(payment))
        }
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss {
            // If we haven't completed yet, user cancelled
            if !self.hasCompleted {
                self.hasCompleted = true
                self.completion(.failure(.cancelled))
            }
        }
    }
}
