import Foundation
import Testing

import HoldMyTrackCore

/// What the Sync tab lists and offers (apps/docs/SPEC.md FR-3.2, FR-3.4).
struct SyncListTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func track(_ id: String, hours: Double, type: String = "walk", meters: Double = 1000, sent: Bool = false) -> RecordedTrack {
        RecordedTrack(id: id, startedAt: t0.addingTimeInterval(hours * 3600), endedAt: t0.addingTimeInterval(hours * 3600 + 600),
                      movingSeconds: 600, meters: meters, type: type, points: [], sent: sent)
    }

    private var walks: [RecordedTrack] {
        [track("old", hours: 0), track("new", hours: 2, type: "ride", meters: 5000), track("mid", hours: 1), track("away", hours: 3, sent: true)]
    }

    @Test func newestFirstWithWhatsOnItsWayListed() {
        let list = SyncList.of(walks, hidden: [], showHidden: false, types: [])
        #expect(list.shown.map(\.id) == ["away", "new", "mid", "old"])
    }

    @Test func aHiddenRowShowsOnlyWithShowHidden() {
        let hidden = SyncList.of(walks, hidden: ["mid"], showHidden: false, types: [])
        #expect(!hidden.shown.contains { $0.id == "mid" })
        #expect(hidden.hiddenCount == 1)
        let shown = SyncList.of(walks, hidden: ["mid"], showHidden: true, types: [])
        #expect(shown.shown.contains { $0.id == "mid" })
    }

    @Test func chipsNarrowTheListAndAPickNoLongerListedCountsForNothing() {
        let list = SyncList.of(walks, hidden: [], showHidden: false, types: ["ride"])
        #expect(list.types == ["ride", "walk"])
        #expect(list.shown.map(\.id) == ["new"])
        let gone = SyncList.of(walks, hidden: [], showHidden: false, types: ["swim"])
        #expect(gone.shown.count == 4, "a chip for no listed type filters nothing")
        #expect(gone.pickedTypes(["swim", "walk"]) == ["walk"])
    }

    @Test func aRowBeingSentOrOnItsWayIsNeitherEditedNorSwiped() {
        let list = SyncList.of(walks, hidden: [], showHidden: false, types: [], inFlight: ["new"])
        #expect(!list.canEdit(walks[1]) && !list.canSwipe(walks[1]), "being sent")
        #expect(!list.canEdit(walks[3]) && !list.canSwipe(walks[3]), "on its way")
        #expect(list.canEdit(walks[0]) && list.canSwipe(walks[0]), "a row outside the send is still the user's")
    }

    @Test func onlyRowsTheListShowsAreComparedAndDrawn() {
        let list = SyncList.of(walks, hidden: ["mid"], showHidden: true, types: ["walk"], inFlight: ["old"])
        #expect(list.comparable.isEmpty, "a ride filtered out, a hidden row, one on its way and one being sent are no one's double")
        #expect(list.drawn.map(\.id) == ["mid", "old"], "what's on its way isn't drawn")
    }

    @Test func aSwipeHidesAndASecondBringsItBack() {
        #expect(SyncHidden.swiped("a", in: []) == ["a"])
        #expect(SyncHidden.swiped("a", in: ["a"]).isEmpty)
        #expect(SyncHidden.setting("a", hidden: false, in: ["a"]).isEmpty, "Undo puts back what was, whatever happened since")
        #expect(SyncHidden.setting("a", hidden: true, in: ["a"]) == ["a"])
    }
}