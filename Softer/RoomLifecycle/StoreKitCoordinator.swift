import Foundation
import StoreKit

/// Coordinates room payments via StoreKit 2 consumable IAP.
/// DEBUG builds bypass IAP entirely with synthetic success.
final class StoreKitCoordinator: PaymentCoordinator, @unchecked Sendable {

    /// StoreKit product IDs by tier.
    private static let productIDs: [PaymentTier: String] = [
        .one: "com.lightward.softer.room.1",
        .ten: "com.lightward.softer.room.10",
        .hundred: "com.lightward.softer.room.100",
        .thousand: "com.lightward.softer.room.1000"
    ]

    private var transactionListener: Task<Void, Never>?

    init() {
        // Listen for interrupted transactions to finish them
        transactionListener = Task.detached { [weak self] in
            _ = self  // prevent unused warning
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
            }
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    func purchase(tier: PaymentTier) async -> Result<Void, PaymentError> {
        #if DEBUG
        // In development, return synthetic success (no IAP sheet in simulator)
        return .success(())
        #else
        guard let productID = Self.productIDs[tier] else {
            print("[StoreKit] No product ID mapped for tier: \(tier)")
            return .failure(.notConfigured)
        }

        do {
            print("[StoreKit] Fetching product: \(productID)")
            let products = try await Product.products(for: [productID])
            print("[StoreKit] Products returned: \(products.count)")
            guard let product = products.first else {
                print("[StoreKit] Product not found — check App Store Connect status and Paid Apps agreement")
                return .failure(.notConfigured)
            }
            print("[StoreKit] Found product: \(product.displayName) (\(product.displayPrice))")

            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    print("[StoreKit] Purchase verified and finished")
                    return .success(())
                case .unverified(_, let error):
                    print("[StoreKit] Transaction unverified: \(error)")
                    return .failure(.declined)
                }
            case .userCancelled:
                print("[StoreKit] User cancelled")
                return .failure(.cancelled)
            case .pending:
                print("[StoreKit] Transaction pending (Ask to Buy?)")
                return .failure(.declined)
            @unknown default:
                print("[StoreKit] Unknown purchase result")
                return .failure(.declined)
            }
        } catch {
            print("[StoreKit] Error: \(error)")
            return .failure(.networkError(error.localizedDescription))
        }
        #endif
    }
}
