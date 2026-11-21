import HoldMyTrackCore
import UIKit

/// The Tracks tab's views (apps/android/docs/SPEC.md FR-2.7): the Type and Distance filters,
/// the selection bar while rows are checked, the rows and the target's footer, and the focused
/// track's card for the sheet's head. It draws PanelState and reports each tap as an Event;
/// the map screen owns the state and applies them, since most touch the map too.
final class TracksPanel: NSObject, UITableViewDataSource, UITableViewDelegate {
    enum Event {
        case tapRow(String), toggleChecked(String), clearFocus, endSelecting
        case checkAll, checkNone, invert
        case toggleVisibility, fly, edit, delete
        case toggleType(String), allTypes, distance(DistanceRange?), resetFilters, dates
        case openTrip(String)
    }

    var onEvent: ((Event) -> Void)?

    /// The tab's content, under the sheet's head.
    let content = UIView()
    /// The focused track, at the head in the range's place while nothing is checked.
    let card = UIView()
    /// "Tracks: 6 · 74.8 km · 9h 6m", under the range.
    let summary = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))

    private let table = UITableView(frame: .zero, style: .plain)
    private let note = Controls.body()
    private let progress = ListProgressView()
    private var progressTask: Task<Void, Never>?
    private let footer = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let typeButton = UIButton(type: .system)
    private let distanceButton = UIButton(type: .system)
    /// The Dates filter (root docs/SPEC.md FR-5.12), its sheet the map's (DatesViewController).
    let datesButton = UIButton(type: .system)
    private let resetButton = Controls.textButton(String(localized: "Reset filters"), id: "resetFilters")
    /// While rows are checked, the map shows it in the mode toggle's place (MapViewController+TopRow).
    let selectionBar = UIView()
    private let checkAllButton = UIButton(type: .system)
    private let selectMenuButton = Controls.iconButton(Controls.icon(UIImage(resource: .chevronDown), size: 14), label: String(localized: "Check"), id: "selectMenu")

    private struct ActionButtons {
        let visibility: UIButton, edit: UIButton, addToTrip: UIButton, delete: UIButton, focus: UIButton
        var all: [UIButton] { [visibility, edit, addToTrip, delete, focus] }
    }
    private var barActions: ActionButtons!
    private var cardActions: ActionButtons!

    private let cardIcon = UIImageView()
    private let cardTitle = Controls.label("", font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink))
    private let cardMeta = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    /// Distance, Moving and Pace or Speed, each a tile, as on Android; a private track's note instead.
    private let cardStats = UIStackView()
    private let cardDistance = TracksPanel.statValue("cardDistance")
    private let cardMoving = TracksPanel.statValue("cardMoving")
    private let cardPace = TracksPanel.statValue("cardPace")
    private let cardPaceLabel = TracksPanel.statLabel("")
    private let cardPrivate = Controls.label(String(localized: "Private: inside a Private location, so it has no route or numbers."),
                                             font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    /// The pace bands' legend, slowest first, while the map draws them.
    private let cardBands = UIStackView()
    private let bandSteps = UIStackView()
    private var bandColors: [String]?

    private var rows: [TrackRowCell.Row] = []
    private var format: PanelFormat
    private var state = PanelState()
    private var byID: [String: Track] = [:]
    private let demo: Bool

    /// The Add to trip buttons, whose menu the map screen builds from the account's Trips.
    var addToTripButtons: [UIButton] { [barActions.addToTrip, cardActions.addToTrip] }

    init(format: PanelFormat, demo: Bool) {
        self.format = format
        self.demo = demo
        super.init()
        barActions = makeActions(prefix: "bar")
        cardActions = makeActions(prefix: "card", labelled: true)
        buildContent()
        buildCard()
    }

    // MARK: Building

    /// The toolbar's icon buttons, or labelled ones for the card: Hide, Edit, Trip, Zoom and
    /// Delete, each its word under its icon, as Android's card has them.
    private func makeActions(prefix: String, labelled: Bool = false) -> ActionButtons {
        func button(_ icon: UIImage, _ label: String, _ word: String, id: String, danger: Bool = false) -> UIButton {
            guard labelled else { return Controls.iconButton(icon, label: label, id: id) }
            var config = UIButton.Configuration.plain()
            config.image = Controls.icon(icon, size: 20)
            config.imagePlacement = .top
            config.imagePadding = DesignTokens.Space.s4
            config.title = word
            config.baseForegroundColor = UIColor(resource: danger ? .danger : .ink)
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = Typeface.sans(DesignTokens.Text.xs, weight: DesignTokens.Weight.semibold, relativeTo: .caption1)
                return a
            }
            config.titleLineBreakMode = .byClipping
            let b = UIButton(configuration: config)
            // A fifth of the card each: a long word ("На карту") shrinks rather than being cut.
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.titleLabel?.minimumScaleFactor = 0.6
            b.accessibilityLabel = label
            b.accessibilityIdentifier = id
            return b
        }
        let a = ActionButtons(
            visibility: button(UIImage(resource: .eye), String(localized: "Hide"), String(localized: "card.hide", defaultValue: "Hide", comment: "The focused track's card: hide it on the map."), id: "\(prefix)Visibility"),
            edit: button(UIImage(resource: .pencil), String(localized: "Edit"), String(localized: "card.edit", defaultValue: "Edit", comment: "The focused track's card: edit it."), id: "\(prefix)Edit"),
            addToTrip: button(UIImage(resource: .bookPlus), String(localized: "Add to trip"), String(localized: "card.trip", defaultValue: "Trip", comment: "The focused track's card: add it to a Trip."), id: "\(prefix)AddToTrip"),
            delete: button(UIImage(resource: .trash2), String(localized: "Delete"), String(localized: "card.delete", defaultValue: "Delete", comment: "The focused track's card: delete it."), id: "\(prefix)Delete", danger: true),
            focus: button(UIImage(resource: .focus), String(localized: "Fly to"), String(localized: "card.zoom", defaultValue: "Zoom", comment: "The focused track's card: fly the camera to it."), id: "\(prefix)Focus")
        )
        a.visibility.addAction(UIAction { [weak self] _ in self?.onEvent?(.toggleVisibility) }, for: .primaryActionTriggered)
        a.edit.addAction(UIAction { [weak self] _ in self?.onEvent?(.edit) }, for: .primaryActionTriggered)
        a.delete.addAction(UIAction { [weak self] _ in self?.onEvent?(.delete) }, for: .primaryActionTriggered)
        a.focus.addAction(UIAction { [weak self] _ in self?.onEvent?(.fly) }, for: .primaryActionTriggered)
        a.addToTrip.showsMenuAsPrimaryAction = true
        return a
    }

    private func buildContent() {
        for (button, id) in [(typeButton, "typeFilter"), (datesButton, "datesFilter"), (distanceButton, "distanceFilter")] {
            var config = UIButton.Configuration.bordered()
            config.cornerStyle = .capsule
            config.baseForegroundColor = UIColor(resource: .ink)
            config.baseBackgroundColor = UIColor(resource: .surface)
            config.background.strokeColor = UIColor(resource: .border)
            config.image = Controls.icon(UIImage(resource: .chevronDown), size: 12)
            config.imagePlacement = .trailing
            config.imagePadding = 4
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = Typeface.sans(DesignTokens.Text.md, relativeTo: .subheadline)
                return a
            }
            button.configuration = config
            button.accessibilityIdentifier = id
        }
        typeButton.showsMenuAsPrimaryAction = true
        distanceButton.addAction(UIAction { [weak self] _ in self?.showDistance() }, for: .primaryActionTriggered)
        datesButton.addAction(UIAction { [weak self] _ in self?.onEvent?(.dates) }, for: .primaryActionTriggered)
        setDates(String(localized: "Dates"), set: false)
        resetButton.addAction(UIAction { [weak self] _ in self?.onEvent?(.resetFilters) }, for: .primaryActionTriggered)
        let filters = UIStackView(arrangedSubviews: [typeButton, datesButton, distanceButton, resetButton, UIView()])
        filters.spacing = DesignTokens.Space.s8
        filters.alignment = .center

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
        // ×, which unchecks every row, the check box and its menu, then the actions over the
        // checked group, Zoom in the accent: Android's selection bar.
        let close = Controls.iconButton(UIImage(resource: .x), label: String(localized: "Uncheck all"), id: "endSelecting")
        close.addAction(UIAction { [weak self] _ in self?.onEvent?(.endSelecting) }, for: .primaryActionTriggered)
        barActions.focus.configuration?.baseForegroundColor = UIColor(resource: .accent)
        let bar = UIStackView(arrangedSubviews: [close, checkAllButton, selectMenuButton, UIView()] + barActions.all)
        for v in bar.arrangedSubviews { Self.shrinkable(v) }
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false
        selectionBar.addSubview(bar)
        selectionBar.backgroundColor = UIColor(resource: .surface)
        selectionBar.layer.cornerRadius = DesignTokens.Radius.md
        selectionBar.layer.shadowColor = UIColor.black.cgColor
        selectionBar.layer.shadowOpacity = 0.15
        selectionBar.layer.shadowRadius = 2
        selectionBar.layer.shadowOffset = CGSize(width: 0, height: 1)
        selectionBar.accessibilityIdentifier = "selectionBar"
        let inset = DesignTokens.Space.s4
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: selectionBar.topAnchor, constant: inset),
            bar.bottomAnchor.constraint(equalTo: selectionBar.bottomAnchor, constant: -inset),
            bar.leadingAnchor.constraint(equalTo: selectionBar.leadingAnchor, constant: inset),
            bar.trailingAnchor.constraint(equalTo: selectionBar.trailingAnchor, constant: -inset),
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

        let top = Controls.column([filters], spacing: DesignTokens.Space.s4)
        for v in [top, progress, table, footer, note] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let m = DesignTokens.Space.s12
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            progress.topAnchor.constraint(equalTo: top.bottomAnchor, constant: DesignTokens.Space.s2),
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

    private func buildCard() {
        cardIcon.tintColor = UIColor(resource: .inkSecondary)
        cardIcon.contentMode = .scaleAspectFit
        cardIcon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        cardIcon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let close = Controls.iconButton(UIImage(resource: .x), label: String(localized: "Close"), id: "cardClose")
        close.addAction(UIAction { [weak self] _ in self?.onEvent?(.clearFocus) }, for: .primaryActionTriggered)
        let titles = Controls.column([cardTitle, cardMeta], spacing: DesignTokens.Space.s2)
        let top = UIStackView(arrangedSubviews: [cardIcon, titles, close])
        top.spacing = DesignTokens.Space.s8
        top.alignment = .center
        // Android's order: Hide, Edit, Trip, Zoom, Delete.
        let actions = UIStackView(arrangedSubviews: [cardActions.visibility, cardActions.edit, cardActions.addToTrip, cardActions.focus, cardActions.delete])
        actions.distribution = .fillEqually
        for (label, value) in [(TracksPanel.statLabel(String(localized: "card.distance", defaultValue: "Distance", comment: "The focused track's card: its distance.")), cardDistance),
                               (TracksPanel.statLabel(String(localized: "card.moving", defaultValue: "Moving", comment: "The focused track's card: its moving time.")), cardMoving),
                               (cardPaceLabel, cardPace)] {
            let tile = Controls.column([label, value], spacing: 2)
            tile.isLayoutMarginsRelativeArrangement = true
            tile.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
            tile.backgroundColor = UIColor(resource: .surfaceTint)
            tile.layer.cornerRadius = DesignTokens.Radius.md
            tile.isAccessibilityElement = true
            cardStats.addArrangedSubview(tile)
        }
        cardStats.distribution = .fillEqually
        cardStats.spacing = DesignTokens.Space.s8
        cardPrivate.numberOfLines = 0
        let legend = Typeface.sans(DesignTokens.Text.xs, relativeTo: .caption2)
        bandSteps.spacing = DesignTokens.Space.s2
        bandSteps.distribution = .fillEqually
        bandSteps.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let slower = Controls.label(String(localized: "Slower"), font: legend, color: UIColor(resource: .inkSecondary))
        let faster = Controls.label(String(localized: "Faster"), font: legend, color: UIColor(resource: .inkSecondary))
        for label in [slower, faster] { label.setContentHuggingPriority(.required, for: .horizontal) }
        for v in [slower, bandSteps, faster] { cardBands.addArrangedSubview(v) }
        cardBands.spacing = DesignTokens.Space.s8
        cardBands.alignment = .center
        cardBands.isHidden = true
        cardBands.accessibilityIdentifier = "cardBands"
        let column = Controls.column([top, cardStats, cardPrivate, cardBands, actions], spacing: DesignTokens.Space.s8)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        card.accessibilityIdentifier = "trackCard"
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
            note.text = listed.isEmpty && !tracks.isEmpty ? String(localized: "No tracks match these filters.") : listed.isEmpty ? String(localized: "No tracks in this range.") : nil
            note.textColor = UIColor(resource: .inkSecondary)
        }
        note.isHidden = note.text == nil

        renderFilters()
        renderToolbar()
        renderCard()
        let targets = state.targets.compactMap { byID[$0.id] }
        footer.text = format.checkedFooter(count: targets.count, meters: targets.compactMap(\.distanceMeters).reduce(0, +))
    }

    /// Whether the card shows at the head: something focused and nothing checked.
    var showsCard: Bool { state.focused != nil && !state.selecting && state.focused.flatMap { byID[$0] } != nil }

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
            d?.title = String(localized: "\(format.distanceValue(band.min))–\(format.distanceValue(band.max)) \(format.unit)")
        } else {
            d?.title = String(localized: "Any distance")
        }
        distanceButton.configuration = d
        resetButton.isHidden = !state.hasActiveFilters
    }

    private func targetName(_ targets: [Track]) -> String {
        state.checked.isEmpty ? format.label(targets[0]) : String(localized: "Checked: \(targets.count)")
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
        for actions in [barActions!, cardActions!] {
            describe(actions.visibility, use.visibility, image: UIImage(resource: anyHidden ? .eyeOff : .eye),
                     anyHidden ? String(localized: "Show \(name ?? "")") : String(localized: "Hide \(name ?? "")"))
            describe(actions.edit, use.edit, demo: String(localized: "The demo account can't edit tracks"), String(localized: "Edit \(name ?? "")"))
            describe(actions.addToTrip, use.addToTrip, demo: String(localized: "The demo account can't change a Trip"), String(localized: "Add \(name ?? "") to a Trip"))
            describe(actions.delete, use.delete, demo: String(localized: "The demo account can't delete tracks"), String(localized: "Delete \(name ?? "")"))
            describe(actions.focus, use.focus, String(localized: "Fly to \(name ?? "")"))
        }
        cardActions.visibility.configuration?.title = anyHidden
            ? String(localized: "card.show", defaultValue: "Show", comment: "The focused track's card: show a hidden track on the map.")
            : String(localized: "card.hide", defaultValue: "Hide", comment: "The focused track's card: hide it on the map.")
    }

    /// Each action says what it would do, or why it can't; a disabled one stays in view.
    private func describe(_ button: UIButton, _ use: ToolbarRules.Use, image: UIImage? = nil, demo: String? = nil, _ ready: String) {
        button.isEnabled = use.enabled
        if let image {
            var config = button.configuration
            // The card's labelled buttons draw their icons at 20 points, as they're built.
            let labelled = config?.title != nil
            config?.image = labelled ? Controls.icon(image, size: 20) : image
            button.configuration = config
        }
        button.accessibilityLabel = switch use {
        case .demo: demo ?? ready
        case .noTarget: String(localized: "Nothing to act on: focus or check a track")
        case .pending: String(localized: "Can't delete while it's being processed")
        case .ready: ready
        }
    }

    /// The map draws the focused track's pace bands in colors, slowest first, or none (nil).
    func setBands(_ colors: [String]?) {
        if let colors, colors != bandColors {
            bandColors = colors
            bandSteps.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for color in colors {
                let step = UIView()
                step.backgroundColor = CSSColor(color).map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
                step.layer.cornerRadius = 3
                bandSteps.addArrangedSubview(step)
            }
        }
        cardBands.isHidden = colors?.isEmpty ?? true
    }

    private func renderCard() {
        guard showsCard, let id = state.focused, let track = byID[id] else { return }
        let kind = TrackTypes.shared.kind(track.trackType)
        cardIcon.image = TrackTypes.icon(kind)
        cardTitle.text = format.label(track)
        cardMeta.text = ([track.title != nil ? format.startedAt(track) : nil, TrackTypes.shared.label(track.trackType)] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
        // A private track has no numbers worth showing: what it is stands in for them.
        cardStats.isHidden = track.isPrivate
        cardPrivate.isHidden = !track.isPrivate
        cardPaceLabel.text = kind.showsPace ? String(localized: "Pace") : String(localized: "Speed")
        cardDistance.text = format.distance(track.distanceMeters)
        cardMoving.text = format.duration(track.movingSeconds)
        cardPace.text = format.paceOrSpeed(kind, meters: track.distanceMeters, seconds: track.movingSeconds)
        for tile in cardStats.arrangedSubviews {
            tile.accessibilityLabel = (tile as? UIStackView)?.arrangedSubviews.compactMap { ($0 as? UILabel)?.text }.joined(separator: ", ")
        }
    }

    private static func statLabel(_ text: String) -> UILabel {
        Controls.label(text, font: Typeface.sans(DesignTokens.Text.xs, relativeTo: .caption2), color: UIColor(resource: .inkSecondary))
    }

    private static func statValue(_ id: String) -> UILabel {
        let label = Controls.label("", font: Typeface.sans(DesignTokens.Text.lg, weight: DesignTokens.Weight.semibold, relativeTo: .body), color: UIColor(resource: .ink))
        label.accessibilityIdentifier = id
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        return label
    }

    // MARK: Distance

    private func showDistance() {
        guard let bounds = TrackFacets.distanceBounds(state.tracks), let anchor = distanceButton.window?.rootViewController else { return }
        var top = anchor
        while let presented = top.presentedViewController { top = presented }
        let picker = DistanceFilterViewController(bounds: bounds, current: state.distanceFilter, format: format) { [weak self] next in
            self?.onEvent?(.distance(next))
        }
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

    /// A selection bar button keeps 44 points where the row has room and gives up to 6 of them on a
    /// 375-point phone, where eight of them and the insets don't fit.
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

/// The Distance filter's two knobs (root docs/SPEC.md FR-5.3), each a slider between the list's
/// shortest and longest distance; both back at the ends is no filter (TrackFacets).
final class DistanceFilterViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    private let bounds: DistanceRange
    private var current: DistanceRange?
    private let format: PanelFormat
    private let onChange: (DistanceRange?) -> Void
    private let low = UISlider()
    private let high = UISlider()
    private let readout = Controls.body(color: UIColor(resource: .ink))

    init(bounds: DistanceRange, current: DistanceRange?, format: PanelFormat, onChange: @escaping (DistanceRange?) -> Void) {
        self.bounds = bounds
        self.current = current
        self.format = format
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 300, height: 170)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .surface)
        for (slider, label, id) in [(low, String(localized: "Shortest"), "distanceMin"), (high, String(localized: "Longest"), "distanceMax")] {
            slider.minimumValue = Float(bounds.min)
            slider.maximumValue = Float(bounds.max)
            slider.minimumTrackTintColor = UIColor(resource: .accent)
            slider.accessibilityLabel = label
            slider.accessibilityIdentifier = id
            slider.addAction(UIAction { [weak self] _ in self?.moved(slider) }, for: .valueChanged)
        }
        let band = current ?? bounds
        low.value = Float(band.min)
        high.value = Float(band.max)
        let column = Controls.column([readout, low, high], spacing: DesignTokens.Space.s12)
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: DesignTokens.Space.s16),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Space.s16),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Space.s16),
        ])
        render()
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    private func moved(_ slider: UISlider) {
        // A Float can't carry every distance exactly: a knob at an end snaps onto that end.
        func snap(_ value: Float) -> Double {
            let v = Double(value)
            if abs(v - bounds.min) < 1 { return bounds.min }
            if abs(v - bounds.max) < 1 { return bounds.max }
            return v
        }
        let knob: DistanceKnob = slider === low ? .min : .max
        current = TrackFacets.nextDistanceFilter(bounds: bounds, current: current ?? bounds, knob: knob, value: snap(slider.value))
        let band = current ?? bounds
        low.value = Float(band.min)
        high.value = Float(band.max)
        render()
        onChange(current)
    }

    private func render() {
        let band = current ?? bounds
        readout.text = current == nil ? String(localized: "Any distance") : "\(format.distance(band.min)) – \(format.distance(band.max))"
    }
}