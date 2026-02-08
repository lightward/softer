import Foundation

/// Protocol for Lightward API interaction, enabling testing.
protocol LightwardAPI: Sendable {
    func respond(body: String) async throws -> String
}

actor LightwardAPIClient: LightwardAPI {
    private nonisolated let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated func respond(body: String) async throws -> String {
        var request = URLRequest(url: Constants.lightwardAPIURL)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.invalidResponse
        }

        return text
    }
}

enum APIError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        }
    }
}
