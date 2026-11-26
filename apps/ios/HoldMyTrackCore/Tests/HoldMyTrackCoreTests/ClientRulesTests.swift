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

/// A case's recording, with no route.
private func ruleRecording(_ json: RuleJSON) -> RecordedTrack {
    let at = Date(timeIntervalSince1970: (json["startedAt"].double ?? 0) / 1000)
    return RecordedTrack(id: json["id"].string!, startedAt: at, endedAt: at, movingSeconds: 0, meters: 0, type: "walk", points: [], sent: json["sent"].bool!)
}

/// Each rule, from a case's input to the JSON its expected value is written in.
let rules: [String: @Sendable (RuleJSON) throws -> RuleJSON] = [
    "pendingChange": { input in
        let change = PendingDiff.of(previous: Set(input.strings("previous")), now: Set(input.strings("now")), awaiting: Set(input.strings("awaiting")), listed: Set(input.strings("listed")))
        return ["started": .bool(change.started), "finished": .bool(change.finished), "left": .ids(change.left), "landed": .ids(change.landed), "awaiting": .ids(change.awaiting), "pending": .ids(change.pending)]
    },
    "recordingSendAllowed": { input in .bool(RecordingSends.sends(emailVerified: input["emailVerified"].bool!, isDemo: input["isDemo"].bool!)) },
    "recordingSendOrder": { input in
        let sends = RecordingSends.toSend(input["recordings"].list!.map(ruleRecording), hidden: Set(input.strings("hidden")), held: Set(input.strings("held")),
                                          refused: Set(input.strings("refused")), setBack: input.strings("setBack"), retry: input["retry"].bool!)
        return .array(sends.map { .string($0.id) })
    },
    "recordingSendFailure": { input in
        let error: APIError = switch input["answer"].string {
        case "none": .unreachable
        case "unreadable": .unreadable
        default: input.int("answer") == 426 ? .outdated : .http(status: input.int("answer"), code: nil, message: nil)
        }
        let outcome = switch RecordingSends.failure(error, afterUnanswered: input["afterUnanswered"].bool!) {
        case .stop: "stop"
        case .next: "next"
        case .refuse: "refuse"
        }
        return ["outcome": .string(outcome), "unanswered": .bool(RecordingSends.unanswered(error))]
    },
    "recordingSendDeletion": { input in
        switch RecordingSends.deletion(stored: input["stored"].bool!, going: input["going"].bool!, landed: input["landed"].bool!) {
        case .deleted: .string("deleted")
        case .sending: .string("sending")
        case .landed: .string("landed")
        }
    },
    "recordingSendNote": { input in
        switch RecordingSends.note(sent: input["sent"].bool!, sending: input["sending"].bool!, hidden: input["hidden"].bool!,
                                   refusal: input["refused"].bool! ? .server(nil) : nil, isDemo: input["isDemo"].bool!) {
        case nil: .null
        case .processing: .string("processing")
        case .sending: .string("sending")
        case .waiting: .string("waiting")
        case .refused: .string("refused")
        }
    },
    "recordingSendWaiting": { input in
        .number(Double(RecordingSends.waiting(input["recordings"].list!.map(ruleRecording), hidden: Set(input.strings("hidden")), isDemo: input["isDemo"].bool!)))
    },
    "editWrites": { input in
        let tracks = input["tracks"].list!.map {
            Track(id: $0["id"].string!, startedAt: "2026-10-11T09:39:00Z", trackType: $0["trackType"].string!, name: $0["name"].string, description: $0["description"].string)
        }
        let written = input["written"].list!.map {
            EditPlan.Write(id: $0["id"].string!, trackType: $0["trackType"].string!, name: $0["name"].string!, description: $0["description"].string!)
        }
        let writes = EditPlan.writes(group: tracks, type: input["type"].string!, name: input["name"].string!, description: input["description"].string!,
                                     written: Dictionary(uniqueKeysWithValues: written.map { ($0.id, $0) }), unsure: Set(input.strings("unsure")))
        return .array(writes.map { ["id": .string($0.id), "trackType": .string($0.trackType), "name": .string($0.name), "description": .string($0.description)] })
    },
    "openingMove": { input in
        .string(OpeningView.move(found: input["found"].bool!, recording: input["recording"].bool!, tripOpen: input["tripOpen"].bool!,
                                 flightAsked: input["flightAsked"].bool!, moved: input["moved"].bool!).rawValue)
    },
    "tripListAnswer": { input in
        let failed = input["failed"].bool!
        return ["openGone": .bool(TripsList.openGone(quiet: input["quiet"].bool!, open: input["open"].string, listed: Set(input.strings("listed")), failed: failed)),
                "showsError": .bool(TripsList.showsError(quiet: input["quiet"].bool!, ready: input["ready"].bool!, failed: failed))]
    },
    "uploadWatch": { input in
        let step = ImportWatch.step(status: input["status"].string!)
        return ["landed": .bool(step.landed), "done": .bool(step.done)]
    },
    "framePadding": { input in
        let fit = MapFraming.padding(height: Double(input.int("height")), top: Double(input.int("top")), coveredBelow: Double(input.int("coveredBelow")),
                                     pad: Double(input.int("pad")), minSpan: Double(input.int("minSpan")))
        return ["top": .number(fit.top), "bottom": .number(fit.bottom)]
    },
    "importRetry": { input in ImportWatch.delay(failures: input.int("failures"), watched: input.int("watched")).map { .number(Double($0)) } ?? .null },
    "deleteDone": { input in .bool(DeleteOutcome.done(status: input.int("status"))) },
    "attachmentName": { input in .string(AttachmentName.of(input["header"].string)) },
    "libraryPageQuery": { input in
        guard let query = LibraryRules.pageQuery(libraryState(input["state"]), allTypes: input.strings("allTypes")) else { return .null }
        return ["page": .num(query.page), "sort": .string(query.sort), "q": .opt(query.q), "types": query.types.map { .list($0) } ?? .null,
                "minDistance": query.minDistance.map { .num($0) } ?? .null, "maxDistance": query.maxDistance.map { .num($0) } ?? .null,
                "from": .opt(query.from), "to": .opt(query.to), "trip": .opt(query.trip)]
    },
    "libraryPager": { input in
        guard let pager = LibraryRules.pager(page: input.int("page"), total: input.int("total"), pageSize: input.int("pageSize")) else { return .null }
        return ["from": .num(pager.from), "to": .num(pager.to), "prev": .bool(pager.prev), "next": .bool(pager.next)]
    },
    "libraryEmptyReason": { input in
        .string(LibraryRules.emptyReason(libraryState(input["state"]), total: input.int("total"), anyTrack: input["anyTrack"].bool!).rawValue)
    },
    "downloadBlock": { input in
        let targets = input["tracks"].list.map { list in
            list.map { DownloadRules.Target(id: $0["id"].string!, pending: $0["pending"].bool!, isPrivate: $0["private"].bool!) }
        } ?? (0..<(input["plainTracks"].double.map { Int($0) } ?? 0)).map { DownloadRules.Target(id: "t\($0)", pending: false, isPrivate: false) }
        let block = input["max"].double.map { DownloadRules.block(targets, max: Int($0)) } ?? DownloadRules.block(targets)
        switch block {
        case nil: return .null
        case .tooMany(let count): return ["kind": "too_many", "count": .num(count)]
        case .pending(let id): return ["kind": "pending", "track": .string(id)]
        case .private(let id): return ["kind": "private", "track": .string(id)]
        }
    },
    "tripFormAction": { input in .bool(TripForms.actionEnabled(text: input["text"].string!, busy: input["busy"].bool!)) },
    "tripFold": { input in
        let folded = input["foldedId"].string, open = input["openId"].string, clicked = input["clicked"].string
        let click = clicked.map { TripFold.folderClick(foldedID: folded, openID: open, clickedID: $0) } ?? TripFold.Click(foldedID: folded, open: false)
        let shown = TripFold.isFolded(foldedID: click.foldedID, openID: click.open ? clicked : open)
        return ["foldedId": click.foldedID.map { .string($0) } ?? .null, "open": .bool(click.open), "folded": .bool(shown)]
    },
    "privateDrawOrder": { input in
        let saved = input.strings("saved").map { PrivateLocation(id: $0, name: "", lon: 0, lat: 0, radiusM: 200) }
        return .list(PrivateLocationEditing.drawOrder(saved, editing: input["editing"].string).map(\.id))
    },
    "profileStats": { input in
        let days = input["days"].list!.map { TrackDay(date: $0["date"].string!, count: $0.int("count"), distanceMeters: $0["distanceMeters"].double!) }
        let totals = ProfileStats.totals(days)
        let weeks = ProfileStats.recentWeeks(days, today: input["today"].string!, weeks: input.int("weeks"))
        return .object(["count": .number(Double(totals.count)), "distanceMeters": .number(totals.distanceMeters), "activeDays": .number(Double(totals.activeDays)),
                        "longestStreakDays": .number(Double(totals.longestStreakDays)), "weeks": .array(weeks.map { .number(Double($0)) })])
    },
    "youRefresh": { input in
        func mark(_ json: RuleJSON) -> YouRefresh.Mark? {
            guard let at = json["atMs"].double else { return nil }
            return YouRefresh.Mark(atMs: Int64(at), tileVersion: json["tileVersion"].string!, today: json["today"].string!)
        }
        let reads = YouRefresh.of(numbers: mark(input["numbers"]), accountAtMs: input["accountAtMs"].double.map { Int64($0) }, now: mark(input["now"])!, resumed: input["resumed"].bool!)
        return .object(["account": .bool(reads.account), "numbers": .bool(reads.numbers)])
    },
    "similarSpans": { input in
        func at(_ span: String, _ end: String) -> Date { Date(timeIntervalSince1970: input[span][end].double! / 1000) }
        return .bool(SyncSimilar.overlaps(at("a", "start"), at("a", "end"), at("b", "start"), at("b", "end")))
    },
    "verifyAction": { input in
        switch VerifyAction.of(input["typed"].string!) {
        case .check: .string("check")
        case .submit(let code): .object(["submit": .string(code)])
        }
    },
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
    "largeText": { input in .bool(LargeText.isOn(scale: input.number("scale"))) },
    "mapTracksFilters": { input in .bool(MapChrome.tracksFiltersApply(onLibrary: ["library", "sync"].contains(input["tab"].string ?? ""))) },
    "basemapStatus": { input in
        .string(BasemapStatus.of(loaded: input["loaded"].bool!, failed: input["failed"].bool!, waitedMs: input.int("waitedMs")).rawValue)
    },
    "satelliteStatus": { input in
        let status = SatelliteStatus.of(loaded: input["loaded"].bool!, failed: input["failed"].bool!, waitedMs: input.int("waitedMs"))
        return ["status": .string(status.rawValue), "look": .bool(SatelliteStatus.look(on: input["on"].bool!, status: status))]
    },
    "pendingBatches": { input in .array(PendingDiff.batches(input.strings("ids"), size: input.int("size")).map { .list($0) }) },
    "pendingCheck": { input in
        let watched = PendingDiff.watched(pending: input.strings("pending"), awaiting: input.strings("awaiting"))
        let answer = PendingDiff.answer(watched: watched, stillPending: input.strings("stillPending"), listed: Set(input.strings("listed")))
        return ["watched": .list(watched), "moved": .bool(answer.moved), "finished": .ids(answer.finished)]
    },
    "boldTracks": { input in .ids(PanelRules.boldIDs(checked: Set(input.strings("checked")), focused: input["focused"].string)) },
    "toolbarTarget": { input in .ids(PanelRules.targetIDs(checked: Set(input.strings("checked")), focused: input["focused"].string)) },
    "targetVisibility": { input in .ids(PanelRules.toggledVisibility(hidden: Set(input.strings("hidden")), target: Set(input.strings("target")))) },
    "distanceBounds": { input in distanceJSON(TrackFacets.distanceBounds(tracks(input["tracks"]))) },
    "distanceFilter": { input in
        let knob: DistanceKnob = input["knob"].string == "min" ? .min : .max
        return distanceJSON(TrackFacets.nextDistanceFilter(bounds: distance(input["bounds"])!, current: distance(input["current"])!, knob: knob, value: input.number("value"),
                                                           imperial: input["system"].string == "imperial"))
    },
    "distanceWholeBounds": { input in distanceJSON(TrackFacets.wholeDistanceBounds(distance(input["bounds"]), imperial: input["system"].string == "imperial")) },
    "typeFacets": { input in
        .array(TrackFacets.typeFacets(tracks(input["tracks"]), distanceFilter: distance(input["distanceFilter"])).map { ["type": .string($0.type), "count": .num($0.count)] })
    },
    "typeSearch": { input in
        let options = (input["options"].list ?? []).map { TypeSearch.Option(value: $0["value"].string!, label: $0["label"].string!, count: $0.int("count")) }
        let result = TypeSearch.search(options, query: input["query"].string!, maxLength: input.int("maxLength"))
        return ["shown": .array(result.shown.map { .string($0.value) }), "add": result.add.map { .string($0) } ?? .null]
    },
    "typeOptions": { input in
        let rows = TypeSearch.options(current: input["current"].string!, known: typeCounts(input["known"]), label: { $0 })
        return .array(rows.map { ["type": .string($0.value), "count": .number(Double($0.count))] })
    },
    "recordingTypes": { input in
        .array(TypeSearch.recordingKnown(server: typeCounts(input["server"]), local: input.strings("local")).map { ["type": .string($0.type), "count": .number(Double($0.count))] })
    },
    "passesFilters": { input in
        .bool(TrackFacets.passesFilters(track(input["track"]), excludedTypes: Set(input.strings("excludedTypes")), distanceFilter: distance(input["distanceFilter"])))
    },
    "panelState": { input in
        let all = (input["tracks"].list ?? []).map { track($0) }
        let state = input["state"]
        var panel = PanelState()
        panel.setTracks(all)
        // Hidden first: hiding goes through the toolbar's target, the checked group.
        for id in state.strings("hidden") { panel.toggleChecked(id) }
        panel.toggleTargetVisibility()
        panel.clearChecked()
        // Filters before checks: setting a filter unchecks what it hides.
        for type in state.strings("excludedTypes") { panel.toggleType(type) }
        panel.distanceFilter = distance(state["distanceFilter"])
        for id in state.strings("checked") { panel.toggleChecked(id) }
        if let focused = state["focused"].string { panel.focus(focused) }
        let event = input["event"]
        switch event["type"].string {
        case "checkToggled": panel.toggleChecked(event["id"].string!)
        case "checkAll": panel.checkAll()
        case "checksCleared": panel.clearChecked()
        case "checksInverted": panel.invertChecked()
        case "visibilityToggled": panel.toggleTargetVisibility()
        case "typeToggled": panel.toggleType(event["trackType"].string!)
        case "distanceSet": panel.distanceFilter = distance(event["filter"])
        case "filtersReset": panel.resetFilters()
        case "listLoaded":
            let ids = Set(event.strings("ids"))
            panel.setTracks(all.filter { ids.contains($0.id) })
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
    "fitBoxes": { input in boxesJSON(FitBoxes.of(framable(input))) },
    "selectionBoxes": { input in boxesJSON(FitBoxes.selection(framable(input))) },
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
        // The Trip first: opening one starts the selection set up below over.
        if let trip = state["tripId"].string {
            session.enterTrip(trip)
            _ = session.consumeFly()
        }
        if state["dates"].object != nil { session.setDates(dates(state["dates"]), fly: false) }
        if let area = state["area"].list { session.areaLoaded(area.map { $0.double! }) }
        var seen = Set<String>()
        let ids = (state.strings("checked") + state.strings("hidden")).filter { seen.insert($0).inserted }
        session.panel.setTracks(ids.map { TrackSummary(id: $0, trackType: "walking", distanceMeters: 1000, isPrivate: false) })
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
        case "tripEntered": session.enterTrip(event["id"].string!)
        case "tripExited": session.exitTrip()
        case let type: throw RuleError("no iOS event \(type ?? "?")")
        }
        var out: [String: RuleJSON] = [
            "dates": datesJSON(session.dates), "area": session.area.map { .array($0.map { .number($0) }) } ?? nil,
            "checked": .ids(session.panel.checked), "hidden": .ids(session.panel.hidden), "excludedTypes": .ids(session.panel.excludedTypes),
            "flyRequest": .bool(session.flyRequest),
        ]
        if let trip = session.tripID { out["tripId"] = .string(trip) }
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
            track: link["track"].string, day: link["day"].string,
            baseScheme: base["scheme"].string, baseAuthority: base["authority"].string, page: input["page"].string!,
            leaving: input["leaving"].bool ?? false, onboarding: input["onboarding"].bool ?? false,
            post: input["post"].bool ?? false
        )
        switch route {
        case .stay: return "stay"
        case .outside: return "outside"
        case .ignore: return "ignore"
        case .close: return "close"
        case .onboarded: return "onboarded"
        case .viewOnMap(let track, let day): return ["viewOnMap": ["track": .string(track), "day": .string(day)]]
        }
    },
    "editRouteFold": { input in editJSON(EditRouteOps.fold(edit(input["base"]), try ops(input["ops"]))) },
    "editRouteApply": { input in .array(EditRouteOps.apply(points(input["points"]), edit(input["edit"])!).map(pointJSON)) },
    "editRouteChop": { input in opJSON(EditRouteOps.chop(points(input["visible"]), lo: input.int("lo"), hi: input.int("hi"))) },
    "editRouteCut": { input in opJSON(EditRouteOps.cut(points(input["visible"]), lo: input.int("lo"), hi: input.int("hi"))) },
    "editRouteSplitIndex": { input in EditRouteOps.splitIndex(points(input["visible"]), lo: input.int("lo"), hi: input.int("hi")).map { .num($0) } ?? nil },
    "editRouteSplitPoint": { input in try EditRouteOps.splitPoint(ops(input["ops"])).map { .num($0) } ?? nil },
    "editRouteMove": { input in opJSON(EditRouteOps.move(t: input.int("t"), lon: input.number("lon"), lat: input.number("lat"))) },
    "editRouteDistances": { input in .array(EditRouteOps.cumulativeDistances(points(input["points"])).map { .num($0) }) },
    "photoScope": { input in
        let scope = PhotoMarkers.scope(mode: MapMode(rawValue: input["mode"].string!)!, editWindowIDs: input["editWindowIds"].list?.compactMap(\.string), focused: input["focused"].string, tripID: input["tripId"].string)
        switch scope {
        case .track(let id): return ["track": .string(id)]
        case .trip(let id): return ["trip": .string(id)]
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
    "photoRoutePoint": { input in
        let point = try photoRoute(input).point(at: input.number("fraction"))
        return ["lon": .num(point.lon), "lat": .num(point.lat), "t": .num(point.t)]
    },
    "photoRouteFraction": { input in .num(photoRoute(input).fraction(at: input.number("t"))) },
    "photoRouteStart": { input in
        let placed = (input["placed"].object ?? [:]).mapValues { $0.double }
        let anchors = (input["anchors"].object ?? [:]).mapValues(anchor)
        return .num(photoRoute(input).startFraction(anchor: anchor(input["anchor"]), placed: placed, anchors: anchors))
    },
    "photoFit": { input in sizeJSON(PhotoZoom.fitSize(image: size(input["image"]), stage: size(input["stage"]))) },
    "photoZoom": { input in
        let point = input["point"]
        return viewJSON(PhotoZoom.zoom(view(input), by: input.number("factor"), at: (point.number("x"), point.number("y")), fitted: size(input["fitted"]), stage: size(input["stage"])))
    },
    "photoPan": { input in viewJSON(PhotoZoom.pan(view(input), dx: input.number("dx"), dy: input.number("dy"), fitted: size(input["fitted"]), stage: size(input["stage"]))) },
    "photoClamp": { input in viewJSON(PhotoZoom.clamp(view(input), fitted: size(input["fitted"]), stage: size(input["stage"]))) },
    "trackZone": { input in .opt(TrackZone.of(own: input["own"].string, account: input["account"].string)) },
    "distanceParts": { input in partsJSON(FormatParts.distance(meters: input.number("meters"), imperial: input["system"].string == "imperial")) },
    "totalDistanceParts": { input in partsJSON(FormatParts.totalDistance(meters: input.number("meters"), imperial: input["system"].string == "imperial")) },
    "distanceBandParts": { input in partsJSON(FormatParts.distanceBand(meters: input.number("meters"), imperial: input["system"].string == "imperial")) },
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
    "statsOffered": { input in .bool(ExportStats.offered(checked: Set(input.strings("checked")), tripID: input["tripId"].string)) },
    "statsCardPlacement": { input in
        let card = input["card"]
        let at = ExportStats.placement(width: input.int("width"), height: input.int("height"), cardWidth: card.int("width"), cardHeight: card.int("height"))
        return ["x": .number(at.x), "y": .number(at.y)]
    },
    "tourStart": { input in
        .string(TourRules.start(requested: input["requested"].bool!, isDemo: input["isDemo"].bool!, hasTracks: input["hasTracks"].bool, seen: tourSeen(input["seen"])).rawValue)
    },
    "tourCard": { input in
        let event = input["event"]
        let picked: TourEvent = event["kind"].string == "mode" ? .mode(MapMode(rawValue: event["mode"].string!)!) : .tab(tourTab(event["tab"].string!))
        return .opt(TourRules.card(picked, seen: tourSeen(input["seen"]), touring: input["touring"].bool!)?.rawValue)
    },
    "tourNextStep": { input in
        TourRules.nextStep(shown: input["shown"].list!.map { $0.bool! }, from: input.int("from"), dir: input.int("dir")).map { .num($0) } ?? .null
    },
    "tourStep": { input in
        let now = input["now"], restore = input["restore"], step = input["step"]
        let picked = step.isNull ? nil : TourStep("case", nil, tab: tourTab(step["tab"].string!), mode: MapMode(rawValue: step["mode"].string!)!,
                                                 card: step["card"].string.flatMap(TourCard.init(rawValue:)))
        let changes = TourRules.changes(mode: MapMode(rawValue: now["mode"].string!)!, tab: tourTab(now["tab"].string!), step: picked,
                                        restoreMode: MapMode(rawValue: restore["mode"].string!)!, restoreTab: tourTab(restore["tab"].string!))
        return ["mode": .opt(changes.mode?.rawValue), "tab": .opt(changes.tab.map(tourTabName)), "card": .opt(changes.card?.rawValue)]
    },
    "tourCamera": { input in
        func view(_ json: RuleJSON) -> TourView? { json.isNull ? nil : TourView(lon: json.number("lon"), lat: json.number("lat"), zoom: json.number("zoom")) }
        func json(_ view: TourView?) -> RuleJSON { view.map { ["lon": .number($0.lon), "lat": .number($0.lat), "zoom": .number($0.zoom)] } ?? .null }
        let camera = TourCamera(start: view(input["start"]), shown: view(input["shown"]))
        let step = input["step"]
        if step.isNull { return ["start": .null, "shown": .null, "move": json(TourRules.cameraEnd(camera))] }
        let next = TourRules.camera(camera, view: view(step["view"]), tab: tourTab(step["tab"].string!), current: view(input["current"])!)
        return ["start": json(next.camera.start), "shown": json(next.camera.shown), "move": json(next.move)]
    },
]

/// The rules' tabs: the web's panel tabs, tracks being the Map tab's.
func tourTab(_ name: String) -> TourTab { name == "trips" ? .trips : .map }

func tourTabName(_ tab: TourTab) -> String {
    switch tab {
    case .map: "tracks"
    case .trips: "trips"
    case .sync: "sync"
    case .you: "you"
    }
}

func tourSeen(_ json: RuleJSON) -> TourSeen { TourSeen(tour: json["tour"].bool!, cards: TourRules.seenCards(json.strings("cards"))) }

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

func photoRoute(_ input: RuleJSON) -> PhotoRoute {
    PhotoRoute((input["points"].list ?? []).map { TimedPoint(lon: $0.number("lon"), lat: $0.number("lat"), t: $0.number("t")) })
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

func points(_ json: RuleJSON) -> [RoutePoint] {
    (json.list ?? []).map { p in
        let v = p.list!.map { $0.double! }
        return RoutePoint(lon: v[0], lat: v[1], t: Int(v[2]))
    }
}

func pointJSON(_ p: RoutePoint) -> RuleJSON { [.num(p.lon), .num(p.lat), .num(p.t)] }

func span(_ json: RuleJSON) -> TimeSpan { TimeSpan(Int(json.list![0].double!), Int(json.list![1].double!)) }
func spanJSON(_ span: TimeSpan) -> RuleJSON { [.num(span.from), .num(span.to)] }

func edit(_ json: RuleJSON) -> RouteEdit? {
    guard json.object != nil else { return nil }
    return RouteEdit(
        keep: json["keep"].list == nil ? nil : span(json["keep"]),
        remove: (json["remove"].list ?? []).map(span),
        drop: (json["drop"].list ?? []).map { Int($0.double!) },
        move: Dictionary(uniqueKeysWithValues: (json["move"].object ?? [:]).map { (Int($0.key)!, $0.value.list!.map { $0.double! }) })
    )
}

/// The edit with its empty fields left out, as the web folds it.
func editJSON(_ edit: RouteEdit) -> RuleJSON {
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

func framable(_ input: RuleJSON) -> [Track] {
    (input["tracks"].list ?? []).map { t in
        Track(id: "a", startedAt: "", trackType: "walking", bbox: t["bbox"].list?.map { $0.double! },
              pending: t["pending"].bool ?? false, isPrivate: t["private"].bool ?? false)
    }
}

func boxesJSON(_ boxes: [[Double]]) -> RuleJSON {
    .array(boxes.map { box in .array(box.map { .number($0) }) })
}

func track(_ json: RuleJSON, id: String = "a") -> TrackSummary {
    TrackSummary(id: json["id"].string ?? id, trackType: json["trackType"].string!, distanceMeters: json["distanceMeters"].double, isPrivate: json["private"].bool ?? false)
}

func tracks(_ json: RuleJSON) -> [TrackSummary] { (json.list ?? []).map { track($0) } }

func partsJSON(_ parts: DistanceParts) -> RuleJSON {
    ["value": .num(parts.value), "minDecimals": .num(parts.minDecimals), "maxDecimals": .num(parts.maxDecimals), "grouping": .bool(parts.grouping), "unit": .string(parts.unit.rawValue)]
}

/// A case's Library state; a field it leaves out is at its default.
private func libraryState(_ json: RuleJSON) -> LibraryRules.State {
    let distance = json["distance"].object.map { _ in LibraryRules.Distance(min: json["distance"].number("min"), max: json["distance"]["max"].double) }
    return LibraryRules.State(
        sort: json["sort"].string.flatMap(LibraryRules.Sort.init(rawValue:)) ?? .started, desc: json["desc"].bool ?? true,
        page: json["page"].double.map { Int($0) } ?? 1, q: json["q"].string ?? "", exclude: Set(json.strings("exclude")),
        distance: distance, after: json["after"].string, before: json["before"].string, trip: json["trip"].string
    )
}

private func dates(_ json: RuleJSON) -> DateFilter { DateFilter(after: json["after"].string, before: json["before"].string) }

private func datesJSON(_ filter: DateFilter) -> RuleJSON { ["after": .opt(filter.after), "before": .opt(filter.before)] }

private func typeCounts(_ json: RuleJSON) -> [(type: String, count: Int)] {
    (json.list ?? []).map { (type: $0["type"].string!, count: $0.int("count")) }
}
