import HoldMyTrackCore
import UIKit

/// The Activities tab's views (apps/android/docs/SPEC.md FR-2.7): the Type and Distance filters,
/// the selection bar while rows are checked, the rows and the target's footer, and the focused
/// activity's card for the sheet's head. It draws PanelState and reports each tap as an Event;
/// the map screen owns the state and applies them, since most touch the map too.
final class ActivitiesPanel: NSObject, UITableViewDataSource, UITableViewDelegate {
    enum Event {
        case tapRow(String), toggleChecked(String), clearFocus, endSelecting
        case checkAll, checkNone, invert
        case toggleVisibility, fly, edit, delete
        case toggleType(String), allTypes, distance(DistanceRange?), resetFilters
        case openStory(String)
    }

    var onEvent: ((Event) -> Void)?

    /// The tab's content, under the sheet's head.
    let content = UIView()
    /// The focused activity, at the head in the range's place while nothing is checked.
    let card = UIView()
    /// "Activities: 6 · 74.8 km · 9h 6m", under the range.
    let summary = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))

    private let table = UITableView(frame: .zero, style: .plain)
    private let note = Controls.body()
    private let footer = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let typeButton = UIButton(type: .system)
    private let distanceButton = UIButton(type: .system)
    private let resetButton = Controls.textButton(String(localized: "Reset filters"), id: "resetFilters")
    private let selectionBar = UIStackView()
    private let checkAllButton = UIButton(type: .system)
    private let selectMenuButton = Controls.iconButton(UIImage(resource: .chevronDown), label: String(localized: "Select"), id: "selectMenu")

    private struct ActionButtons {
        let visibility: UIButton, edit: UIButton, addToStory: UIButton, delete: UIButton, focus: UIButton
        var all: [UIButton] { [visibility, edit, addToStory, delete, focus] }
    }
    private var barActions: ActionButtons!
    private var cardActions: ActionButtons!

    private let cardIcon = UIImageView()
    private let cardTitle = Controls.label("", font: Typeface.sans(DesignTokens.Text.xl, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private let cardMeta = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let cardStats = Controls.label("", font: Typeface.sans(DesignTokens.Text.md), color: UIColor(resource: .ink))

    private var rows: [ActivityRowCell.Row] = []
    private var format: PanelFormat
    private var state = PanelState()
    private var byID: [String: Activity] = [:]
    private let demo: Bool

    /// The Add to story buttons, whose menu the map screen builds from the account's Stories.
    var addToStoryButtons: [UIButton] { [barActions.addToStory, cardActions.addToStory] }

    init(format: PanelFormat, demo: Bool) {
        self.format = format
        self.demo = demo
        super.init()
        barActions = makeActions(prefix: "bar")
        cardActions = makeActions(prefix: "card")
        buildContent()
        buildCard()
    }

    // MARK: Building

    private func makeActions(prefix: String) -> ActionButtons {
        let a = ActionButtons(
            visibility: Controls.iconButton(UIImage(resource: .eye), label: String(localized: "Hide"), id: "\(prefix)Visibility"),
            edit: Controls.iconButton(UIImage(resource: .pencil), label: String(localized: "Edit"), id: "\(prefix)Edit"),
            addToStory: Controls.iconButton(UIImage(resource: .bookPlus), label: String(localized: "Add to story"), id: "\(prefix)AddToStory"),
            delete: Controls.iconButton(UIImage(resource: .trash2), label: String(localized: "Delete"), id: "\(prefix)Delete"),
            focus: Controls.iconButton(UIImage(resource: .focus), label: String(localized: "Fly to"), id: "\(prefix)Focus")
        )
        a.visibility.addAction(UIAction { [weak self] _ in self?.onEvent?(.toggleVisibility) }, for: .primaryActionTriggered)
        a.edit.addAction(UIAction { [weak self] _ in self?.onEvent?(.edit) }, for: .primaryActionTriggered)
        a.delete.addAction(UIAction { [weak self] _ in self?.onEvent?(.delete) }, for: .primaryActionTriggered)
        a.focus.addAction(UIAction { [weak self] _ in self?.onEvent?(.fly) }, for: .primaryActionTriggered)
        a.addToStory.showsMenuAsPrimaryAction = true
        return a
    }

    private func buildContent() {
        for (button, id) in [(typeButton, "typeFilter"), (distanceButton, "distanceFilter")] {
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
        resetButton.addAction(UIAction { [weak self] _ in self?.onEvent?(.resetFilters) }, for: .primaryActionTriggered)
        let filters = UIStackView(arrangedSubviews: [typeButton, distanceButton, resetButton, UIView()])
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
        let close = Controls.iconButton(UIImage(resource: .x), label: String(localized: "Stop selecting"), id: "endSelecting")
        close.addAction(UIAction { [weak self] _ in self?.onEvent?(.endSelecting) }, for: .primaryActionTriggered)
        for v in [checkAllButton, selectMenuButton, UIView()] + barActions.all + [close] as [UIView] { selectionBar.addArrangedSubview(v) }
        selectionBar.alignment = .center
        selectionBar.accessibilityIdentifier = "selectionBar"

        table.dataSource = self
        table.delegate = self
        table.register(ActivityRowCell.self, forCellReuseIdentifier: ActivityRowCell.reuse)
        table.backgroundColor = .clear
        table.separatorInset = .init(top: 0, left: 64, bottom: 0, right: 0)
        table.accessibilityIdentifier = "activityList"
        table.estimatedRowHeight = 64
        let tapEmpty = UITapGestureRecognizer(target: self, action: #selector(tappedList(_:)))
        tapEmpty.cancelsTouchesInView = false
        table.addGestureRecognizer(tapEmpty)
        note.textAlignment = .center
        note.accessibilityIdentifier = "panelNote"

        let top = Controls.column([filters, selectionBar], spacing: DesignTokens.Space.s4)
        for v in [top, table, footer, note] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let m = DesignTokens.Space.s12
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            table.topAnchor.constraint(equalTo: top.bottomAnchor, constant: DesignTokens.Space.s4),
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
        let actions = UIStackView(arrangedSubviews: cardActions.all)
        actions.distribution = .equalSpacing
        let column = Controls.column([top, cardStats, actions], spacing: DesignTokens.Space.s4)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        card.accessibilityIdentifier = "activityCard"
    }

    // MARK: Rendering

    /// Draws state over the range's activities; note says the list is loading or why it failed.
    func render(_ state: PanelState, activities: [Activity], format: PanelFormat, note loadNote: (text: String, failed: Bool)?) {
        self.state = state
        self.format = format
        byID = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let listed = state.listed.compactMap { byID[$0.id] }
        summary.text = format.summary(count: listed.count, meters: listed.compactMap(\.distanceMeters).reduce(0, +), seconds: listed.compactMap(\.movingSeconds).reduce(0, +))

        rows = listed.map { ActivityRowCell.Row(activity: $0, checked: state.checked.contains($0.id), focused: state.focused == $0.id, hidden: state.hidden.contains($0.id), selecting: state.selecting) }
        table.reloadData()
        if let loadNote {
            note.text = loadNote.text
            note.textColor = UIColor(resource: loadNote.failed ? .danger : .inkSecondary)
        } else {
            note.text = listed.isEmpty && !activities.isEmpty ? String(localized: "No activities match these filters.") : listed.isEmpty ? String(localized: "No activities in this range.") : nil
            note.textColor = UIColor(resource: .inkSecondary)
        }
        note.isHidden = note.text == nil

        renderFilters()
        renderToolbar()
        renderCard()
        let targets = state.targets.compactMap { byID[$0.id] }
        footer.text = targets.isEmpty ? nil : [targetName(targets), format.totalDistance(targets.compactMap(\.distanceMeters).reduce(0, +))].joined(separator: " · ")
        footer.isHidden = footer.text == nil
    }

    /// Whether the card shows at the head: something focused and nothing checked.
    var showsCard: Bool { state.focused != nil && !state.selecting && state.focused.flatMap { byID[$0] } != nil }

    /// Centers id's row in the list, never moving the sheet.
    func scrollTo(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.activity.id == id }) else { return }
        table.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: true)
    }

    private func renderFilters() {
        let facets = ActivityFacets.typeFacets(state.activities, distanceFilter: state.distanceFilter)
        var config = typeButton.configuration
        config?.title = state.excludedTypes.isEmpty ? String(localized: "Type") : String(localized: "Type •")
        typeButton.configuration = config
        typeButton.accessibilityValue = state.excludedTypes.isEmpty ? String(localized: "All types") : String(localized: "Filtered")
        let all = UIAction(title: String(localized: "All types"), state: state.excludedTypes.isEmpty ? .on : .off) { [weak self] _ in self?.onEvent?(.allTypes) }
        let types = facets.map { facet in
            UIAction(title: ActivityTypes.shared.label(facet.type), subtitle: format.count(facet.count),
                     image: ActivityTypes.icon(ActivityTypes.shared.kind(facet.type)),
                     state: state.excludedTypes.contains(facet.type) ? .off : .on) { [weak self] _ in self?.onEvent?(.toggleType(facet.type)) }
        }
        typeButton.menu = UIMenu(children: [all, UIMenu(options: .displayInline, children: types)])
        typeButton.isEnabled = !facets.isEmpty

        // Offered only with two or more distinct distances.
        let bounds = ActivityFacets.distanceBounds(state.activities)
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

    private func targetName(_ targets: [Activity]) -> String {
        state.checked.isEmpty ? format.label(targets[0]) : String(localized: "Checked: \(targets.count)")
    }

    private func renderToolbar() {
        selectionBar.isHidden = !state.selecting
        let listed = state.listed
        let all = ToolbarRules.checkAll(listed: listed.count, checked: listed.filter { state.checked.contains($0.id) }.count)
        var config = checkAllButton.configuration ?? .plain()
        config.image = UIImage(resource: all == .all ? .check : all == .some ? .square : .square)
        config.baseForegroundColor = UIColor(resource: all == .none ? .inkSecondary : .accent)
        checkAllButton.configuration = config
        checkAllButton.accessibilityLabel = all == .all ? String(localized: "Uncheck all") : String(localized: "Check all")
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
            describe(actions.edit, use.edit, demo: String(localized: "The demo account can't edit activities"), String(localized: "Edit \(name ?? "")"))
            describe(actions.addToStory, use.addToStory, demo: String(localized: "The demo account can't change a Story"), String(localized: "Add \(name ?? "") to a Story"))
            describe(actions.delete, use.delete, demo: String(localized: "The demo account can't delete activities"), String(localized: "Delete \(name ?? "")"))
            describe(actions.focus, use.focus, String(localized: "Fly to \(name ?? "")"))
        }
    }

    /// Each action says what it would do, or why it can't; a disabled one stays in view.
    private func describe(_ button: UIButton, _ use: ToolbarRules.Use, image: UIImage? = nil, demo: String? = nil, _ ready: String) {
        button.isEnabled = use.enabled
        if let image {
            var config = button.configuration
            config?.image = image
            button.configuration = config
        }
        button.accessibilityLabel = switch use {
        case .demo: demo ?? ready
        case .noTarget: String(localized: "Nothing to act on: focus or check an activity")
        case .pending: String(localized: "Can't delete while it's being processed")
        case .ready: ready
        }
    }

    private func renderCard() {
        guard showsCard, let id = state.focused, let activity = byID[id] else { return }
        let kind = ActivityTypes.shared.kind(activity.activityType)
        cardIcon.image = ActivityTypes.icon(kind)
        cardTitle.text = format.label(activity)
        cardMeta.text = ([activity.title != nil ? format.startedAt(activity) : nil, ActivityTypes.shared.label(activity.activityType)] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
        if activity.isPrivate {
            cardStats.text = String(localized: "Private: inside a Private location, so it has no track or numbers.")
        } else {
            let speed = kind.showsPace ? String(localized: "Pace") : String(localized: "Speed")
            cardStats.text = [
                String(localized: "Distance: \(format.distance(activity.distanceMeters))"),
                String(localized: "Moving: \(format.duration(activity.movingSeconds))"),
                "\(speed): \(format.paceOrSpeed(kind, meters: activity.distanceMeters, seconds: activity.movingSeconds))",
            ].joined(separator: "  ·  ")
        }
    }

    // MARK: Distance

    private func showDistance() {
        guard let bounds = ActivityFacets.distanceBounds(state.activities), let anchor = distanceButton.window?.rootViewController else { return }
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
        let cell = tableView.dequeueReusableCell(withIdentifier: ActivityRowCell.reuse, for: indexPath) as! ActivityRowCell
        let row = rows[indexPath.row]
        let id = row.activity.id
        cell.bind(row, format: format, openStoryID: nil, demo: demo,
                  onCheck: { [weak self] in self?.onEvent?(.toggleChecked(id)) },
                  onOpenStory: { [weak self] in self?.onEvent?(.openStory($0)) },
                  onRemove: nil)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = rows[indexPath.row]
        guard !row.activity.pending || row.checked else { return }
        onEvent?(row.selecting ? .toggleChecked(row.activity.id) : .tapRow(row.activity.id))
    }

    @objc private func tappedList(_ tap: UITapGestureRecognizer) {
        if table.indexPathForRow(at: tap.location(in: table)) == nil { onEvent?(.clearFocus) }
    }
}

/// The Distance filter's two knobs (root docs/SPEC.md FR-5.3), each a slider between the list's
/// shortest and longest distance; both back at the ends is no filter (ActivityFacets).
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
        current = ActivityFacets.nextDistanceFilter(bounds: bounds, current: current ?? bounds, knob: knob, value: snap(slider.value))
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