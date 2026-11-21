/// A first-time card: a feature's own explanation, shown once per phone.
public enum TourCard: String, CaseIterable, Sendable { case fog, trips }

/// The tab bar's tabs, as the tour moves between them.
public enum TourTab: Equatable, Sendable { case map, trips, sync, you }

/// What the tour has shown on this phone: tour once it was started or its offer answered.
public struct TourSeen: Equatable, Sendable {
    public var tour: Bool
    public var cards: Set<TourCard>

    public init(tour: Bool = false, cards: Set<TourCard> = []) {
        self.tour = tour
        self.cards = cards
    }
}

public enum TourStart: String, Sendable { case start, offer, none, wait }

/// A camera: lon, lat, zoom, then a slow pan through each point of pan, if any.
public struct TourView: Equatable, Sendable {
    public let lon: Double
    public let lat: Double
    public let zoom: Double
    public let pan: [(lon: Double, lat: Double)]

    public init(lon: Double, lat: Double, zoom: Double, pan: [(lon: Double, lat: Double)] = []) {
        self.lon = lon
        self.lat = lat
        self.zoom = zoom
        self.pan = pan
    }

    public func sameSpot(_ other: TourView) -> Bool { lon == other.lon && lat == other.lat && zoom == other.zoom }

    public static func == (a: TourView, b: TourView) -> Bool {
        a.sameSpot(b) && a.pan.map(\.lon) == b.pan.map(\.lon) && a.pan.map(\.lat) == b.pan.map(\.lat)
    }
}

/// The camera through the tour: the view before its first move, and the one it last moved to,
/// nil where the map took it somewhere unknown.
public struct TourCamera: Equatable, Sendable {
    public var start: TourView?
    public var shown: TourView?

    public init(start: TourView? = nil, shown: TourView? = nil) {
        self.start = start
        self.shown = shown
    }
}

/// What a step changes, or the end puts back: the mode and tab where they differ, else nil, and
/// the card the step counts as seen.
public struct TourChanges: Equatable, Sendable {
    public let mode: MapMode?
    public let tab: TourTab?
    public let card: TourCard?
}

/// Something the user picked that may earn a card.
public enum TourEvent: Equatable, Sendable {
    case mode(MapMode)
    case tab(TourTab)
}

/// The tour's shared decisions (root docs/SPEC.md FR-4.14): when it starts by itself or is offered,
/// which card a pick earns, which step comes next, what a step changes and where the camera goes.
/// The web's `tourRules.ts` and Android's `TourRules`; all run `testdata/client-rules/tour-*.json`.
public enum TourRules {
    /// hasTracks is nil until the account's history is known.
    public static func start(requested: Bool, isDemo: Bool, hasTracks: Bool?, seen: TourSeen) -> TourStart {
        guard let hasTracks else { return .wait }
        if requested { return .start }
        if seen.tour { return .none }
        if isDemo { return .start }
        return hasTracks ? .offer : .none
    }

    /// The cards kept as seen, by name; a name this build has no card for is dropped.
    public static func seenCards(_ names: [String]) -> Set<TourCard> { Set(names.compactMap(TourCard.init(rawValue:))) }

    /// The card event earns, once, and never while the tour runs, whose steps say the same.
    public static func card(_ event: TourEvent, seen: TourSeen, touring: Bool) -> TourCard? {
        if touring { return nil }
        let card: TourCard? = switch event {
        case .mode(let mode): mode == .fog ? .fog : nil
        case .tab(let tab): tab == .trips ? .trips : nil
        }
        guard let card, !seen.cards.contains(card) else { return nil }
        return card
    }

    /// Where the camera goes for a step with view on tab, current being the map's view now. The
    /// first step with its own view or on Trips keeps current as the start, since the map's own
    /// first flight may still be under way when the tour starts; Trips frames its Trip itself, so
    /// after it the camera is unknown. move is nil for none.
    public static func camera(_ camera: TourCamera, view: TourView?, tab: TourTab, current: TourView) -> (camera: TourCamera, move: TourView?) {
        let trips = tab == .trips
        var start = camera.start, shown = camera.shown
        if start == nil && (view != nil || trips) {
            start = current
            shown = current
        }
        if view == nil && trips { return (TourCamera(start: start, shown: nil), nil) }
        guard let target = view ?? start, shown.map({ !$0.sameSpot(target) }) ?? true else {
            return (TourCamera(start: start, shown: shown), nil)
        }
        return (TourCamera(start: start, shown: target), target)
    }

    /// Where the camera goes when the tour ends: back to the start, unless it's there.
    public static func cameraEnd(_ camera: TourCamera) -> TourView? {
        guard let start = camera.start else { return nil }
        return camera.shown?.sameSpot(start) == true ? nil : start
    }

    /// What step changes from mode and tab, or the end (nil) puts back from restore.
    public static func changes(mode: MapMode, tab: TourTab, step: TourStep?, restoreMode: MapMode, restoreTab: TourTab) -> TourChanges {
        let wantMode = step?.mode ?? restoreMode, wantTab = step?.tab ?? restoreTab
        return TourChanges(mode: wantMode == mode ? nil : wantMode, tab: wantTab == tab ? nil : wantTab, card: step?.card)
    }

    /// The step after from in direction dir that shown says is on screen, or nil past either end.
    public static func nextStep(shown: [Bool], from: Int, dir: Int) -> Int? {
        var i = from + dir
        while shown.indices.contains(i) {
            if shown[i] { return i }
            i += dir
        }
        return nil
    }
}

/// What a step points at, found by the app; nil points at nothing and puts the card at the bottom.
public enum TourTarget: Sendable { case sheet, dates, layers, places, export, modes, fogLevel, record, youTour }

/// A map menu the tour can hold open.
public enum TourMenu: CaseIterable, Sendable { case layers, places, fogLevel }

/// One step of the tour. tab is the tab bar's tab for the step, mode the map's, sheet whether the
/// map's sheet is open, menu the map menu held open; the user's come back when the tour ends. view
/// is the camera, nil for the one before the tour's first move. card is the first-time card the
/// step stands in for, and text the key of its title and body.
public struct TourStep: Equatable, Sendable {
    public let id: String
    public let target: TourTarget?
    public var tab: TourTab = .map
    public var mode: MapMode = .normal
    public var sheet = false
    public var menu: TourMenu?
    public var view: TourView?
    public var card: TourCard?
    public var text: String

    init(_ id: String, _ target: TourTarget?, tab: TourTab = .map, mode: MapMode = .normal, sheet: Bool = false,
         menu: TourMenu? = nil, view: TourView? = nil, card: TourCard? = nil, text: String? = nil) {
        self.id = id
        self.target = target
        self.tab = tab
        self.mode = mode
        self.sheet = sheet
        self.menu = menu
        self.view = view
        self.card = card
        self.text = text ?? id
    }
}

/// What a tour's hold does to a map menu: a menu the user opened is taken over as held, so it lets
/// go of touches and closes after the step; letting go closes only a held one, never the user's own.
/// Android's `MenuHold`.
public enum MenuHold: Equatable, Sendable {
    case none, close, openHeld, reopenHeld

    public static func next(isOpen: Bool, held: Bool, want: Bool, canOpen: Bool) -> MenuHold {
        if !want { return isOpen && held ? .close : .none }
        if isOpen && held { return .none }
        if !canOpen { return .none }
        return isOpen ? .reopenHeld : .openHeld
    }
}

/// The iOS tour's steps (apps/android/docs/SPEC.md FR-2.12).
public enum TourSteps {
    /// The demo's views over its fixed history (`services/server/internal/httpapi/demo_data`), the
    /// web's `DEMO_VIEWS`, one per Fog level: Brecksville Reservation's tracks, exact coverage
    /// (zoom 11 up); Cleveland's towns (8 to 11); northern Ohio's counties (6 to 8); the eastern
    /// US's states (3 to 6); and the world's countries (0 to 3). A phone shows one country at a
    /// time there, so the camera pans from the US over Europe to Vietnam, each leg east and under 180°.
    public static let exact = TourView(lon: -81.609, lat: 41.315, zoom: 12)
    public static let city = TourView(lon: -81.72, lat: 41.42, zoom: 9)
    public static let counties = TourView(lon: -81.6, lat: 41.2, zoom: 7)
    public static let regions = TourView(lon: -82, lat: 36, zoom: 3.6)
    public static let countries = TourView(lon: -80, lat: 38, zoom: 1.5, pan: [(15, 45), (106, 25)])

    public static func of(isDemo: Bool) -> [TourStep] {
        let fog: [TourStep] = isDemo
            ? [
                TourStep("fog", .modes, mode: .fog, view: exact, card: .fog, text: "fog_exact"),
                TourStep("fog_cities", .modes, mode: .fog, view: city),
                TourStep("fog_counties", .modes, mode: .fog, view: counties),
                TourStep("fog_regions", .modes, mode: .fog, view: regions),
                TourStep("fog_countries", .fogLevel, mode: .fog, menu: .fogLevel, view: countries),
            ]
            : [TourStep("fog", .fogLevel, mode: .fog, menu: .fogLevel, card: .fog)]
        return [
            TourStep("welcome", nil),
            TourStep("tracks", .sheet, sheet: true),
            TourStep("range", .dates, sheet: true),
            TourStep("trips", .sheet, tab: .trips, sheet: true, card: .trips),
            TourStep("layers", .layers, menu: .layers),
            TourStep("places", .places, menu: .places),
            TourStep("export", .export),
        ] + fog + [
            TourStep("record", .record, text: isDemo ? "record_demo" : "record"),
            TourStep("sync", .sheet, tab: .sync, sheet: true, text: isDemo ? "sync_demo" : "sync"),
            TourStep("done", .youTour, tab: .you),
        ]
    }

    /// The sheet for step: half open for one that opens it, else closed; at the end (nil), as the
    /// user had it.
    public static func sheet(_ step: TourStep?, restore: SheetDetent) -> SheetDetent {
        guard let step else { return restore }
        return step.sheet ? .half : .collapsed
    }

    /// Each map menu, and whether step holds it open; at the end (nil) every one is let go. The
    /// app applies them after the step's mode: Fog's level menu hangs from Fog's button, and a mode
    /// change would close it again.
    public static func menus(_ step: TourStep?) -> [(menu: TourMenu, open: Bool)] {
        TourMenu.allCases.map { ($0, step?.menu == $0) }
    }

    /// A first-time card's text and what it points at.
    public static func card(_ card: TourCard) -> (text: String, target: TourTarget) {
        switch card {
        case .fog: ("fog", .fogLevel)
        case .trips: ("trips", .sheet)
        }
    }

    public enum Edge: Sendable { case top, bottom }

    /// Where a step's card goes: across the top, under topInset, when it fits above the target
    /// (targetTop), else across the bottom, over what's least needed. The web's phone sheet
    /// (`placePopover`).
    public static func edge(targetTop: Double?, cardHeight: Double, topInset: Double, gap: Double) -> Edge {
        guard let targetTop, targetTop - topInset >= cardHeight + gap else { return .bottom }
        return .top
    }

    /// A first-time card's or the offer's top, in a screen height tall: under the target when it's
    /// in the upper half, else over it but never above topInset; at topInset with no target.
    public static func cardTop(targetTop: Double?, targetBottom: Double?, cardHeight: Double, height: Double, topInset: Double, gap: Double) -> Double {
        guard let targetTop, let targetBottom else { return topInset }
        if (targetTop + targetBottom) / 2 < height / 2 { return targetBottom + gap }
        return max(targetTop - gap - cardHeight, topInset)
    }
}