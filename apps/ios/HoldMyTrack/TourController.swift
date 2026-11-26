import HoldMyTrackCore
import UIKit

/// What the tour drives in the app: the tabs, the map's mode, sheet and camera, and the views it
/// points at.
@MainActor
protocol TourHost: AnyObject {
    var isDemo: Bool { get }
    var tourTab: TourTab { get }
    /// root: back to the tab's first page, for a step that points at it.
    func showTourTab(_ tab: TourTab, root: Bool)
    var map: MapViewController { get }
    /// The views target points at on whichever tab shows it.
    func tourViews(_ target: TourTarget) -> [UIView]
    /// Scrolls target into view where its screen scrolls.
    func revealTourTarget(_ target: TourTarget)
    /// What the overlay is laid over: the whole app, tab bar included.
    var tourContainer: UIView { get }
}

/// The tour, its offer and the first-time cards (apps/docs/SPEC.md FR-2.12), the state around
/// TourRules and TourSteps: the web's `useTour.ts` and Android's `TourController`. Each step puts
/// its tab, mode and sheet as it says, and the user's come back when the tour ends. The camera
/// follows the steps' views, and goes back to where it was before the first move.
@MainActor
final class TourController {
    private unowned let host: TourHost
    private var seen = TourStore.load()

    private final class Running {
        let steps: [TourStep]
        var index = -1
        let mode: MapMode
        let tab: TourTab
        let sheet: SheetDetent
        /// The rows checked when the tour started, checked again at its end.
        var checked: Set<String> = []

        init(steps: [TourStep], mode: MapMode, tab: TourTab, sheet: SheetDetent) {
            self.steps = steps
            self.mode = mode
            self.tab = tab
            self.sheet = sheet
        }
    }

    private var running: Running?
    private var overlay: TourOverlay?
    private var card: TourOverlay?
    /// The card showing is the offer, which only its own buttons answer.
    private var offering = false
    /// A start the Edit window or the Private location editor held back, made when it gives the
    /// map back (mapFreed).
    private var pendingStart = false
    private var dir = 1
    private var camera = TourCamera()

    /// Whether the account has tracks, once the map knows; nil until then.
    private var hasTracks: Bool?
    private var requested = false
    private var decided = false

    var touring: Bool { running != nil }

    init(host: TourHost) {
        self.host = host
    }

    /// The map found the account's history: the tour starts or is offered, once.
    func historyKnown(_ any: Bool) {
        hasTracks = any
        decide()
    }

    /// The You tab's Take a tour, which starts it however often it was seen.
    func request() {
        requested = true
        decided = false
        // Asked before the map has looked: an unknown history doesn't hold the tour back.
        if hasTracks == nil { hasTracks = false }
        decide()
        // Held back by an editor: the map shows it, and the tour starts once it's closed.
        if pendingStart { host.showTourTab(.map, root: false) }
    }

    /// The map's editor closed: a start it held back is made now.
    func mapFreed() {
        guard pendingStart else { return }
        pendingStart = false
        begin()
    }

    /// Starts the tour, or holds the start while an editor has the map.
    private func begin() {
        if host.map.tourBlocked {
            pendingStart = true
            return
        }
        start()
    }

    private func decide() {
        guard !decided else { return }
        switch TourRules.start(requested: requested, isDemo: host.isDemo, hasTracks: hasTracks, seen: seen) {
        case .wait: return
        case .start: begin()
        case .offer: offer()
        case .none: break
        }
        decided = true
        requested = false
    }

    private func save(_ next: TourSeen) {
        seen = next
        TourStore.save(next)
    }

    private func start() {
        guard running == nil else { return }
        closeCard()
        save(TourSeen(tour: true, cards: seen.cards))
        let checked = host.map.uncheckForTour()
        let run = Running(steps: TourSteps.of(isDemo: host.isDemo), mode: host.map.pickedMode, tab: host.tourTab, sheet: host.map.tourSheetDetent)
        run.checked = checked
        running = run
        let view = TourOverlay(dim: true)
        view.skipButton.configuration?.title = String(localized: "tour.skip", defaultValue: "Skip", comment: "The tour: leave it.")
        view.skipButton.addAction(UIAction { [weak self] _ in self?.end() }, for: .primaryActionTriggered)
        view.backButton.addAction(UIAction { [weak self] _ in self?.move(-1) }, for: .primaryActionTriggered)
        view.nextButton.addAction(UIAction { [weak self] _ in
            guard let self, let run = self.running else { return }
            if run.index == run.steps.count - 1 { self.end() } else { self.move(1) }
        }, for: .primaryActionTriggered)
        add(view)
        overlay = view
        dir = 1
        go(run, TourRules.nextStep(shown: run.steps.map { _ in true }, from: -1, dir: 1))
    }

    private func move(_ d: Int) {
        guard let run = running else { return }
        dir = d
        go(run, TourRules.nextStep(shown: run.steps.map { _ in true }, from: run.index, dir: d))
    }

    func end() {
        guard let run = running else { return }
        go(run, nil)
    }

    private func go(_ run: Running, _ index: Int?) {
        let step = index.map { run.steps[$0] }
        let changes = TourRules.changes(mode: host.map.pickedMode, tab: host.tourTab, step: step, restoreMode: run.mode, restoreTab: run.tab)
        // The You and Sync steps need their tab's first page, Sync's being its map with the sheet,
        // even with the tab showing already; the end leaves the user's pages as they were.
        let needsRoot = step?.target == .youTour || step?.tab == .sync
        if let tab = changes.tab ?? (needsRoot ? step?.tab : nil) { host.showTourTab(tab, root: needsRoot) }
        if let mode = changes.mode { host.map.showTourMode(mode) }
        host.map.setTourSheet(TourSteps.sheet(step, restore: run.sheet))
        for (menu, open) in TourSteps.menus(step) { host.map.holdTourMenu(menu, open: open) }
        if let card = changes.card { save(TourSeen(tour: seen.tour, cards: seen.cards.union([card]))) }
        guard let step, let index else {
            host.map.recheckAfterTour(run.checked)
            endCamera()
            overlay?.removeFromSuperview()
            overlay = nil
            running = nil
            return
        }
        run.index = index
        showCamera(step)
        guard let view = overlay else { return }
        let text = TourText.of(step.text)
        view.title.text = text.title
        view.body.text = text.body
        view.progress.text = String(localized: "tour.progress", defaultValue: "\(index + 1) of \(run.steps.count)", comment: "The tour: the step shown and how many there are.")
        let last = index == run.steps.count - 1
        view.backButton.isHidden = index == 0
        view.skipButton.isHidden = last
        view.nextButton.configuration?.title = last
            ? String(localized: "tour.finish", defaultValue: "Done", comment: "The tour's last step: close it.")
            : String(localized: "tour.next", defaultValue: "Next", comment: "The tour: the next step.")
        if let target = step.target { DispatchQueue.main.async { [weak self] in self?.host.revealTourTarget(target) } }
        view.point(at: { [weak self] in step.target.flatMap { self?.host.tourViews($0) } ?? [] }, onMissing: { [weak self] in
            guard let self else { return }
            self.move(self.dir)
        })
    }

    private func add(_ view: TourOverlay) {
        let container = host.tourContainer
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }

    // MARK: The offer and the cards

    private func offer() {
        showCard(
            title: String(localized: "tour.offer.title", defaultValue: "New here?", comment: "The tour's offer to an account with tracks."),
            body: String(localized: "tour.offer.body", defaultValue: "See what HoldMyTrack can do in a one-minute tour.", comment: "The tour's offer to an account with tracks."),
            target: nil,
            secondary: (String(localized: "tour.offer.later", defaultValue: "Not now", comment: "The tour's offer: decline it."), { [weak self] in
                guard let self else { return }
                self.save(TourSeen(tour: true, cards: self.seen.cards))
                self.tip()
            }),
            primary: (String(localized: "tour.offer.take", defaultValue: "Take the tour", comment: "The tour's offer: start it."), { [weak self] in self?.begin() }),
            closesOutside: false)
        offering = true
    }

    /// Where the tour is from now on, said once after Not now.
    private func tip() {
        let text = String(localized: "tour.tip", defaultValue: "The tour is always on the You tab.", comment: "After the tour's offer is declined.")
        host.map.notice(.tour, text, onClose: {})
        UIAccessibility.post(notification: .announcement, argument: text)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.host.map.hideNotice(.tour)
        }
    }

    /// A mode or tab the user picked, which may earn its card. The offer stays until it's answered,
    /// and a card earned meanwhile waits for the next pick.
    func notice(_ event: TourEvent) {
        if offering { return }
        let earned = TourRules.card(event, seen: seen, touring: touring)
        closeCard()
        guard let earned else { return }
        save(TourSeen(tour: seen.tour, cards: seen.cards.union([earned])))
        let (key, target) = TourSteps.card(earned)
        let text = TourText.of(key)
        showCard(
            title: text.title, body: text.body, target: target,
            secondary: (String(localized: "tour.card.full", defaultValue: "Take the full tour", comment: "A first-time card: start the tour."), { [weak self] in self?.begin() }),
            primary: (String(localized: "tour.card.ok", defaultValue: "Got it", comment: "A first-time card: close it."), {}),
            closesOutside: true)
    }

    private func showCard(title: String, body: String, target: TourTarget?, secondary: (String, () -> Void), primary: (String, () -> Void), closesOutside: Bool) {
        closeCard()
        let view = TourOverlay(dim: false)
        view.title.text = title
        view.body.text = body
        view.progress.isHidden = true
        view.backButton.isHidden = true
        view.skipButton.configuration?.title = secondary.0
        view.skipButton.addAction(UIAction { [weak self] _ in
            self?.closeCard()
            secondary.1()
        }, for: .primaryActionTriggered)
        view.nextButton.configuration?.title = primary.0
        view.nextButton.addAction(UIAction { [weak self] _ in
            self?.closeCard()
            primary.1()
        }, for: .primaryActionTriggered)
        if closesOutside { view.onOutside = { [weak self] in self?.closeCard() } }
        add(view)
        card = view
        view.point(at: { [weak self] in target.flatMap { self?.host.tourViews($0) } ?? [] }, onMissing: nil)
    }

    private func closeCard() {
        card?.removeFromSuperview()
        card = nil
        offering = false
    }

    // MARK: The camera

    /// Eases over FLY seconds and pans each leg over PAN, as Android and the web do; Reduce
    /// Motion jumps, and makes the pan a jump to each of its points in turn.
    private static let fly: TimeInterval = 2
    private static let panLeg: TimeInterval = 5

    private func showCamera(_ step: TourStep) {
        let map = host.map
        map.tourStopCamera()
        guard let current = map.tourCurrentView else { return }
        let next = TourRules.camera(camera, view: step.view, tab: step.tab, current: current)
        camera = next.camera
        guard let target = next.move else { return }
        map.tourMove(to: target, duration: Self.duration(Self.fly)) { [weak self] in self?.pan(target.pan) }
    }

    private func endCamera() {
        let map = host.map
        map.tourStopCamera()
        if let back = TourRules.cameraEnd(camera) { map.tourMove(to: back, duration: Self.duration(Self.fly)) {} }
        camera = TourCamera()
    }

    private func pan(_ legs: [(lon: Double, lat: Double)]) {
        guard let leg = legs.first else { return }
        let rest = Array(legs.dropFirst())
        let map = host.map
        if UIAccessibility.isReduceMotionEnabled {
            let moves = map.tourMoves
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.panLeg))
                guard map.tourMoves == moves else { return }
                map.tourPan(lon: leg.lon, lat: leg.lat, duration: 0) { self?.pan(rest) }
            }
            return
        }
        map.tourPan(lon: leg.lon, lat: leg.lat, duration: Self.panLeg) { [weak self] in self?.pan(rest) }
    }

    private static func duration(_ seconds: TimeInterval) -> TimeInterval { UIAccessibility.isReduceMotionEnabled ? 0 : seconds }
}

/// What the tour has shown on this phone (apps/docs/SPEC.md FR-2.12): kept by the phone, not
/// the account, as the web keeps it by browser, since the demo is one account every visitor shares.
@MainActor
enum TourStore {
    private static let defaults = UserDefaults.standard

    /// The UI tests' -hmtTourSeen keeps the tour and its cards out of flows about something else;
    /// -hmtTourReset forgets what was shown, for the tour's own flows.
    static func load() -> TourSeen {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-hmtTourSeen") { return TourSeen(tour: true, cards: Set(TourCard.allCases)) }
        if arguments.contains("-hmtTourReset") {
            defaults.removeObject(forKey: "tour.seen")
            defaults.removeObject(forKey: "tour.cards")
        }
        return TourSeen(tour: defaults.bool(forKey: "tour.seen"), cards: TourRules.seenCards(defaults.stringArray(forKey: "tour.cards") ?? []))
    }

    static func save(_ seen: TourSeen) {
        defaults.set(seen.tour, forKey: "tour.seen")
        defaults.set(seen.cards.map(\.rawValue).sorted(), forKey: "tour.cards")
    }
}