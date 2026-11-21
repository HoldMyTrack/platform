import Testing

@testable import HoldMyTrackCore

/// The iOS tour's own steps and placement; the rules every client shares run from
/// testdata/client-rules/tour-*.json (ClientRulesTests).
struct TourTests {
    @Test func aRealAccountGetsOneFogStepOnItsLevelMenu() {
        let steps = TourSteps.of(isDemo: false)
        #expect(steps.map(\.id) == ["welcome", "tracks", "range", "trips", "layers", "places", "export", "fog", "record", "sync", "done"])
        let fog = steps.first { $0.id == "fog" }!
        #expect(fog.target == .fogLevel && fog.mode == .fog && fog.card == .fog && fog.view == nil)
        let sync = steps.first { $0.id == "sync" }!
        #expect(sync.text == "sync")
        #expect(sync.target == .sheet && sync.tab == .sync && sync.sheet, "the Sync tab's sheet, half open, as on Android")
        #expect(steps.first { $0.id == "places" }?.target == .places, "Places is a step of its own, after Layers")
    }

    @Test func theLayersAndPlacesStepsEachHoldTheirMenuOpenAndTheEndLetsGo() {
        let steps = TourSteps.of(isDemo: false)
        let layers = steps.first { $0.id == "layers" }
        #expect(TourSteps.menus(layers).map(\.open) == [true, false, false])
        #expect(TourSteps.menus(steps.first { $0.id == "places" }).map(\.open) == [false, true, false])
        #expect(TourSteps.menus(steps.first { $0.id == "fog" }).map(\.open) == [false, false, true], "Fog's step opens its level menu")
        let demo = TourSteps.of(isDemo: true).filter { $0.menu == .fogLevel }.map(\.id)
        #expect(demo == ["fog_countries"], "the demo's last Fog step opens it")
        #expect(TourSteps.menus(steps.first { $0.id == "export" }).allSatisfy { !$0.open })
        #expect(TourSteps.menus(nil).allSatisfy { !$0.open })
    }

    @Test func aHoldTakesOverTheUsersMenuAndLetsGoOnlyOfItsOwn() {
        #expect(MenuHold.next(isOpen: false, held: false, want: true, canOpen: true) == .openHeld)
        #expect(MenuHold.next(isOpen: true, held: false, want: true, canOpen: true) == .reopenHeld)
        #expect(MenuHold.next(isOpen: true, held: true, want: true, canOpen: true) == MenuHold.none)
        #expect(MenuHold.next(isOpen: false, held: false, want: true, canOpen: false) == MenuHold.none, "nothing to show yet")
        #expect(MenuHold.next(isOpen: true, held: true, want: false, canOpen: true) == .close)
        #expect(MenuHold.next(isOpen: true, held: false, want: false, canOpen: true) == MenuHold.none, "the user's own stays")
    }

    @Test func aDemoFliesFogOutLevelByLevel() {
        let steps = TourSteps.of(isDemo: true)
        let fog = steps.filter { $0.mode == .fog }
        #expect(fog.map(\.id) == ["fog", "fog_cities", "fog_counties", "fog_regions", "fog_countries"])
        #expect(fog.map(\.view) == [TourSteps.exact, TourSteps.city, TourSteps.counties, TourSteps.regions, TourSteps.countries])
        #expect(fog.first?.text == "fog_exact" && fog.first?.card == .fog)
        #expect(fog.last?.target == .fogLevel)
        #expect(steps.first { $0.id == "sync" }?.text == "sync_demo")
        #expect(steps.first { $0.id == "record" }?.text == "record_demo", "the demo can't send what it records")
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