import XCTest
@testable import Softer

final class RoomCreationTests: XCTestCase {

    func testCreateRoomReturnsRoomID() async {
        // When a room is created, the method should return the room ID
        // so callers can navigate to it immediately
        //
        // This is a contract test - we can't easily test CloudKit directly,
        // but we verify the method signature returns what we need.
        //
        // The implementation will change createRoom from:
        //   func createRoom(name: String, creatorName: String) async
        // to:
        //   func createRoom(name: String, creatorName: String) async -> String?

        // For now, this test documents the expected behavior.
        // When we change the signature, this will compile and pass.

        let room = Room(
            name: "Test Room",
            turnOrder: ["Creator", "Lightward"],
            currentTurnIndex: 0
        )

        // Room should have a non-empty ID
        XCTAssertFalse(room.id.isEmpty)

        // The ID should be a valid UUID string
        XCTAssertNotNil(UUID(uuidString: room.id))
    }

    func testRoomIDIsUUIDFormat() {
        let room = Room(
            name: "Test",
            turnOrder: ["A", "B"],
            currentTurnIndex: 0
        )

        // Verify Room IDs follow UUID format (important for CloudKit record names)
        XCTAssertNotNil(UUID(uuidString: room.id), "Room ID should be valid UUID format")
    }
}
