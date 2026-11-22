import Testing
@testable import HoldMyTrackCore

/// The Distance slider's steps between the shortest and longest track.
struct DistanceStepsTests {
    let bounds = DistanceRange(min: 1_200, max: 10_400)

    @Test func theEndStepsAreTheEndsExactly() {
        #expect(DistanceSteps.meters(0, bounds: bounds) == 1_200)
        #expect(DistanceSteps.meters(DistanceSteps.count, bounds: bounds) == 10_400)
    }

    @Test func bothKnobsAtTheEndsAreNoFilter() {
        let lower = DistanceSteps.meters(0, bounds: bounds)
        let upper = DistanceSteps.meters(DistanceSteps.count, bounds: bounds)
        let min = TrackFacets.nextDistanceFilter(bounds: bounds, current: bounds, knob: .min, value: lower)
        #expect(TrackFacets.nextDistanceFilter(bounds: bounds, current: min ?? bounds, knob: .max, value: upper) == nil)
    }

    @Test func aStepMapsToItsShareOfTheRangeAndBack() {
        #expect(DistanceSteps.meters(500, bounds: bounds) == 5_800)
        #expect(DistanceSteps.step(5_800, bounds: bounds) == 500)
        #expect(DistanceSteps.step(0, bounds: bounds) == 0)
        #expect(DistanceSteps.step(99_000, bounds: bounds) == DistanceSteps.count)
    }

    @Test func aRangeOfOneDistanceHasOneStep() {
        #expect(DistanceSteps.step(5, bounds: DistanceRange(min: 5, max: 5)) == 0)
    }
}
