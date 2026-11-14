import HoldMyTrackCore
import MapLibre
import UIKit

/// Points of interest on the map (apps/android/docs/SPEC.md FR-2.8): the Layers menu's
/// categories, kept on the phone, the badge images the layers document names, the account's
/// captured badges, a badge's popup and "Show in this area". What each layer does with the picks
/// is the document's (Spots.apply).
extension MapViewController {
    /// The categories drawn: the picks, while Show layers is on.
    var shownSpotCategories: [SpotCategory] { state.showLayers ? spots.categories : [] }

    /// The picks, the captures and the switch into the style, and everything that follows them.
    func applySpots() {
        Spots.apply(categories: spots.categories, captured: spots.captured, target: spots.target, to: &state)
        if let open = spotViews.popup.spot, !shownSpotCategories.contains(where: { $0.rawValue == open.category }) {
            spotViews.popup.close()
        }
        render()
        renderInArea()
    }

    /// The Layers menu's Points of interest. A pick turns Show layers back on, so it shows.
    func spotsMenu(_ refresh: @escaping () -> Void) -> UIMenu {
        let items = SpotCategory.allCases.map { category in
            UIAction(title: Self.menuLabel(category), image: Self.icon(category), state: spots.categories.contains(category) ? .on : .off) { [weak self] _ in
                guard let self else { return }
                if let at = self.spots.categories.firstIndex(of: category) {
                    self.spots.categories.remove(at: at)
                    // Unticking the place's category ends its capture.
                    if self.capturing.spot?.category == category.rawValue { self.capturing.stop() }
                } else {
                    self.spots.categories = SpotCategory.allCases.filter { self.spots.categories.contains($0) || $0 == category }
                    self.state.showLayers = true
                }
                MapPreferences.save(self.state, mode: self.pickedMode)
                MapPreferences.saveSpots(self.spots.categories)
                self.applySpots()
                refresh()
            }
        }
        return UIMenu(title: String(localized: "Points of interest"), options: .displayInline, children: items)
    }

    /// Every badge the layers document names, drawn on each style load, which drops the images
    /// with the layers. The colors are the document's, the icon shapes the app's.
    func addBadgeImages(to style: MLNStyle) {
        guard let pair else { return }
        let side: CGFloat = 30
        for (name, badge) in Spots.badges(pair.layers) where style.image(forName: name) == nil {
            let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                let ring = UIBezierPath(ovalIn: CGRect(x: 1.5, y: 1.5, width: 27, height: 27))
                Self.color(badge.fill).setFill()
                ring.fill()
                ring.lineWidth = 2
                Self.color(badge.ring).setStroke()
                ring.stroke()
                // Lucide draws in a 24-unit box; 16 of the badge's 30 leaves a comfortable margin.
                Self.icon(badge.category).withTintColor(Self.color(badge.ink)).draw(in: CGRect(x: 7, y: 7, width: 16, height: 16))
            }
            style.setImage(image, forName: name)
        }
    }

    /// The account's captures (root docs/SPEC.md FR-14.6), for the badges and the popup: all of
    /// them the first time, then only what's newer. Kept as they were on a failure.
    func loadCaptures() {
        let since = spots.capturesLoaded ? Spots.capturesSince(spots.captured) : nil
        Task {
            guard let fresh = try? await flow.api.spotCaptures(since: since) else { return }
            spots.captured = since == nil ? fresh : Spots.merge(spots.captured, fresh)
            spots.capturesLoaded = true
            if let open = spotViews.popup.spot { showPopup(open) }
            applySpots()
        }
    }

    /// A tap on a shown badge opens its popup (true); anywhere else closes an open one (false).
    func tapSpot(at point: CGPoint) -> Bool {
        let r: CGFloat = 19 // half the badge and 4 points of slop
        let rect = CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)
        let layers = Set(Spots.badgeLayers.filter { mapView.style?.layer(withIdentifier: $0)?.isVisible == true })
        let spot = layers.isEmpty ? nil : mapView.visibleFeatures(in: rect, styleLayerIdentifiers: layers).lazy.compactMap { Spot(attributes: $0.attributes) }.first
        guard let spot else {
            spotViews.popup.close()
            return false
        }
        photoViews.popup.close()
        showPopup(spot)
        return true
    }

    private func showPopup(_ spot: Spot) {
        let on = spots.captured[spot.id].map { date in
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeZone = TimeZone(identifier: account.timezone) ?? .current
            return formatter.string(from: date)
        }
        spotViews.popup.show(spot, capturedOn: on, canCapture: !account.isDemo)
        placeSpotPopup()
    }

    /// Over its place again, on every camera move while it's open.
    func placeSpotPopup() {
        guard let spot = spotViews.popup.spot else { return }
        let point = mapView.convert(CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon), toPointTo: view)
        spotViews.popup.place(at: point, top: chromeBottom)
    }

    // MARK: Capture

    /// What capture asks of the map.
    func captureMap() -> CaptureController.Map {
        CaptureController.Map(
            target: { [weak self] id in self?.setCaptureTarget(id) },
            guide: { [weak self] from, to in self?.setGuide(from, to) },
            frame: { [weak self] box in self?.fit(box, animated: true) },
            bearing: { [weak self] in self?.mapView.direction ?? 0 },
            captured: { [weak self] id, date in
                guard let self else { return }
                self.spots.captured[id] = date
                self.applySpots()
            },
            notice: { [weak self] text in self?.notice(.location, text) }
        )
    }

    /// Capture aims at a place, or stops: the areas shade darker, and the position dot shows
    /// with the phone's heading, as it was before once capture ends.
    private func setCaptureTarget(_ id: Int?) {
        spots.target = id
        if id != nil {
            spots.dotWasOn = mapView.showsUserLocation
            mapView.showsUserLocation = true
            mapView.showsUserHeadingIndicator = true
        } else {
            mapView.showsUserHeadingIndicator = false
            if !spots.dotWasOn { mapView.showsUserLocation = false }
        }
        applySpots()
    }

    /// Capture's dashed line, from the user to the area's nearest point, the app's own layer under
    /// the badges in the areas' color; a style load drops it with the rest (addGuide).
    private func setGuide(_ from: GeoPoint?, _ to: GeoPoint?) {
        if let from, let to {
            spots.guide = MLNPolylineFeature(coordinates: [CLLocationCoordinate2D(latitude: from.lat, longitude: from.lon),
                                                           CLLocationCoordinate2D(latitude: to.lat, longitude: to.lon)], count: 2)
        } else {
            spots.guide = nil
        }
        (mapView.style?.source(withIdentifier: Self.guideSource) as? MLNShapeSource)?.shape = spots.guide ?? MLNShapeCollectionFeature(shapes: [])
    }

    /// The guide's source and layer onto a style just loaded.
    func addGuide(to style: MLNStyle) {
        guard style.source(withIdentifier: Self.guideSource) == nil else { return }
        let source = MLNShapeSource(identifier: Self.guideSource, shape: spots.guide ?? MLNShapeCollectionFeature(shapes: []))
        style.addSource(source)
        let line = MLNLineStyleLayer(identifier: Self.guideSource, source: source)
        line.lineWidth = NSExpression(forConstantValue: 2.5)
        line.lineDashPattern = NSExpression(forConstantValue: [1.5, 1.5])
        line.lineCap = NSExpression(forConstantValue: "round")
        line.lineColor = NSExpression(forConstantValue: Self.color(pair.flatMap { Spots.areaColor($0.layers) } ?? "#8a6d1f"))
        if let below = style.layer(withIdentifier: Spots.inAreaLayer) { style.insertLayer(line, below: below) } else { style.addLayer(line) }
    }

    private static let guideSource = "spots-capture-guide"

    // MARK: Show in this area

    func renderInArea() {
        let zooms = pair.flatMap { Spots.inAreaZooms($0.layers) }
        let label = spots.area.label(categories: shownSpotCategories, zoom: mapView.zoomLevel, zooms: zooms)
        let button = spotViews.inArea
        button.isHidden = label == nil
        guard let label else { return }
        let format = { (n: Int) in NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
        let (title, offer): (String, Bool) = switch label {
        case .offer: (String(localized: "Show in this area"), true)
        case .loading: (String(localized: "Loading places…"), true)
        case .failed: (String(localized: "Couldn't load places — try again"), true)
        case .none: (String(localized: "No places in this area"), false)
        case let .truncated(shown, total): (String(localized: "Showing \(format(shown)) of \(format(total)) places — zoom in for the rest"), false)
        case let .count(n): (String(localized: "Places in this area: \(format(n))"), false)
        }
        button.configuration?.title = title
        button.configuration?.image = offer ? Controls.icon(UIImage(resource: .mapPin), size: 14) : nil
        button.configuration?.baseForegroundColor = UIColor(resource: label == .loading ? .inkMuted : offer ? .ink : .inkSecondary)
        button.isUserInteractionEnabled = offer && label != .loading
    }

    func loadInArea() {
        guard !spots.area.loading else { return }
        let bounds = mapView.visibleCoordinateBounds
        let wanted = shownSpotCategories
        let edges = Spots.viewEdges(west: bounds.sw.longitude, east: bounds.ne.longitude)
        spots.areaRequest += 1
        let request = spots.areaRequest
        spots.area.started()
        renderInArea()
        Task {
            do {
                let found = try await flow.api.spotsInArea(west: edges.west, south: bounds.sw.latitude, east: edges.east, north: bounds.ne.latitude, categories: wanted)
                guard request == spots.areaRequest else { return }
                spots.area.finished(categories: wanted, shown: found.spots.count, total: found.total)
                state.geojson[Spots.inAreaSource] = Spots.inAreaFeatures(found.spots)
                render()
            } catch {
                guard request == spots.areaRequest else { return }
                spots.area.failedLoading()
            }
            renderInArea()
        }
    }

    // MARK: Categories

    static func menuLabel(_ category: SpotCategory) -> String {
        switch category {
        case .playground: String(localized: "Playgrounds")
        case .dogPark: String(localized: "Dog parks")
        case .monument: String(localized: "Monuments")
        case .viewpoint: String(localized: "Mesmerizing views")
        case .waterfall: String(localized: "Waterfalls")
        case .history: String(localized: "Historic sites")
        }
    }

    static func icon(_ category: SpotCategory) -> UIImage {
        switch category {
        case .playground: UIImage(resource: .seesaw)
        case .dogPark: UIImage(resource: .dog)
        case .monument: UIImage(resource: .landmark)
        case .viewpoint: UIImage(resource: .binoculars)
        case .waterfall: UIImage(resource: .waterfall)
        case .history: UIImage(resource: .castle)
        }
    }

    private static func color(_ css: String) -> UIColor {
        guard let c = CSSColor(css) else { return .gray }
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}

/// The picks, the captures and "Show in this area"'s state.
struct SpotsState {
    var categories: [SpotCategory]
    var captured: [Int: Date] = [:]
    var capturesLoaded = false
    var area = ShowInArea()
    /// Bumped per "Show in this area" request, so only the latest one's answer lands.
    var areaRequest = 0
    /// The place capture aims at, and its guide line.
    var target: Int?
    var guide: MLNPolylineFeature?
    /// Whether Find my location had the dot on before capture.
    var dotWasOn = false
}

/// The popup and the "Show in this area" pill.
@MainActor
final class SpotViews {
    let popup = SpotPopupView()
    let inArea: UIButton = {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor(resource: .surface)
        config.cornerStyle = .capsule
        config.imagePadding = DesignTokens.Space.s6
        config.contentInsets = .init(top: DesignTokens.Space.s8, leading: DesignTokens.Space.s16, bottom: DesignTokens.Space.s8, trailing: DesignTokens.Space.s16)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold)
            return a
        }
        let button = UIButton(configuration: config)
        button.titleLabel?.numberOfLines = 0
        button.accessibilityIdentifier = "showInArea"
        button.isHidden = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }()
}