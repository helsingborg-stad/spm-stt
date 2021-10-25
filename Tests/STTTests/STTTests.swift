import XCTest
@testable import STT

final class STTTests: XCTestCase {
    func testSupportsLocale() {
        XCTAssert(AppleSTT.hasSupportFor(locale: Locale(identifier: "en_US")))
        XCTAssertFalse(AppleSTT.hasSupportFor(locale: Locale(identifier: "agq_CM")))
    }
}
