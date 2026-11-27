import HoldMyTrackCore
import UIKit

/// The Tracks tab's views (apps/docs/SPEC.md FR-2.7): the master checkbox and the Type, Dates and
/// Distance filters, the rows and the target's footer, and the toolbar for the sheet's head. It
/// draws PanelState and reports each tap as an Event; the map screen owns the state and applies
/// them, since most touch the map too.
final class TracksPanel: NSObject, UITableViewDataSource, UITableViewDelegate {
    enum Event {
        case tapRow(String), toggleChecked(String), clearFocus
        case checkAll, checkNone, invert
        case toggleVisibility, fly, edit, info, delete, download
        case toggleType(String), allTypes, distance(DistanceRange?), resetFilters, dates
        case openTrip(String)
    }

    var onEvent: ((Event) -> Void)?

    /// The tab's content, under the sheet's head.
    let content = UIView()
    /// The toolbar, at the head in the summary's place while it has a target: Show/Hide, Info,
    /// Edit, Add to trip, ⋯ with Download and Delete, and Zoom in the accent.
    let actions = UIView()
    /// "Tracks: 6 · 74.8 km · 9h 6m", under the range.
    let summary = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))

    private let table = UITableView(frame: .zero, style: .plain)
    private let note = Controls.body()
    private let progress = ListProgressView()
    private var progressTask: Task<Void, Never>?
    private let footer = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let typeButton = UIButton(type: .system)
    private let distanceButton = UIButton(type: .system)
    /// The Distance popover while it's open.
    private weak var distancePicker: DistanceFilterViewController?
    /// The Dates filter (root docs/SPEC.md FR-5.12), its sheet the map's (DatesViewController).
    let datesButton = UIButton(type: .system)
    private let resetButton = Controls.textButton(String(localized: "panel.resetFilters", defaultValue: "Reset", comment: "Tracks tab: clears the Type and Distance filters."), id: "resetFilters")
    private let checkAllButton = UIButton(type: .system)
    private let selectMenuButton = Controls.iconButton(Controls.icon(UIImage(resource: .chevronDown), size: 14), label: String(localized: "Check"), id: "selectMenu")

    private let visibilityButton = Controls.iconButton(UIImage(resource: .eyeOff), label: String(localized: "Hide"), id: "barVisibility")
    private let editButton = Controls.iconButton(UIImage(resource: .pencil), label: String(localized: "Edit"), id: "barEdit")
    /// Add to trip, whose menu the map screen builds from the account's Trips.
    let addToTripButton = Controls.iconButton(UIImage(resource: .bookPlus), label: String(localized: "Add to trip"), id: "barAddToTrip")
    private let infoButton = Controls.iconButton(UIImage(resource: .info), label: String(localized: "Info"), id: "barInfo")
    /// Download (root docs/SPEC.md FR-17.2) and Delete, which don't fit across a phone beside the
    /// others. A blocked one says why under its title.
    private let moreButton = Controls.iconButton(UIImage(resource: .ellipsis), label: String(localized: "More"), id: "barMore")
    private let focusButton = Controls.iconButton(UIImage(resource: .focus), label: String(localized: "Fly to"), id: "barFocus")

    /// The pace bands' colors, slowest first, while the map draws them for the focused track:
    /// Info shows their legend then.
    private(set) var bandColors: [String]?

    private var rows: [TrackRowCell.Row] = []
    private var format: PanelFormat
    private var state = PanelState()
    private var byID: [String: Track] = [:]
    private let demo: Bool

    init(format: PanelFormat, demo: Bool) {
        self.format = format
        self.demo = demo
        super.init()
        buildContent()
        buildActions()
    }

    // MARK: Building

    private func buildContent() {
        for (button, id) in [(typeButton, "typeFilter"), (datesButton, "datesFilter"), (distanceButton, "distanceFilter")] {
            Controls.styleFilter(button, id: id)
        }
        typeButton.showsMenuAsPrimaryAction = true
        distanceButton.addAction(UIAction { [weak self] _ in self?.showDistance() }, for: .primaryActionTriggered)
        datesButton.addAction(UIAction { [weak self] _ in self?.onEvent?(.dates) }, for: .primaryActionTriggered)
        setDates(String(localized: "Dates"), set: false)
        resetButton.addAction(UIAction { [weak self] _ in self?.onEvent?(.resetFilters) }, for: .primaryActionTriggered)
        resetButton.configuration?.titleLineBreakMode = .byTruncatingTail

        checkAllButton.configuration = .plain()
        checkAllButton.accessibilityIdentifier = "checkAll"
        checkAllButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        checkAllButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        checkAllButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let listed = self.state.listed
            let all = ToolbarRules.checkAll(listed: listed.count, checked: listed.filter { self.state.checked.contains($0.id) }.count)
            self.onEvent?(all == .all ? .checkNone : .checkAll)
        }, for: .primaryActionTriggered)
        selectMenuButton.showsMenuAsPrimaryAction = true

        // The master checkbox and its menu, then the filters, scrolling sideways when they don't fit.
        let filters = UIStackView(arrangedSubviews: [checkAllButton, selectMenuButton, typeButton, datesButton, distanceButton, resetButton])
        filters.spacing = DesignTokens.Space.s8
        filters.setCustomSpacing(0, after: checkAllButton)
        filters.alignment = .center
        filters.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.accessibilityIdentifier = "filterRow"
        scroll.addSubview(filters)
        NSLayoutConstraint.activate([
            filters.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            filters.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            filters.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            filters.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            filters.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        table.dataSource = self
        table.delegate = self
        table.register(TrackRowCell.self, forCellReuseIdentifier: TrackRowCell.reuse)
        table.backgroundColor = .clear
        table.separatorInset = .init(top: 0, left: 64, bottom: 0, right: 0)
        table.accessibilityIdentifier = "trackList"
        table.estimatedRowHeight = 64
        let tapEmpty = UITapGestureRecognizer(target: self, action: #selector(tappedList(_:)))
        tapEmpty.cancelsTouchesInView = false
        table.addGestureRecognizer(tapEmpty)
        note.textAlignment = .center
        note.accessibilityIdentifier = "panelNote"

        for v in [scroll, progress, table, footer, note] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let m = DesignTokens.Space.s12
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Space.s4),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.heightAnchor.constraint(equalTo: filters.heightAnchor),
            progress.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: DesignTokens.Space.s2),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            table.topAnchor.constraint(equalTo: progress.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: table.bottomAnchor, constant: DesignTokens.Space.s4),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -DesignTokens.Space.s8),
            note.topAnchor.constraint(equalTo: table.topAnchor, constant: DesignTokens.Space.s16),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
        ])
    }

    /// The toolbar, Android's order: Show/Hide, Info, Edit, Add to trip, ⋯, Zoom.
    private func buildActions() {
        visibilityButton.addAction(UIAction { [weak self] _ in self?.onEvent?(.toggleVisibility) }, for: .primaryActionTriggered)
        editButton.addAction(UIAction { [weak self] _ in self?.onEvent?(.edit) }, for: .primaryActionTriggered)
        infoButton.addAction(UIAction { [weak self] _ in self?.onEvent?(.info) }, for: .primaryActionTriggered)
        focusButton.addAction(UIAction { [weak self] _ in self?.onEvent?(.fly) }, for: .primaryActionTriggered)
        focusButton.configuration?.baseForegroundColor = UIColor(resource: .accent)
        addToTripButton.showsMenuAsPrimaryAction = true
        moreButton.showsMenuAsPrimaryAction = true
        let buttons = [visibilityButton, infoButton, editButton, addToTripButton, moreButton, focusButton]
        for v in buttons { Self.shrinkable(v) }
        // Spread across the head: the map and the list show what they act on, and each one's
        // label names it.
        let row = UIStackView(arrangedSubviews: buttons)
        row.alignment = .center
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        actions.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: actions.topAnchor),
            row.bottomAnchor.constraint(equalTo: actions.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
        ])
        actions.accessibilityIdentifier = "trackActions"
        actions.isHidden = true
    }

    // MARK: Rendering

    /// Draws state over the range's tracks; note says the list is loading or why it failed.
    func render(_ state: PanelState, tracks: [Track], format: PanelFormat, note loadNote: (text: String, failed: Bool)?) {
        self.state = state
        self.format = format
        byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let listed = state.listed.compactMap { byID[$0.id] }
        summary.text = format.summary(count: listed.count, meters: listed.compactMap(\.distanceMeters).reduce(0, +), seconds: listed.compactMap(\.movingSeconds).reduce(0, +))

        rows = listed.map { TrackRowCell.Row(track: $0, checked: state.checked.contains($0.id), focused: state.focused == $0.id, hidden: state.hidden.contains($0.id), selecting: state.selecting) }
        table.reloadData()
        if let loadNote {
            note.text = loadNote.text
            note.textColor = UIColor(resource: loadNote.failed ? .danger : .inkSecondary)
        } else {
            note.text = listed.isEmpty && !tracks.isEmpty ? String(localized: "No tracks here match the current filters.") : listed.isEmpty ? String(localized: "No tracks in this part of the map.") : nil
            note.textColor = UIColor(resource: .inkSecondary)
        }
        note.isHidden = note.text == nil

        renderFilters()
        renderToolbar()
        let targets = state.targets.compactMap { byID[$0.id] }
        footer.text = format.checkedFooter(count: targets.count, meters: targets.compactMap(\.distanceMeters).reduce(0, +))
    }

    /// Whether the toolbar shows at the head: it has a target.
    var showsActions: Bool { !state.targets.compactMap { byID[$0.id] }.isEmpty }

    /// A list load is under way, or over: the bar over the rows shows once one has run
    /// progressDelay, so a quick pan doesn't flicker. The list keeps its rows meanwhile, and a
    /// "Loading…" line below them would go unseen.
    func setLoading(_ loading: Bool) {
        progressTask?.cancel()
        guard loading else { return progress.stop() }
        guard !progress.running else { return }
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: Self.progressDelay)
            guard !Task.isCancelled else { return }
            self?.progress.start()
        }
    }

    /// How long a list load runs before the progress bar shows.
    private static let progressDelay = Duration.milliseconds(300)

    /// The Dates button's words: "Dates", or the days set, marked while set.
    func setDates(_ text: String, set: Bool) {
        datesButton.configuration?.title = set ? "\(text) •" : text
        datesButton.accessibilityLabel = String(localized: "Filter by dates")
        datesButton.accessibilityValue = text
    }

    /// Centers id's row in the list, never moving the sheet.
    func scrollTo(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.track.id == id }) else { return }
        table.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: true)
    }

    private func renderFilters() {
        let facets = TrackFacets.typeFacets(state.tracks, distanceFilter: state.distanceFilter)
        var config = typeButton.configuration
        config?.title = state.excludedTypes.isEmpty ? String(localized: "Type") : String(localized: "Type •")
        typeButton.configuration = config
        typeButton.accessibilityValue = state.excludedTypes.isEmpty ? String(localized: "All types") : String(localized: "Filtered")
        let all = UIAction(title: String(localized: "All types"), state: state.excludedTypes.isEmpty ? .on : .off) { [weak self] _ in self?.onEvent?(.allTypes) }
        let types = facets.map { facet in
            UIAction(title: TrackTypes.shared.label(facet.type), subtitle: format.count(facet.count),
                     image: TrackTypes.icon(TrackTypes.shared.kind(facet.type)),
                     state: state.excludedTypes.contains(facet.type) ? .off : .on) { [weak self] _ in self?.onEvent?(.toggleType(facet.type)) }
        }
        typeButton.menu = UIMenu(children: [all, UIMenu(options: .displayInline, children: types)])
        typeButton.isEnabled = !facets.isEmpty

        // Offered only with two or more distinct distances.
        let bounds = TrackFacets.distanceBounds(state.tracks)
        distanceButton.isHidden = bounds.map { $0.min >= $0.max } ?? true
        var d = distanceButton.configuration
        if let band = state.distanceFilter {
            d?.title = String(localized: "\(format.distanceBandValue(band.min)) – \(format.distanceBandValue(band.max)) \(format.unit)")
        } else {
            d?.title = String(localized: "Any distance")
        }
        distanceButton.configuration = d
        resetButton.isHidden = !state.hasActiveFilters
        // A list reloaded under the open popover moves its ends with it, or both knobs at the ends
        // would set a filter at the old ones.
        if let picker = distancePicker {
            if let bounds, bounds.min < bounds.max { picker.update(bounds: bounds, current: state.distanceFilter) } else { picker.dismiss(animated: true) }
        }
    }

    private func targetName(_ targets: [Track]) -> String {
        state.checked.isEmpty ? String(localized: "“\(format.label(targets[0]))”", comment: "Tracks tab: one track named as an action's target.") : String(localized: "panel.checkedCount", defaultValue: "\(targets.count) checked tracks", comment: "Tracks tab: the checked tracks an action applies to.")
    }

    private func renderToolbar() {
        let listed = state.listed
        let all = ToolbarRules.checkAll(listed: listed.count, checked: listed.filter { state.checked.contains($0.id) }.count)
        var config = checkAllButton.configuration ?? .plain()
        config.image = UIImage(resource: all == .all ? .check : all == .some ? .square : .square)
        config.baseForegroundColor = UIColor(resource: all == .none ? .inkSecondary : .accent)
        checkAllButton.configuration = config
        checkAllButton.accessibilityLabel = all == .all ? String(localized: "Uncheck all tracks") : String(localized: "Check all tracks")
        checkAllButton.accessibilityValue = all == .some ? String(localized: "Some checked") : nil
        checkAllButton.isEnabled = !listed.isEmpty
        selectMenuButton.menu = UIMenu(children: [
            UIAction(title: String(localized: "All"), attributes: all == .all ? .disabled : []) { [weak self] _ in self?.onEvent?(.checkAll) },
            UIAction(title: String(localized: "None"), attributes: state.checked.isEmpty ? .disabled : []) { [weak self] _ in self?.onEvent?(.checkNone) },
            UIAction(title: String(localized: "Invert")) { [weak self] _ in self?.onEvent?(.invert) },
        ])

        let targets = state.targets.compactMap { byID[$0.id] }
        let use = ToolbarRules.actions(targets: targets.count, anyPending: targets.contains(where: \.pending), demo: demo)
        let anyHidden = targets.contains { state.hidden.contains($0.id) }
        let name = targets.isEmpty ? nil : targetName(targets)
        let deleteDemo = String(localized: "Not available for demo accounts — create an account to delete tracks")
        // What a tap does: show (the open eye) or hide (crossed out).
        describe(visibilityButton, use.visibility, image: UIImage(resource: anyHidden ? .eye : .eyeOff),
                 anyHidden ? String(localized: "Show \(name ?? "") on the map") : String(localized: "Hide \(name ?? "") from the map"))
        describe(editButton, use.edit, demo: String(localized: "Not available for demo accounts — create an account to edit tracks"), targets.count == 1 ? String(localized: "Edit \(name ?? ""): type, name, description and route") : String(localized: "Edit type for \(name ?? "")"))
        describe(addToTripButton, use.addToTrip, demo: String(localized: "Not available for demo accounts — create an account to change trips"), String(localized: "Add \(name ?? "") to a trip"))
        describe(infoButton, use.info, String(localized: "panel.infoTarget", defaultValue: "Info for \(name ?? "")", comment: "Tracks tab: Info's label; the placeholder names its target."))
        describe(focusButton, use.focus, String(localized: "Zoom to \(name ?? "")"))
        renderMore(targets, name: name, delete: use.delete, deleteDemo: deleteDemo)
    }


    /// The ⋯ menu over targets, named name: Download unless DownloadRules blocks it, then Delete
    /// as ToolbarRules has it. A blocked item is disabled with why under its title.
    private func renderMore(_ targets: [Track], name: String?, delete: ToolbarRules.Use, deleteDemo: String) {
        moreButton.isEnabled = name != nil
        moreButton.accessibilityLabel = name.map { String(localized: "panel.moreTarget", defaultValue: "More for \($0)", comment: "Tracks tab: the toolbar's ⋯, which holds Download and Delete for the target.") }
            ?? String(localized: "Tap a track, or check some, first")
        guard let name else {
            moreButton.menu = nil
            return
        }
        func label(_ id: String) -> String { targets.first { $0.id == id }.map(format.label) ?? "" }
        let block = DownloadRules.block(targets.map { DownloadRules.Target(id: $0.id, pending: $0.pending, isPrivate: $0.isPrivate) })
        let downloadWhy: String? = switch block {
        case nil: nil
        case .tooMany(let count): String(localized: "panel.downloadTooMany", defaultValue: "Download takes at most \(DownloadRules.maxTracks) tracks at a time; \(count) are checked",
                                         comment: "Tracks tab: why Download can't take the checked tracks; the first number is the limit, the second how many are checked.")
        case .pending(let id): String(localized: "panel.downloadPending", defaultValue: "Can't download: “\(label(id))” is still being processed", comment: "Tracks tab: why Download can't go; the placeholder names the track.")
        case .private(let id): String(localized: "panel.downloadPrivate", defaultValue: "Can't download: “\(label(id))” lies entirely inside your private locations", comment: "Tracks tab: why Download can't go; the placeholder names the track.")
        }
        let deleteWhy: String? = switch delete {
        case .ready: nil
        case .demo: deleteDemo
        case .noTarget: String(localized: "Tap a track, or check some, first")
        case .pending: String(localized: "panel.deletePending", defaultValue: "Can't delete while a track is being processed", comment: "Tracks tab: why Delete is off while a checked or focused track is still being processed.")
        }
        let download = UIAction(title: String(localized: "panel.moreDownload", defaultValue: "Download as GPX", comment: "Tracks tab: the ⋯ menu's Download."),
                                subtitle: downloadWhy, image: UIImage(resource: .download), attributes: downloadWhy == nil ? [] : .disabled) { [weak self] _ in self?.onEvent?(.download) }
        download.accessibilityIdentifier = "moreDownload"
        let remove = UIAction(title: String(localized: "panel.moreDelete", defaultValue: "Delete…", comment: "Tracks tab: the ⋯ menu's Delete, which asks first."),
                              subtitle: deleteWhy, image: UIImage(resource: .trash2), attributes: deleteWhy == nil ? .destructive : .disabled) { [weak self] _ in self?.onEvent?(.delete) }
        remove.accessibilityIdentifier = "moreDelete"
        moreButton.menu = UIMenu(children: [download, remove])
    }

    /// Each action says what it would do, or why it can't; a disabled one stays in view.
    private func describe(_ button: UIButton, _ use: ToolbarRules.Use, image: UIImage? = nil, demo: String? = nil, _ ready: String) {
        button.isEnabled = use.enabled
        if let image { button.configuration?.image = image }
        button.accessibilityLabel = switch use {
        case .demo: demo ?? ready
        case .noTarget: String(localized: "Tap a track, or check some, first")
        case .pending: String(localized: "panel.deletePending", defaultValue: "Can't delete while a track is being processed", comment: "Tracks tab: why Delete is off while a checked or focused track is still being processed.")
        case .ready: ready
        }
    }

    /// The map draws the focused track's pace bands in colors, slowest first, or none (nil).
    func setBands(_ colors: [String]?) {
        bandColors = colors?.isEmpty == true ? nil : colors
    }

    // MARK: Distance

    private func showDistance() {
        guard let bounds = TrackFacets.distanceBounds(state.tracks), let anchor = distanceButton.window?.rootViewController else { return }
        var top = anchor
        while let presented = top.presentedViewController { top = presented }
        let picker = DistanceFilterViewController(bounds: bounds, current: state.distanceFilter, format: format) { [weak self] next in
            self?.onEvent?(.distance(next))
        }
        distancePicker = picker
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = distanceButton
        picker.popoverPresentationController?.delegate = picker
        top.present(picker, animated: true)
    }

    // MARK: The list

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TrackRowCell.reuse, for: indexPath) as! TrackRowCell
        let row = rows[indexPath.row]
        let id = row.track.id
        cell.bind(row, format: format, openTripID: nil, demo: demo,
                  onCheck: { [weak self] in self?.onEvent?(.toggleChecked(id)) },
                  onOpenTrip: { [weak self] in self?.onEvent?(.openTrip($0)) },
                  onRemove: nil)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = rows[indexPath.row]
        guard !row.track.pending || row.checked else { return }
        onEvent?(row.selecting ? .toggleChecked(row.track.id) : .tapRow(row.track.id))
    }

    /// A toolbar button keeps 44 points where the row has room and gives up to 6 of them on a
    /// narrow phone or at a large text size, where the target's name and six of them don't fit.
    private static func shrinkable(_ view: UIView) {
        for fixed in view.constraints where fixed.firstAttribute == .width && fixed.relation == .equal && fixed.constant == 44 {
            fixed.isActive = false
            let preferred = view.widthAnchor.constraint(equalToConstant: 44)
            preferred.priority = .defaultHigh
            NSLayoutConstraint.activate([preferred, view.widthAnchor.constraint(greaterThanOrEqualToConstant: 38)])
        }
    }

    @objc private func tappedList(_ tap: UITapGestureRecognizer) {
        if table.indexPathForRow(at: tap.location(in: table)) == nil { onEvent?(.clearFocus) }
    }
}

/// The Distance filter (root docs/SPEC.md FR-5.3), as Android's: one two-knob slider between the
/// list's shortest and longest track, those two under its ends; both knobs back at the ends is no
/// filter (TrackFacets).
final class DistanceFilterViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    /// The slider's ends: the bounds rounded outward to whole units (TrackFacets.wholeDistanceBounds).
    private var bounds: DistanceRange
    private var current: DistanceRange?
    private let format: PanelFormat
    private let onChange: (DistanceRange?) -> Void
    private let slider = RangeSlider()
    private let shortest = Controls.body("")
    private let longest = Controls.body("")
    /// The knobs' steps as last drawn, so a move changes only the knob that moved.
    private var lower = 0
    private var upper = 0

    /// bounds: the tracks' own; the slider runs between them rounded to whole units.
    init(bounds: DistanceRange, current: DistanceRange?, format: PanelFormat, onChange: @escaping (DistanceRange?) -> Void) {
        self.bounds = TrackFacets.wholeDistanceBounds(bounds, imperial: format.imperial) ?? bounds
        self.current = current
        self.format = format
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .surface)
        let title = Controls.body(String(localized: "filter.distance", defaultValue: "Distance", comment: "Tracks tab: the Distance filter's heading."), color: UIColor(resource: .ink))
        slider.label(lower: String(localized: "Shortest"), upper: String(localized: "Longest"))
        slider.accessibilityStep = 1
        slider.describe = { [weak self] step in
            guard let self else { return "" }
            return self.format.distanceBand(DistanceSteps.meters(step, ends: self.bounds, imperial: self.format.imperial))
        }
        slider.accessibilityIdentifier = "distanceRange"
        slider.addAction(UIAction { [weak self] _ in self?.moved() }, for: .valueChanged)
        for end in [shortest, longest] { end.font = Typeface.sans(DesignTokens.Text.xs) }
        longest.textAlignment = .right
        let ends = UIStackView(arrangedSubviews: [shortest, longest])
        ends.distribution = .fillEqually
        let column = Controls.column([title, slider, ends], spacing: DesignTokens.Space.s4)
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: DesignTokens.Space.s12),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Space.s16),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Space.s16),
        ])
        render()
        // As tall as its content, which grows with the text size.
        let width: CGFloat = 300
        let fitted = column.systemLayoutSizeFitting(CGSize(width: width - 2 * DesignTokens.Space.s16, height: 0),
                                                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: width, height: fitted.height + DesignTokens.Space.s12 + DesignTokens.Space.s16)
    }

    /// A list reloaded under the popover: its ends and the filter as they are now.
    func update(bounds: DistanceRange, current: DistanceRange?) {
        let bounds = TrackFacets.wholeDistanceBounds(bounds, imperial: format.imperial) ?? bounds
        guard bounds != self.bounds || current != self.current else { return }
        self.bounds = bounds
        self.current = current
        if isViewLoaded { render() }
    }

    /// The knobs on the filter, and the ends under them.
    private func render() {
        let band = current ?? bounds
        lower = DistanceSteps.step(band.min, ends: bounds, imperial: format.imperial)
        upper = DistanceSteps.step(band.max, ends: bounds, imperial: format.imperial)
        slider.set(lower: lower, upper: upper, maximum: DistanceSteps.count(bounds, imperial: format.imperial))
        shortest.text = format.distanceBand(bounds.min)
        longest.text = format.distanceBand(bounds.max)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    /// The knob that moved, alone, on a whole unit; the other end holds. Both knobs back at the
    /// ends is no filter.
    private func moved() {
        let knob: DistanceKnob = slider.lower != lower ? .min : .max
        let step = knob == .min ? slider.lower : slider.upper
        lower = slider.lower
        upper = slider.upper
        current = TrackFacets.nextDistanceFilter(bounds: bounds, current: current ?? bounds, knob: knob, value: DistanceSteps.meters(step, ends: bounds, imperial: format.imperial), imperial: format.imperial)
        onChange(current)
    }
}
