import HoldMyTrackCore
import UIKit

/// The slider's track (root docs/SPEC.md FR-6), drawn as Android's DayScrubberView: a thin line
/// with the selection in the accent between two pill knobs, a tick on every boundary between
/// activity days, tall where a month starts, and the month's name under it (SliderRules.ticks).
///
/// It knows slots and two slot boundaries, start and end (0...slots, or -1 / slots + 1 for a knob
/// off either side, not drawn), and nothing of dates. A touch is one of three gestures: a knob
/// dragged (a press within 24pt of one; the drag unclamped, so a finger past an edge pages the
/// window), a swipe (any other press moving sideways, a slot at a time, positive toward the past),
/// or a tap (the nearer knob moves to the nearest boundary).
final class DayScrubberView: UIView {
    private(set) var slots = 0
    private(set) var start = 0
    private(set) var end = 0
    private var ticks: [SliderRules.Tick] = []

    var onPress: ((Int) -> Void)?
    var onDrag: ((Int) -> Void)?
    var onRelease: (() -> Void)?
    var onSwipe: ((Int) -> Void)?

    private enum Gesture { case handle, undecided, swipe }
    private var gesture: Gesture?
    private var downX: CGFloat = 0
    private var swipeAnchorX: CGFloat = 0

    private static let trackArea: CGFloat = 40
    /// The track's inset each side, so a knob on either end is drawn whole.
    private static let inset: CGFloat = 8
    private static let handleGrab: CGFloat = 24
    private static let touchSlop: CGFloat = 8
    private let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("LLL")
        return f
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isMultipleTouchEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.trackArea + 18) }

    func set(slots: Int, start: Int, end: Int, ticks: [SliderRules.Tick]) {
        guard slots != self.slots || start != self.start || end != self.end || ticks != self.ticks else { return }
        self.slots = slots
        self.start = start
        self.end = end
        self.ticks = ticks
        setNeedsDisplay()
    }

    private var slotWidth: CGFloat { slots == 0 ? 0 : (bounds.width - 2 * Self.inset) / CGFloat(slots) }
    private func x(_ boundary: Int) -> CGFloat { Self.inset + CGFloat(min(max(boundary, 0), slots)) * slotWidth }
    /// The slot boundary nearest x, not clamped to the window.
    private func boundary(at x: CGFloat) -> Int { slotWidth == 0 ? 0 : Int(((x - Self.inset) / slotWidth).rounded()) }

    override func draw(_ rect: CGRect) {
        guard slots > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let accent = UIColor(resource: .accent)
        let ink = UIColor(resource: .ink)
        let cy = Self.trackArea / 2
        UIColor(resource: .borderStrong).setFill()
        UIBezierPath(roundedRect: CGRect(x: Self.inset, y: cy - 2, width: bounds.width - 2 * Self.inset, height: 4), cornerRadius: 2).fill()
        let s = min(max(start, 0), slots), e = min(max(end, 0), slots)
        if e > s {
            accent.setFill()
            UIBezierPath(roundedRect: CGRect(x: x(s), y: cy - 2, width: x(e) - x(s), height: 4), cornerRadius: 2).fill()
        }
        let labelFont = Typeface.sans(DesignTokens.Text.xs, weight: DesignTokens.Weight.bold, relativeTo: .caption2)
        for tick in ticks {
            let tx = x(tick.boundary)
            let half: CGFloat = tick.monthStart ? 8 : 4
            let color = (tick.boundary >= s && tick.boundary <= e && e > s) ? accent
                : ink.withAlphaComponent(tick.monthStart ? 0.5 : 0.28)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: tx, y: cy - half))
            context.addLine(to: CGPoint(x: tx, y: cy + half))
            context.strokePath()
            guard let month = tick.month else { continue }
            var parts = DateComponents()
            parts.year = 2026
            parts.month = month
            parts.day = 1
            guard let date = Calendar(identifier: .gregorian).date(from: parts) else { continue }
            let text = monthFormatter.string(from: date) as NSString
            text.draw(at: CGPoint(x: tick.boundary == 0 ? Self.inset : tx + 3, y: Self.trackArea + 2),
                      withAttributes: [.font: labelFont, .foregroundColor: UIColor(resource: .inkMuted)])
        }
        let knobWidth: CGFloat = slotWidth < 18 ? 12 : 16
        for b in [start, end] where b >= 0 && b <= slots {
            let knob = CGRect(x: x(b) - knobWidth / 2, y: cy - 14, width: knobWidth, height: 28)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.19).cgColor)
            UIColor(resource: .surface).setFill()
            UIBezierPath(roundedRect: knob, cornerRadius: 6).fill()
            context.restoreGState()
            accent.setStroke()
            let ring = UIBezierPath(roundedRect: knob.insetBy(dx: 1, dy: 1), cornerRadius: 6)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    /// The drawn knob within reach of x, the nearer of the two.
    private func handle(near x: CGFloat) -> Int? {
        [start, end].filter { $0 >= 0 && $0 <= slots && abs(self.x($0) - x) <= Self.handleGrab }
            .min { abs(self.x($0) - x) < abs(self.x($1) - x) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard slots > 0, let point = touches.first?.location(in: self) else { return }
        downX = point.x
        if let h = handle(near: point.x) {
            gesture = .handle
            onPress?(h)
        } else {
            gesture = .undecided
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        switch gesture {
        case .handle: onDrag?(boundary(at: point.x))
        case .undecided where abs(point.x - downX) > Self.touchSlop:
            gesture = .swipe
            swipeAnchorX = downX
            swipe(point.x)
        case .swipe: swipe(point.x)
        default: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let point = touches.first?.location(in: self)
        switch gesture {
        case .handle: onRelease?()
        case .undecided:
            if let point { onPress?(min(max(boundary(at: point.x), 0), slots)) }
            onRelease?()
        default: break
        }
        gesture = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if gesture == .handle { onRelease?() }
        gesture = nil
    }

    /// Hands on each whole slot the finger has moved since the last one counted.
    private func swipe(_ x: CGFloat) {
        guard slotWidth > 0 else { return }
        let moved = Int((x - swipeAnchorX) / slotWidth)
        guard moved != 0 else { return }
        swipeAnchorX += CGFloat(moved) * slotWidth
        onSwipe?(moved)
    }
}
