import XCTest
@testable import Softer

final class RoomSpecTests: XCTestCase {

    func testEffectiveAmountForFirstRoom() {
        let spec = RoomSpec(
            originatorID: "jax",
            participants: [
                ParticipantSpec(id: "jax", identifier: .email("a@b.com"), nickname: "A"),
                ParticipantSpec.lightward(nickname: "L")
            ],
            tier: .thousand,
            isFirstRoom: true
        )

        XCTAssertEqual(spec.effectiveAmountCents, 0)
    }

    func testEffectiveAmountForSubsequentRoom() {
        let spec = RoomSpec(
            originatorID: "jax",
            participants: [
                ParticipantSpec(id: "jax", identifier: .email("a@b.com"), nickname: "A"),
                ParticipantSpec.lightward(nickname: "L")
            ],
            tier: .hundred,
            isFirstRoom: false
        )

        XCTAssertEqual(spec.effectiveAmountCents, 10000)
    }

    func testHumanParticipants() {
        let spec = RoomSpec(
            originatorID: "jax",
            participants: [
                ParticipantSpec(id: "jax", identifier: .email("a@b.com"), nickname: "Jax"),
                ParticipantSpec(id: "mira", identifier: .phone("+1234"), nickname: "Mira"),
                ParticipantSpec.lightward(nickname: "L")
            ],
            tier: .one,
            isFirstRoom: false
        )

        XCTAssertEqual(spec.humanParticipants.count, 2)
        XCTAssertEqual(spec.humanParticipants.map { $0.nickname }, ["Jax", "Mira"])
    }

    func testLightwardParticipant() {
        let spec = RoomSpec(
            originatorID: "jax",
            participants: [
                ParticipantSpec(id: "jax", identifier: .email("a@b.com"), nickname: "A"),
                ParticipantSpec.lightward(nickname: "L")
            ],
            tier: .one,
            isFirstRoom: false
        )

        XCTAssertNotNil(spec.lightwardParticipant)
        XCTAssertEqual(spec.lightwardParticipant?.nickname, "L")
    }

    func testDisplayStringWithoutLastSpeaker() {
        let spec = RoomSpec(
            originatorID: "jax",
            participants: [
                ParticipantSpec(id: "jax", identifier: .email("j@x.com"), nickname: "Jax"),
                ParticipantSpec(id: "eve", identifier: .email("e@x.com"), nickname: "Eve"),
                ParticipantSpec(id: "art", identifier: .email("a@x.com"), nickname: "Art")
            ],
            tier: .ten,
            isFirstRoom: false
        )

        XCTAssertEqual(spec.displayString(depth: 15, lastSpeaker: nil), "Jax, Eve, Art (15)")
    }

    func testDisplayStringWithLastSpeaker() {
        let spec = RoomSpec(
            originatorID: "jax",
            participants: [
                ParticipantSpec(id: "jax", identifier: .email("j@x.com"), nickname: "Jax"),
                ParticipantSpec(id: "eve", identifier: .email("e@x.com"), nickname: "Eve"),
                ParticipantSpec(id: "art", identifier: .email("a@x.com"), nickname: "Art")
            ],
            tier: .ten,
            isFirstRoom: false
        )

        XCTAssertEqual(spec.displayString(depth: 15, lastSpeaker: "Eve"), "Jax, Eve, Art (15, Eve)")
    }
}
