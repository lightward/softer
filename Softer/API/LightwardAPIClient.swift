import Foundation

/// Protocol for Lightward API interaction, enabling testing.
protocol LightwardAPI: Sendable {
    /// Streams a response from Lightward given a chat log.
    func stream(chatLog: [[String: Any]]) -> AsyncThrowingStream<String, Error>
}

actor LightwardAPIClient: LightwardAPI {
    private nonisolated let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated func stream(chatLog: [[String: Any]]) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try Self.buildRequest(chatLog: chatLog)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: APIError.invalidResponse)
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: APIError.httpError(httpResponse.statusCode))
                        return
                    }

                    let parser = SSEParser()
                    var lineBuffer = ""

                    for try await byte in bytes {
                        let char = Character(UnicodeScalar(byte))
                        lineBuffer.append(char)

                        // Process when we have potential complete events (double newline)
                        if lineBuffer.hasSuffix("\n\n") || lineBuffer.hasSuffix("\r\n\r\n") {
                            let events = await parser.parse(chunk: lineBuffer)
                            lineBuffer = ""

                            for event in events {
                                if SSEParser.isMessageStop(event: event) {
                                    continuation.finish()
                                    return
                                }
                                if let text = SSEParser.extractContentDelta(from: event) {
                                    continuation.yield(text)
                                }
                            }
                        }
                    }

                    // Process any remaining buffer
                    if !lineBuffer.isEmpty {
                        let events = await parser.parse(chunk: lineBuffer + "\n\n")
                        for event in events {
                            if let text = SSEParser.extractContentDelta(from: event) {
                                continuation.yield(text)
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func completeResponse(chatLog: [[String: Any]]) async throws -> String {
        var result = ""
        for try await chunk in stream(chatLog: chatLog) {
            result += chunk
        }
        return result
    }

    private static func buildRequest(chatLog: [[String: Any]]) throws -> URLRequest {
        var request = URLRequest(url: Constants.lightwardAPIURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "chat_log": chatLog
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum APIError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .invalidJSON:
            return "Invalid JSON in request"
        }
    }
}
