import HoldMyTrackCore
import MapLibre
import UIKit

/// The sheet's tabs: the tab bar's Tracks shows Tracks, its Trips the Trips tab, its Sync the
/// Sync tab.
enum PanelTab { case tracks, trips, sync }

/// The sheet over the map (apps/android/docs/SPEC.md FR-2.7): the list for the range or the open
/// Trip, the selection bound into the map's `focused` and `hidden` vars, Pending watched, and the
/// toolbar's Edit, Delete and Add to trip. How it fits together is
/// apps/ios/docs/IMPLEMENTATION.md §3.4.
extension MapViewController {
    func buildPanel() {
        tracksPanel = TracksPanel(format: format, demo: account.isDemo)
        tripsPanel = TripsPanel(api: flow.api, format: format, demo: account.isDemo)
        tracksPanel.onEvent = { [weak self] in self?.handle($0) }
        tripsPanel.onEvent = { [weak self] in self?.handle($0) }
        for button in tracksPanel.addToTripButtons {
            button.menu = TripDialogs.addToTripMenu(api: flow.api, over: view, targets: { [weak self] in
                guard let self else { return [] }
                return self.session.panel.targets.map(\.id)
            }, added: { [weak self] trip, created in self?.addedToTrip(trip, created: created) })
        }

        for v in [tracksPanel.card, tracksPanel.summary, tripsPanel.head, syncPanel?.head].compactMap({ $0 }) as [UIView] { sheet.head.addArrangedSubview(v) }
        // In the mode toggle's place while rows are checked (MapViewController+TopRow).
        modesRow.insertArrangedSubview(tracksPanel.selectionBar, at: 1)
        for v in [tracksPanel.content, tripsPanel.content, syncPanel?.content].compactMap({ $0 }) {
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
        bindRouteEditDrag()
        NotificationCenter.default.addObserver(forName: TrackTypes.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderPanel() }
        }
        renderPanel()
    }

    // MARK: Tabs

    /// The tab bar's Tracks, Trips or Sync brought the map forward. fresh is false for a return
    /// from a screen pushed over the map, such as Upload, which keeps the Sync tab's ticks.
    func show(_ next: PanelTab, trip: String? = nil, fresh: Bool = true) {
        loadViewIfNeeded()
        if next == panelTab {
            if let trip { open(trip) }
            if next == .sync {
                if fresh { syncPanel?.start() } else { syncPanel?.render() }
            }
            return
        }
        let left = panelTab
        panelTab = next
        if left == .sync { syncPanel?.stop() }
        switch next {
        case .trips:
            tripsPanel.start()
            sheet.setDetent(.half, animated: false)
            if let trip { open(trip) }
        case .tracks, .sync:
            tripsPanel.stop()
            if session.tripID != nil {
                session.exitTrip()
                tripsPanel.setOpen(nil)
                updateTracksQuery()
                followArea(always: true)
            }
            sheet.setDetent(next == .sync ? .half : .collapsed, animated: false)
        }
        applyTabMode()
        panelChanged()
        // Once the sheet is up at half height, so the first framing clears it.
        if next == .sync { syncPanel?.start() }
    }

    private func open(_ trip: String) {
        session.enterTrip(trip)
        tripsPanel.setOpen(trip)
        tracks = []
        updateTracksQuery()
        loadList()
        panelChanged()
    }

    /// Sync history's View on map (apps/android/docs/SPEC.md FR-4.1): the track focused once
    /// the list has it; one not listed sets Dates to its day, which flies the camera there.
    func viewOnMap(track: String, day: String) {
        loadViewIfNeeded()
        // The track's route is Normal mode's.
        if pickedMode != .normal { pickMode(.normal) }
        focusWhenListed = track
        if session.tripID == nil && tracks.contains(where: { $0.id == track }) {
            loadList()
        } else {
            if session.tripID != nil { show(.tracks) }
            session.viewDay(day)
            datesChanged()
        }
    }

    // MARK: The list

    /// The open Trip's tracks, else the area's under Dates, read for each and on every
    /// return to the map. Too far out the list is empty, asking nothing.
    func loadList() {
        guard isViewLoaded else { return }
        listTask?.cancel()
        let trip = session.tripID, dates = session.dates, area = session.area
        if trip == nil {
            // Not until the opening view has asked about an area.
            guard area != nil else { return }
            zoomedOut = listZoomedOut
            if zoomedOut {
                areaTotal = nil
                listed([])
                return
            }
        }
        listLoading = true
        listError = nil
        renderPanel()
        listTask = Task {
            do {
                let read: (tracks: [Track], total: Int?, types: [String: TrackTypeInfo])
                if let trip {
                    let r = try await flow.api.tripTracks(trip)
                    read = (r.tracks, nil, r.types)
                } else {
                    read = try await flow.api.areaList(box: area, dates: dates)
                }
                guard !Task.isCancelled else { return }
                TrackTypes.shared.merge(read.types)
                TrackTypes.shared.refresh(read.tracks.map(\.trackType), api: flow.api)
                areaTotal = read.total
                listed(read.tracks)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                listLoading = false
                listError = (error as? APIError)?.serverMessage ?? String(localized: "Tracks couldn't load.")
                renderPanel()
                // A failed read doesn't end the polling: a Pending row still has to be seen finishing.
                watchPending()
            }
        }
    }

    /// A fresh list: what of the selection still exists stays, a finished reprocess fetches the
    /// tracks again, and a picked range or an opened Trip flies onto it.
    private func listed(_ next: [Track]) {
        let change = PendingDiff.of(previous: pendingIDs, now: Set(next.filter(\.pending).map(\.id)), awaiting: awaiting, listed: Set(next.map(\.id)))
        pendingIDs = change.pending
        awaiting = change.awaiting
        tracks = next
        listLoading = false
        listError = nil
        session.panel.setTracks(next.map(\.summary))
        renderCap()
        if session.consumeFly() {
            let hidden = session.panel.mapHidden
            if let box = MapFraming.union(FitBoxes.of(next.filter { !hidden.contains($0.id) })) { fit(box, animated: true) }
        }
        if let id = focusWhenListed, next.contains(where: { $0.id == id }) {
            focusWhenListed = nil
            session.panel.focus(id)
            fly([id])
        }
        panelChanged()
        if change.finished { reprocessFinished(change.landed.union(change.left)) }
        watchPending()
    }

    /// A recording sent from the Sync tab is on the map: its tiles, Dates' bounds and the list.
    func recordingLanded() {
        tracksVersion += 1
        updateTracksQuery()
        loadHistory()
        loadList()
    }

    /// Reprocesses of ids finished, seen by a list or by the Pending check: the tracks' tiles,
    /// Dates' bounds and the photos follow the new points, and the focused track's bands if it
    /// is among them.
    private func reprocessFinished(_ ids: Set<String>) {
        tracksVersion += 1
        updateTracksQuery()
        loadHistory()
        if let focused = session.panel.focused, ids.contains(focused) { updateBands(refetch: true) }
        refreshPhotos(force: true)
    }

    /// Every 2 seconds while a row is held Pending or an edit saved here hasn't landed: the list is
    /// read again once a listed one moves, and one it doesn't show finishes by the check alone.
    /// Called again after a save, which cancels the check in flight: its answer was asked before
    /// the save and would count the new edit as landed.
    func watchPending() {
        pendingTask?.cancel()
        let watched = PendingDiff.watched(pending: Array(pendingIDs), awaiting: Array(awaiting))
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
            let answer = PendingDiff.answer(watched: watched, stillPending: still, listed: Set(tracks.map(\.id)))
            if !answer.finished.isEmpty {
                pendingIDs.subtract(answer.finished)
                awaiting.subtract(answer.finished)
                reprocessFinished(answer.finished)
            }
            if answer.moved { loadList() } else { watchPending() }
        }
    }

    // MARK: State to the map and the sheet

    /// The selection changed: the map's bold and hidden tracks, and the sheet.
    func panelChanged() {
        let panel = session.panel
        state.vars["focused"] = .array(panel.highlighted.sorted().map { .string($0) })
        state.vars["hidden"] = .array(hiddenTracks.map { .string($0) })
        updateBands()
        render()
        renderPanel()
        refreshPhotos(force: false)
    }

    func renderPanel() {
        guard tracksPanel != nil else { return }
        let format = format
        let zoomNote = zoomedOut && session.tripID == nil ? String(localized: "Zoom in to see your tracks.") : nil
        let note: (text: String, failed: Bool)? = zoomNote.map { ($0, false) }
            ?? (listLoading && tracks.isEmpty ? (String(localized: "Loading…"), false) : listError.map { ($0, true) })
        tracksPanel.render(session.panel, tracks: tracks, format: format, note: note)
        tracksPanel.setLoading(listLoading && !(zoomedOut && session.tripID == nil))
        if panelTab == .trips {
            let panel = session.panel
            let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let rows = session.tripID == nil ? [] : panel.listed.compactMap { byID[$0.id] }.map {
                TrackRowCell.Row(track: $0, checked: false, focused: panel.focused == $0.id, hidden: panel.hidden.contains($0.id), selecting: false)
            }
            tripsPanel.setRows(rows, note: session.tripID == nil ? nil : note, format: format)
        }
        let tracksTab = panelTab == .tracks
        let card = tracksTab && tracksPanel.showsCard
        tracksPanel.summary.isHidden = !tracksTab || card
        tracksPanel.card.isHidden = !card
        tripsPanel.head.isHidden = panelTab != .trips
        tracksPanel.content.isHidden = !tracksTab
        tripsPanel.content.isHidden = panelTab != .trips
        syncPanel?.head.isHidden = panelTab != .sync
        syncPanel?.content.isHidden = panelTab != .sync
        notices.aside = MapChrome.areaNoticesShown(recording: recordingLive, onSync: panelTab == .sync) ? [] : [Notice.empty.rawValue, Notice.capped.rawValue]
        // Normal mode only (apps/android/docs/SPEC.md FR-2.7).
        sheet.isHidden = !MapChrome.sheetShown(normal: state.mode == .normal, recording: recordingLive, onSync: panelTab == .sync,
                                               editing: editOpen || privateLocations.open)
        sheet.setNeedsLayout()
        // The map's credit sits above the sheet (placeAttribution), and the row's controls follow it.
        view.setNeedsLayout()
        renderTopRow()
    }

    // MARK: Events

    private func handle(_ event: TracksPanel.Event) {
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
        case .dates: showDates()
        case .openTrip(let id):
            onWantsTrips?(id)
            return
        }
        panelChanged()
    }

    /// The tour runs with no rows checked, since checked rows put the rail its steps point at
    /// away; it hands back the ones it unchecked, for recheckAfterTour.
    func uncheckForTour() -> Set<String> {
        let checked = session.panel.checked
        guard !checked.isEmpty else { return [] }
        session.panel.clearChecked()
        panelChanged()
        return checked
    }

    /// The rows the tour unchecked, checked again as it ends.
    func recheckAfterTour(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        session.panel.restoreChecked(ids)
        panelChanged()
    }

    private func handle(_ event: TripsPanel.Event) {
        switch event {
        case .open(let id, let collapse):
            if collapse { sheet.setDetent(.collapsed, animated: true) }
            open(id)
        case .close:
            session.exitTrip()
            tripsPanel.setOpen(nil)
            updateTracksQuery()
            followArea(always: true)
        case .select(let id):
            session.panel.focus(id)
            fly([id])
            panelChanged()
        case .clearFocus:
            session.panel.clearFocus()
            panelChanged()
        case .tripsChanged:
            loadList()
            // A Trip's photos change with its members.
            refreshPhotos(force: true)
        case .removed:
            tracksVersion += 1
            updateTracksQuery()
            loadList()
        case .copyArrived:
            tracksVersion += 1
            updateTracksQuery()
            loadHistory()
            loadList()
        case .waiting(let count):
            onWaiting?(count)
        }
    }

    /// A Trip made or added to from the toolbar: the badges, and a new one opened on the
    /// Trips tab.
    private func addedToTrip(_ trip: Trip, created: Bool) {
        loadList()
        if created {
            tripsPanel.added(trip)
            onWantsTrips?(trip.id)
        } else {
            TripDialogs.inform(over: view, String(localized: "Added to “\(trip.name)”."))
        }
    }

    // MARK: The map

    /// The camera onto ids' tracks, leaving out what the map doesn't draw.
    func fly(_ ids: [String]) {
        let hidden = session.panel.mapHidden
        let wanted = Set(ids)
        let boxes = FitBoxes.selection(tracks.filter { wanted.contains($0.id) && !hidden.contains($0.id) })
        guard let box = MapFraming.union(boxes) else { return }
        fit(box, animated: true)
    }

    /// A track within TrackTap.radius of the finger: checked while selecting, else focused,
    /// without opening the sheet. Empty map clears the focus.
    @objc private func tappedMap(_ tap: UITapGestureRecognizer) {
        // The Edit window's group mustn't change under it; a tap serves only Delete point.
        guard !editOpen else { return routeEditTapped(at: tap.location(in: mapView)) }
        // The Private location editor holds the map: a tap serves only its circles.
        guard !privateLocations.open else { return privateLocationTapped(at: tap.location(in: mapView)) }
        // A place's badge first, in every mode; a tap elsewhere closes its popup.
        if tapSpot(at: tap.location(in: mapView)) {
            closeFogPlace()
            return
        }
        if state.mode == .fog {
            _ = tapFogPlace(at: tap.location(in: mapView))
            return
        }
        if panelTab == .sync {
            tapSyncLine(at: tap.location(in: mapView))
            return
        }
        guard state.mode == .normal, !sheet.isHidden || panelTab == .trips else { return }
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
        if panelTab == .tracks && session.panel.selecting {
            session.panel.toggleChecked(id)
            tracksPanel.scrollTo(id)
        } else {
            session.panel.focus(id)
            fly([id])
            if panelTab == .trips { tripsPanel.scrollTo(id) } else { tracksPanel.scrollTo(id) }
        }
        panelChanged()
    }

    // MARK: The Sync tab's lines

    /// The Sync tab's rows to draw, highlight picked out in its pace bands (SyncLines). Each
    /// route is simplified and banded once (syncShapes), and nothing is redrawn while the same
    /// rows and pick are.
    func drawSyncLines(_ tracks: [RecordedTrack], highlight: String?) {
        let drawn = SyncLines.Drawn(ids: tracks.map(\.id), highlight: highlight)
        guard drawn != syncDrawn else { return }
        syncDrawn = drawn
        var shapes: [String: SyncLines.Shape] = [:]
        for track in tracks { shapes[track.id] = syncShapes[track.id].flatMap { $0.points == track.points.count ? $0 : nil } ?? SyncLines.Shape(track) }
        syncShapes = shapes
        let lines = tracks.compactMap { shapes[$0.id] }
        state.geojson[SyncLines.group] = SyncLines.features(lines, highlight: highlight)
        state.geojson[SyncLines.bandsSource] = PaceBands.features(highlight.flatMap { shapes[$0]?.metrics })
        render()
    }

    /// A line tapped on the Sync tab: its row picked out.
    private func tapSyncLine(at point: CGPoint) {
        let r = TrackTap.radius
        let rect = CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)
        let features = mapView.visibleFeatures(in: rect, styleLayerIdentifiers: [SyncLines.highlightID, SyncLines.lineID])
        guard let key = features.lazy.compactMap({ $0.attribute(forKey: "key") as? String }).first else { return }
        syncPanel?.focus(key)
    }

    // MARK: Edit and Delete

    private var targets: [Track] {
        let ids = Set(session.panel.targets.map(\.id))
        return tracks.filter { ids.contains($0.id) }
    }

    /// The Edit window over the toolbar's target, each track read in full first: the area's
    /// rows leave out the description, the track's edit and the photos (root docs/SPEC.md FR-5.11).
    private func edit() {
        let ids = targets.map(\.id)
        guard !ids.isEmpty, !account.isDemo, !editOpen else { return }
        editOpen = true
        Task {
            var group: [Track] = []
            for id in ids {
                do {
                    group.append(try await flow.api.track(id))
                } catch {
                    editOpen = false
                    let reason = (error as? APIError)?.serverMessage ?? String(localized: "The server couldn't be reached.")
                    TripDialogs.inform(over: view, String(localized: "The track couldn't be opened: \(reason)"))
                    return
                }
            }
            openEditor(group)
        }
    }

    private func openEditor(_ group: [Track]) {
        photos.editIDs = group.map(\.id)
        refreshPhotos(force: false)
        let facets = TrackFacets.typeFacets(session.panel.tracks, distanceFilter: nil)
        let editor = EditTrackViewController(
            api: flow.api, group: group, facets: facets, format: format, images: photoViews.images,
            onOverlay: { [weak self] in self?.setPhotoOverlay($0) },
            onRouteDraw: { [weak self] in self?.setRouteEdit($0) },
            onRouteOpened: { [weak self] covered in self?.frameEditedTrack(group[0], covered: covered) }
        ) { [weak self] written, photosSaved in
            guard let self else { return }
            self.editOpen = false
            self.setRouteEdit(nil)
            self.photosEditClosed(saved: photosSaved)
            guard !written.isEmpty else { return }
            self.awaiting.formUnion(written)
            self.watchPending()
            self.loadList()
        }
        editWindow = editor
        let nav = UINavigationController(rootViewController: editor)
        // As tall as its content up to EditSheet's share, with the map live above, so the Photos
        // tab's slider moves a photo in sight; still expandable.
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.custom(identifier: EditTrackViewController.fitted) { [weak editor] context in
                editor?.detentMaximum = context.maximumDetentValue
                return editor?.detentHeight ?? context.maximumDetentValue / 2
            }, .large()]
            sheet.largestUndimmedDetentIdentifier = EditTrackViewController.fitted
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        present(nav, animated: true)
    }

    /// Delete over the toolbar's target (root docs/SPEC.md FR-5.6), confirmed first, one at a
    /// time; on a failure, what was already deleted is reported as gone.
    private func confirmDelete() {
        let group = targets
        guard !group.isEmpty, !account.isDemo else { return }
        let format = format
        let name = group.count == 1 ? String(localized: "“\(format.label(group[0]))”", comment: "Tracks tab: one track named as an action's target.") : String(localized: "panel.checkedCount", defaultValue: "\(group.count) checked tracks", comment: "Tracks tab: the checked tracks an action applies to.")
        let summary = "\(name) (\(format.totalDistance(group.compactMap(\.distanceMeters).reduce(0, +))))"
        let title = group.count == 1 ? String(localized: "Delete this track?") : String(localized: "Delete this group?")
        let message = group.count == 1
            ? String(localized: "\(summary) will be permanently deleted — its route, fog coverage, and any performance records it contributed to. This can't be undone.")
            : String(localized: "\(summary) will be permanently deleted — their routes, fog coverage, and any performance records they contributed to. This can't be undone.")
        var done: [String] = []
        TripDialogs.confirm(over: view, title: title, message: message, action: String(localized: "Delete")) { [weak self] in
            guard let self else { return nil }
            defer { if !done.isEmpty { self.deleted(done) } }
            for track in group where !done.contains(track.id) {
                do {
                    try await self.flow.api.deleteTrack(track.id)
                    done.append(track.id)
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
        loadHistory()
        loadList()
        if panelTab == .trips { tripsPanel.reloadOpen() }
    }
}

/// The tab bar's Tracks, Trips or Sync: all are the one map screen, moved into whichever shows,
/// so the camera, range and selection are as they were (apps/android/docs/SPEC.md FR-2.9).
final class MapHostViewController: UIViewController {
    private let map: MapViewController
    private let panelTab: PanelTab
    /// A Trip to open when this host next shows.
    var pendingTrip: String?
    /// A screen was pushed over this one: its return isn't a fresh showing of the tab.
    private var covered = false

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
        map.show(panelTab, trip: pendingTrip, fresh: !covered)
        pendingTrip = nil
        covered = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        covered = navigationController.map { $0.topViewController !== self } ?? false
    }
}