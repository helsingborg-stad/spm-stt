import XCTest
@testable import STT

final class STTTests: XCTestCase {
    func testAppleSupport() {
        XCTAssertTrue(AppleSTT.hasSupportFor(locale: Locale(identifier: "sv-SE")))
        XCTAssertTrue(AppleSTT.hasSupportFor(locale: Locale(identifier: "sv")))
        XCTAssertFalse(AppleSTT.hasSupportFor(locale: Locale(identifier: "")))
        XCTAssertFalse(AppleSTT.hasSupportFor(locale: Locale(identifier: "benz-TZ")))
    }
}
