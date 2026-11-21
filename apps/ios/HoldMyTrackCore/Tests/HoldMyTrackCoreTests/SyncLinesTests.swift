import Foundation
import Testing

@testable import HoldMyTrackCore

/// The Sync tab's recordings on the map, and which rows cover the same time.
struct SyncLinesTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func track(_ id: String, minutes: Double, length: Double = 30, points: Int = 3) -> RecordedTrack {
        let start = t0.addingTimeInterval(minutes * 60)
        return RecordedTrack(id: id, startedAt: start, endedAt: start.addingTimeInterval(length * 60), movingSeconds: length * 60, meters: 1000, type: "walk",
                             points: (0..<points).map { RecordedPoint(lat: 50 + Double($0) / 100, lon: 10 - Double($0) / 100, ele: nil, time: start) })
    }

    private let document = LayersDocument(JSONValue.parse(Data("""
    {"styleBuild": "b1", "views": {}, "groups": [
      {"id": "tracks", "layers": [
        {"id": "tracks-casing", "type": "line", "source": "tracks", "minzoom": 4, "metadata": {"holdmytrack:role": "casing"},
         "layout": {"line-cap": "round"}, "paint": {"line-color": "#202b25", "line-width": 7.5}},
        {"id": "tracks-line", "type": "line", "source": "tracks", "minzoom": 4, "metadata": {"holdmytrack:role": "track"},
         "paint": {"line-color": "#b07e2e", "line-width": 2.5}},
        {"id": "tracks-focused", "type": "line", "source": "tracks", "minzoom": 4, "metadata": {"holdmytrack:role": "focused"},
         "paint": {"line-color": "#b07e2e", "line-width": 4.5}}]},
      {"id": "route-bands", "layers": [
        {"id": "route-bands-line", "type": "line", "source": "route-bands", "filter": ["has", "band"], "metadata": {"holdmytrack:role": "pace-bands"},
         "paint": {"line-width": 6}}]}]}
    """.utf8))!)!

    @Test func theGroupIsDashedInTheTracksColorWithTheFocusedLookForThePickedOne() throws {
        let added = SyncLines.adding(to: document)
        let group = try #require(added.groups.last)
        #expect(group.id == SyncLines.group)
        #expect(group.layers.map { $0["id"]?.string } == ["sync-candidates-halo", "sync-candidates-line", "sync-candidates-highlight", "sync-candidates-bands"])
        #expect(group.layers[3]["source"] == .string(SyncLines.bandsSource))
        #expect(group.layers[3]["filter"] == .array([.string("has"), .string("band")]), "only the runs, not the arrows' route")
        #expect(group.layers[0]["paint"]?["line-width"] == .number(7.5), "the halo is the casing")
        #expect(group.layers[1]["paint"]?["line-color"] == .string("#b07e2e"))
        #expect(group.layers[1]["paint"]?["line-dasharray"] != nil)
        #expect(group.layers[2]["paint"]?["line-width"] == .number(4.5), "the picked one is the focused line")
        #expect(group.layers.allSatisfy { $0["minzoom"] == .number(4) }, "from the zoom tracks start at")
        #expect(group.sources.keys.sorted() == [SyncLines.group, SyncLines.bandsSource])
        #expect(SyncLines.adding(to: added).groups.count == added.groups.count, "added once")
    }

    @Test func composedTheLinesHaveTheirGeoJSONSource() {
        var state = MapState()
        state.geojson[SyncLines.group] = SyncLines.features([track("a", minutes: 0)], highlight: nil)
        let style = JSONValue.parse(Data(#"{"version": 8, "sources": {}, "layers": [{"id": "bg", "type": "background"}]}"#.utf8))!
        let composed = MapStyle.compose(style: style, document: SyncLines.adding(to: document), state: state, apiBase: URL(string: "http://localhost")!)
        #expect(composed["sources"]?[SyncLines.group]?["data"]?["features"]?.array?.count == 1)
    }

    @Test func thePickedLineIsLastAndOneWithoutALineIsLeftOut() {
        let features = SyncLines.features([track("a", minutes: 0), track("b", minutes: 60), track("dot", minutes: 120, points: 1)], highlight: "a")
        let list = features["features"]?.array ?? []
        #expect(list.map { $0["properties"]?["key"]?.string } == ["b", "a"])
        #expect(list.last?["properties"]?["role"] == .string("highlight"))
        #expect(list.first?["geometry"]?["coordinates"]?.array?.first == .array([.number(10), .number(50)]), "longitude first")
    }

    @Test func theBoxHoldsEveryPoint() {
        #expect(SyncLines.box([track("a", minutes: 0)]) == [9.98, 50, 10, 50.02])
        #expect(SyncLines.box([]) == nil)
    }

    @Test func rowsCoveringTheSameTimeFindEachOtherNewestFirst() {
        let a = track("a", minutes: 0), b = track("b", minutes: 1), c = track("c", minutes: 2), far = track("far", minutes: 600)
        let found = SyncSimilar.waiting([a, b, c, far])
        #expect(found["a"]?.map(\.id) == ["c", "b"])
        #expect(found["far"] == nil)
    }

    @Test func theAccountsTrackOpensOnItsOwnDay() {
        let late = TrackOverlap(trackID: "t", name: "", trackType: "walk", startedAt: "2026-11-21T03:30:00Z", timezone: "America/New_York")
        #expect(late.day(accountZone: "Europe/Berlin") == "2026-11-20", "its own zone first")
        let unzoned = TrackOverlap(trackID: "t", name: "", trackType: "walk", startedAt: "2026-11-21T03:30:00.000Z", timezone: nil)
        #expect(unzoned.day(accountZone: "Europe/Berlin") == "2026-11-21")
        #expect(TrackOverlap(trackID: "t", name: "", trackType: "walk", startedAt: "garbage", timezone: nil).day(accountZone: nil) == nil)
    }

    @Test func aRowsInfoCountsTheOtherRowsAndTheAccountsTrackAndTheBarCountsTickedDoubles() {
        let a = track("a", minutes: 0), b = track("b", minutes: 1), c = track("c", minutes: 600)
        let waiting = SyncSimilar.waiting([a, b, c])
        #expect(SyncSimilar.count(a, waiting: waiting, onMap: true) == 2)
        #expect(SyncSimilar.count(c, waiting: waiting, onMap: false) == 0)
        var sent = a
        sent.sent = true
        #expect(SyncSimilar.count(sent, waiting: waiting, onMap: true) == 0, "none for one on its way")
        #expect(SyncSimilar.doubled([a, b, c], waiting: waiting) == 2)
        #expect(SyncSimilar.doubled([a, c], waiting: waiting) == 0, "a double left unticked isn't counted")
    }

    @Test func onlyThePickedRowIsBanded() {
        let a = track("a", minutes: 0), b = track("b", minutes: 60)
        #expect(SyncLines.bands([a, b], highlight: nil)["features"]?.array?.isEmpty == true)
        let banded = SyncLines.bands([a, b], highlight: "b")["features"]?.array ?? []
        #expect(banded.contains { $0["properties"]?["band"] != nil })
    }
}
