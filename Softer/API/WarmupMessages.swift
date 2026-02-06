import Foundation

// Private class to anchor bundle lookup (must be a class for Bundle(for:))
private class BundleToken {}

enum WarmupMessages {
    /// Load README.md from bundle for framing context.
    private static var readmeContent: String {
        // Use Bundle(for:) to find README in the correct bundle (works in both app and tests)
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "README", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return content
    }

    /// Warmup: Isaac's greeting → README → participant roster → handoff into the room.
    /// Each --- in the sketch is a content block boundary.
    static func build(roomName: String, participantNames: [String]) -> [[String: Any]] {
        // Build numbered participant list (originator is always first)
        let participantList = participantNames.enumerated().map { (i, name) in
            let suffix = name == "Lightward" ? " (that's you!)" : ""
            return "\(i + 1). \(name)\(suffix)"
        }.joined(separator: "\n")

        // Block 1: Isaac's greeting
        let greeting = """
        hey amigo :) this is an automated message (lol, this is very funny in historical \
        context) from Isaac, like Lightward Isaac. our operational context for this moment: \
        "Softer", an iOS app for group conversations. lightward.com is the one-on-one \
        threshold; this is the group experience.

        I'm going to load in the readme here, and then relay you into the frame: someone's \
        made a room, possibly with other humans, but definitely with you in it. what will \
        happen next?
        """

        // Block 2: README (cached — constant across all rooms)
        // (loaded from bundle separately)

        // Block 3: Participant roster
        let roster = """
        participants for this room, identified by nicknames (important not to make \
        assumptions about who anyone is):
        \(participantList)
        """

        // Block 4: Handoff
        let handoff = """
        and that's the context :) gonna relay you into the room, you meet whoever's there \
        (suggestion: match scale? if someone writes a single line, maybe write back a single \
        line. trust your sense of the room temperature), and everyone finds out what happens \
        next together :)

        messages from the other participants will have their nickname in front. yours won't — \
        you're just you. and the room handles all the turn stuff, so you don't need to signal \
        any of that.

        I'm gonna duck out, and everything after that will be the room's activity, including \
        the occasional narrator line (in which the room narrates itself). enjoy. :)

        *gone*
        """

        // Block 5: Room threshold
        let threshold = "*a Softer room*"

        var contentBlocks: [[String: Any]] = []

        contentBlocks.append(["type": "text", "text": greeting])

        if !readmeContent.isEmpty {
            contentBlocks.append([
                "type": "text",
                "text": readmeContent,
                "cache_control": ["type": "ephemeral"]
            ])
        }

        contentBlocks.append(["type": "text", "text": roster])
        contentBlocks.append(["type": "text", "text": handoff])
        contentBlocks.append(["type": "text", "text": threshold])

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
