import HoldMyTrackCore
import UIKit

/// The date range (root docs/SPEC.md FR-6, apps/android/docs/SPEC.md FR-2.6), the head of the
/// sheet's Activities tab.
extension MapViewController {
    /// The activity days from the newest end, on every return to the map, since an upload may
    /// have added some; the default range is offered again until the user picks one.
    func reloadDays() {
        Task {
            guard let page = try? await flow.api.activityDays(limit: ActivityDays.pageSize, before: nil) else { return }
            days.reloaded(days: page.days, earliest: page.earliest)
            daysChanged(reloaded: true)
        }
    }

    func loadEarlier(_ oldest: String?) {
        guard let oldest, !loadingEarlier else { return }
        loadingEarlier = true
        Task {
            defer { loadingEarlier = false }
            guard let page = try? await flow.api.activityDays(limit: ActivityDays.pageSize, before: oldest) else { return }
            days.prepended(days: page.days, before: oldest, earliest: page.earliest)
            daysChanged(reloaded: false)
        }
    }

    func daysChanged(reloaded: Bool) {
        slider.setDays(days.visibleDays, canPanEarlier: days.canPanEarlier, canPanLater: days.canPanLater)
        if reloaded {
            let range = DefaultRange.of(days.visibleDays, earliest: days.earliest, today: DefaultRange.today(in: account.timezone))
            if session.offerDefault(range, editOpen: editOpen) { showRange() }
        }
        loadEarlier(days.wantsEarlier)
        renderPanel()
    }

    /// The range's tracks and list; a range the user picked also flies the camera onto them once
    /// the list is in (listed).
    func showRange() {
        guard let range = session.range else { return }
        slider.value = range
        updateTracksQuery()
        if session.storyID == nil { loadList() }
    }

    func bindSlider() {
        slider.onChange = { [weak self] range in
            guard let self else { return }
            self.session.pickRange(range)
            self.panelChanged()
            self.showRange()
        }
        slider.onPan = { [weak self] delta in
            guard let self else { return }
            self.days.pan(by: delta)
            self.daysChanged(reloaded: false)
        }
        slider.onShift = { [weak self] range, dir in
            guard let self else { return nil }
            let result = self.days.shift(range, dir: dir)
            if result.wantsLoad { self.loadEarlier(self.days.days.first) }
            self.daysChanged(reloaded: false)
            return result.range
        }
        slider.canShift = { [weak self] range, dir in self?.days.canShift(range, dir: dir) ?? false }
        slider.onWindowDays = { [weak self] size in
            guard let self else { return }
            self.days.resize(size, selection: self.session.range)
            self.daysChanged(reloaded: false)
        }
    }

    /// The tiles' query: an open Story whole, whatever the range (root docs/SPEC.md FR-14.6), else
    /// the range, and a counter bumped whenever tracks change under the same query.
    func updateTracksQuery() {
        var parts: [String] = []
        if let story = session.storyID {
            parts.append("story=\(story.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? story)")
        } else {
            let range = MapFraming.tracksQuery(session.range)
            if !range.isEmpty { parts.append(range) }
        }
        if tracksVersion > 0 { parts.append("v=\(tracksVersion)") }
        state.queries["tracks"] = parts.joined(separator: "&")
        render()
    }
}