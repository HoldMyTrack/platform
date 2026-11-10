/// What the Activities panel and the map agree on: the date range's activities, the two filters,
/// the checked group, the one selected (focused) activity, and the tracks hidden for the session.
///
/// Selection and the checked group take turns (apps/android/docs/SPEC.md FR-2.7): outside
/// selecting, tapping a row or a track selects it (at most one, bold on the map, flown to).
/// Checking a row starts selecting, the selected one joining the group, and the list is selecting
/// for exactly as long as anything is checked.
public struct PanelState: Equatable, Sendable {
    public private(set) var activities: [ActivitySummary] = []
    public private(set) var checked: Set<String> = []
    /// The selected activity, if any.
    public private(set) var focused: String?
    /// Tracks the user hid from the map with the toolbar's Show/Hide: this session only, never
    /// sent to the server, and cleared by a new date range.
    public private(set) var hidden: Set<String> = []
    public private(set) var excludedTypes: Set<String> = []
    /// nil is "any distance": the band at the list's own ends is stored as nil, so it doesn't
    /// count as an active filter.
    public var distanceFilter: DistanceRange?

    public init() {}

    /// Whether the list is selecting: anything checked. Off, a row's tap selects it, as the
    /// map's tap on its track does; on, a tap checks or unchecks it.
    public var selecting: Bool { !checked.isEmpty }

    /// What the map draws bold.
    public var highlighted: Set<String> { PanelRules.boldIDs(checked: checked, focused: focused) }

    /// The rows the panel lists: the range's activities narrowed by TYPE and DISTANCE.
    public var listed: [ActivitySummary] {
        activities.filter { ActivityFacets.passesFilters($0, excludedTypes: excludedTypes, distanceFilter: distanceFilter) }
    }

    /// Every track the map shouldn't paint: filtered out, hidden, or Pending, all the same answer
    /// for the map (don't draw it, don't fly to it). Pending isn't folded into hidden, so the
    /// user's own Show/Hide survives the reprocess.
    public var mapHidden: Set<String> {
        Set(activities.filter {
            $0.isPending || hidden.contains($0.id) || !ActivityFacets.passesFilters($0, excludedTypes: excludedTypes, distanceFilter: distanceFilter)
        }.map(\.id))
    }

    /// What the toolbar acts on.
    public var targetIDs: Set<String> { PanelRules.targetIDs(checked: checked, focused: focused) }

    /// targetIDs' rows among the ones listed: none when every one is filtered out, which
    /// disables the toolbar the same as having no target at all.
    public var targets: [ActivitySummary] {
        let ids = targetIDs
        return listed.filter { ids.contains($0.id) }
    }

    public var hasActiveFilters: Bool { !excludedTypes.isEmpty || distanceFilter != nil }

    /// A fresh list for the same range, after a sync or an edit. Selection, the group and the
    /// hidden set keep whatever of theirs still exists.
    public mutating func setActivities(_ next: [ActivitySummary]) {
        activities = next
        let ids = Set(next.map(\.id))
        checked.formIntersection(ids)
        hidden.formIntersection(ids)
        if let focused, !ids.contains(focused) { self.focused = nil }
    }

    /// A Story opened or closed changes which rows exist, so everything built against the old
    /// ones goes; a stale Distance band in particular could exclude everything.
    public mutating func startOver() {
        checked = []
        focused = nil
        hidden = []
        excludedTypes = []
        distanceFilter = nil
    }

    /// Selects id alone, which ends selecting, as the two never show at once.
    public mutating func focus(_ id: String) {
        checked = []
        focused = id
    }

    public mutating func clearFocus() { focused = nil }

    /// Checks id, or unchecks it; true when it's now checked. The first check starts selecting,
    /// and the selected activity, if any, joins the group rather than vanishing.
    @discardableResult
    public mutating func toggleChecked(_ id: String) -> Bool {
        if checked.contains(id) {
            checked.remove(id)
            return false
        }
        if checked.isEmpty, let focused { checked.insert(focused) }
        focused = nil
        checked.insert(id)
        return true
    }

    /// The master checkbox from unchecked or partial: every row listed, not the ones filtered
    /// out of sight.
    public mutating func checkAll() { checked = Set(listed.map(\.id)) }

    public mutating func clearChecked() { checked = [] }

    /// Checks every listed row that isn't and unchecks every one that is; a checked row filtered
    /// out of sight is dropped rather than kept checked where it can't be seen.
    public mutating func invertChecked() { checked = Set(listed.map(\.id).filter { !checked.contains($0) }) }

    /// The toolbar's Show/Hide over its target.
    public mutating func toggleTargetVisibility() {
        hidden = PanelRules.toggledVisibility(hidden: hidden, target: targetIDs)
    }

    /// A toggle, so a type is always one tap from coming back without "Reset filters".
    public mutating func toggleType(_ type: String) {
        if excludedTypes.remove(type) == nil { excludedTypes.insert(type) }
    }

    /// The TYPE dropdown's "All types": only ever re-includes everything.
    public mutating func includeAllTypes() { excludedTypes = [] }

    public mutating func resetFilters() {
        excludedTypes = []
        distanceFilter = nil
    }
}

/// Which activities the map's list and tracks show, the visible area under Dates or a Story, and
/// the rules between that scope, the panel's selection and the camera (root docs/SPEC.md FR-5.19,
/// FR-5.20, FR-14.6): Dates and the area keep the selection, which the next list prunes
/// (PanelState.setActivities); setting Dates or opening a Story moves the camera once (consumeFly).
public struct MapSession: Equatable, Sendable {
    public var panel = PanelState()
    /// The Dates filter; all time until set.
    public private(set) var dates = DateFilter.allTime
    /// The map view the list was last asked about, `[west, south, east, north]`; nil until the
    /// opening view settles.
    public private(set) var area: [Double]?
    /// The open Story: the list and tracks are its activities, dates and area kept for when it closes.
    public private(set) var storyID: String?
    /// The camera moves onto what's shown next: a Story's list, or what Dates match.
    public private(set) var flyRequest = false

    public init() {}

    /// Dates changed (DateFilter.setting); fly moves the camera onto the matches once, never with
    /// a Story open.
    public mutating func setDates(_ next: DateFilter, fly: Bool) {
        dates = next
        flyRequest = fly && storyID == nil
    }

    /// The list is asked about this view; false for one it was already asked about.
    @discardableResult
    public mutating func areaLoaded(_ box: [Double]) -> Bool {
        guard !AreaLoad.same(area, box) else { return false }
        area = box
        return true
    }

    /// View on map for an activity not listed: Dates on its own day, and the camera onto it.
    public mutating func viewDay(_ day: String) {
        setDates(DateFilter(after: day, before: day), fly: true)
    }

    public mutating func enterStory(_ id: String) {
        storyID = id
        flyRequest = true
        panel.startOver()
    }

    /// Back to the area and Dates; the camera stays.
    public mutating func exitStory() {
        storyID = nil
        flyRequest = false
        panel.startOver()
    }

    /// Whether a flight was requested, which this answer uses up.
    public mutating func consumeFly() -> Bool {
        defer { flyRequest = false }
        return flyRequest
    }
}
