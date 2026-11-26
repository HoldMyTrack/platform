import HoldMyTrackCore
import UIKit

/// The rail down the map's right edge (apps/docs/SPEC.md FR-2.2): Layers, Places, Find my
/// location and the export, each on a panel of its own. Layers and Places each open a menu
/// (MapMenuPopup) of picks under a switch that shows or hides them all and keeps them; the button
/// is filled while picks show, with a badge counting them (MapChrome.RailLook). When the rail
/// shows is MapViewController+TopRow's.
extension MapViewController {
    /// Both buttons, and an open menu, from the saved picks.
    func updateRailMenus() {
        rail.layers.render(MapChrome.layers(state), label: String(localized: "Layers"))
        rail.places.render(MapChrome.places(state, picked: spots.categories.count), label: String(localized: "Places"))
        // The documents arriving can open a menu the tour asked for before they had.
        layersMenu.refresh()
        placesMenu.refresh()
        layersMenu.retry()
    }

    /// The tour holds a menu open, view-only, or lets go of it.
    func holdTourMenu(_ menu: TourMenu, open: Bool) {
        switch menu {
        case .layers: layersMenu.hold(open)
        case .places: placesMenu.hold(open)
        case .fogLevel: fogLevelMenu.hold(open)
        }
    }

    /// Every menu the user opened closed; one the tour holds stays.
    func dismissMenus() {
        layersMenu.dismissUsers()
        placesMenu.dismissUsers()
        fogLevelMenu.dismissUsers()
    }

    /// A pick changed: kept on the phone, then drawn.
    private func picked(_ change: (inout MapState) -> Void) {
        change(&state)
        MapPreferences.save(state, mode: pickedMode)
        MapPreferences.saveSpots(spots.categories)
        applySpots()
        updateRailMenus()
        countSatelliteWait(onScreen: viewIfLoaded?.window != nil)
    }

    /// Show layers and Satellite, then Map's Roads and the Paths, each path with its line as the
    /// map draws it, then the trails and dirt tracks the map always draws. A pick while Show
    /// layers is off turns it back on, or the pick would seem to do nothing.
    func layersContent() -> UIView {
        let look = MapChrome.layers(state)
        let legend = pair?.layers.groups.first { $0.id == "bike-paths" }?.legend ?? [:]
        var rows: [UIView] = [
            MenuRows.toggle(String(localized: "Show layers"), on: state.showLayers, enabled: look.switchEnabled,
                            disabledHint: String(localized: "Pick roads or paths first"), id: "showLayers") { [weak self] on in
                self?.picked { $0.showLayers = on }
            },
        ]
        if pair.map({ MapStyle.hasSatellite($0.style) }) ?? false {
            rows.append(MenuRows.toggle(String(localized: "Satellite"), on: state.satellite, id: "satellite") { [weak self] on in
                self?.picked { $0.satellite = on }
            })
        }
        rows += [MenuRows.divider(), MenuRows.heading(String(localized: "Map"))]
        rows.append(MenuRows.check(String(localized: "Roads"), on: state.roads) { [weak self] in
            self?.picked { state in
                state.roads.toggle()
                if state.roads { state.showLayers = true }
            }
        })
        rows.append(MenuRows.heading(String(localized: "Paths")))
        let paths: [(String, String)] = [
            (String(localized: "Bike paths"), "bikePaths"),
            (String(localized: "Shared paths"), "sharedPaths"),
            (String(localized: "Mountain bike trails"), "mtbTrails"),
        ]
        for (title, id) in paths {
            rows.append(MenuRows.check(title, on: state.toggles[id] == true, trailing: legend[id].map(Self.swatch)) { [weak self] in
                self?.picked { state in
                    let on = !(state.toggles[id] ?? false)
                    state.toggles[id] = on
                    if on { state.showLayers = true }
                }
            })
        }
        rows.append(MenuRows.key(String(localized: "Always shown when zoomed in:"), [
            (String(localized: "Trails"), legend["trails"].map(Self.swatch)),
            (String(localized: "Dirt tracks"), legend["tracks"].map(Self.swatch)),
        ]))
        return Controls.column(rows, spacing: 0)
    }

    /// Show places, then each category.
    func placesContent() -> UIView {
        let look = MapChrome.places(state, picked: spots.categories.count)
        var rows: [UIView] = [
            MenuRows.toggle(String(localized: "Show places"), on: state.showPlaces, enabled: look.switchEnabled,
                            disabledHint: String(localized: "Pick places first"), id: "showPlaces") { [weak self] on in
                self?.picked { $0.showPlaces = on }
            },
            MenuRows.divider(),
        ]
        for category in SpotCategory.allCases {
            rows.append(MenuRows.check(Self.menuLabel(category), on: spots.categories.contains(category)) { [weak self] in
                guard let self else { return }
                if let at = self.spots.categories.firstIndex(of: category) {
                    self.spots.categories.remove(at: at)
                    // Unticking the place's category ends its capture.
                    if self.capturing.spot?.category == category.rawValue { self.capturing.stop() }
                    self.picked { _ in }
                } else {
                    self.spots.categories = SpotCategory.allCases.filter { self.spots.categories.contains($0) || $0 == category }
                    self.picked { $0.showPlaces = true }
                }
            })
        }
        return Controls.column(rows, spacing: 0)
    }

    /// A short sample of a path, in the legend's color and dash.
    private static func swatch(_ line: LayersDocument.Legend) -> UIImage {
        let size = CGSize(width: 24, height: 8), width: CGFloat = 3
        let color = CSSColor(line.color).map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) } ?? .gray
        return UIGraphicsImageRenderer(size: size).image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: width, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - width, y: size.height / 2))
            path.lineWidth = width
            if let dash = line.dash, !dash.isEmpty {
                path.setLineDash(dash.map { CGFloat($0) * width }, count: dash.count, phase: 0)
            } else {
                path.lineCapStyle = .round
            }
            color.setStroke()
            path.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// The rail's views: a column of panels, a row in landscape, where stacked it would take the
/// height the sheet needs.
@MainActor
final class MapRail {
    let view = PassThroughStackView()
    let layers: RailItem
    let places: RailItem
    let locate: RailItem
    let export: RailItem

    init(layers: UIButton, places: UIButton, locate: UIButton, export: UIButton) {
        self.layers = RailItem(layers, icon: UIImage(resource: .layers), label: String(localized: "Layers"), id: "layers")
        self.places = RailItem(places, icon: UIImage(resource: .mapPin), label: String(localized: "Places"), id: "places")
        self.locate = RailItem(locate, icon: UIImage(resource: .locateFixed), label: String(localized: "Find my location"), id: "locate")
        self.export = RailItem(export, icon: UIImage(resource: .camera),
                               label: String(localized: "export.open", defaultValue: "Export map image", comment: "The map's camera button: open the image export."),
                               id: "export")
        for item in [self.layers, self.places, self.locate, self.export] { view.addArrangedSubview(item) }
        view.spacing = DesignTokens.Space.s8
        // Its panels' own size: the toggle, the selection bar or the recording's status take the rest.
        view.alignment = .fill
    }

    /// Stacked down the edge in portrait, in a row in landscape.
    func layOut(landscape: Bool) {
        view.axis = landscape ? .horizontal : .vertical
    }
}

/// A stack laid over the map that takes no touch of its own, so the map pans and taps through its
/// gaps; Android's top bar does the same.
final class PassThroughStackView: UIStackView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// One of the rail's buttons on its panel, with a badge on its corner for Layers and Places.
final class RailItem: UIView {
    let button: UIButton
    private let badge = UILabel()

    init(_ button: UIButton, icon: UIImage, label: String, id: String) {
        self.button = button
        super.init(frame: .zero)
        backgroundColor = UIColor(resource: .surface)
        layer.cornerRadius = DesignTokens.Radius.md
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        var config = UIButton.Configuration.filled()
        config.image = icon
        config.background.cornerRadius = DesignTokens.Radius.sm
        config.baseBackgroundColor = UIColor(resource: .surface)
        config.baseForegroundColor = UIColor(resource: .ink)
        button.configuration = config
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        badge.font = Typeface.sans(DesignTokens.Text.xxxs, weight: DesignTokens.Weight.bold)
        badge.textColor = UIColor(resource: .onAccent)
        badge.backgroundColor = UIColor(resource: .accent)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8
        badge.layer.masksToBounds = true
        badge.isAccessibilityElement = false
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        let inset = DesignTokens.Space.s4
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 48),
            button.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            badge.heightAnchor.constraint(equalToConstant: 16),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: -6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Filled while picks show, the count on its corner, greyed while the switch hides them.
    func render(_ look: MapChrome.RailLook, label: String) {
        button.configuration?.baseBackgroundColor = UIColor(resource: look.filled ? .ink : .surface)
        button.configuration?.baseForegroundColor = UIColor(resource: look.filled ? .surface : .ink)
        badge.text = " \(look.count) "
        badge.isHidden = !look.badge
        badge.alpha = look.greyed ? 0.55 : 1
        button.accessibilityLabel = look.count > 0 ? "\(label), \(look.count)" : label
    }
}
