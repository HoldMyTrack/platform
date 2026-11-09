import HoldMyTrackCore
import UIKit

/// The Edit window's Track tab (root docs/SPEC.md FR-5.14, FR-5.17), Android's TrackEditor: the
/// activity's recorded points and the edit saved on them (TrackEditSession), a two-knob range over
/// the points as the edit leaves them, and Chop, Cut, Split, Delete point, Move point, Undo and
/// Reset. Nothing is sent from here: the window's Save sends session.pending and session.splitAt.
/// Every change is drawn over the map through onDraw. Cut and Split preview while held; the tap
/// that follows performs them.
final class TrackEditorView: UIView {
    private let api: APIClient
    private let format: PanelFormat
    private let activity: Activity
    /// The overlay: what the session would leave, or nil to clear it.
    var onDraw: ((TrackEditDrawing.Shape?) -> Void)?
    /// The session changed, or finished loading: the window's tab and Save follow it.
    var onChange: (() -> Void)?

    private(set) var session: TrackEditSession?
    private var loading = false
    private var preview = EditPreview.chop
    /// Delete point is on: a tap on a point on the map deletes it.
    private(set) var deleteMode = false
    /// Move point is on: a press on a point on the map drags it. Never on with deleteMode.
    private(set) var moveMode = false
    /// The point a Move point drag holds, drawn at the finger; nothing is committed until let go.
    private var dragging: (t: Int, lon: Double, lat: Double)?
    /// The window is saving: nothing here changes meanwhile.
    var busy = false { didSet { render() } }

    private let note = Controls.body()
    private let body = UIStackView()
    private let readout = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private let slider = RangeSlider()
    private let start = Controls.body()
    private let count = Controls.body()
    private let end = Controls.body()
    private lazy var chop = tool(String(localized: "Chop"), "trackChop", hint: String(localized: "Keep only the part between the knobs")) { $0.perform { $0.chop() } }
    private lazy var cut = tool(String(localized: "Cut"), "trackCut", hint: String(localized: "Remove the part between the knobs and join its two ends. Hold to preview.")) { $0.preview = .chop; $0.perform { $0.cut() } }
    private lazy var split = tool(String(localized: "Split"), "trackSplit", hint: String(localized: "Split the activity in two at the knob you moved")) { view in
        view.preview = .chop
        view.pointModesOff()
        view.perform { $0.split() }
    }
    private lazy var deletePoint = tool(String(localized: "Delete point"), "trackDeletePoint", hint: String(localized: "Tap points on the map to delete them")) { view in
        view.deleteMode.toggle()
        if view.deleteMode { view.moveMode = false }
        view.render()
    }
    private lazy var movePoint = tool(String(localized: "Move point"), "trackMovePoint", hint: String(localized: "Drag points on the map to move them")) { view in
        view.moveMode.toggle()
        if view.moveMode { view.deleteMode = false } else { view.dragging = nil }
        view.render()
    }
    private lazy var undo = tool(String(localized: "Undo"), "trackUndo", hint: String(localized: "Undo the last change")) { $0.perform { $0.undo() } }
    private lazy var reset = tool(String(localized: "Reset"), "trackReset", hint: String(localized: "Go back to the track as it was recorded (Undo brings the edits back)")) { $0.perform { $0.reset() } }
    private let modeNote = Controls.body()

    init(api: APIClient, format: PanelFormat, activity: Activity) {
        self.api = api
        self.format = format
        self.activity = activity
        super.init(frame: .zero)
        accessibilityIdentifier = "trackEditor"
        slider.accessibilityIdentifier = "trackRange"
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.session?.setKnobs(lo: self.slider.lower, hi: self.slider.upper)
            self.render()
        }, for: .valueChanged)
        slider.describe = { [weak self] index in self?.place(index) ?? "" }
        holdToPreview(cut, .cut)
        holdToPreview(split, .split)

        let ends = UIStackView(arrangedSubviews: [start, count, end])
        ends.distribution = .equalSpacing
        count.textAlignment = .center
        func row(_ views: [UIView]) -> UIStackView {
            let row = UIStackView(arrangedSubviews: views)
            row.spacing = DesignTokens.Space.s8
            row.distribution = .fillEqually
            return row
        }
        for v in [readout, slider, ends, row([chop, cut, split]), row([deletePoint, movePoint]), row([undo, reset]), modeNote] as [UIView] {
            body.addArrangedSubview(v)
        }
        body.axis = .vertical
        body.spacing = DesignTokens.Space.s8
        body.isHidden = true
        let column = Controls.column([note, body], spacing: DesignTokens.Space.s8)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Loads the points the first time the tab opens; the session then lasts until the window
    /// closes, so switching tabs loses nothing.
    func open() {
        guard session == nil, !loading else { return render() }
        loading = true
        note.text = String(localized: "Loading points…")
        note.textColor = UIColor(resource: .inkSecondary)
        Task { [weak self] in
            guard let self else { return }
            do {
                let read = try await self.api.trackPoints(self.activity.id)
                self.session = TrackEditSession(points: read.points, base: read.edit)
                self.note.isHidden = true
                self.render()
                self.onChange?()
            } catch {
                self.note.text = (error as? APIError)?.serverMessage ?? String(localized: "The changes couldn't be saved.")
                self.note.textColor = UIColor(resource: .danger)
            }
            self.loading = false
        }
    }

    /// The tab is out of sight: Delete point and Move point go off, and the overlay with them.
    func hide() {
        pointModesOff()
        onDraw?(nil)
    }

    private func pointModesOff() {
        deleteMode = false
        moveMode = false
        dragging = nil
    }

    // MARK: The map's touches

    /// A tap on the point at t in Delete point mode.
    func dropPoint(_ t: Int) {
        guard deleteMode, !busy else { return }
        perform { $0.drop(t) }
    }

    /// Whether a press on the point at t starts a Move point drag.
    func beginMove(_ t: Int) -> Bool {
        guard moveMode, !busy, let p = session?.visible.first(where: { $0.t == t }) else { return false }
        dragging = (t, p.lon, p.lat)
        return true
    }

    /// The finger moved: the held point follows it.
    func moveTo(lon: Double, lat: Double) {
        guard let held = dragging else { return }
        dragging = (held.t, lon, lat)
        draw()
    }

    /// Let go (commit) or interrupted: one step, or nothing.
    func endMove(commit: Bool) {
        guard let held = dragging else { return }
        dragging = nil
        if commit { perform { $0.move(held.t, lon: held.lon, lat: held.lat) } } else { draw() }
    }

    // MARK: Rendering

    private func perform(_ change: (inout TrackEditSession) -> Void) {
        guard session != nil, !busy else { return }
        change(&session!)
        render()
        onChange?()
    }

    private func render() {
        guard let session else { return }
        let visible = session.visible
        guard visible.count >= 2 else {
            body.isHidden = true
            onDraw?(nil)
            return
        }
        body.isHidden = false
        let distances = EditTrackOps.cumulativeDistances(visible)
        let (lo, hi) = session.knobs(in: visible)
        slider.set(lower: lo, upper: hi, maximum: visible.count - 1)
        slider.isEnabled = !busy
        readout.text = String(localized: "\(format.distanceValue(distances[lo])) – \(format.distanceValue(distances[hi])) \(format.unit) · \(clock(visible[lo].t))–\(clock(visible[hi].t))",
                              comment: "Track editor: the range's distances along the track, its unit, and the times at its ends.")
        start.text = format.distance(0)
        count.text = String(localized: "Points: \(format.count(visible.count))", comment: "Track editor: how many points the track has, written as label: N.")
        end.text = format.distance(distances[visible.count - 1])

        let splitting = session.splitAt
        chop.isEnabled = !busy && session.chopOp != nil
        cut.isEnabled = !busy && session.cutOp != nil
        split.isEnabled = !busy && session.splitIndex != nil
        deletePoint.isEnabled = !busy && session.pointToolsOn
        movePoint.isEnabled = !busy && session.pointToolsOn
        if !session.pointToolsOn { pointModesOff() }
        setOn(deletePoint, deleteMode)
        setOn(movePoint, moveMode)
        undo.isEnabled = !busy && session.changed
        reset.isHidden = !session.canReset
        reset.isEnabled = !busy
        if let splitting {
            modeNote.text = String(localized: "Saving splits this activity in two at \(clock(splitting)). The new part gets the same type, name and description.")
        } else if deleteMode {
            modeNote.text = String(localized: "Tap a point on the map to delete it.")
        } else if moveMode {
            modeNote.text = String(localized: "Press a point on the map and drag it to move it.")
        } else {
            modeNote.text = nil
        }
        modeNote.isHidden = modeNote.text == nil
        draw()
    }

    /// The overlay alone, for each step of a drag: the held point at the finger.
    private func draw() {
        guard let session else { return }
        let visible = session.visible
        guard visible.count >= 2 else { return }
        let (lo, hi) = session.knobs(in: visible)
        let shown = dragging.map { held in visible.map { $0.t == held.t ? TrackPoint(lon: held.lon, lat: held.lat, t: $0.t) : $0 } } ?? visible
        // The split made, else the one Split would make while it's held.
        let splitIndex = session.splitAt.flatMap { t in visible.firstIndex { $0.t == t } }
            ?? (preview == .split ? session.splitIndex : nil)
        let shownPreview: EditPreview = preview == .cut && session.cutOp != nil ? .cut : .chop
        onDraw?(TrackEditDrawing.shape(shown, lo: lo, hi: hi, preview: shownPreview, split: splitIndex))
    }

    /// A point's time of day, in the zone the activity was recorded in.
    private func clock(_ ms: Int) -> String { format.clock(Double(ms) / 1000, zone: activity.timezone) }

    /// What VoiceOver says of a knob at index.
    private func place(_ index: Int) -> String {
        guard let visible = session?.visible, visible.indices.contains(index) else { return "" }
        let distances = EditTrackOps.cumulativeDistances(visible)
        return "\(format.distance(distances[index])), \(clock(visible[index].t))"
    }

    // MARK: Buttons

    private func tool(_ title: String, _ id: String, hint: String, _ action: @escaping (TrackEditorView) -> Void) -> UIButton {
        var config = UIButton.Configuration.bordered()
        config.title = title
        config.baseForegroundColor = UIColor(resource: .ink)
        config.baseBackgroundColor = UIColor(resource: .surface)
        config.cornerStyle = .medium
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold)
            return a
        }
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = id
        button.accessibilityHint = hint
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in
            guard let self, !self.busy else { return }
            action(self)
        }, for: .primaryActionTriggered)
        return button
    }

    /// A toggle's look: filled in the accent while on.
    private func setOn(_ button: UIButton, _ on: Bool) {
        button.configuration?.baseBackgroundColor = UIColor(resource: on ? .accent : .surface)
        button.configuration?.baseForegroundColor = UIColor(resource: on ? .onAccent : .ink)
        button.accessibilityTraits = on ? [.button, .selected] : .button
    }

    /// The web previews Cut and Split while hovered; on a phone, while held.
    private func holdToPreview(_ button: UIButton, _ what: EditPreview) {
        button.addAction(UIAction { [weak self] _ in
            self?.preview = what
            self?.draw()
        }, for: .touchDown)
        for event: UIControl.Event in [.touchUpOutside, .touchCancel, .touchDragExit] {
            button.addAction(UIAction { [weak self] _ in
                self?.preview = .chop
                self?.draw()
            }, for: event)
        }
    }
}
