import XCTest
@testable import HoldMyTrackCore

final class ToastDurationTests: XCTestCase {
    func testAShortMessageStaysFourSeconds() {
        XCTAssertEqual(ToastDuration.seconds("Saved to Photos", action: false), 4)
    }

    func testAnActionStaysSix() {
        XCTAssertEqual(ToastDuration.seconds("Hidden", action: true), 6)
    }

    func testLongWordsStayLonger() {
        XCTAssertEqual(ToastDuration.seconds(String(repeating: "a", count: 150), action: false), 10)
    }
}
