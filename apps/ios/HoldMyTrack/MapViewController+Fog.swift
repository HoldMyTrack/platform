import CoreLocation
import HoldMyTrackCore
import MapLibre
import UIKit

/// Fog's level control and place popup (root docs/SPEC.md FR-4.2, apps/docs/SPEC.md
/// FR-2.2). While Fog shows, its button names the level in view, with a lock while one is locked,
/// and a tap on it opens the level menu (MapMenuPopup): Auto, which follows the zoom, and every
/// level with how many of its places the account has explored, read on each opening. A picked
/// level draws at every zoom (MapState.fogLevel, FogLevels.zoomRanges) until Auto or a restart,
/// through a trip out of Fog. A tap on a place outlines it, through the layers document's
/// `fogPlace` var, since MapLibre Native has no feature-state to set, and names it in a popup until
/// it's closed, a tap lands off every place, the level in view changes or Fog is left.
extension MapViewController {
    var levels: [FogLevels.Level] { pair?.layers.levels ?? [] }

    private var levelInView: String {
        FogLevels.inView(levels, zoom: mapView.zoomLevel, locked: state.fogLevel)
    }

    /// Fog's label and its menu, for the mode and level in view; called on every camera move, so
    /// it names the level only when the level, the lock or the text size changes.
    func renderLevel() {
        let level = state.mode == .fog && !levels.isEmpty ? levelInView : nil
        if let place = fogViews.place, place.level != level { closeFogPlace() }
        if state.mode != .fog { fogLevelMenu.dismiss() } else { fogLevelMenu.retry() }
        guard let level else {
            if fogViews.shown != nil {
                fogViews.shown = nil
                let fog = String(localized: "Fog")
                modes.setFogTitle(fog, locked: false, menu: false, spoken: fog)
            }
            return
        }
        let locked = FogLevels.lock(levels, state.fogLevel) != nil
        let shown = FogViews.Shown(level: level, locked: locked, size: traitCollection.preferredContentSizeCategory)
        guard shown != fogViews.shown else { return }
        fogViews.shown = shown
        let fog = String(localized: "Fog"), name = levelName(level)
        let spoken = "\(fog) · \(name)" + (locked ? ", " + String(localized: "Locked") : "")
        modes.setFogTitle("\(fog) · \(name)", locked: locked, menu: true, spoken: spoken)
    }

    /// A level's name in the control: its country's word for regions and counties where there's
    /// one; a level this build doesn't know shows as its id.
    private func levelName(_ level: String) -> String {
        let word = levels.first { $0.level == level }?.word
        return FogLevels.labelKey(level, word: word, has: FogWords.has).flatMap(FogWords.string) ?? level
    }

    func setUpFogControl() {
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.fogViews.shown = nil
            self.renderLevel()
        }
        // The counts change only with the account's tiles: read once per opening.
        fogLevelMenu.onOpen = { [weak self] in
            Task { @MainActor in
                guard let explored = (try? await self?.flow.api.coverageStatus())?.explored else { return }
                self?.fogViews.explored = explored
                self?.fogLevelMenu.refresh()
            }
        }
        fogViews.popup.onClose = { [weak self] in self?.closeFogPlace() }
        view.insertSubview(fogViews.popup, aboveSubview: spotViews.popup)
    }

    /// The level menu: a heading, Auto, then each level with its count once read.
    func fogLevelContent() -> UIView {
        let locked = FogLevels.lock(levels, state.fogLevel)
        var rows: [UIView] = [
            MenuRows.heading(String(localized: "Fog level")),
            MenuRows.radio(String(localized: "Auto"), hint: String(localized: "follows the zoom"), on: locked == nil) { [weak self] in
                self?.pickLevel(nil)
            },
        ]
        for level in levels {
            let count = fogViews.explored.flatMap { FogLevels.exploredCount($0, level: level.level) }
            rows.append(MenuRows.radio(levelName(level.level), on: locked == level.level, count: count?.formatted()) { [weak self] in
                self?.pickLevel(level.level)
            })
        }
        return Controls.column(rows, spacing: 0)
    }

    /// Auto (nil) or a level, picked in the menu.
    private func pickLevel(_ picked: String?) {
        fogLevelMenu.dismiss()
        let locked = FogLevels.lock(levels, state.fogLevel)
        guard picked != locked else { return }
        let next = picked.map { FogLevels.pick(levels, zoom: mapView.zoomLevel, locked: locked, picked: $0) }
        // Dropped before the one render, which a new level would otherwise follow with another.
        if fogViews.place != nil, FogLevels.inView(levels, zoom: next?.zoom ?? mapView.zoomLevel, locked: next?.locked) != fogViews.place?.level {
            fogViews.place = nil
            fogViews.popup.close()
            state.vars[FogViews.placeVar] = nil
        }
        state.fogLevel = next?.locked
        MapPreferences.save(state, mode: pickedMode)
        render()
        renderLevel()
        // Out to the level's band, keeping the centre; never in.
        if let zoom = next?.zoom { mapView.setZoomLevel(zoom, animated: true) }
    }

    // MARK: A place

    /// In Fog, a tap on an outline on every level but Exact picks it (true); anywhere else closes
    /// an open popup (false).
    func tapFogPlace(at point: CGPoint) -> Bool {
        let level = levelInView
        let fills = (levels.first { $0.level == level && $0.level != FogLevels.exact }?.layers ?? [])
            .filter { mapView.style?.layer(withIdentifier: $0) is MLNFillStyleLayer }
        let feature = fills.isEmpty ? nil : mapView.visibleFeatures(at: point, styleLayerIdentifiers: Set(fills)).first
        let props = (feature?.attributes ?? [:]).compactMapValues { JSONValue($0) }
        guard let label = FogPlaceLabel.of(props, has: FogWords.has), let id = props["id"]?.number else {
            closeFogPlace()
            return false
        }
        spotViews.popup.close()
        photoViews.popup.close()
        fogViews.place = (mapView.convert(point, toCoordinateFrom: mapView), level)
        state.vars[FogViews.placeVar] = .number(id)
        render()
        fogViews.popup.show(label)
        placeFogPlace()
        return true
    }

    func closeFogPlace() {
        fogViews.place = nil
        fogViews.popup.close()
        guard state.vars[FogViews.placeVar] != nil else { return }
        state.vars[FogViews.placeVar] = nil
        render()
    }

    /// Over the tap again, on every camera move while it's open.
    func placeFogPlace() {
        guard let at = fogViews.place?.at else { return }
        fogViews.popup.place(at: mapView.convert(at, toPointTo: view), top: chromeBottom)
    }
}

/// The place popup, and what Fog's label and menu show.
@MainActor
final class FogViews {
    /// The layers document's var naming the picked outline by its tile `id`.
    static let placeVar = "fogPlace"

    let popup = FogPlacePopupView()
    /// Fog's label as last drawn, nil while it reads "Fog".
    var shown: Shown?
    /// The explored counts last read.
    var explored: FogLevels.Explored?
    /// Where the picked place was tapped and the level it's on.
    var place: (at: CLLocationCoordinate2D, level: String)?

    struct Shown: Equatable {
        let level: String
        let locked: Bool
        let size: UIContentSizeCategory
    }
}
