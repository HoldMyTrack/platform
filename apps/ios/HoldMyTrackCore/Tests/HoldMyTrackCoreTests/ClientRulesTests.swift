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
        // A file that can't be read stays in, so its own test fails naming it.
        return names.filter { $0.hasSuffix(".json") }.sorted().filter { name in
            guard let doc = try? load(name), let clients = doc["clients"].list else { return true }
            return clients.contains("ios")
        }
    }()

    /// A rule file that couldn't be read or parsed, by name: one bad file (a merge conflict left
    /// in it) fails its own test, not the whole run.
    struct UnreadableRuleFile: Error, CustomStringConvertible {
        let name: String
        let cause: any Error
        var description: String { "\(name): \(cause)" }
    }

    static func load(_ name: String) throws -> RuleJSON {
        do {
            let data = try Data(contentsOf: dir.appending(path: name))
            return RuleJSON(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        } catch {
            throw UnreadableRuleFile(name: name, cause: error)
        }
    }

    @Test func everyRuleFileHasASwiftImplementation() {
        #expect(!Self.files.isEmpty, "no cases in \(Self.dir.path)")
        for name in Self.files {
            guard let doc = try? Self.load(name) else { continue } // its own test reports it
            let rule = doc["rule"].string ?? "?"
            #expect(rules[rule] != nil, "\(name): no Swift implementation of \(rule)")
        }
    }

    @Test(arguments: files)
    func casesHold(file: String) throws {
        let doc = try Self.load(file)
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
    "pendingChange": { input in
        let change = PendingDiff.of(previous: Set(input.strings("previous")), now: Set(input.strings("now")), awaiting: Set(input.strings("awaiting")))
        return ["started": .bool(change.started), "finished": .bool(change.finished), "left": .ids(change.left), "landed": .ids(change.landed), "awaiting": .ids(change.awaiting)]
    },
    "deleteDone": { input in .bool(DeleteOutcome.done(status: input.int("status"))) },
    "uploadPlan": { input in
        let files = input["files"].list!.map { UploadPlan.Picked(name: $0["name"].string!, size: $0.int("size")) }
        let plan = UploadPlan.of(files)
        let refusals: [RuleJSON] = plan.refusals.map { refusal in
            switch refusal {
            case .zip(let name): ["kind": "zip", "name": .string(name)]
            case .wrongType(let name): ["kind": "wrongType", "name": .string(name)]
            case .tooMany(let count): ["kind": "tooMany", "count": .number(Double(count))]
            case .tooLarge(let name): ["kind": "tooLarge", "name": .string(name)]
            }
        }
        return ["send": .array(plan.send.map { .number(Double($0)) }), "refusals": .array(refusals)]
    },
    "basemapStatus": { input in
        .string(BasemapStatus.of(loaded: input["loaded"].bool!, failed: input["failed"].bool!, waitedMs: input.int("waitedMs")).rawValue)
    },
    "satelliteStatus": { input in
        let status = SatelliteStatus.of(loaded: input["loaded"].bool!, failed: input["failed"].bool!, waitedMs: input.int("waitedMs"))
        return ["status": .string(status.rawValue), "look": .bool(SatelliteStatus.look(on: input["on"].bool!, status: status))]
    },
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
        case let type: throw RuleError("no iOS event \(type ?? "?")")
        }
        return [
            "checked": .ids(panel.checked), "focused": .opt(panel.focused), "hidden": .ids(panel.hidden),
            "excludedTypes": .ids(panel.excludedTypes), "distanceFilter": distanceJSON(panel.distanceFilter),
        ]
    },
    "areaLoad": { input in
        let result = AreaLoad.of(zoom: input["zoom"].double!, listed: input.int("listed"), total: input["total"].double.map { Int($0) })
        return ["load": .string(result.load.rawValue), "capped": .bool(result.capped)]
    },
    "openingView": { input in
        let boxes = (input["boxes"].list ?? []).map { $0.list!.map { $0.double! } }
        guard let view = OpeningView.of(boxes, width: input["viewport"]["width"].double!, height: input["viewport"]["height"].double!) else { return nil }
        return ["center": .array([.number(view.lon), .number(view.lat)]), "zoom": .number(view.zoom)]
    },
    "dateFilterBounds": { input in
        let b = DateFilter.bounds(earliest: input["earliest"].string, latest: input["latest"].string, today: input["today"].string!)
        return ["min": .string(b.min), "max": .string(b.max)]
    },
    "dateFilterLabel": { input in
        switch DateFilter(after: input["after"].string, before: input["before"].string).label {
        case .all: ["kind": "all"]
        case let .between(a, b): ["kind": "between", "after": .string(a), "before": .string(b)]
        case let .after(a): ["kind": "after", "after": .string(a)]
        case let .before(b): ["kind": "before", "before": .string(b)]
        }
    },
    "dateFilterSet": { input in
        let current = dates(input["current"])
        let bounds = (min: input["bounds"]["min"].string!, max: input["bounds"]["max"].string!)
        let result = current.setting(input["end"].string == "after" ? .after : .before, to: input["value"].string, bounds: bounds)
        return ["filter": datesJSON(result.filter), "fly": .bool(result.fly)]
    },
    "webSession": { input in
        let state = input["state"]
        var session = MapSession()
        // The Story first: opening one starts the selection set up below over.
        if let story = state["storyId"].string {
            session.enterStory(story)
            _ = session.consumeFly()
        }
        if state["dates"].object != nil { session.setDates(dates(state["dates"]), fly: false) }
        if let area = state["area"].list { session.areaLoaded(area.map { $0.double! }) }
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
        case "datesSet": session.setDates(dates(event["dates"]), fly: event["fly"].bool!)
        case "areaLoaded": session.areaLoaded(event["area"].list!.map { $0.double! })
        case "dayViewed": session.viewDay(event["day"].string!)
        case "storyEntered": session.enterStory(event["id"].string!)
        case "storyExited": session.exitStory()
        case let type: throw RuleError("no iOS event \(type ?? "?")")
        }
        var out: [String: RuleJSON] = [
            "dates": datesJSON(session.dates), "area": session.area.map { .array($0.map { .number($0) }) } ?? nil,
            "checked": .ids(session.panel.checked), "hidden": .ids(session.panel.hidden), "excludedTypes": .ids(session.panel.excludedTypes),
            "flyRequest": .bool(session.flyRequest),
        ]
        if let story = session.storyID { out["storyId"] = .string(story) }
        return .object(out)
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
    "fogLevelInView": { input in
        .string(FogLevels.inView(fogLevels(input["levels"]), zoom: input.number("zoom"), locked: input["locked"].string))
    },
    "fogLevelPick": { input in
        let pick = FogLevels.pick(fogLevels(input["levels"]), zoom: input.number("zoom"), locked: input["locked"].string, picked: input["picked"].string!)
        return ["locked": pick.locked.map(RuleJSON.string) ?? nil, "zoom": pick.zoom.map(RuleJSON.number) ?? nil]
    },
    "fogPlaceLabel": { input in
        let catalog = Set(input.strings("catalog"))
        let props = (input["props"].object ?? [:]).mapValues(jsonValue)
        guard let label = FogPlaceLabel.of(props, has: catalog.contains) else { return nil }
        return [
            "name": .string(label.name), "kindKey": .string(label.kindKey), "within": .string(label.within),
            "visitedKey": .string(label.visitedKey),
            "counts": .array(label.counts.map { ["key": .string($0.key), "explored": .num($0.explored), "total": .num($0.total)] }),
        ]
    },
]

func jsonValue(_ json: RuleJSON) -> JSONValue {
    switch json {
    case .null: .null
    case .bool(let b): .bool(b)
    case .number(let n): .number(n)
    case .string(let s): .string(s)
    case .array(let a): .array(a.map(jsonValue))
    case .object(let o): .object(o.mapValues(jsonValue))
    }
}

func fogLevels(_ json: RuleJSON) -> [FogLevels.Level] {
    (json.list ?? []).map { FogLevels.Level(level: $0["level"].string!, from: $0["from"].double, below: $0["below"].double) }
}

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

private func dates(_ json: RuleJSON) -> DateFilter { DateFilter(after: json["after"].string, before: json["before"].string) }

private func datesJSON(_ filter: DateFilter) -> RuleJSON { ["after": .opt(filter.after), "before": .opt(filter.before)] }
