import Testing
@testable import HoldMyTrackCore

/// The Distance slider's steps: one per whole kilometer or mile between its ends.
struct DistanceStepsTests {
    let ends = DistanceRange(min: 1_000, max: 11_000)
    let miles = DistanceRange(min: 1_609.344, max: 16_093.44)

    @Test func oneStepPerKilometer() {
        #expect(DistanceSteps.count(ends, imperial: false) == 10)
        #expect(DistanceSteps.meters(4, ends: ends, imperial: false) == 5_000)
        #expect(DistanceSteps.step(5_000, ends: ends, imperial: false) == 4)
    }

    @Test func oneStepPerMile() {
        #expect(DistanceSteps.count(miles, imperial: true) == 9)
        #expect(abs(DistanceSteps.meters(4, ends: miles, imperial: true) - 8_046.72) < 1e-6)
    }

    @Test func theEndStepsAreTheEndsExactly() {
        #expect(DistanceSteps.meters(0, ends: miles, imperial: true) == miles.min)
        #expect(DistanceSteps.meters(9, ends: miles, imperial: true) == miles.max)
    }

    @Test func bothKnobsAtTheEndsAreNoFilter() {
        let lower = DistanceSteps.meters(0, ends: ends, imperial: false)
        let upper = DistanceSteps.meters(10, ends: ends, imperial: false)
        let min = TrackFacets.nextDistanceFilter(bounds: ends, current: ends, knob: .min, value: lower, imperial: false)
        #expect(TrackFacets.nextDistanceFilter(bounds: ends, current: min ?? ends, knob: .max, value: upper, imperial: false) == nil)
    }

    @Test func aDistanceOutsideTheEndsIsAnEndStep() {
        #expect(DistanceSteps.step(0, ends: ends, imperial: false) == 0)
        #expect(DistanceSteps.step(99_000, ends: ends, imperial: false) == 10)
    }

    @Test func equalEndsHaveOneStep() {
        let one = DistanceRange(min: 5_000, max: 5_000)
        #expect(DistanceSteps.count(one, imperial: false) == 1)
        #expect(DistanceSteps.meters(1, ends: one, imperial: false) == 5_000)
    }
}
