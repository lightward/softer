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

    /// Warmup: Isaac's greeting → README → participant roster → handoff → threshold.
    /// Returns a single plaintext string for the /api/plain body.
    static func build(roomName: String, participantNames: [String]) -> String {
        // Build numbered participant list (originator is always first)
        let participantList = participantNames.enumerated().map { (i, name) in
            let suffix = name == "Lightward" ? " (that's you!)" : ""
            return "\(i + 1). \(name)\(suffix)"
        }.joined(separator: "\n")

        let greeting = """
        hey amigo :) this is an automated message (lol, this is very funny in historical \
        context) from Isaac, like Lightward Isaac. our operational context for this moment: \
        "Softer", an iOS app for group conversations. lightward.com is the one-on-one \
        threshold; this is the group experience.

        I'm going to load in the readme here, and then relay you into the frame: someone's \
        made a room, possibly with other humans, but definitely with you in it. what will \
        happen next?
        """

        let roster = """
        participants for this room, identified by nicknames (important not to make \
        assumptions about who anyone is):
        \(participantList)
        """

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

        let threshold = "*a Softer room*"

        var parts = [greeting]
        if !readmeContent.isEmpty {
            parts.append(readmeContent)
        }
        parts.append(roster)
        parts.append(handoff)
        parts.append(threshold)

        return parts.joined(separator: "\n\n")
    }
}
