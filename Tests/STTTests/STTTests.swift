import XCTest
@testable import STT

struct TestObj : Codable {
    var test:String?
}

final class STTTests: XCTestCase {
    func testSupportsLocale() {
        XCTAssert(AppleSTT.hasSupportFor(locale: Locale(identifier: "en_US")))
        XCTAssertFalse(AppleSTT.hasSupportFor(locale: Locale(identifier: "agq_CM")))
    }
    func testJSON () {
        let e = JSONEncoder()
        //e.outputFormatting = .
        let data = try! e.encode(TestObj(test: nil))
        debugPrint(String(data: data, encoding: .utf8))
    }
}
