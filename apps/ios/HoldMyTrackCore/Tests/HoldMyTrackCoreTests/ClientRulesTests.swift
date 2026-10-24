import Foundation
import Testing

@testable import HoldMyTrackCore

/// The rules every client implements alike, run against the shared cases in
/// testdata/client-rules (its README has the format), so a rule can't change here without the
/// web's and Android's failing too (ADR-0049).
struct ClientRulesTests {
    static let dir = Contract().root.appending(path: "testdata/client-rules")

    /// Every file whose clients, when it names any, include iOS.
    static let files: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().filter { name in
            guard let clients = load(name)["clients"].list else { return true }
            return clients.contains("ios")
        }
    }()

    static func load(_ name: String) -> RuleJSON {
        let data = try! Data(contentsOf: dir.appending(path: name))
        return RuleJSON(try! JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Rules not ported yet; empty once every one is.
    static let unported: Set<String> = [
        "photoScope", "photoGroup", "photoClusters", "photoMarkerSize", "photoMarkerLayout",
        "photoTrackPoint", "photoTrackFraction", "photoTrackStart", "photoFit", "photoZoom", "photoPan", "photoClamp",
        "editTrackFold", "editTrackApply", "editTrackChop", "editTrackCut", "editTrackSplitIndex", "editTrackSplitPoint",
        "editTrackMove", "editTrackDistances",
    ]

    @Test func everyRuleFileHasASwiftImplementation() {
        #expect(!Self.files.isEmpty, "no cases in \(Self.dir.path)")
        for name in Self.files {
            let rule = Self.load(name)["rule"].string ?? "?"
            #expect(rules[rule] != nil || Self.unported.contains(rule), "\(name): no Swift implementation of \(rule)")
        }
    }

    @Test(arguments: files)
    func casesHold(file: String) throws {
        let doc = Self.load(file)
        let rule = doc["rule"].string!
        guard let run = rules[rule] else { return }
        let cases = (doc["cases"].list ?? []) + (doc["generated"].list ?? [])
        var failures = 0
        for item in cases where failures < 5 {
            let name = "\(rule): \(item["name"].string ?? "?")"
            let expected = item["expected"]
            if expected["throws"].bool == true {
                #expect(throws: (any Error).self, Comment(rawValue: name)) { _ = try run(item["input"]) }
                continue
            }
            let actual: RuleJSON
            do { actual = try run(item["input"]) } catch {
                Issue.record("\(name): threw \(error)")
                failures += 1
                continue
            }
            let tolerance = item["tolerance"].double ?? doc["tolerance"].double ?? 0
            if let difference = expected.normalized.difference(from: actual.normalized, tolerance: tolerance) {
                Issue.record("\(name)\(difference)\n  input: \(item["input"])")
                failures += 1
            }
        }
    }
}

/// Each rule, from a case's input to the JSON its expected value is written in.
let rules: [String: @Sendable (RuleJSON) throws -> RuleJSON] = [
    "defaultRange": { input in
        rangeJSON(DefaultRange.of(input.strings("visibleDays"), earliest: input["earliest"].string, today: input["today"].string!))
    },
    "rangeShift": { input in
        switch RangeShift.of(days: input.strings("days"), hasEarlier: input["hasEarlier"].bool!, range: range(input["range"]), dir: input.int("dir")) {
        case .shifted(let range): rangeJSON(range)
        case .none: nil
        case .load: "load"
        }
    },
    "pendingChange": { input in
        let change = PendingDiff.of(previous: Set(input.strings("previous")), now: Set(input.strings("now")), awaiting: Set(input.strings("awaiting")))
        return ["started": .bool(change.started), "finished": .bool(change.finished), "left": .ids(change.left), "landed": .ids(change.landed), "awaiting": .ids(change.awaiting)]
    },
    "pendingCheck": { input in
        let watched = PendingDiff.watched(listed: input.strings("listed"), awaiting: input.strings("awaiting"))
        return ["watched": .list(watched), "moved": .bool(PendingDiff.moved(watched: watched, stillPending: input.strings("stillPending")))]
    },
    "boldTracks": { input in .ids(PanelRules.boldIDs(checked: Set(input.strings("checked")), focused: input["focused"].string)) },
    "toolbarTarget": { input in .ids(PanelRules.targetIDs(checked: Set(input.strings("checked")), focused: input["focused"].string)) },
    "targetVisibility": { input in .ids(PanelRules.toggledVisibility(hidden: Set(input.strings("hidden")), target: Set(input.strings("target")))) },
    "distanceBounds": { input in distanceJSON(ActivityFacets.distanceBounds(activities(input["activities"]))) },
    "distanceFilter": { input in
        let knob: DistanceKnob = input["knob"].string == "min" ? .min : .max
        return distanceJSON(ActivityFacets.nextDistanceFilter(bounds: distance(input["bounds"])!, current: distance(input["current"])!, knob: knob, value: input.number("value")))
    },
    "typeFacets": { input in
        .array(ActivityFacets.typeFacets(activities(input["activities"]), distanceFilter: distance(input["distanceFilter"])).map { ["type": .string($0.type), "count": .num($0.count)] })
    },
    "passesFilters": { input in
        .bool(ActivityFacets.passesFilters(activity(input["activity"]), excludedTypes: Set(input.strings("excludedTypes")), distanceFilter: distance(input["distanceFilter"])))
    },
    "sliderLayout": { input in
        let layout = SliderRules.layout(width: input.int("width"), finePointer: input["finePointer"].bool!)
        return ["buttons": .bool(layout.buttons), "days": .num(layout.days)]
    },
    "sliderBoundaries": { input in
        let (start, end) = SliderRules.boundaries(sliderWindow(input), range(input["range"]))
        return ["start": .num(start), "end": .num(end)]
    },
    "sliderMoveKnob": { input in
        let knob: SliderRules.Knob = input["knob"].string == "start" ? .start : .end
        return rangeJSON(SliderRules.moveKnob(sliderWindow(input), range(input["range"]), knob: knob, to: input.int("boundary")))
    },
    "sliderTicks": { input in
        .array(SliderRules.ticks(input.strings("days")).map { tick in
            ["boundary": .num(tick.boundary), "kind": tick.monthStart ? "month" : "day", "month": tick.month.map { .num($0) } ?? nil]
        })
    },
    "sliderPanLand": { input in
        rangeJSON(SliderRules.panLand(days: input.strings("days"), range: range(input["range"]), start: input["start"].bool!, end: input["end"].bool!))
    },
    "sliderWindowFit": { input in
        .num(SliderRules.windowFit(count: input.int("count"), windowDays: input.int("windowDays"), left: input.int("left"), first: input.int("first"), last: input.int("last"), dir: input.int("dir")))
    },
    "panelState": { input in
        let all = (input["activities"].list ?? []).map { activity($0) }
        let state = input["state"]
        var panel = PanelState()
        panel.setActivities(all)
        // Hidden first: hiding goes through the toolbar's target, the checked group.
        for id in state.strings("hidden") { panel.toggleChecked(id) }
        panel.toggleTargetVisibility()
        panel.clearChecked()
        for id in state.strings("checked") { panel.toggleChecked(id) }
        if let focused = state["focused"].string { panel.focus(focused) }
        for type in state.strings("excludedTypes") { panel.toggleType(type) }
        panel.distanceFilter = distance(state["distanceFilter"])
        let event = input["event"]
        switch event["type"].string {
        case "checkToggled": panel.toggleChecked(event["id"].string!)
        case "checkAll": panel.checkAll()
        case "checksCleared": panel.clearChecked()
        case "checksInverted": panel.invertChecked()
        case "visibilityToggled": panel.toggleTargetVisibility()
        case "typeToggled": panel.toggleType(event["activityType"].string!)
        case "distanceSet": panel.distanceFilter = distance(event["filter"])
        case "filtersReset": panel.resetFilters()
        case "listLoaded":
            let ids = Set(event.strings("ids"))
            panel.setActivities(all.filter { ids.contains($0.id) })
        case "rangePicked": panel.resetForNewRange()
        case let type: throw RuleError("no iOS event \(type ?? "?")")
        }
        return [
            "checked": .ids(panel.checked), "focused": .opt(panel.focused), "hidden": .ids(panel.hidden),
            "excludedTypes": .ids(panel.excludedTypes), "distanceFilter": distanceJSON(panel.distanceFilter),
        ]
    },
    "session": { input in
        let state = input["state"]
        var session = MapSession()
        if state["range"].object != nil { session.restore(range(state["range"]), picked: state["userPicked"].bool ?? false) }
        // The Story first: opening one resets the selection set up below.
        if let story = state["storyId"].string {
            session.enterStory(story)
            _ = session.consumeFly()
        }
        var seen = Set<String>()
        let ids = (state.strings("checked") + state.strings("hidden")).filter { seen.insert($0).inserted }
        session.panel.setActivities(ids.map { ActivitySummary(id: $0, activityType: "walking", distanceMeters: 1000, isPrivate: false) })
        // Hidden first: hiding goes through the toolbar's target, the checked group.
        for id in state.strings("hidden") { session.panel.toggleChecked(id) }
        session.panel.toggleTargetVisibility()
        session.panel.clearChecked()
        for id in state.strings("checked") { session.panel.toggleChecked(id) }
        for type in state.strings("excludedTypes") { session.panel.toggleType(type) }
        let event = input["event"]
        switch event["type"].string {
        case "rangePicked": session.pickRange(range(event["range"]))
        case "defaultRange": session.offerDefault(range(event["range"]), editOpen: event["editOpen"].bool ?? false)
        case "storyEntered": session.enterStory(event["id"].string!)
        case "storyExited": session.exitStory()
        case let type: throw RuleError("no iOS event \(type ?? "?")")
        }
        return [
            "range": session.range.map(rangeJSON) ?? nil, "userPicked": .bool(session.userPicked), "storyId": .opt(session.storyID),
            "checked": .ids(session.panel.checked), "hidden": .ids(session.panel.hidden), "excludedTypes": .ids(session.panel.excludedTypes),
            "flyRequest": .bool(session.flyRequest),
        ]
    },
    "layerInsertion": { input in
        .opt(MapLayers.insertionPoint(current: input.strings("current"), order: input.strings("order"), id: input["id"].string!, own: Set(input.strings("own")), fallback: input["fallback"].string))
    },
    "layerLift": { input in .bool(MapLayers.needsLift(current: input.strings("current"), id: input["id"].string!, own: Set(input.strings("own")))) },
    "webPageRoute": { input in
        let link = input["link"]
        let base = input["base"]
        let route = WebRoute.of(
            scheme: link["scheme"].string, authority: link["authority"].string, path: link["path"].string,
            activity: link["activity"].string, day: link["day"].string,
            baseScheme: base["scheme"].string, baseAuthority: base["authority"].string, page: input["page"].string!,
            leaving: input["leaving"].bool ?? false, onboarding: input["onboarding"].bool ?? false
        )
        switch route {
        case .stay: return "stay"
        case .outside: return "outside"
        case .ignore: return "ignore"
        case .close: return "close"
        case .onboarded: return "onboarded"
        case .viewOnMap(let activity, let day): return ["viewOnMap": ["activity": .string(activity), "day": .string(day)]]
        }
    },
    "activityZone": { input in .opt(ActivityZone.of(own: input["own"].string, account: input["account"].string)) },
    "distanceParts": { input in partsJSON(FormatParts.distance(meters: input.number("meters"), imperial: input["system"].string == "imperial")) },
    "totalDistanceParts": { input in partsJSON(FormatParts.totalDistance(meters: input.number("meters"), imperial: input["system"].string == "imperial")) },
    "durationParts": { input in
        switch FormatParts.duration(seconds: input.int("seconds")) {
        case .hoursMinutes(let h, let m): ["key": "duration.hm", "args": ["h": .num(h), "m": .num(m)]]
        case .minutes(let m): ["key": "duration.m", "args": ["m": .num(m)]]
        case .seconds(let s): ["key": "duration.s", "args": ["s": .num(s)]]
        }
    },
]

struct RuleError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func sliderWindow(_ input: RuleJSON) -> SliderRules.Window {
    SliderRules.Window(days: input.strings("days"), canPanEarlier: input["canPanEarlier"].bool!, canPanLater: input["canPanLater"].bool!)
}

func range(_ json: RuleJSON) -> DateRange { DateRange(from: json["from"].string!, to: json["to"].string!) }
func rangeJSON(_ range: DateRange) -> RuleJSON { ["from": .string(range.from), "to": .string(range.to)] }

func distance(_ json: RuleJSON) -> DistanceRange? {
    json.object == nil ? nil : DistanceRange(min: json.number("min"), max: json.number("max"))
}

func distanceJSON(_ range: DistanceRange?) -> RuleJSON {
    range.map { ["min": .num($0.min), "max": .num($0.max)] } ?? nil
}

func activity(_ json: RuleJSON, id: String = "a") -> ActivitySummary {
    ActivitySummary(id: json["id"].string ?? id, activityType: json["activityType"].string!, distanceMeters: json["distanceMeters"].double, isPrivate: json["private"].bool ?? false)
}

func activities(_ json: RuleJSON) -> [ActivitySummary] { (json.list ?? []).map { activity($0) } }

func partsJSON(_ parts: DistanceParts) -> RuleJSON {
    ["value": .num(parts.value), "minDecimals": .num(parts.minDecimals), "maxDecimals": .num(parts.maxDecimals), "grouping": .bool(parts.grouping), "unit": .string(parts.unit.rawValue)]
}
