import Foundation
import Testing

import HoldMyTrackCore

/// What the Sync tab lists and offers (apps/android/docs/SPEC.md FR-3.2, FR-3.4).
struct SyncListTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func track(_ id: String, hours: Double, type: String = "walk", meters: Double = 1000, sent: Bool = false) -> RecordedTrack {
        RecordedTrack(id: id, startedAt: t0.addingTimeInterval(hours * 3600), endedAt: t0.addingTimeInterval(hours * 3600 + 600),
                      movingSeconds: 600, meters: meters, type: type, points: [], sent: sent)
    }

    private var walks: [RecordedTrack] {
        [track("old", hours: 0), track("new", hours: 2, type: "ride", meters: 5000), track("mid", hours: 1), track("away", hours: 3, sent: true)]
    }

    @Test func newestFirstWithWhatsOnItsWayListedButNeverTickable() {
        let list = SyncList.of(walks, hidden: [], showHidden: false, types: [], ticked: [])
        #expect(list.shown.map(\.id) == ["away", "new", "mid", "old"])
        #expect(list.tickable.map(\.id) == ["new", "mid", "old"])
    }

    @Test func aHiddenRowShowsOnlyWithShowHiddenAndIsNeverTickable() {
        let hidden = SyncList.of(walks, hidden: ["mid"], showHidden: false, types: [], ticked: ["mid"])
        #expect(!hidden.shown.contains { $0.id == "mid" })
        #expect(hidden.hiddenCount == 1)
        #expect(hidden.sendable.isEmpty, "a hidden row isn't sent even if it was ticked")
        let shown = SyncList.of(walks, hidden: ["mid"], showHidden: true, types: [], ticked: [])
        #expect(shown.shown.contains { $0.id == "mid" })
        #expect(!shown.tickable.contains { $0.id == "mid" })
    }

    @Test func chipsNarrowTheListAndAPickNoLongerListedCountsForNothing() {
        let list = SyncList.of(walks, hidden: [], showHidden: false, types: ["ride"], ticked: [])
        #expect(list.types == ["ride", "walk"])
        #expect(list.shown.map(\.id) == ["new"])
        let gone = SyncList.of(walks, hidden: [], showHidden: false, types: ["swim"], ticked: [])
        #expect(gone.shown.count == 4, "a chip for no listed type filters nothing")
        #expect(gone.pickedTypes(["swim", "walk"]) == ["walk"])
    }

    @Test func onlyWhatsTickedAndShownIsSent() {
        let list = SyncList.of(walks, hidden: [], showHidden: false, types: ["walk"], ticked: ["new", "mid", "away"])
        #expect(list.sendable.map(\.id) == ["mid"], "a ride filtered out and one on its way aren't sent")
        #expect(list.sendableMeters == 1000)
    }

    @Test func selectAllTicksEveryTickableRowAndThenUnticksThem() {
        let list = SyncList.of(walks, hidden: [], showHidden: false, types: [], ticked: [])
        #expect(!list.allTicked([]))
        let all = list.toggleAll([])
        #expect(all == ["new", "mid", "old"])
        #expect(list.allTicked(all))
        #expect(list.toggleAll(all).isEmpty)
        #expect(!SyncList.of([], hidden: [], showHidden: false, types: [], ticked: []).allTicked([]), "nothing to tick reads Select all")
    }

    @Test func aRowBeingSentIsNeitherTickedEditedNorSwipedAndNoRowIsSwipedMeanwhile() {
        let list = SyncList.of(walks, hidden: [], showHidden: false, types: [], ticked: ["new", "mid"], inFlight: ["new", "mid"])
        #expect(list.tickable.map(\.id) == ["old"], "Select all leaves the send alone")
        #expect(list.sendable.isEmpty)
        #expect(!list.canTick(walks[1]))
        #expect(!list.canEdit(walks[1]))
        #expect(list.canEdit(walks[0]), "a row outside the send is still edited")
        #expect(!list.canSwipe(walks[0]))
        let idle = SyncList.of(walks, hidden: [], showHidden: false, types: [], ticked: [])
        #expect(idle.canSwipe(walks[0]))
        #expect(!idle.canSwipe(walks[3]), "not one on its way")
        #expect(!idle.canEdit(walks[3]))
    }

    @Test func theDemoTicksNothing() {
        let list = SyncList.of(walks, hidden: [], showHidden: false, types: [], ticked: [], isDemo: true)
        #expect(list.tickable.isEmpty)
        #expect(!list.canTick(walks[0]))
        #expect(list.toggleAll([]).isEmpty)
    }

    @Test func aSwipeHidesAndASecondBringsItBackAndALeftRecordingIsForgotten() {
        #expect(SyncHidden.swiped("a", in: []) == ["a"])
        #expect(SyncHidden.swiped("a", in: ["a"]).isEmpty)
        #expect(SyncHidden.setting("a", hidden: false, in: ["a"]).isEmpty, "Undo puts back what was, whatever happened since")
        #expect(SyncHidden.setting("a", hidden: true, in: ["a"]) == ["a"])
        #expect(SyncHidden.pruned(["a", "gone"], present: [track("a", hours: 0)]) == ["a"])
    }
}