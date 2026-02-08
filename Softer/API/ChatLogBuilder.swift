import Foundation

enum ChatLogBuilder {
    /// Builds the plaintext request body for Lightward's /api/plain endpoint.
    /// - Parameters:
    ///   - messages: The conversation history
    ///   - roomName: Context for the room
    ///   - participantNames: Names of all participants
    static func build(
        messages: [Message],
        roomName: String,
        participantNames: [String]
    ) -> String {
        let warmup = WarmupMessages.build(
            roomName: roomName,
            participantNames: participantNames
        )

        let conversationLines = messages.map { message -> String in
            if message.isNarration {
                return "Narrator: \(message.text)"
            } else if message.isLightward {
                return message.text
            } else {
                return "\(message.authorName): \(message.text)"
            }
        }

        var parts = [warmup]
        if !conversationLines.isEmpty {
            parts.append(conversationLines.joined(separator: "\n"))
        }
        parts.append("(your turn)")

        return parts.joined(separator: "\n\n")
    }
}
