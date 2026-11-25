import Testing

@testable import HoldMyTrackCore

/// Library's own decisions beyond the shared cases (testdata/client-rules/library-*.json).
struct LibraryRulesTests {
    @Test func downloadNamesTheFirstRowItCantTake() {
        #expect(LibraryRules.downloadBlocked([("a", nil), ("b", "too_long")]) == nil, "a reason Download doesn't know isn't Download's")
        let blocked = LibraryRules.downloadBlocked([("a", nil), ("b", "no_original"), ("c", "pending")])
        #expect(blocked?.id == "b")
        #expect(blocked?.why == .noOriginal)
        #expect(LibraryRules.downloadBlocked([("p", "private")])?.why == .private)
    }

    @Test func theSliderStaysInsideBoundsThatShrank() {
        let bounds = DistanceRange(min: 1000, max: 20000)
        #expect(LibraryRules.sliderRange(.init(min: 5000, max: 10000), bounds: bounds) == DistanceRange(min: 5000, max: 10000))
        #expect(LibraryRules.sliderRange(.init(min: 0, max: nil), bounds: bounds) == bounds, "an open top is the longest")
        #expect(LibraryRules.sliderRange(.init(min: 30000, max: 40000), bounds: bounds) == DistanceRange(min: 20000, max: 20000))
        #expect(LibraryRules.sliderRange(.init(min: 500, max: 800), bounds: bounds) == DistanceRange(min: 1000, max: 1000))
    }

    @Test func aFilterChangeGoesBackToPageOne() {
        let state = LibraryRules.State(page: 3)
        #expect(state.withFilter { $0.q = "lake" } == LibraryRules.State(page: 1, q: "lake"))
    }
}
