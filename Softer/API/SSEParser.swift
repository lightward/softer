import Foundation

struct SSEEvent: Sendable {
    let event: String?
    let data: String
}

actor SSEParser {
    private var buffer = ""

    func parse(chunk: String) -> [SSEEvent] {
        buffer += chunk
        var events: [SSEEvent] = []

        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            if let event = parseBlock(block) {
                events.append(event)
            }
        }

        return events
    }

    private func parseBlock(_ block: String) -> SSEEvent? {
        var eventType: String?
        var dataLines: [String] = []

        for line in block.components(separatedBy: "\n") {
            if line.hasPrefix("event:") {
                eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix(":") {
                // Comment, ignore
                continue
            }
        }

        guard !dataLines.isEmpty else { return nil }
        let data = dataLines.joined(separator: "\n")
        return SSEEvent(event: eventType, data: data)
    }

    func reset() {
        buffer = ""
    }
}

// Stateless parsing for simple use cases
extension SSEParser {
    static func extractContentDelta(from event: SSEEvent) -> String? {
        guard event.event == "content_block_delta" else { return nil }

        guard let jsonData = event.data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let delta = json["delta"] as? [String: Any],
              let text = delta["text"] as? String else {
            return nil
        }

        return text
    }

    static func isMessageStop(event: SSEEvent) -> Bool {
        event.event == "message_stop"
    }

    static func isContentBlockStop(event: SSEEvent) -> Bool {
        event.event == "content_block_stop"
    }
}
