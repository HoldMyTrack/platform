import CoreLocation
import HoldMyTrackCore
import MapLibre
import UIKit

/// The list of the visible area under Dates (root docs/SPEC.md FR-4.5, FR-5.19, FR-5.20): the
/// opening view, the list following the map once it settles from zoom 4, the 1,000 cap drawn
/// through the tracks layer's `capped` and `listed` vars, and the Dates sheet with its one flight.
extension MapViewController {
    // MARK: The opening view

    /// Once per app session per account: the newest few tracks framed at zoom 12 (OpeningView),
    /// then the list asked about wherever the camera is. An account with nothing on the map gets a
    /// pointer, the demo never; a flight already asked for (View on map) keeps its camera.
    func openOnce() {
        guard !Self.framed.contains(accountKey) else { return }
        Task {
            guard let newest = try? await flow.api.areaList(box: nil, dates: .allTime, limit: OpeningView.activities) else {
                followArea()
                return
            }
            Self.framed.insert(accountKey)
            let boxes = newest.activities.filter { !$0.pending }.compactMap(\.bbox)
            if let view = OpeningView.of(boxes, width: mapView.bounds.width, height: mapView.bounds.height) {
                hideNotice(.empty)
                if !session.flyRequest {
                    appFlying = true
                    mapView.setCenter(CLLocationCoordinate2D(latitude: view.lat, longitude: view.lon), zoomLevel: view.zoom, animated: false)
                    DispatchQueue.main.async { [weak self] in self?.appFlying = false }
                }
            } else if !account.isDemo {
                notice(.empty, String(localized: "Nothing on your map yet. Upload a GPX, FIT or TCX file from the You tab to see it here."))
            }
            followArea()
        }
    }

    // MARK: Following the map

    /// The camera settled: from zoom 4 the list follows it once it has been still for a moment, so
    /// a pan in steps asks once. The app's own flights (a focused row, a Story) leave the list as
    /// it is, or focusing a row would shrink the list to that row's track.
    func cameraSettled() {
        settleTask?.cancel()
        guard !appFlying else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.followArea()
        }
    }

    /// The list asked about the view as it is, unless it already was; always, on closing a Story.
    /// An open Story's list is its own: the view is only kept for when it closes.
    func followArea(always: Bool = false) {
        let b = mapView.visibleCoordinateBounds
        let box = AreaLoad.box(west: b.sw.longitude, south: b.sw.latitude, east: b.ne.longitude, north: b.ne.latitude)
        let moved = session.areaLoaded(box)
        guard session.storyID == nil else { return }
        if moved || always || listZoomedOut != zoomedOut { loadList() }
    }

    /// Whether the map is too far out to list anything.
    var listZoomedOut: Bool { AreaLoad.of(zoom: mapView.zoomLevel, listed: 0, total: nil).load == .none }

    /// Past the cap the map draws only the listed tracks and says how many the area holds.
    func renderCap() {
        let capped = session.storyID == nil && AreaLoad.of(zoom: mapView.zoomLevel, listed: activities.count, total: areaTotal).capped
        state.vars["capped"] = .bool(capped)
        state.vars["listed"] = .array(capped ? activities.map { .string($0.id) } : [])
        if capped, let total = areaTotal {
            let count = { (n: Int) in NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
            notice(.capped, String(localized: "Showing the newest \(count(activities.count)) of \(count(total)) activities here. Zoom in or set Dates to see the rest."))
        } else {
            hideNotice(.capped)
        }
    }

    // MARK: Dates

    /// Dates' bounds: the first and newest activities' days, asked again on every return to the
    /// map and after an import or a delete, which can change them.
    func loadHistory() {
        Task {
            guard let page = try? await flow.api.activityDays(limit: 1, before: nil) else { return }
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
        if session.consumeFly() { datesFlight() } else { loadList() }
    }

    func renderDates() {
        let format = { (day: String) in DateFilter.short(day, today: self.today, locale: .current) }
        let text = switch session.dates.label {
        case .all: String(localized: "Dates")
        case let .between(a, b): String(localized: "\(format(a)) – \(format(b))", comment: "Dates: both ends set.")
        // Its own key: "From %@" is a Story copy's sender, which Russian words differently.
        case let .after(a): String(localized: "dates.from", defaultValue: "From \(format(a))", comment: "Dates: only the first day set.")
        case let .before(b): String(localized: "Until \(format(b))")
        }
        activitiesPanel.setDates(text, set: session.dates != .allTime)
    }

    /// Setting Dates moves the camera once onto what they match, wherever it is, asked for without
    /// an area, since the area holds only what's in view; the list then follows the new view.
    /// Nothing matched leaves the camera.
    private func datesFlight() {
        let dates = session.dates
        Task {
            let read = try? await flow.api.areaList(box: nil, dates: dates)
            guard dates == session.dates else { return }
            guard let box = MapFraming.union((read?.activities ?? []).filter { !$0.pending }.compactMap(\.bbox)) else { return loadList() }
            fit(box, animated: true) { [weak self] in
                guard let self else { return }
                self.followArea()
                self.loadList()
            }
        }
    }

    /// The tiles' query: an open Story whole (root docs/SPEC.md FR-14.6), else every track Dates
    /// pass, and a counter bumped whenever tracks change under the same query. The area is the
    /// list's alone: past the cap the listed vars choose (renderCap).
    func updateTracksQuery() {
        var parts: [String] = []
        if let story = session.storyID {
            parts.append("story=\(story.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? story)")
        } else {
            parts += session.dates.query.map { "\($0.name)=\($0.value ?? "")" }
        }
        if tracksVersion > 0 { parts.append("v=\(tracksVersion)") }
        state.queries["tracks"] = parts.joined(separator: "&")
        render()
    }
}