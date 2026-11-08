import Foundation
import Testing

@testable import HoldMyTrackCore

/// The Activities panel's decisions that aren't shared rules (those run from
/// testdata/client-rules in ClientRulesTests).
struct PanelTests {
    private func activity(_ id: String, _ type: String = "running", name: String? = nil, description: String? = nil) -> Activity {
        Activity(id: id, startedAt: "2026-10-11T09:39:00Z", activityType: type, name: name, description: description)
    }

    // MARK: Toolbar

    @Test func withNoTargetNothingButTheMasterCheckboxApplies() {
        let use = ToolbarRules.actions(targets: 0, anyPending: false, demo: false)
        #expect([use.visibility, use.edit, use.addToStory, use.delete, use.focus].allSatisfy { $0 == .noTarget })
    }

    @Test func theDemoAccountLooksButCantChange() {
        let use = ToolbarRules.actions(targets: 2, anyPending: true, demo: true)
        #expect(use.visibility == .ready && use.focus == .ready)
        #expect(use.edit == .demo && use.addToStory == .demo && use.delete == .demo)
    }

    @Test func aPendingTargetBlocksDeleteAlone() {
        let use = ToolbarRules.actions(targets: 3, anyPending: true, demo: false)
        #expect(use.delete == .pending && !use.delete.enabled)
        #expect(use.edit == .ready && use.addToStory == .ready)
    }

    @Test func theMasterCheckboxReadsTheListedRows() {
        #expect(ToolbarRules.checkAll(listed: 0, checked: 0) == .none)
        #expect(ToolbarRules.checkAll(listed: 3, checked: 1) == .some)
        #expect(ToolbarRules.checkAll(listed: 3, checked: 3) == .all)
    }

    // MARK: Types

    @Test func anUndescribedTypeFallsBackAsTheServerDoes() {
        let catalog = ActivityTypeCatalog()
        #expect(catalog.label("open_water_swimming") == "Open Water Swimming")
        #expect(catalog.kind("open_water_swimming") == .other)
    }

    @Test func aMergeKeepsWhatEachPartSaysAndReportsChange() {
        var catalog = ActivityTypeCatalog()
        let first = catalog.merge(["running": ActivityTypeInfo(kind: .foot, label: "Run")])
        let again = catalog.merge(["running": ActivityTypeInfo(kind: nil, label: "Run")])
        #expect(first && !again)
        #expect(catalog.kind("running") == .foot && catalog.label("running") == "Run")
        #expect(catalog.missing(["running", "", "cycling", "cycling"]) == ["cycling"])
    }

    @Test func aKindFromANewerServerIsOther() {
        #expect(ActivityKind(wire: "hovercraft") == .other)
        #expect(ActivityKind(wire: "e_scooter") == .eScooter)
        #expect(ActivityKind.foot.showsPace && !ActivityKind.wheels.showsPace)
    }

    @Test func paceAndSpeedNeedADistanceAndATime() {
        #expect(Pace.secondsPerUnit(meters: 0, seconds: 60, unitMeters: 1000) == nil)
        #expect(Pace.speed(meters: 10_000, seconds: nil, unitMeters: 1000) == nil)
        #expect(Pace.format(Pace.secondsPerUnit(meters: 10_000, seconds: 3270, unitMeters: 1000)!) == "5:27")
        #expect(Pace.format(59.5) == "1:00")
        #expect(Pace.speed(meters: 20_000, seconds: 3600, unitMeters: 1000) == 20)
    }

    // MARK: Edit

    @Test func oneActivityWritesAllThreeFieldsOnlyWhenOneChanged() {
        let one = [activity("a", name: "Morning", description: "")]
        #expect(EditPlan.writes(group: one, type: "running", name: " Morning ", description: "").isEmpty)
        #expect(EditPlan.writes(group: one, type: "running", name: "", description: "") == [
            EditPlan.Write(id: "a", activityType: "running", name: "", description: ""),
        ])
    }

    @Test func aGroupWritesAPickedTypeToTheOnesNotOfItAlready() {
        let group = [activity("a", "running", name: "A"), activity("b", "cycling", description: "d")]
        #expect(EditPlan.initialType(group) == "")
        #expect(EditPlan.writes(group: group, type: "", name: "", description: "").isEmpty)
        #expect(EditPlan.writes(group: group, type: "running", name: "ignored", description: "ignored") == [
            EditPlan.Write(id: "b", activityType: "running", name: "", description: "d"),
        ])
    }

    @Test func editRefusesWhatTheServerWould() {
        let one = [activity("a")]
        #expect(EditPlan.invalid(group: one, type: " ", name: "", description: "") == .typeRequired)
        #expect(EditPlan.invalid(group: [activity("a"), activity("b", "cycling")], type: "", name: "", description: "") == nil)
        #expect(EditPlan.invalid(group: one, type: String(repeating: "x", count: 51), name: "", description: "") == .typeTooLong)
        #expect(EditPlan.invalid(group: one, type: "running", name: String(repeating: "x", count: 201), description: "") == .nameTooLong)
        #expect(EditPlan.invalid(group: one, type: "running", name: "", description: String(repeating: "x", count: 2001)) == .descriptionTooLong)
    }

    // MARK: The sheet

    @Test func theSheetsHeightsKeepItsHeadAndTheTopRow() {
        let h = SheetRules.heights(container: 800, topInset: 100, head: 150)
        #expect(h == [.collapsed: 150, .half: 400, .expanded: 700])
        let short = SheetRules.heights(container: 300, topInset: 250, head: 180)
        #expect(short[.expanded] == 180 && short[.half] == 180)
    }

    @Test func aReleaseSettlesOnTheNearestDetentAndAFlickMovesOn() {
        let h = SheetRules.heights(container: 800, topInset: 100, head: 150)
        #expect(SheetRules.resting(height: 380, velocity: 0, heights: h) == .half)
        #expect(SheetRules.resting(height: 380, velocity: 1600, heights: h) == .expanded)
        #expect(SheetRules.resting(height: 380, velocity: -1400, heights: h) == .collapsed)
        #expect(SheetRules.toggled(.collapsed) == .half && SheetRules.toggled(.expanded) == .collapsed)
    }

    // MARK: A tap on the map

    @Test func aTapPicksTheTopmostListedTrack() {
        #expect(TrackTap.pick([nil, "gone", "b", "a"], listed: ["a", "b"]) == "b")
        #expect(TrackTap.pick(["gone"], listed: ["a"]) == nil)
    }

    @Test func aTapAsksTheTracksLines() throws {
        let json = try #require(JSONValue.parse(Data(#"""
        {"views": {}, "groups": [
          {"id": "tracks", "layers": [{"id": "tracks-line", "type": "line"}, {"id": "tracks-arrows", "type": "symbol"}]},
          {"id": "track-bands", "layers": [{"id": "track-bands-line", "type": "line"}]}
        ]}
        """#.utf8)))
        let document = try #require(LayersDocument(json))
        #expect(TrackTap.layerIDs(document) == ["tracks-line"])
    }
}