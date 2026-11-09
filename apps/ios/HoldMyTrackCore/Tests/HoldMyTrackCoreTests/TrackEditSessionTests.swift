import Foundation
import Testing

@testable import HoldMyTrackCore

/// One Edit track session (root docs/SPEC.md FR-5.14, FR-5.17), as Android's TrackEditor runs it.
struct TrackEditSessionTests {
    /// Five points a second apart along a meridian.
    private let points = (0..<5).map { TrackPoint(lon: 10, lat: 50 + Double($0) * 0.001, t: 1000 * ($0 + 1)) }

    @Test func theKnobsStartAtTheEndsAndOfferNothingToChop() {
        let session = TrackEditSession(points: points, base: nil)
        #expect(session.knobs(in: session.visible) == (0, 4))
        #expect(session.chopOp == nil)
        #expect(session.splitIndex == nil)
        #expect(!session.changed)
    }

    @Test func choppingKeepsTheKnobsStretchAndUndoBringsItBack() {
        var session = TrackEditSession(points: points, base: nil)
        session.setKnobs(lo: 1, hi: 3)
        session.chop()
        #expect(session.visible.map(\.t) == [2000, 3000, 4000])
        #expect(session.pending == TrackEdit(keep: TimeSpan(2000, 4000)))
        #expect(session.knobs(in: session.visible) == (0, 2), "a step puts the knobs back at the ends")
        session.undo()
        #expect(session.visible.count == 5)
        #expect(!session.changed)
    }

    @Test func theKnobsFollowTheirPointsWhenAnotherIsDeleted() {
        var session = TrackEditSession(points: points, base: nil)
        session.drop(1000)
        session.setKnobs(lo: 1, hi: 2)
        let visible = session.visible
        #expect(visible[session.knobs(in: visible).lo].t == 3000)
    }

    @Test func aTrackKeepsTwoPoints() {
        var session = TrackEditSession(points: Array(points.prefix(2)), base: nil)
        session.drop(1000)
        #expect(!session.changed)
    }

    @Test func oneMovedKnobSplitsAndTheOtherToolsWaitForUndo() {
        var session = TrackEditSession(points: points, base: nil)
        session.setKnobs(lo: 2, hi: 4)
        #expect(session.splitIndex == 2)
        session.split()
        #expect(session.splitAt == 3000)
        #expect(session.pending == nil, "a split isn't part of the edit")
        #expect(session.chopOp == nil && session.cutOp == nil && session.splitIndex == nil)
        session.drop(4000)
        #expect(session.visible.count == 5, "point tools wait while a split is made")
        session.undo()
        #expect(session.splitAt == nil)
    }

    @Test func resetIsAStepOverTheSavedEdit() {
        var session = TrackEditSession(points: points, base: TrackEdit(drop: [3000]))
        #expect(session.canReset)
        session.reset()
        #expect(session.pending == nil)
        #expect(session.changed)
        session.undo()
        #expect(session.visible.count == 4)
    }

    @Test func aMoveIsRoundedToTheServersPrecision() {
        var session = TrackEditSession(points: points, base: nil)
        session.move(2000, lon: 10.12345678, lat: 50.00149999)
        #expect(session.pending?.move[2000] == [10.123457, 50.0015])
    }

    @Test func theDrawingDashesWhatChopOrCutWouldTakeOut() {
        let chop = TrackEditDrawing.shape(points, lo: 1, hi: 3, preview: .chop, split: nil)
        #expect(chop.lines.map(\.role) == ["preview", "kept", "preview"])
        #expect(chop.points.map(\.removed) == [true, false, false, false, true])
        #expect(chop.knobs.map(\.t) == [2000, 4000])
        let cut = TrackEditDrawing.shape(points, lo: 1, hi: 3, preview: .cut, split: nil)
        #expect(cut.lines.map(\.role) == ["kept", "kept", "kept", "preview"])
        #expect(cut.points.map(\.removed) == [false, false, true, false, false])
        let split = TrackEditDrawing.shape(points, lo: 2, hi: 4, preview: .chop, split: 2)
        #expect(split.lines.map(\.role) == ["kept", "second"])
        #expect(split.knobs.map(\.t) == [3000])
        #expect(split.points.map(\.second) == [false, false, false, true, true])
    }

    @Test func availabilityIsTheServersAnswerForOneActivity() {
        let ok = Activity(id: "a", startedAt: "", activityType: "ride")
        let pending = Activity(id: "b", startedAt: "", activityType: "ride", trackEdit: "pending", photosBlock: "no_original")
        #expect(EditAvailability.track([ok]) == nil)
        #expect(EditAvailability.track([ok, pending]) == .checkOne)
        #expect(EditAvailability.track([pending]) == .pending)
        #expect(EditAvailability.photos([pending]) == .noOriginal)
        #expect(EditAvailability.track([Activity(id: "c", startedAt: "", activityType: "ride", trackEdit: "from_the_future")]) == nil)
    }
}
