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

    @Test func everyRuleFileHasASwiftImplementation() {
        #expect(!Self.files.isEmpty, "no cases in \(Self.dir.path)")
        for name in Self.files {
            let rule = Self.load(name)["rule"].string ?? "?"
            #expect(rules[rule] != nil, "\(name): no Swift implementation of \(rule)")
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
    "deleteDone": { input in .bool(DeleteOutcome.done(status: input.int("status"))) },
    "pendingBatches": { input in .array(PendingDiff.batches(input.strings("ids"), size: input.int("size")).map { .list($0) }) },
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
    "editTrackFold": { input in editJSON(EditTrackOps.fold(edit(input["base"]), try ops(input["ops"]))) },
    "editTrackApply": { input in .array(EditTrackOps.apply(points(input["points"]), edit(input["edit"])!).map(pointJSON)) },
    "editTrackChop": { input in opJSON(EditTrackOps.chop(points(input["visible"]), lo: input.int("lo"), hi: input.int("hi"))) },
    "editTrackCut": { input in opJSON(EditTrackOps.cut(points(input["visible"]), lo: input.int("lo"), hi: input.int("hi"))) },
    "editTrackSplitIndex": { input in EditTrackOps.splitIndex(points(input["visible"]), lo: input.int("lo"), hi: input.int("hi")).map { .num($0) } ?? nil },
    "editTrackSplitPoint": { input in try EditTrackOps.splitPoint(ops(input["ops"])).map { .num($0) } ?? nil },
    "editTrackMove": { input in opJSON(EditTrackOps.move(t: input.int("t"), lon: input.number("lon"), lat: input.number("lat"))) },
    "editTrackDistances": { input in .array(EditTrackOps.cumulativeDistances(points(input["points"])).map { .num($0) }) },
    "photoScope": { input in
        let scope = PhotoMarkers.scope(mode: MapMode(rawValue: input["mode"].string!)!, editWindowIDs: input["editWindowIds"].list?.compactMap(\.string), focused: input["focused"].string, storyID: input["storyId"].string)
        switch scope {
        case .activity(let id): return ["activity": .string(id)]
        case .story(let id): return ["story": .string(id)]
        case nil: return nil
        }
    },
    "photoGroup": { input in
        let photos = (input["photos"].list ?? []).map { (lon: $0.number("lon"), lat: $0.number("lat")) }
        return PhotoMarkers.groupFit(photos).map { ["fit": .array($0.map { .num($0) })] } ?? "open"
    },
    "photoClusters": { input in
        .array(PhotoMarkers.cluster(screenPoints(input["points"]), radius: input.number("radius")).map { ["ids": .list($0.ids), "x": .num($0.x), "y": .num($0.y)] })
    },
    "photoMarkerSize": { input in .string(PhotoMarkers.size(zoom: input.number("zoom")).rawValue) },
    "photoMarkerLayout": { input in
        let placed = PhotoMarkers.layout(
            screenPoints(input["points"]), zoom: input.number("zoom"), activeID: input["activeId"].string, loneID: input["loneId"].string,
            width: input.number("width"), height: input.number("height"), scale: input.number("scale")
        )
        return .array(placed.map { ["ids": .list($0.ids), "x": .num($0.x), "y": .num($0.y), "diameter": .num($0.diameter), "active": .bool($0.active), "small": .bool($0.small)] })
    },
    "photoTrackPoint": { input in
        let point = try photoTrack(input).point(at: input.number("fraction"))
        return ["lon": .num(point.lon), "lat": .num(point.lat), "t": .num(point.t)]
    },
    "photoTrackFraction": { input in .num(photoTrack(input).fraction(at: input.number("t"))) },
    "photoTrackStart": { input in
        let placed = (input["placed"].object ?? [:]).mapValues { $0.double }
        let anchors = (input["anchors"].object ?? [:]).mapValues(anchor)
        return .num(photoTrack(input).startFraction(anchor: anchor(input["anchor"]), placed: placed, anchors: anchors))
    },
    "photoFit": { input in sizeJSON(PhotoZoom.fitSize(image: size(input["image"]), stage: size(input["stage"]))) },
    "photoZoom": { input in
        let point = input["point"]
        return viewJSON(PhotoZoom.zoom(view(input), by: input.number("factor"), at: (point.number("x"), point.number("y")), fitted: size(input["fitted"]), stage: size(input["stage"])))
    },
    "photoPan": { input in viewJSON(PhotoZoom.pan(view(input), dx: input.number("dx"), dy: input.number("dy"), fitted: size(input["fitted"]), stage: size(input["stage"]))) },
    "photoClamp": { input in viewJSON(PhotoZoom.clamp(view(input), fitted: size(input["fitted"]), stage: size(input["stage"]))) },
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

func screenPoints(_ json: RuleJSON) -> [ScreenPoint] {
    (json.list ?? []).map { ScreenPoint(id: $0["id"].string!, x: $0.number("x"), y: $0.number("y")) }
}

func photoTrack(_ input: RuleJSON) -> PhotoTrack {
    PhotoTrack((input["points"].list ?? []).map { TimedPoint(lon: $0.number("lon"), lat: $0.number("lat"), t: $0.number("t")) })
}

func anchor(_ json: RuleJSON) -> PlaceAnchor? {
    if let key = json["waiting"].string { return .waiting(key) }
    if let t = json["t"].double { return .at(t: t) }
    return nil
}

func size(_ json: RuleJSON) -> PhotoZoom.Size { PhotoZoom.Size(width: json.number("width"), height: json.number("height")) }
func sizeJSON(_ size: PhotoZoom.Size) -> RuleJSON { ["width": .num(size.width), "height": .num(size.height)] }
func view(_ input: RuleJSON) -> PhotoZoom.View {
    let v = input["view"]
    return PhotoZoom.View(scale: v.number("scale"), x: v.number("x"), y: v.number("y"))
}
func viewJSON(_ view: PhotoZoom.View) -> RuleJSON { ["scale": .num(view.scale), "x": .num(view.x), "y": .num(view.y)] }

func points(_ json: RuleJSON) -> [TrackPoint] {
    (json.list ?? []).map { p in
        let v = p.list!.map { $0.double! }
        return TrackPoint(lon: v[0], lat: v[1], t: Int(v[2]))
    }
}

func pointJSON(_ p: TrackPoint) -> RuleJSON { [.num(p.lon), .num(p.lat), .num(p.t)] }

func span(_ json: RuleJSON) -> TimeSpan { TimeSpan(Int(json.list![0].double!), Int(json.list![1].double!)) }
func spanJSON(_ span: TimeSpan) -> RuleJSON { [.num(span.from), .num(span.to)] }

func edit(_ json: RuleJSON) -> TrackEdit? {
    guard json.object != nil else { return nil }
    return TrackEdit(
        keep: json["keep"].list == nil ? nil : span(json["keep"]),
        remove: (json["remove"].list ?? []).map(span),
        drop: (json["drop"].list ?? []).map { Int($0.double!) },
        move: Dictionary(uniqueKeysWithValues: (json["move"].object ?? [:]).map { (Int($0.key)!, $0.value.list!.map { $0.double! }) })
    )
}

/// The edit with its empty fields left out, as the web folds it.
func editJSON(_ edit: TrackEdit) -> RuleJSON {
    var out: [String: RuleJSON] = [:]
    if let keep = edit.keep { out["keep"] = spanJSON(keep) }
    if !edit.remove.isEmpty { out["remove"] = .array(edit.remove.map(spanJSON)) }
    if !edit.drop.isEmpty { out["drop"] = .array(edit.drop.map { .num($0) }) }
    if !edit.move.isEmpty { out["move"] = .object(Dictionary(uniqueKeysWithValues: edit.move.map { (String($0.key), .array($0.value.map { .num($0) })) })) }
    return .object(out)
}

func ops(_ json: RuleJSON) throws -> [EditOp] {
    try (json.list ?? []).map { op in
        switch op["kind"].string {
        case "chop": .chop(keep: span(op["keep"]))
        case "cut": .cut(remove: span(op["remove"]))
        case "drop": .drop(t: op.int("t"))
        case "move": .move(t: op.int("t"), lon: op["to"].list![0].double!, lat: op["to"].list![1].double!)
        case "reset": .reset
        case "split": .split(t: op.int("t"))
        case let kind: throw RuleError("no iOS op \(kind ?? "?")")
        }
    }
}

func opJSON(_ op: EditOp?) -> RuleJSON {
    switch op {
    case nil: nil
    case .chop(let keep): ["kind": "chop", "keep": spanJSON(keep)]
    case .cut(let remove): ["kind": "cut", "remove": spanJSON(remove)]
    case .drop(let t): ["kind": "drop", "t": .num(t)]
    case .move(let t, let lon, let lat): ["kind": "move", "t": .num(t), "to": [.num(lon), .num(lat)]]
    case .reset: ["kind": "reset"]
    case .split(let t): ["kind": "split", "t": .num(t)]
    }
}

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
