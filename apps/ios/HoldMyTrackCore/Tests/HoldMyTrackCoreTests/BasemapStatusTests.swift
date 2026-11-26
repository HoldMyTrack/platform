import XCTest
@testable import HoldMyTrackCore

final class BasemapStatusTests: XCTestCase {
    private func style(_ basemap: String?, layers: Int = 0) -> JSONValue {
        let source = basemap.map { #","protomaps":{"type":"vector","url":"\#($0)"}"# } ?? ""
        let json = #"{"version":8,"sources":{"own":{"type":"geojson","data":{"n":\#(layers)}}\#(source)},"layers":[]}"#
        return JSONValue.parse(Data(json.utf8))!
    }

    func testTheFirstStyleWithABasemapStartsTheClock() {
        XCTAssertTrue(BasemapStatus.sourceChanged(from: nil, to: style("pmtiles://a")))
    }

    func testAReloadKeepingTheBasemapDoesNot() {
        XCTAssertFalse(BasemapStatus.sourceChanged(from: style("pmtiles://a"), to: style("pmtiles://a", layers: 1)))
    }

    func testAnotherBasemapDoes() {
        XCTAssertTrue(BasemapStatus.sourceChanged(from: style("pmtiles://a"), to: style("pmtiles://b")))
    }

    func testAStyleWithNoBasemapDoesNot() {
        XCTAssertFalse(BasemapStatus.sourceChanged(from: nil, to: style(nil)))
    }
}
