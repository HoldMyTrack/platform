import Testing

@testable import HoldMyTrackCore

/// The export viewfinder, its sizes, the stats card's request and the image's credit
/// (apps/ios/docs/SPEC.md FR-2.11); Android's ViewfinderTest, ExportStatsRulesTest and
/// ImageMarksTest. The shared rules run from testdata/client-rules (ClientRulesTests).
struct ExportTests {
    let area = Viewfinder.area(width: 1032, height: 708, margins: ViewfinderMargins(top: 64, bottom: 44, side: 16, minWindow: 64))

    func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ViewfinderBox { ViewfinderBox(x: x, y: y, w: w, h: h) }

    @Test func theAreaKeepsRoomForTheToolbarAboveAndTheSizeBelow() {
        #expect(area == box(16, 64, 1000, 600))
    }

    @Test func aWindowFitsTheAreaInItsShapeCentred() {
        #expect(Viewfinder.fit(1, area: area) == box(216, 64, 600, 600))
        #expect(Viewfinder.fit(4, area: area) == box(16, 239, 1000, 250))
        #expect(Viewfinder.fit(nil, area: area) == area)
    }

    @Test func draggingACornerKeepsTheOppositeOneWhereItWas() {
        #expect(Viewfinder.resize(area, corner: .se, dx: -200, dy: -100, aspect: nil, area: area, minWindow: 64) == box(16, 64, 800, 500))
        #expect(Viewfinder.resize(area, corner: .nw, dx: 300, dy: 100, aspect: nil, area: area, minWindow: 64) == box(316, 164, 700, 500))
    }

    @Test func aCornerNeverCropsPastTheAreaOrBelowTheSmallestWindow() {
        #expect(Viewfinder.resize(area, corner: .se, dx: 500, dy: 500, aspect: nil, area: area, minWindow: 64) == area)
        let tiny = Viewfinder.resize(area, corner: .se, dx: -5000, dy: -5000, aspect: nil, area: area, minWindow: 64)
        #expect(tiny.w == 64 && tiny.h == 64)
    }

    @Test func aPresetsShapeHoldsWhileItsCornerIsDragged() {
        let start = Viewfinder.fit(1, area: area)
        let r = Viewfinder.resize(start, corner: .ne, dx: -300, dy: 0, aspect: 1, area: area, minWindow: 64)
        #expect(r.w == r.h && r.w == 300)
        #expect(r.x == start.x && r.y + r.h == start.y + start.h)
    }

    @Test func aCropSettlesBackToTheFullWindowAndZoomsInSoTheCropFillsIt() {
        let settled = Viewfinder.settle(box(16, 64, 500, 300), area: area)
        #expect(settled.window == area)
        #expect(abs(settled.zoomDelta - 1) < 1e-9)
        #expect(settled.focusX == 266 && settled.focusY == 214)
    }

    @Test func aCropOfANewShapeSettlesToTheLargestWindowOfThatShape() {
        let settled = Viewfinder.settle(box(100, 100, 300, 300), area: area)
        #expect(settled.window == box(216, 64, 600, 600))
        #expect(abs(settled.zoomDelta - 1) < 1e-9)
    }

    @Test func aDragThatChangedNothingLeavesTheMapAlone() {
        #expect(!Viewfinder.moved(area, box(area.x, area.y, area.w + 0.2, area.h)))
        #expect(Viewfinder.moved(area, box(area.x, area.y, area.w - 10, area.h)))
    }

    @Test func theMapEasesToThePointThatPutsTheCropsMiddleInTheWindows() {
        // A window centred 20 points above the map's middle; a crop that doubles to fill it.
        let at = Viewfinder.settledCenter(Viewfinder.Settled(window: box(0, 0, 400, 360), zoomDelta: 1, focusX: 100, focusY: 100), mapW: 400, mapH: 400)
        #expect(abs(at.x - 100) < 1e-9 && abs(at.y - 110) < 1e-9)
    }

    @Test func aCustomImagesLongSideIsTheSizePickedItsShortSideTheWindowsShape() {
        #expect(ExportChoice.custom(.hd).outputSize(windowW: 1600, windowH: 900) == (1920, 1080))
        #expect(ExportChoice.custom(.fourK).outputSize(windowW: 900, windowH: 1600) == (2160, 3840))
        #expect(ExportChoice.custom(.twoK).outputSize(windowW: 500, windowH: 500) == (2560, 2560))
    }

    @Test func aPresetMakesItsOwnSizeWhateverTheWindowsShape() {
        let story = ExportPreset.all.first { $0.id == "instagram-story" }!
        #expect(ExportChoice.preset(story).outputSize(windowW: 300, windowH: 300) == (1080, 1920))
        #expect(abs(ExportChoice.preset(story).aspect! - 1080.0 / 1920) < 1e-9)
        #expect(ExportChoice.custom(.hd).aspect == nil)
    }

    @Test func theMenuListsCustomAtEachSizeThenEveryPresetCustomHDFirst() {
        #expect(ExportChoice.all.first == .initial)
        #expect(ExportChoice.all.count == CustomSize.allCases.count + ExportPreset.all.count)
    }

    @Test func theCardIsAskedForOnlyWithShowStatsTickedAndOffered() {
        #expect(ExportStats.request(show: false, checked: ["a"], tripID: nil, width: 1920, height: 1080, dark: false) == nil)
        #expect(ExportStats.request(show: true, checked: [], tripID: nil, width: 1920, height: 1080, dark: false) == nil)
        #expect(ExportStats.request(show: true, checked: ["a"], tripID: "t1", width: 1920, height: 1080, dark: false) == nil)
    }

    @Test func theRequestCarriesTheImageSizeAndThemeItsIDsSorted() {
        #expect(ExportStats.request(show: true, checked: ["b", "a"], tripID: nil, width: 1920, height: 1080, dark: true)
            == ExportStats.Request(trackIDs: ["a", "b"], width: 1920, height: 1080, dark: true))
    }

    @Test func theCreditIsTheBasemapsThenTheImagerysWhenShownAsPlainText() {
        let basemap = "<a href=\"https://protomaps.com\">Protomaps</a> © <a href=\"https://openstreetmap.org\">OpenStreetMap</a>"
        #expect(ImageMarks.creditText(basemap: basemap, satellite: nil) == "Protomaps © OpenStreetMap")
        #expect(ImageMarks.creditText(basemap: basemap, satellite: "<a href=\"x\">© MapTiler</a>") == "Protomaps © OpenStreetMap · © MapTiler")
        #expect(ImageMarks.creditText(basemap: basemap, satellite: "  ") == "Protomaps © OpenStreetMap")
        #expect(ImageMarks.creditText(basemap: "&copy; OpenStreetMap &amp; co", satellite: nil) == "© OpenStreetMap & co")
        #expect(ImageMarks.creditText(basemap: "&#169; &#xA9;", satellite: nil) == "© ©")
    }

    @Test func theCreditsSizeFollowsTheImagesShorterSideWithinBounds() {
        #expect(abs(ImageMarks.stripMetrics(width: 1080, height: 1920).font - 17.28) < 1e-3)
        #expect(ImageMarks.stripMetrics(width: 500, height: 300).font == 12)
        #expect(ImageMarks.stripMetrics(width: 3840, height: 3840).font == 28)
        #expect(abs(ImageMarks.stripMetrics(width: 3840, height: 3840).margin - 53.76) < 1e-3)
    }

    @Test func theImageReadsDarkUnderTheDarkFlavorOrSatelliteShowing() {
        #expect(ExportStats.dark(darkFlavor: true, satellite: false, satelliteFailed: false))
        #expect(ExportStats.dark(darkFlavor: false, satellite: true, satelliteFailed: false))
        #expect(!ExportStats.dark(darkFlavor: false, satellite: true, satelliteFailed: true))
        #expect(!ExportStats.dark(darkFlavor: false, satellite: false, satelliteFailed: false))
    }

    @Test func captureWaitsForTheCardTheWindowAskedFor() {
        let a = ExportStats.Request(trackIDs: ["a"], width: 1080, height: 1080, dark: false)
        let b = ExportStats.Request(trackIDs: ["a", "b"], width: 1080, height: 1080, dark: false)
        var hold = ExportStats.Hold()
        #expect(hold.ready, "no card wanted")
        let askA = hold.want(a)
        #expect(askA && !hold.ready)
        let again = hold.want(a)
        #expect(!again, "the same request isn't asked again")
        let answeredA = hold.answer(a)
        #expect(answeredA && hold.ready)
        let askB = hold.want(b)
        #expect(askB && !hold.ready)
        let late = hold.answer(a)
        #expect(!late && !hold.ready, "an answer no longer wanted is dropped")
        let answeredB = hold.answer(b)
        #expect(answeredB && hold.ready)
    }

    @Test func showStatsOffAndOnAgainWaitsForTheCardAgain() {
        let a = ExportStats.Request(trackIDs: ["a"], width: 1080, height: 1080, dark: false)
        var hold = ExportStats.Hold()
        _ = hold.want(a)
        _ = hold.answer(a)
        let off = hold.want(nil)
        #expect(!off && hold.ready)
        let on = hold.want(a)
        #expect(on && !hold.ready, "the card dropped with Show stats is fetched again")
    }

    @Test func theImageIsTheLiveMapWithoutSpotsOrATappedPlace() {
        var live = MapState()
        live.mode = .fog
        live.toggles = [Spots.group: true, "bikePaths": true]
        live.vars = ["fogPlace": .string("p1"), "focused": .string("t1")]
        let image = ExportStyle.state(live)
        #expect(image.mode == .fog)
        #expect(image.toggles == [Spots.group: false, "bikePaths": true])
        #expect(image.vars == ["focused": .string("t1")])
    }

    @Test func aSourcesCreditIsReadFromTheStyle() {
        let style = JSONValue.object(["sources": .object(["protomaps": .object(["attribution": .string("© OSM")])])])
        #expect(ImageMarks.attribution(style, source: "protomaps") == "© OSM")
        #expect(ImageMarks.attribution(style, source: "satellite") == nil)
    }
}