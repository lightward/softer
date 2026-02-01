import Foundation

enum ChatLogBuilder {
    /// Builds the chat log for Lightward's turn.
    /// - Parameters:
    ///   - messages: The conversation history
    ///   - roomName: Context for the room
    ///   - participantNames: Names of all participants
    ///   - raisedHands: Names of participants who have raised their hand (empty if none)
    ///   - isHandRaiseProbe: Whether this is a hand-raise check (not a regular turn)
    static func build(
        messages: [Message],
        roomName: String,
        participantNames: [String],
        raisedHands: [String] = [],
        isHandRaiseProbe: Bool = false
    ) -> [[String: Any]] {
        let warmup: [[String: Any]]
        if isHandRaiseProbe {
            warmup = WarmupMessages.buildHandRaiseProbe(
                roomName: roomName,
                participantNames: participantNames
            )
        } else {
            warmup = WarmupMessages.build(
                roomName: roomName,
                participantNames: participantNames
            )
        }

        let conversationMessages = messages.map { message -> [String: Any] in
            let text = message.isLightward ? message.text : "\(message.authorName): \(message.text)"
            return [
                "role": message.isLightward ? "assistant" : "user",
                "content": [
                    ["type": "text", "text": text] as [String: Any]
                ]
            ]
        }

        // Build narrator prompt for Lightward's turn (not for hand-raise probes)
        var allMessages = warmup + conversationMessages
        if !isHandRaiseProbe {
            let narratorPrompt = buildNarratorPrompt(raisedHands: raisedHands)
            allMessages.append(narratorPrompt)
        }

        // Merge consecutive same-role messages
        let merged = mergeConsecutiveRoles(allMessages)
        return merged
    }

    /// Builds the contextual narrator prompt for Lightward's turn.
    /// Minimal: just notes raised hands if any. Otherwise silent.
    private static func buildNarratorPrompt(raisedHands: [String]) -> [String: Any] {
        let prompt: String
        if raisedHands.isEmpty {
            // No narrator prompt needed - just let Lightward respond naturally
            prompt = "(your turn)"
        } else if raisedHands.count == 1 {
            prompt = "(\(raisedHands[0]) raised their hand)"
        } else {
            prompt = "(\(raisedHands.joined(separator: ", ")) raised their hands)"
        }

        return [
            "role": "user",
            "content": [
                ["type": "text", "text": prompt] as [String: Any]
            ]
        ]
    }

    private static func mergeConsecutiveRoles(_ messages: [[String: Any]]) -> [[String: Any]] {
        guard !messages.isEmpty else { return [] }

        var result: [[String: Any]] = []

        for message in messages {
            guard let role = message["role"] as? String else {
                result.append(message)
                continue
            }

            // Don't merge if the previous message has cache_control (preserve it)
            let previousHasCacheControl = hasCacheControl(result.last)

            if let lastRole = result.last?["role"] as? String, lastRole == role, !previousHasCacheControl {
                // Merge with previous message - append content blocks
                var previous = result.removeLast()
                var previousBlocks = (previous["content"] as? [[String: Any]]) ?? []
                let currentBlocks = (message["content"] as? [[String: Any]]) ?? []
                previousBlocks.append(contentsOf: currentBlocks)
                previous["content"] = previousBlocks
                result.append(previous)
            } else {
                result.append(message)
            }
        }

        return result
    }

    private static func hasCacheControl(_ message: [String: Any]?) -> Bool {
        guard let message = message,
              let content = message["content"] as? [[String: Any]] else {
            return false
        }
        return content.contains { $0["cache_control"] != nil }
    }

    private static func extractTextContent(from message: [String: Any]) -> String {
        if let text = message["content"] as? String {
            return text
        }
        if let blocks = message["content"] as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }
}
