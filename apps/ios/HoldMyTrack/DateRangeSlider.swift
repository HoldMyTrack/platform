import HoldMyTrackCore
import UIKit

/// The map's date-range control (root docs/SPEC.md FR-6; Android's DateRangeSlider): the range as
/// a heading with ‹ › beside it, and under them « scrubber », « » only where the width leaves room
/// (SliderRules.layout).
///
/// The scrubber is a window of activity days (ActivityDays), the days between taking no room; its
/// knobs sit on slot boundaries, so a one-day range has them a slot apart. « » move the window
/// five activity days, repeating while held, as does a knob held past an edge, which is pulled
/// along; ‹ › move the range its own length. Drags and held buttons render from a draft and
/// commit through onChange on release, so the tracks aren't fetched for every day passed.
final class DateRangeSlider: UIView {
    var onPan: ((Int) -> Void)?
    var onShift: ((DateRange, Int) -> DateRange?)?
    var canShift: ((DateRange, Int) -> Bool)?
    var onWindowDays: ((Int) -> Void)?
    var onChange: ((DateRange) -> Void)?

    /// The committed range; nil until the map has one.
    var value: DateRange? {
        didSet {
            draft = nil
            render()
        }
    }

    private var draft: DateRange?
    private var current: DateRange? { draft ?? value }
    private var days: [String] = []
    private var canPanEarlier = false
    private var canPanLater = false

    private let label = Controls.label("", font: Typeface.sans(DesignTokens.Text.lg, weight: DesignTokens.Weight.semibold, relativeTo: .subheadline), color: UIColor(resource: .ink))
    private let shiftEarlier = DateRangeSlider.button(.chevronLeft, String(localized: "Earlier range"), "shiftEarlier")
    private let shiftLater = DateRangeSlider.button(.chevronRight, String(localized: "Later range"), "shiftLater")
    private let pageEarlier = DateRangeSlider.button(.chevronsLeft, String(localized: "Earlier days"), "pageEarlier")
    private let pageLater = DateRangeSlider.button(.chevronsRight, String(localized: "Later days"), "pageLater")
    private let track = DayScrubberView()

    private enum Knob { case start, end }
    private var dragging: Knob?
    /// A pan asked for and not yet in view, the knobs it pulls along, and whether the gesture has
    /// ended and commits once it lands.
    private struct Pan { var start: Bool; var end: Bool; var commit: Bool }
    private var pan: Pan?
    private var repeatTimer: Timer?
    private var repeatAction: (() -> Bool)?
    private var edgePan = 0
    private var edgeTimer: Timer?
    private var waitingDays: Int?
    private var lastWidth: CGFloat = 0

    static let initialWindowDays = 14
    private static let stepDays = 5

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.accessibilityIdentifier = "rangeLabel"
        track.accessibilityIdentifier = "scrubber"
        track.onPress = { [weak self] in self?.press($0) }
        track.onDrag = { [weak self] in self?.drag($0) }
        track.onRelease = { [weak self] in self?.release() }
        track.onSwipe = { [weak self] in self?.swipe($0) }
        repeating(shiftEarlier) { [weak self] in self?.shiftStep(-1) ?? false }
        repeating(shiftLater) { [weak self] in self?.shiftStep(1) ?? false }
        repeating(pageEarlier) { [weak self] in self?.step(-1) ?? false }
        repeating(pageLater) { [weak self] in self?.step(1) ?? false }

        let heading = UIStackView(arrangedSubviews: [shiftEarlier, label, shiftLater])
        heading.alignment = .center
        let row = UIStackView(arrangedSubviews: [pageEarlier, track, pageLater])
        row.alignment = .top
        row.spacing = 6
        let column = UIStackView(arrangedSubviews: [heading, row])
        column.axis = .vertical
        column.spacing = DesignTokens.Space.s4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Space.s8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Space.s4),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func button(_ icon: ImageResource, _ label: String, _ id: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(resource: icon)
        config.baseForegroundColor = UIColor(resource: .ink)
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return button
    }

    // MARK: Size: the width decides how many days the window holds; it waits for a gesture's end.

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        let layout = SliderRules.layout(width: Int(bounds.width - 16), finePointer: false)
        pageEarlier.isHidden = !layout.buttons
        pageLater.isHidden = !layout.buttons
        waitingDays = layout.days
        flushWindowDays()
    }

    private func flushWindowDays() {
        guard let next = waitingDays, dragging == nil, repeatAction == nil, pan == nil else { return }
        waitingDays = nil
        onWindowDays?(next)
    }

    /// The window changed: paged, loaded further back, or reloaded.
    func setDays(_ days: [String], canPanEarlier: Bool, canPanLater: Bool) {
        let moved = days.first != self.days.first || days.last != self.days.last
        self.days = days
        self.canPanEarlier = canPanEarlier
        self.canPanLater = canPanLater
        if moved { landPan() }
        render()
    }

    // MARK: Dates and boundaries (SliderRules)

    private var dayWindow: SliderRules.Window { SliderRules.Window(days: days, canPanEarlier: canPanEarlier, canPanLater: canPanLater) }
    private func startOf(_ from: String) -> Int { SliderRules.boundaries(dayWindow, DateRange(from: from, to: from)).start }
    private func endOf(_ to: String) -> Int { SliderRules.boundaries(dayWindow, DateRange(from: to, to: to)).end }

    private func commit(_ next: DateRange?) {
        draft = nil
        if let next, next != value {
            value = next
            onChange?(next)
        } else {
            render()
        }
    }

    // MARK: Paging

    /// A pan has landed: the knobs it carried go onto the new edges, committed if the gesture is over.
    private func landPan() {
        guard let pending = pan, !days.isEmpty, let sel = current else { return }
        let next = SliderRules.panLand(days: days, range: sel, start: pending.start, end: pending.end)
        pan = nil
        if pending.commit {
            commit(next)
            flushWindowDays()
        } else {
            draft = next
        }
    }

    /// Moves the window five days; a knob on the edge it moves toward is pulled along.
    private func step(_ dir: Int) -> Bool {
        guard dir < 0 ? canPanEarlier : canPanLater, let sel = current else { return false }
        let inFlight = pan
        pan = Pan(start: (inFlight?.start ?? false) || (dir < 0 && startOf(sel.from) == 0),
                  end: (inFlight?.end ?? false) || (dir > 0 && endOf(sel.to) == days.count),
                  commit: false)
        onPan?(dir * Self.stepDays)
        return true
    }

    private func shiftStep(_ dir: Int) -> Bool {
        guard let sel = current, let next = onShift?(sel, dir) else { return false }
        draft = next
        render()
        return true
    }

    /// Ends a gesture: commits now, or once a pan in flight has landed.
    private func finish() {
        if pan != nil { pan?.commit = true } else { commit(current) }
        flushWindowDays()
    }

    /// A tap steps once; held, the step repeats, and the release commits.
    private func repeating(_ button: UIButton, _ action: @escaping () -> Bool) {
        button.addAction(UIAction { [weak self] _ in
            guard let self, action() else { return }
            self.repeatAction = action
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.startRepeating() }
            }
        }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: event)
        }
    }

    private func startRepeating() {
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let action = self.repeatAction else { return }
                if !action() { self.stopRepeat() }
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        guard repeatAction != nil else { return }
        repeatAction = nil
        finish()
    }

    // MARK: The track

    private func press(_ b: Int) {
        guard let sel = current else { return }
        // An off-screen knob counts as sitting on the edge it went past.
        let s = min(max(startOf(sel.from), 0), days.count), e = min(max(endOf(sel.to), 0), days.count)
        let knob: Knob = abs(b - s) <= abs(b - e) ? .start : .end
        dragging = knob
        draft = SliderRules.moveKnob(dayWindow, sel, knob: knob == .start ? .start : .end, to: b)
        render()
    }

    private func drag(_ b: Int) {
        guard let knob = dragging, let sel = draft else { return }
        // Held past the edge it moves toward, a knob pages the window that way.
        let past = knob == .start && b < 0 && canPanEarlier ? -1 : knob == .end && b > days.count && canPanLater ? 1 : 0
        if past != edgePan {
            edgeTimer?.invalidate()
            edgePan = past
            if past != 0 {
                _ = step(past)
                edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.edgePan != 0, self.step(self.edgePan) else { self?.edgeTimer?.invalidate(); return }
                    }
                }
            }
        }
        if past == 0 {
            draft = SliderRules.moveKnob(dayWindow, sel, knob: knob == .start ? .start : .end, to: b)
            render()
        }
    }

    /// The finger moved slots toward the right: the window moves that many days into the past.
    private func swipe(_ moved: Int) {
        if moved > 0 && !canPanEarlier { return }
        if moved < 0 && !canPanLater { return }
        onPan?(-moved)
    }

    private func release() {
        guard dragging != nil else { return }
        dragging = nil
        edgeTimer?.invalidate()
        edgePan = 0
        finish()
    }

    // MARK: Rendering

    private func render() {
        pageEarlier.isEnabled = canPanEarlier
        pageLater.isEnabled = canPanLater
        guard let sel = current else {
            track.set(slots: 0, start: 0, end: 0, ticks: [])
            label.text = nil
            shiftEarlier.isEnabled = false
            shiftLater.isEnabled = false
            return
        }
        track.set(slots: days.count, start: startOf(sel.from), end: endOf(sel.to), ticks: SliderRules.ticks(days))
        label.text = RangeLabel.of(sel, locale: Locale(identifier: AppLanguage.current))
        shiftEarlier.isEnabled = canShift?(sel, -1) ?? false
        shiftLater.isEnabled = canShift?(sel, 1) ?? false
    }
}
