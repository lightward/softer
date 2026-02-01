import Foundation
@testable import Softer

/// Mock Lightward evaluator for testing.
final class MockLightwardEvaluator: LightwardEvaluator, @unchecked Sendable {
    var decision: LightwardDecision = .accepted

    var evaluateCallCount = 0
    var lastRoster: [ParticipantSpec]?
    var lastTier: PaymentTier?

    func evaluate(roster: [ParticipantSpec], tier: PaymentTier) async -> LightwardDecision {
        evaluateCallCount += 1
        lastRoster = roster
        lastTier = tier
        return decision
    }

    /// Configure Lightward to decline.
    func setDecline() {
        decision = .declined
    }

    /// Configure Lightward to accept.
    func setAccept() {
        decision = .accepted
    }
}
