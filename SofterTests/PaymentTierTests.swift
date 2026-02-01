import XCTest
@testable import Softer

final class PaymentTierTests: XCTestCase {

    func testTierValues() {
        XCTAssertEqual(PaymentTier.one.rawValue, 1)
        XCTAssertEqual(PaymentTier.ten.rawValue, 10)
        XCTAssertEqual(PaymentTier.hundred.rawValue, 100)
        XCTAssertEqual(PaymentTier.thousand.rawValue, 1000)
    }

    func testCentsConversion() {
        XCTAssertEqual(PaymentTier.one.cents, 100)
        XCTAssertEqual(PaymentTier.ten.cents, 1000)
        XCTAssertEqual(PaymentTier.hundred.cents, 10000)
        XCTAssertEqual(PaymentTier.thousand.cents, 100000)
    }

    func testDisplayString() {
        XCTAssertEqual(PaymentTier.one.displayString, "$1")
        XCTAssertEqual(PaymentTier.ten.displayString, "$10")
        XCTAssertEqual(PaymentTier.hundred.displayString, "$100")
        XCTAssertEqual(PaymentTier.thousand.displayString, "$1000")
    }

    func testAllCases() {
        XCTAssertEqual(PaymentTier.allCases.count, 4)
    }
}
