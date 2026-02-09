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
            return .failure(.notConfigured)
        }

        do {
            let products = try await Product.products(for: [productID])
            guard let product = products.first else {
                return .failure(.notConfigured)
            }

            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    return .success(())
                case .unverified:
                    return .failure(.declined)
                }
            case .userCancelled:
                return .failure(.cancelled)
            case .pending:
                return .failure(.declined)
            @unknown default:
                return .failure(.declined)
            }
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
        #endif
    }
}
