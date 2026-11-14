import CoreLocation
import HoldMyTrackCore
import MapLibre
import UIKit

/// Fog's level control and place popup (root docs/SPEC.md FR-4.2, apps/android/docs/SPEC.md
/// FR-2.2). While Fog shows, its segment names the level in view, with a lock while one is locked,
/// and a tap on it opens the level menu: Auto, which follows the zoom, and every level with how
/// many of its places the account has explored, read on each opening. A picked level draws at
/// every zoom (MapState.fogLevel, FogLevels.zoomRanges) until Auto or a restart, through a trip
/// out of Fog. A tap on a place outlines it, through the layers document's `fogPlace` var, since
/// MapLibre Native has no feature-state to set, and names it in a popup until it's closed, a tap
/// lands off every place, the level in view changes or Fog is left.
extension MapViewController {
    private var fogIndex: Int { MapMode.allCases.firstIndex(of: .fog) ?? 1 }

    private var levels: [FogLevels.Level] { pair?.layers.levels ?? [] }

    private var levelInView: String {
        FogLevels.inView(levels, zoom: mapView.zoomLevel, locked: state.fogLevel)
    }

    /// The Fog segment's label and the menu over it, for the mode and level in view; called on
    /// every camera move, so it names the level only when the level, the lock or the look changes.
    func renderLevel() {
        let level = state.mode == .fog && !levels.isEmpty ? levelInView : nil
        fogViews.menuButton.isHidden = level == nil || modes.isHidden
        if let place = fogViews.place, place.level != level { closeFogPlace() }
        guard let level else {
            if fogViews.shown != nil {
                fogViews.shown = nil
                modes.setTitle(String(localized: "Fog"), forSegmentAt: fogIndex)
            }
            return
        }
        let locked = FogLevels.lock(levels, state.fogLevel) != nil
        let shown = FogViews.Shown(level: level, locked: locked, style: traitCollection.userInterfaceStyle,
                                   size: traitCollection.preferredContentSizeCategory)
        guard shown != fogViews.shown else { return }
        fogViews.shown = shown
        let fog = String(localized: "Fog"), name = levelName(level)
        let spoken = "\(fog) · \(name)" + (locked ? ", " + String(localized: "Locked") : "")
        let image = FogViews.label("\(fog) · \(name)", locked: locked, font: FogViews.font, traits: traitCollection)
        image.accessibilityLabel = spoken
        modes.setImage(image, forSegmentAt: fogIndex)
        fogViews.menuButton.accessibilityLabel = spoken
    }

    /// A level's name in the control: its country's word for regions and counties where there's
    /// one; a level this build doesn't know shows as its id.
    private func levelName(_ level: String) -> String {
        let word = levels.first { $0.level == level }?.word
        return FogLevels.labelKey(level, word: word, has: FogWords.has).flatMap(FogWords.string) ?? level
    }

    /// The segments' text in the app's face at the reader's text size, which the Fog segment's
    /// label is drawn in too.
    func styleModes() {
        modes.setTitleTextAttributes([.font: FogViews.font], for: .normal)
        renderLevel()
    }

    func setUpFogControl() {
        styleModes()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in self.styleModes() }
        let button = fogViews.menuButton
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "fogLevel"
        button.menu = UIMenu(title: String(localized: "Fog level"), children: [
            // The counts are read on each opening; past a second the menu opens with the last ones
            // read, so a slow network never keeps Auto out of reach.
            UIDeferredMenuElement.uncached { [weak self] completion in
                let opened = FogViews.Once()
                let open: @MainActor () -> Void = {
                    guard !opened.done else { return }
                    opened.done = true
                    completion(self?.levelItems(explored: self?.fogViews.explored) ?? [])
                }
                Task { @MainActor in
                    if let explored = (try? await self?.flow.api.coverageStatus())?.explored { self?.fogViews.explored = explored }
                    open()
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    open()
                }
            },
        ])
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        // Over the Fog segment: the segments share the control's width.
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: modes.centerXAnchor),
            button.trailingAnchor.constraint(equalTo: modes.trailingAnchor),
            button.topAnchor.constraint(equalTo: modes.topAnchor),
            button.bottomAnchor.constraint(equalTo: modes.bottomAnchor),
        ])
        fogViews.popup.onClose = { [weak self] in self?.closeFogPlace() }
        view.insertSubview(fogViews.popup, aboveSubview: spotViews.popup)
    }

    private func levelItems(explored: FogLevels.Explored?) -> [UIMenuElement] {
        let locked = FogLevels.lock(levels, state.fogLevel)
        var items: [UIMenuElement] = [
            UIAction(title: String(localized: "Auto"), subtitle: String(localized: "follows the zoom"), state: locked == nil ? .on : .off) { [weak self] _ in
                self?.pickLevel(nil)
            },
        ]
        for level in levels {
            let count = explored.flatMap { FogLevels.exploredCount($0, level: level.level) }
            let subtitle = count.map { String(localized: "\($0.formatted()) explored", comment: "Fog's level control: under a level, how many of its places the account has explored.") }
            items.append(UIAction(title: levelName(level.level), subtitle: subtitle, state: locked == level.level ? .on : .off) { [weak self] _ in
                self?.pickLevel(level.level)
            })
        }
        return items
    }

    /// Auto (nil) or a level, picked in the menu.
    private func pickLevel(_ picked: String?) {
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

/// The level menu's button over the Fog segment, the place popup, and what they show.
@MainActor
final class FogViews {
    /// The layers document's var naming the picked outline by its tile `id`.
    static let placeVar = "fogPlace"

    let menuButton = UIButton(type: .system)
    let popup = FogPlacePopupView()
    /// The Fog segment's label as last drawn, nil while it reads "Fog".
    var shown: Shown?
    /// The explored counts last read, for a level menu the network keeps waiting.
    var explored: FogLevels.Explored?
    /// Where the picked place was tapped and the level it's on.
    var place: (at: CLLocationCoordinate2D, level: String)?

    struct Shown: Equatable {
        let level: String
        let locked: Bool
        let style: UIUserInterfaceStyle
        let size: UIContentSizeCategory
    }

    /// Whether the level menu has opened.
    @MainActor final class Once {
        var done = false
    }

    /// The mode toggle's text, scaled with Dynamic Type.
    static var font: UIFont { Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold, relativeTo: .footnote) }

    /// The segment's label as an image, since a segment takes a title or an image: "Fog · City",
    /// a lock while one holds, and the chevron saying it opens a menu.
    static func label(_ text: String, locked: Bool, font: UIFont, traits: UITraitCollection) -> UIImage {
        let color = UIColor.label.resolvedColor(with: traits)
        let line = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let symbol = UIImage.SymbolConfiguration(pointSize: font.pointSize * 0.75, weight: .semibold)
        for name in (locked ? ["lock.fill"] : []) + ["chevron.down"] {
            guard let image = UIImage(systemName: name, withConfiguration: symbol)?.withTintColor(color, renderingMode: .alwaysOriginal) else { continue }
            let attachment = NSTextAttachment(image: image)
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
            line.append(NSAttributedString(string: " "))
            line.append(NSAttributedString(attachment: attachment))
        }
        let size = line.boundingRect(with: CGSize(width: 400, height: 40), options: [.usesLineFragmentOrigin], context: nil).size
        let format = UIGraphicsImageRendererFormat(for: traits)
        let image = UIGraphicsImageRenderer(size: CGSize(width: ceil(size.width), height: ceil(size.height)), format: format).image { _ in
            line.draw(at: .zero)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}