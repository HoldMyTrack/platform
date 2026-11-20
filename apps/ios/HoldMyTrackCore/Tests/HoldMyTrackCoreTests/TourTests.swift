import Testing

@testable import HoldMyTrackCore

/// The iOS tour's own steps and placement; the rules every client shares run from
/// testdata/client-rules/tour-*.json (ClientRulesTests).
struct TourTests {
    @Test func aRealAccountGetsOneFogStepOnItsLevelMenu() {
        let steps = TourSteps.of(isDemo: false)
        #expect(steps.map(\.id) == ["welcome", "tracks", "range", "trips", "layers", "export", "fog", "record", "sync", "done"])
        let fog = steps.first { $0.id == "fog" }!
        #expect(fog.target == .fogLevel && fog.mode == .fog && fog.card == .fog && fog.view == nil)
        #expect(steps.first { $0.id == "sync" }?.text == "sync")
    }

    @Test func aDemoFliesFogOutLevelByLevel() {
        let steps = TourSteps.of(isDemo: true)
        let fog = steps.filter { $0.mode == .fog }
        #expect(fog.map(\.id) == ["fog", "fog_cities", "fog_counties", "fog_regions", "fog_countries"])
        #expect(fog.map(\.view) == [TourSteps.exact, TourSteps.city, TourSteps.counties, TourSteps.regions, TourSteps.countries])
        #expect(fog.first?.text == "fog_exact" && fog.first?.card == .fog)
        #expect(fog.last?.target == .fogLevel)
        #expect(steps.first { $0.id == "sync" }?.text == "sync_demo")
    }

    @Test func everyStepHasItsOwnTabAndOnlyTheMapsStepsChangeTheMode() {
        for step in TourSteps.of(isDemo: true) where step.tab != .map {
            #expect(step.mode == .normal, "\(step.id)")
        }
        let tabs = TourSteps.of(isDemo: false).map(\.tab)
        #expect(tabs.contains(.trips) && tabs.contains(.sync) && tabs.last == .you)
    }

    @Test func theSheetIsTheStepsOrAtTheEndExactlyTheUsers() {
        let steps = TourSteps.of(isDemo: false)
        #expect(TourSteps.sheet(steps[1], restore: .expanded) == .half)
        #expect(TourSteps.sheet(steps[0], restore: .expanded) == .collapsed)
        #expect(TourSteps.sheet(nil, restore: .expanded) == .expanded)
        #expect(TourSteps.sheet(nil, restore: .collapsed) == .collapsed)
    }

    @Test func aCardSitsOverItsTargetWhenThereIsRoom() {
        #expect(TourSteps.edge(targetTop: 500, cardHeight: 200, topInset: 50, gap: 12) == .top)
        #expect(TourSteps.edge(targetTop: 200, cardHeight: 200, topInset: 50, gap: 12) == .bottom)
        #expect(TourSteps.edge(targetTop: nil, cardHeight: 200, topInset: 50, gap: 12) == .bottom)
    }

    @Test func aFirstTimeCardGoesUnderATargetUpTopAndOverOneBelow() {
        #expect(TourSteps.cardTop(targetTop: 60, targetBottom: 100, cardHeight: 150, height: 800, topInset: 50, gap: 12) == 112)
        #expect(TourSteps.cardTop(targetTop: 600, targetBottom: 700, cardHeight: 150, height: 800, topInset: 50, gap: 12) == 438)
        #expect(TourSteps.cardTop(targetTop: 420, targetBottom: 700, cardHeight: 400, height: 800, topInset: 50, gap: 12) == 50)
        #expect(TourSteps.cardTop(targetTop: nil, targetBottom: nil, cardHeight: 150, height: 800, topInset: 50, gap: 12) == 50)
    }

    @Test func aCardNameThisBuildLacksIsDropped() {
        #expect(TourRules.seenCards(["fog", "stories", "trips"]) == [.fog, .trips])
    }
}