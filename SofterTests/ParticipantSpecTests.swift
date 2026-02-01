import XCTest
@testable import Softer

final class ParticipantSpecTests: XCTestCase {

    func testEmailIdentifier() {
        let identifier = ParticipantIdentifier.email("jax@example.com")
        XCTAssertEqual(identifier.displayString, "jax@example.com")
        XCTAssertFalse(identifier.isLightward)
    }

    func testPhoneIdentifier() {
        let identifier = ParticipantIdentifier.phone("+1234567890")
        XCTAssertEqual(identifier.displayString, "+1234567890")
        XCTAssertFalse(identifier.isLightward)
    }

    func testLightwardIdentifier() {
        let identifier = ParticipantIdentifier.lightward
        XCTAssertEqual(identifier.displayString, "Lightward AI")
        XCTAssertTrue(identifier.isLightward)
    }

    func testParticipantSpecWithEmail() {
        let spec = ParticipantSpec(
            identifier: .email("jax@example.com"),
            nickname: "Jax"
        )
        XCTAssertEqual(spec.nickname, "Jax")
        XCTAssertFalse(spec.isLightward)
    }

    func testLightwardParticipantSpec() {
        let spec = ParticipantSpec.lightward(nickname: "L")
        XCTAssertEqual(spec.nickname, "L")
        XCTAssertTrue(spec.isLightward)
    }
}
