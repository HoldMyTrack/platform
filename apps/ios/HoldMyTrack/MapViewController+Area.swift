import CoreLocation
import HoldMyTrackCore
import MapLibre
import UIKit

/// The list of the visible area under Dates (root docs/SPEC.md FR-4.4, FR-5.11, FR-5.12): the
/// opening view, the list following the map once it settles from zoom 4, the 1,000 cap drawn
/// through the tracks layer's `capped` and `listed` vars, and the Dates sheet with its one flight.
extension MapViewController {
    // MARK: The opening view

    /// Once per sign-in, whose screens are new: the newest few tracks framed at zoom 12 (OpeningView),
    /// then the list asked about wherever the camera is. An account with nothing on the map gets a
    /// pointer, the demo never, and is asked again on every return to the map while it shows, as
    /// on Android; a flight already asked for (View on map) keeps its camera.
    /// asked: a new ask, a return or something arriving, which a failed read is made again for
    /// while the empty map's pointer shows.
    func openOnce(asked: Bool = false) {
        if asked {
            openRetriesLeft = OpeningView.retries
            openRetry?.cancel()
        }
        guard !framed || noticeShown(.empty) else {
            if let known = hasTracks { onHistoryKnown?(known) }
            return
        }
        // One read at a time, or a later answer would pull the camera back from the user.
        guard !opening else {
            openAgain = true
            return
        }
        opening = true
        let movesAsked = cameraMoves
        Task {
            defer {
                opening = false
                // Asked while this one read an empty account: something may have come since.
                let again = openAgain && noticeShown(.empty)
                openAgain = false
                if again { openOnce() }
            }
            guard let newest = try? await flow.api.areaList(box: nil, dates: .allTime, limit: OpeningView.tracks) else {
                followArea()
                // Asked again meanwhile: the defer reads now. Else one retry waits at a time.
                if !openAgain, OpeningView.retries(emptyShown: noticeShown(.empty), left: openRetriesLeft) {
                    openRetriesLeft -= 1
                    openRetry?.cancel()
                    openRetry = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled, let self, self.noticeShown(.empty) else { return }
                        self.openOnce()
                    }
                }
                return
            }
            framed = true
            hasTracks = !newest.tracks.isEmpty
            onHistoryKnown?(!newest.tracks.isEmpty)
            let boxes = FitBoxes.of(newest.tracks)
            if let view = OpeningView.of(boxes, width: mapView.bounds.width, height: mapView.bounds.height) {
                hideNotice(.empty)
                switch OpeningView.move(found: true, recording: recordingLive, tripOpen: session.tripID != nil,
                                        flightAsked: session.flyRequest, moved: cameraMoves != movesAsked) {
                case .move:
                    appFlying = true
                    mapView.setCenter(CLLocationCoordinate2D(latitude: view.lat, longitude: view.lon), zoomLevel: view.zoom, animated: false)
                    DispatchQueue.main.async { [weak self] in self?.appFlying = false }
                case .hold: openingHeldAt = cameraMoves
                case .stay: break
                }
            } else if MapChrome.emptyNoticeShown(empty: true, demo: account.isDemo, closed: EmptyNoticeDismissal.closed(account: accountKey)) {
                let account = accountKey
                notice(.empty, String(localized: "Nothing on your map yet. Record a walk with the button below."), action: (String(localized: "Sync"), { [weak self] in self?.onWantsSync?() })) {
                    EmptyNoticeDismissal.close(account: account)
                }
            }
            followArea()
        }
    }

    /// A Trip closed: an opening view it held back is taken, unless the camera has moved since, the
    /// Trip's own flight included, which has framed its tracks.
    func tripClosed() {
        guard let held = openingHeldAt else { return }
        openingHeldAt = nil
        guard held == cameraMoves else { return }
        framed = false
        openOnce()
    }

    // MARK: Following the map

    /// The camera settled: from zoom 4 the list follows it once it has been still for a moment, so
    /// a pan in steps asks once. The app's own flights (a focused row, a Trip) leave the list as
    /// it is, or focusing a row would shrink the list to that row's track; so does a recording,
    /// whose camera moves with every fix (MapChrome.listFollows).
    func cameraSettled() {
        settleTask?.cancel()
        guard MapChrome.listFollows(appFlight: appFlying, recording: recordingLive) else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.followArea()
        }
    }

    /// The list asked about the view as it is, unless it already was; always, on closing a Trip.
    /// An open Trip's list is its own: the view is only kept for when it closes.
    func followArea(always: Bool = false) {
        let b = mapView.visibleCoordinateBounds
        let box = AreaLoad.box(west: b.sw.longitude, south: b.sw.latitude, east: b.ne.longitude, north: b.ne.latitude)
        let moved = session.areaLoaded(box)
        guard session.tripID == nil else { return }
        if moved || always || listZoomedOut != zoomedOut { loadList() }
    }

    /// Whether the map is too far out to list anything.
    var listZoomedOut: Bool { AreaLoad.of(zoom: mapView.zoomLevel, listed: 0, total: nil).load == .none }

    /// Past the cap the map draws only the listed tracks and says how many the area holds.
    func renderCap() {
        let capped = session.tripID == nil && AreaLoad.of(zoom: mapView.zoomLevel, listed: tracks.count, total: areaTotal).capped
        // The cap narrows the map to the Tracks list, which Library's map doesn't follow.
        let mapCapped = capped && mapFiltersApply
        state.vars["capped"] = .bool(mapCapped)
        state.vars["listed"] = .array(mapCapped ? tracks.map { .string($0.id) } : [])
        if capped, let total = areaTotal {
            let count = { (n: Int) in NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
            notice(.capped, String(localized: "Showing the newest \(count(tracks.count)) of \(count(total)) tracks here. Zoom in or set Dates to see the rest."))
        } else {
            hideNotice(.capped)
        }
    }

    // MARK: Dates

    /// Dates' bounds: the first and newest tracks' days, asked again on every return to the
    /// map and after an import or a delete, which can change them.
    func loadHistory() {
        Task {
            guard let page = try? await flow.api.trackDays(limit: 1, before: nil) else { return }
            history = (page.earliest, page.days.last)
        }
    }

    private var today: String { DateFilter.today(in: account.timezone) }
    private var datesBounds: (min: String, max: String) { DateFilter.bounds(earliest: history.earliest, latest: history.latest, today: today) }

    func showDates() {
        let sheet = DatesViewController(filter: session.dates, bounds: datesBounds, earliest: history.earliest, today: today) { [weak self] end, value in
            self?.setDates(end, value)
        }
        datesSheet = sheet
        let nav = UINavigationController(rootViewController: sheet)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        present(nav, animated: true)
    }

    private func setDates(_ end: DateFilter.End, _ value: String?) {
        let result = session.dates.setting(end, to: value, bounds: datesBounds)
        guard result.filter != session.dates else { return }
        session.setDates(result.filter, fly: result.fly)
        datesChanged()
    }

    /// Dates changed: their button, the tracks, and the list, after a flight onto what they match
    /// when one was asked for.
    func datesChanged() {
        datesSheet?.update(session.dates)
        renderDates()
        updateTracksQuery()
        if MapChrome.flies(asked: session.consumeFly(), recording: recordingLive) { datesFlight() } else { loadList() }
    }

    func renderDates() {
        tracksPanel.setDates(session.dates.buttonText(today: today), set: session.dates != .allTime)
    }

    /// Setting Dates moves the camera once onto what they match, wherever it is, asked for without
    /// an area, since the area holds only what's in view; the list then follows the new view.
    /// Nothing matched leaves the camera.
    private func datesFlight() {
        let dates = session.dates
        Task {
            let read = try? await flow.api.areaList(box: nil, dates: dates)
            guard dates == session.dates else { return }
            // A recording started while the tracks were read has the camera.
            guard MapChrome.flies(asked: true, recording: recordingLive) else { return loadList() }
            guard let box = MapFraming.union(FitBoxes.of(read?.tracks ?? [])) else { return loadList() }
            fit(box, animated: true) { [weak self] in
                guard let self else { return }
                self.followArea()
                self.loadList()
            }
        }
    }

    /// The tiles' query: an open Trip whole (root docs/SPEC.md FR-13.6), else every track Dates
    /// pass, and a counter bumped whenever tracks change under the same query. The area is the
    /// list's alone: past the cap the listed vars choose (renderCap).
    func updateTracksQuery() {
        var parts: [String] = []
        if let trip = session.tripID {
            parts.append("trip=\(trip.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trip)")
        } else if mapFiltersApply {
            // Library's map shows every track, of all time.
            parts += session.dates.query.map { "\($0.name)=\($0.value ?? "")" }
        }
        if tracksVersion > 0 { parts.append("v=\(tracksVersion)") }
        state.queries["tracks"] = parts.joined(separator: "&")
        render()
    }
}

extension DateFilter {
    /// The Dates button's words, the Tracks tab's and Library's: "Dates", or the days set.
    func buttonText(today: String) -> String {
        let format = { (day: String) in DateFilter.short(day, today: today, locale: .current) }
        return switch label {
        case .all: String(localized: "Dates")
        case let .between(a, b): String(localized: "\(format(a)) – \(format(b))", comment: "Dates: both ends set.")
        // Its own key: "From %@" is a Trip copy's sender, which Russian words differently.
        case let .after(a): String(localized: "dates.from", defaultValue: "From \(format(a))", comment: "Dates: only the first day set.")
        case let .before(b): String(localized: "Until \(format(b))")
        }
    }
}