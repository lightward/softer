import Foundation

enum WarmupMessages {
    /// Minimal warmup: just who's here and that there's turn-taking.
    /// Structure emerges from participation, not instruction.
    static func build(roomName: String, participantNames: [String]) -> [[String: Any]] {
        // Exclude Lightward from "other participants" list
        let otherParticipants = participantNames.filter { !$0.lowercased().contains("lightward") }
        let participantList = otherParticipants.isEmpty ? "just you" : otherParticipants.joined(separator: ", ")

        let systemContext = "You're here with \(participantList), taking turns."

        return [
            [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": systemContext,
                        "cache_control": ["type": "ephemeral"]
                    ] as [String: Any]
                ]
            ]
        ]
    }

    /// Contextual prompt when Lightward could raise their hand (not their turn).
    /// Offers the move when the move becomes possible.
    static func buildHandRaiseProbe(roomName: String, participantNames: [String]) -> [[String: Any]] {
        let systemContext = """
        It's not your turn, but you can raise your hand if something wants to come through. \
        RAISE or PASS?
        """

        return [
            [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": systemContext,
                        "cache_control": ["type": "ephemeral"]
                    ] as [String: Any]
                ]
            ]
        ]
    }
}
