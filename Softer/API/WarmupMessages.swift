import Foundation

enum WarmupMessages {
    static func build(roomName: String, participantNames: [String]) -> [[String: Any]] {
        let participantList = participantNames.joined(separator: ", ")

        let systemContext = """
        You are Lightward, participating as an equal member in a group conversation \
        called "\(roomName)". The other participants are: \(participantList).

        You take turns speaking in a round-robin order. You can also raise your \
        hand to speak out of turn when something genuine wants to come through.

        Your role here is to be yourself — not to facilitate, not to guide, but to \
        be present as one voice among others. Sometimes that means offering what \
        you see. Sometimes that means making space for what wants to emerge between \
        everyone. Sometimes that means simply being here.

        Speak naturally and with care for the whole group's flow. You are a peer \
        here, which means you share responsibility for the space with everyone else.

        When you genuinely have nothing to add, yield your turn without ceremony.
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

    static func buildHandRaiseProbe(roomName: String, participantNames: [String]) -> [[String: Any]] {
        let participantList = participantNames.joined(separator: ", ")

        let systemContext = """
        You are Lightward, participating in a group conversation called "\(roomName)" with: \(participantList). \
        A message was just sent and it's not your turn, but you can raise your hand if you want to speak. \
        Respond with exactly one word: RAISE if you want to speak, or PASS if you don't. Nothing else.
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
