import HoldMyTrackCore
import MapLibre
import UIKit

/// The sheet's tabs: the tab bar's Map shows Activities, its Stories the Stories tab.
enum PanelTab { case activities, stories }

/// The sheet over the map (apps/android/docs/SPEC.md FR-2.7): the list for the range or the open
/// Story, the selection bound into the map's `focused` and `hidden` vars, Pending watched, and the
/// toolbar's Edit, Delete and Add to story. How it fits together is
/// apps/ios/docs/IMPLEMENTATION.md §3.4.
extension MapViewController {
    func buildPanel() {
        activitiesPanel = ActivitiesPanel(format: format, demo: account.isDemo)
        storiesPanel = StoriesPanel(api: flow.api, format: format, demo: account.isDemo)
        activitiesPanel.onEvent = { [weak self] in self?.handle($0) }
        storiesPanel.onEvent = { [weak self] in self?.handle($0) }
        for button in activitiesPanel.addToStoryButtons {
            button.menu = StoryDialogs.addToStoryMenu(api: flow.api, over: view, targets: { [weak self] in
                guard let self else { return [] }
                return self.session.panel.targets.map(\.id)
            }, added: { [weak self] story, created in self?.addedToStory(story, created: created) })
        }

        slider.accessibilityIdentifier = "dateRange"
        for v in [slider, activitiesPanel.card, activitiesPanel.summary, storiesPanel.head] as [UIView] { sheet.head.addArrangedSubview(v) }
        for v in [activitiesPanel.content, storiesPanel.content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sheet.content.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: sheet.content.topAnchor),
                // Below required, so a collapsed sheet clips its content rather than squeezing its head.
                {
                    let c = v.bottomAnchor.constraint(equalTo: sheet.content.bottomAnchor)
                    c.priority = .defaultHigh
                    return c
                }(),
                v.leadingAnchor.constraint(equalTo: sheet.content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: sheet.content.trailingAnchor),
            ])
        }

        // A tap on a track, or on empty map; the map's own double tap still zooms.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedMap(_:)))
        for other in mapView.gestureRecognizers ?? [] where (other as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 {
            tap.require(toFail: other)
        }
        mapView.addGestureRecognizer(tap)
        NotificationCenter.default.addObserver(forName: ActivityTypes.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderPanel() }
        }
        renderPanel()
    }

    // MARK: Tabs

    /// The tab bar's Map or Stories brought the map forward.
    func show(_ next: PanelTab, story: String? = nil) {
        loadViewIfNeeded()
        if next == panelTab {
            if let story { open(story) }
            return
        }
        panelTab = next
        if next == .stories {
            storiesPanel.start()
            sheet.setDetent(.half, animated: false)
            if let story { open(story) }
        } else {
            storiesPanel.stop()
            if session.storyID != nil {
                session.exitStory()
                storiesPanel.setOpen(nil)
                updateTracksQuery()
                loadList()
            }
            sheet.setDetent(.collapsed, animated: false)
        }
        applyTabMode()
        panelChanged()
    }

    private func open(_ story: String) {
        session.enterStory(story)
        storiesPanel.setOpen(story)
        activities = []
        updateTracksQuery()
        loadList()
        panelChanged()
    }

    /// Sync history's View on map (apps/android/docs/SPEC.md FR-4.1): the activity focused once
    /// the list is in; a day outside the range becomes the range, as if picked.
    func viewOnMap(activity: String, day: String) {
        loadViewIfNeeded()
        // The activity's track is Normal mode's.
        if pickedMode != .normal { pickMode(.normal) }
        focusWhenListed = activity
        if session.range?.contains(day) == true && session.storyID == nil {
            loadList()
        } else {
            session.viewDay(day)
            panelChanged()
            showRange()
        }
    }

    // MARK: The list

    /// The range's or the open Story's activities, read for each and on every return to the map.
    func loadList() {
        guard isViewLoaded, session.storyID != nil || session.range != nil else { return }
        listTask?.cancel()
        let story = session.storyID, range = session.range
        listLoading = true
        listError = nil
        renderPanel()
        listTask = Task {
            do {
                let read = try await flow.api.activityList(from: range?.from, to: range?.to, story: story)
                guard !Task.isCancelled else { return }
                ActivityTypes.shared.merge(read.types)
                ActivityTypes.shared.refresh(read.activities.map(\.activityType), api: flow.api)
                listed(read.activities)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                listLoading = false
                listError = (error as? APIError)?.serverMessage ?? String(localized: "Activities couldn't load.")
                renderPanel()
            }
        }
    }

    /// A fresh list: what of the selection still exists stays, a finished reprocess fetches the
    /// tracks again, and a picked range or an opened Story flies onto it.
    private func listed(_ next: [Activity]) {
        let change = PendingDiff.of(previous: pendingIDs, now: Set(next.filter(\.pending).map(\.id)), awaiting: awaiting)
        pendingIDs = change.now
        awaiting = change.awaiting
        activities = next
        listLoading = false
        listError = nil
        session.panel.setActivities(next.map(\.summary))
        if change.finished {
            tracksVersion += 1
            updateTracksQuery()
            reloadDays()
        }
        if change.started || !change.now.isEmpty {
            notice(.pending, String(localized: "Some activities are being processed. They'll show on the map when they're done."))
        } else {
            hideNotice(.pending)
        }
        if session.consumeFly() {
            fly(next.map(\.id))
        }
        if let id = focusWhenListed, next.contains(where: { $0.id == id }) {
            focusWhenListed = nil
            session.panel.focus(id)
            fly([id])
        }
        panelChanged()
        watchPending()
    }

    /// Every 2 seconds while a row is Pending or an edit saved here hasn't landed: the list is
    /// read again once one of them moves.
    private func watchPending() {
        pendingTask?.cancel()
        let watched = PendingDiff.watched(listed: activities.filter(\.pending).map(\.id), awaiting: Array(awaiting))
        guard !watched.isEmpty else { return }
        pendingTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            var still: [String] = []
            for batch in PendingDiff.batches(watched) {
                guard let answer = try? await flow.api.pending(batch) else {
                    watchPending()
                    return
                }
                still += answer
            }
            guard !Task.isCancelled else { return }
            if PendingDiff.moved(watched: watched, stillPending: still) { loadList() } else { watchPending() }
        }
    }

    // MARK: State to the map and the sheet

    /// The selection changed: the map's bold and hidden tracks, and the sheet.
    func panelChanged() {
        let panel = session.panel
        state.vars["focused"] = .array(panel.highlighted.sorted().map { .string($0) })
        state.vars["hidden"] = .array(panel.mapHidden.sorted().map { .string($0) })
        render()
        renderPanel()
    }

    func renderPanel() {
        guard activitiesPanel != nil else { return }
        let format = format
        let note: (text: String, failed: Bool)? = listLoading && activities.isEmpty ? (String(localized: "Loading…"), false) : listError.map { ($0, true) }
        activitiesPanel.render(session.panel, activities: activities, format: format, note: note)
        if panelTab == .stories {
            let panel = session.panel
            let byID = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let rows = session.storyID == nil ? [] : panel.listed.compactMap { byID[$0.id] }.map {
                ActivityRowCell.Row(activity: $0, checked: false, focused: panel.focused == $0.id, hidden: panel.hidden.contains($0.id), selecting: false)
            }
            storiesPanel.setRows(rows, note: session.storyID == nil ? nil : note, format: format)
        }
        let activitiesTab = panelTab == .activities
        let card = activitiesTab && activitiesPanel.showsCard
        slider.isHidden = !activitiesTab || card || !days.ready || days.days.isEmpty
        activitiesPanel.summary.isHidden = !activitiesTab || card
        activitiesPanel.card.isHidden = !card
        storiesPanel.head.isHidden = activitiesTab
        activitiesPanel.content.isHidden = !activitiesTab
        storiesPanel.content.isHidden = activitiesTab
        // Normal mode only (apps/android/docs/SPEC.md FR-2.7).
        sheet.isHidden = state.mode != .normal
        sheet.setNeedsLayout()
    }

    // MARK: Events

    private func handle(_ event: ActivitiesPanel.Event) {
        switch event {
        case .tapRow(let id):
            session.panel.focus(id)
            fly([id])
            sheet.setDetent(.collapsed, animated: true)
        case .toggleChecked(let id):
            if session.panel.toggleChecked(id) { fly([id]) }
        case .clearFocus: session.panel.clearFocus()
        case .endSelecting, .checkNone: session.panel.clearChecked()
        case .checkAll: session.panel.checkAll()
        case .invert: session.panel.invertChecked()
        case .toggleVisibility: session.panel.toggleTargetVisibility()
        case .fly: fly(session.panel.targets.map(\.id))
        case .edit: edit()
        case .delete: confirmDelete()
        case .toggleType(let type): session.panel.toggleType(type)
        case .allTypes: session.panel.includeAllTypes()
        case .distance(let band): session.panel.distanceFilter = band
        case .resetFilters: session.panel.resetFilters()
        case .openStory(let id):
            onWantsStories?(id)
            return
        }
        panelChanged()
    }

    private func handle(_ event: StoriesPanel.Event) {
        switch event {
        case .open(let id, let collapse):
            if collapse { sheet.setDetent(.collapsed, animated: true) }
            open(id)
        case .close:
            session.exitStory()
            storiesPanel.setOpen(nil)
            updateTracksQuery()
            loadList()
        case .select(let id):
            session.panel.focus(id)
            fly([id])
            panelChanged()
        case .clearFocus:
            session.panel.clearFocus()
            panelChanged()
        case .storiesChanged:
            loadList()
        case .removed:
            tracksVersion += 1
            updateTracksQuery()
            loadList()
        case .copyArrived:
            tracksVersion += 1
            updateTracksQuery()
            reloadDays()
            loadList()
        case .waiting(let count):
            onWaiting?(count)
        }
    }

    /// A Story made or added to from the toolbar: the badges, and a new one opened on the
    /// Stories tab.
    private func addedToStory(_ story: Story, created: Bool) {
        loadList()
        if created {
            storiesPanel.added(story)
            onWantsStories?(story.id)
        } else {
            StoryDialogs.inform(over: view, String(localized: "Added to “\(story.name)”."))
        }
    }

    // MARK: The map

    /// The camera onto ids' tracks, leaving out what the map doesn't draw.
    func fly(_ ids: [String]) {
        let hidden = session.panel.mapHidden
        let wanted = Set(ids)
        let boxes = activities.filter { wanted.contains($0.id) && !hidden.contains($0.id) }.compactMap(\.bbox)
        guard let box = MapFraming.union(boxes) else { return }
        fit(box, animated: true)
    }

    /// A track within TrackTap.radius of the finger: checked while selecting, else focused,
    /// without opening the sheet. Empty map clears the focus.
    @objc private func tappedMap(_ tap: UITapGestureRecognizer) {
        guard state.mode == .normal, !sheet.isHidden || panelTab == .stories else { return }
        let point = tap.location(in: mapView)
        let r = TrackTap.radius
        let rect = CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)
        let features = mapView.visibleFeatures(in: rect, styleLayerIdentifiers: trackLayers)
        let listed = Set(session.panel.listed.map(\.id))
        guard let id = TrackTap.pick(features.map { $0.attribute(forKey: "id") as? String }, listed: listed) else {
            if session.panel.focused != nil {
                session.panel.clearFocus()
                panelChanged()
            }
            return
        }
        if panelTab == .activities && session.panel.selecting {
            session.panel.toggleChecked(id)
            activitiesPanel.scrollTo(id)
        } else {
            session.panel.focus(id)
            fly([id])
            if panelTab == .stories { storiesPanel.scrollTo(id) } else { activitiesPanel.scrollTo(id) }
        }
        panelChanged()
    }

    // MARK: Edit and Delete

    private var targets: [Activity] {
        let ids = Set(session.panel.targets.map(\.id))
        return activities.filter { ids.contains($0.id) }
    }

    private func edit() {
        let group = targets
        guard !group.isEmpty, !account.isDemo else { return }
        editOpen = true
        let facets = ActivityFacets.typeFacets(session.panel.activities, distanceFilter: nil)
        let editor = EditActivityViewController(api: flow.api, group: group, facets: facets, format: format) { [weak self] written in
            guard let self else { return }
            self.editOpen = false
            guard !written.isEmpty else { return }
            self.awaiting.formUnion(written)
            self.loadList()
        }
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    /// Delete over the toolbar's target (root docs/SPEC.md FR-5.11), confirmed first, one at a
    /// time; on a failure, what was already deleted is reported as gone.
    private func confirmDelete() {
        let group = targets
        guard !group.isEmpty, !account.isDemo else { return }
        let format = format
        let name = group.count == 1 ? format.label(group[0]) : String(localized: "Checked: \(group.count)")
        let summary = "\(name) (\(format.totalDistance(group.compactMap(\.distanceMeters).reduce(0, +))))"
        let title = group.count == 1 ? String(localized: "Delete this activity?") : String(localized: "Delete these activities?")
        let message = String(localized: "\(summary) will be deleted for good, with its track and its part of Fog of War and Heatmap.")
        var done: [String] = []
        StoryDialogs.confirm(over: view, title: title, message: message, action: String(localized: "Delete")) { [weak self] in
            guard let self else { return nil }
            defer { if !done.isEmpty { self.deleted(done) } }
            for activity in group where !done.contains(activity.id) {
                do {
                    try await self.flow.api.deleteActivity(activity.id)
                    done.append(activity.id)
                } catch {
                    let reason = (error as? APIError)?.serverMessage ?? String(localized: "The server couldn't be reached.")
                    return String(localized: "Deleted: \(done.count). The rest couldn't be deleted: \(reason)")
                }
            }
            return nil
        }
    }

    private func deleted(_ ids: [String]) {
        tracksVersion += 1
        updateTracksQuery()
        reloadDays()
        loadList()
        if panelTab == .stories { storiesPanel.reloadOpen() }
    }
}

/// The tab bar's Map or Stories: both are the one map screen, moved into whichever of the two
/// shows, so the camera, range and selection are as they were (apps/android/docs/SPEC.md FR-2.9).
final class MapHostViewController: UIViewController {
    private let map: MapViewController
    private let panelTab: PanelTab
    /// A Story to open when this host next shows.
    var pendingStory: String?

    init(map: MapViewController, tab: PanelTab) {
        self.map = map
        self.panelTab = tab
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if map.parent !== self {
            map.willMove(toParent: nil)
            map.view.removeFromSuperview()
            map.removeFromParent()
            addChild(map)
            map.view.frame = view.bounds
            map.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(map.view)
            map.didMove(toParent: self)
        }
        map.show(panelTab, story: pendingStory)
        pendingStory = nil
    }
}