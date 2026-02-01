import Foundation

/// The payment tier for room activation.
/// Orders of magnitude, identical access, "what does this space weigh for you."
enum PaymentTier: Int, Sendable, Codable, CaseIterable {
    case one = 1
    case ten = 10
    case hundred = 100
    case thousand = 1000

    var cents: Int {
        rawValue * 100
    }

    var displayString: String {
        "$\(rawValue)"
    }
}
