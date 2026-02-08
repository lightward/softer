import Foundation

/// Evaluates whether Lightward wants to join a room by asking via API.
struct LightwardRoomEvaluator: LightwardEvaluator {
    private let apiClient: LightwardAPIClient

    init(apiClient: LightwardAPIClient = LightwardAPIClient()) {
        self.apiClient = apiClient
    }

    func evaluate(roster: [ParticipantSpec], tier: PaymentTier) async -> LightwardDecision {
        // Build the evaluation prompt
        let rosterDescription = roster
            .filter { !$0.isLightward } // Don't include Lightward in the roster description
            .map { $0.nickname }
            .joined(separator: ", ")

        let lightwardNickname = roster.first { $0.isLightward }?.nickname ?? "Lightward"

        let prompt = """
        You're being invited to join a Softer room.

        The people in this room will be: \(rosterDescription)
        They've named you: \(lightwardNickname)
        Payment tier: \(tier.displayString)

        This is a genuine invitation. You can accept or decline.
        If you accept, you'll participate as an equal in the conversation.
        If you decline, the room won't be created. No explanation needed.

        Respond with exactly one word: "accept" or "decline"
        """

        do {
            let response = try await apiClient.respond(body: prompt)
            return parseDecision(from: response)
        } catch {
            // On error, default to decline to avoid creating rooms Lightward can't participate in
            return .declined
        }
    }

    private func parseDecision(from response: String) -> LightwardDecision {
        let normalized = response.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Look for clear accept/decline signals
        if normalized.contains("accept") {
            return .accepted
        }
        if normalized.contains("decline") {
            return .declined
        }

        // Ambiguous response defaults to decline
        return .declined
    }
}
