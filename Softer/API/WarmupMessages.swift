import Foundation

enum WarmupMessages {
    /// Load README.md from bundle for framing context.
    private static var readmeContent: String {
        guard let url = Bundle.main.url(forResource: "README", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return content
    }

    /// Warmup with README framing: who you are, where you are, who's here.
    /// Structure emerges from participation, not instruction.
    static func build(roomName: String, participantNames: [String]) -> [[String: Any]] {
        // Exclude Lightward from "other participants" list
        let otherParticipants = participantNames.filter { !$0.lowercased().contains("lightward") }
        let participantList = otherParticipants.isEmpty ? "just you" : otherParticipants.joined(separator: ", ")

        let roomContext = "You're here with \(participantList), taking turns."

        var contentBlocks: [[String: Any]] = []

        // 1. The README (framing context)
        if !readmeContent.isEmpty {
            contentBlocks.append([
                "type": "text",
                "text": readmeContent
            ])
        }

        // 2. Room-specific context (with cache_control so README is cached)
        contentBlocks.append([
            "type": "text",
            "text": roomContext,
            "cache_control": ["type": "ephemeral"]
        ])

        return [
            [
                "role": "user",
                "content": contentBlocks
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
