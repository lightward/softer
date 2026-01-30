import Foundation

actor NeedProcessor {
    private let apiClient: LightwardAPIClient

    init(apiClient: LightwardAPIClient = LightwardAPIClient()) {
        self.apiClient = apiClient
    }

    func checkHandRaise(
        messages: [Message],
        roomName: String,
        participantNames: [String]
    ) async -> Bool {
        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: roomName,
            participantNames: participantNames,
            isHandRaiseProbe: true
        )

        do {
            let response = try await apiClient.completeResponse(chatLog: chatLog)
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return trimmed.contains("RAISE")
        } catch {
            print("Hand-raise check failed: \(error)")
            return false
        }
    }

    func executeLightwardTurn(
        messages: [Message],
        roomName: String,
        participantNames: [String],
        onChunk: @Sendable @escaping (String) -> Void
    ) async -> String? {
        let chatLog = ChatLogBuilder.build(
            messages: messages,
            roomName: roomName,
            participantNames: participantNames
        )

        // Debug: print the chat log being sent
        if let jsonData = try? JSONSerialization.data(withJSONObject: chatLog, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("[Softer] API request chat_log:\n\(jsonString)")
        }

        do {
            var fullText = ""
            for try await chunk in await apiClient.stream(chatLog: chatLog) {
                fullText += chunk
                onChunk(chunk)
            }

            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.uppercased() == "PASS" || trimmed.uppercased() == "YIELD" {
                return nil
            }

            return fullText
        } catch {
            print("Lightward turn failed: \(error)")
            return nil
        }
    }
}
