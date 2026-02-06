import XCTest
@testable import Softer

final class ParticipantIdentityTests: XCTestCase {

    // MARK: - Helpers

    private func participant(
        id: String = UUID().uuidString,
        nickname: String = "Test",
        type: String = "email",
        value: String? = "test@example.com",
        orderIndex: Int = 0,
        signaled: Bool = false,
        userRecordID: String? = nil
    ) -> EmbeddedParticipant {
        EmbeddedParticipant(
            id: id,
            nickname: nickname,
            identifierType: type,
            identifierValue: value,
            orderIndex: orderIndex,
            hasSignaledHere: signaled,
            userRecordID: userRecordID
        )
    }

    // MARK: - findLocalParticipant

    func testMatchByUserRecordID() {
        let p = participant(id: "p1", nickname: "Isaac", userRecordID: "rec-123")
        let lightward = participant(id: "lw", nickname: "Lightward", type: "lightward", value: nil)

        let result = ParticipantIdentity.findLocalParticipant(
            in: [p, lightward],
            localUserRecordID: "rec-123",
            isSharedWithMe: false
        )
        XCTAssertEqual(result, "p1")
    }

    func testMatchByCurrentUserTypeOwnRoom() {
        let owner = participant(id: "p1", nickname: "Isaac", type: "currentUser", value: nil)
        let other = participant(id: "p2", nickname: "Abe", type: "email", value: "abe@example.com", orderIndex: 1)

        let result = ParticipantIdentity.findLocalParticipant(
            in: [owner, other],
            localUserRecordID: "rec-999",
            isSharedWithMe: false
        )
        XCTAssertEqual(result, "p1")
    }

    func testCurrentUserFallbackSkippedOnSharedRoom() {
        // The bug: on Abe's device viewing a shared room, the currentUser type
        // matched Isaac (the owner) instead of Abe
        let owner = participant(id: "p1", nickname: "Isaac", type: "currentUser", value: nil)
        let other = participant(id: "p2", nickname: "Abe", type: "email", value: "abe@example.com", orderIndex: 1)

        let result = ParticipantIdentity.findLocalParticipant(
            in: [owner, other],
            localUserRecordID: "abe-rec-id",
            isSharedWithMe: true
        )
        XCTAssertNil(result)
    }

    func testNoMatchReturnsNil() {
        let p1 = participant(id: "p1", nickname: "Isaac", userRecordID: "rec-111")
        let p2 = participant(id: "p2", nickname: "Abe", userRecordID: "rec-222")

        let result = ParticipantIdentity.findLocalParticipant(
            in: [p1, p2],
            localUserRecordID: "rec-999",
            isSharedWithMe: true
        )
        XCTAssertNil(result)
    }

    func testLightwardNeverMatched() {
        // Lightward has nil userRecordID — shouldn't be returned even if
        // localUserRecordID were somehow nil-matching
        let lightward = participant(id: "lw", nickname: "Lightward", type: "lightward", value: nil, userRecordID: nil)
        let human = participant(id: "p1", nickname: "Isaac", type: "email", userRecordID: "rec-123")

        let result = ParticipantIdentity.findLocalParticipant(
            in: [lightward, human],
            localUserRecordID: "rec-456",
            isSharedWithMe: true
        )
        XCTAssertNil(result)
    }

    // MARK: - populateUserRecordID

    func testPopulatesNilUserRecordID() {
        let p = participant(id: "p1", nickname: "Abe", type: "email", value: "abe@example.com", userRecordID: nil)
        let owner = participant(id: "p0", nickname: "Isaac", type: "currentUser", value: nil, userRecordID: "rec-owner")
        let lightward = participant(id: "lw", nickname: "Lightward", type: "lightward", value: nil)

        let result = ParticipantIdentity.populateUserRecordID(
            in: [owner, p, lightward],
            shareUserRecordID: "rec-abe",
            localUserRecordID: "rec-abe"
        )

        XCTAssertEqual(result[1].userRecordID, "rec-abe")
        // Owner and Lightward unchanged
        XCTAssertEqual(result[0].userRecordID, "rec-owner")
        XCTAssertNil(result[2].userRecordID)
    }

    func testSkipsWhenAlreadyPopulated() {
        let p = participant(id: "p1", nickname: "Abe", type: "email", value: "abe@example.com", userRecordID: "rec-abe")

        let result = ParticipantIdentity.populateUserRecordID(
            in: [p],
            shareUserRecordID: "rec-abe",
            localUserRecordID: "rec-abe"
        )

        XCTAssertEqual(result, [p])
    }

    func testSkipsLightwardAndCurrentUser() {
        let lightward = participant(id: "lw", nickname: "Lightward", type: "lightward", value: nil, userRecordID: nil)
        let owner = participant(id: "p0", nickname: "Isaac", type: "currentUser", value: nil, userRecordID: nil)

        let result = ParticipantIdentity.populateUserRecordID(
            in: [lightward, owner],
            shareUserRecordID: "rec-abe",
            localUserRecordID: "rec-abe"
        )

        // Neither should be modified
        XCTAssertNil(result[0].userRecordID)
        XCTAssertNil(result[1].userRecordID)
    }

    func testMultipleNilUserRecordIDs() {
        // Only the first eligible participant gets populated
        let p1 = participant(id: "p1", nickname: "Abe", type: "email", value: "abe@example.com", orderIndex: 0, userRecordID: nil)
        let p2 = participant(id: "p2", nickname: "Eve", type: "email", value: "eve@example.com", orderIndex: 1, userRecordID: nil)

        let result = ParticipantIdentity.populateUserRecordID(
            in: [p1, p2],
            shareUserRecordID: "rec-abe",
            localUserRecordID: "rec-abe"
        )

        XCTAssertEqual(result[0].userRecordID, "rec-abe")
        XCTAssertNil(result[1].userRecordID)
    }
}
