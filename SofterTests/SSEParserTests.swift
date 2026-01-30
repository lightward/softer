import XCTest
@testable import Softer

final class SSEParserTests: XCTestCase {
    func testParseContentBlockDelta() async {
        let parser = SSEParser()
        let chunk = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}


        """

        let events = await parser.parse(chunk: chunk)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "content_block_delta")

        let text = SSEParser.extractContentDelta(from: events[0])
        XCTAssertEqual(text, "Hello")
    }

    func testParseMessageStop() async {
        let parser = SSEParser()
        let chunk = """
        event: message_stop
        data: {"type":"message_stop"}


        """

        let events = await parser.parse(chunk: chunk)

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(SSEParser.isMessageStop(event: events[0]))
    }

    func testParseMultipleEventsInChunk() async {
        let parser = SSEParser()
        let chunk = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}


        """

        let events = await parser.parse(chunk: chunk)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(SSEParser.extractContentDelta(from: events[0]), "Hi")
        XCTAssertEqual(SSEParser.extractContentDelta(from: events[1]), " there")
    }

    func testParseChunkedAcrossCalls() async {
        let parser = SSEParser()

        // First chunk - incomplete event
        let events1 = await parser.parse(chunk: "event: content_block_delta\n")
        XCTAssertEqual(events1.count, 0)

        // Second chunk - completes the event
        let events2 = await parser.parse(chunk: "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}\n\n")
        XCTAssertEqual(events2.count, 1)
        XCTAssertEqual(SSEParser.extractContentDelta(from: events2[0]), "world")
    }

    func testIgnoresComments() async {
        let parser = SSEParser()
        let chunk = """
        : this is a comment
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"test"}}


        """

        let events = await parser.parse(chunk: chunk)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(SSEParser.extractContentDelta(from: events[0]), "test")
    }

    func testNonDeltaEventReturnsNilContent() async {
        let parser = SSEParser()
        let chunk = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_123"}}


        """

        let events = await parser.parse(chunk: chunk)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(SSEParser.extractContentDelta(from: events[0]))
    }

    func testContentBlockStop() async {
        let parser = SSEParser()
        let chunk = """
        event: content_block_stop
        data: {"type":"content_block_stop","index":0}


        """

        let events = await parser.parse(chunk: chunk)
        XCTAssertTrue(SSEParser.isContentBlockStop(event: events[0]))
    }

    func testReset() async {
        let parser = SSEParser()

        // Add partial data
        let _ = await parser.parse(chunk: "event: content_block_delta\n")
        await parser.reset()

        // After reset, parsing a complete event should work fresh
        let events = await parser.parse(chunk: "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(SSEParser.isMessageStop(event: events[0]))
    }
}
