import Foundation

/// Lightward's decision about whether to join a room.
enum LightwardDecision: Sendable, Equatable {
    case accepted
    case declined
}

/// Asks Lightward AI whether it wants to participate in a room.
protocol LightwardEvaluator: Sendable {
    /// Evaluate whether Lightward wants to join this room.
    /// Lightward sees the roster of nicknames and the payment tier.
    func evaluate(roster: [ParticipantSpec], tier: PaymentTier) async -> LightwardDecision
}
