import UIKit

/// A slider with two knobs over whole steps 0...maximum, the track editor's range: UIKit has no
/// two-knob slider. A drag moves the knob nearer the finger, never past the other; valueChanged
/// fires on every step. VoiceOver reads each knob as its own adjustable element.
final class RangeSlider: UIControl {
    private(set) var lower = 0
    private(set) var upper = 1
    private(set) var maximum = 1
    private var dragging: Knob?
    private let knobSide: CGFloat = 28
    private lazy var lowerKnob = KnobElement(slider: self, knob: .lower)
    private lazy var upperKnob = KnobElement(slider: self, knob: .upper)

    enum Knob { case lower, upper }

    /// Each knob's spoken value: a point's place, as the readout writes it.
    var describe: ((Int) -> String)?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = false
        lowerKnob.accessibilityLabel = String(localized: "Start of the range")
        upperKnob.accessibilityLabel = String(localized: "End of the range")
        heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(lower: Int, upper: Int, maximum: Int) {
        self.maximum = max(maximum, 1)
        self.lower = min(max(lower, 0), self.maximum)
        self.upper = min(max(upper, self.lower), self.maximum)
        setNeedsDisplay()
    }

    private var inset: CGFloat { knobSide / 2 + 2 }

    private func x(_ value: Int) -> CGFloat {
        inset + (bounds.width - 2 * inset) * CGFloat(value) / CGFloat(maximum)
    }

    private func value(at x: CGFloat) -> Int {
        let f = (x - inset) / max(bounds.width - 2 * inset, 1)
        return Int((min(max(f, 0), 1) * CGFloat(maximum)).rounded())
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        let at = touch.location(in: self).x
        // The nearer knob; on a tie, the one that can move toward the finger.
        let dl = abs(at - x(lower)), du = abs(at - x(upper))
        dragging = dl < du || (dl == du && at < x(lower)) ? .lower : .upper
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let dragging else { return false }
        move(dragging, to: value(at: touch.location(in: self).x))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { dragging = nil }

    override func cancelTracking(with event: UIEvent?) { dragging = nil }

    fileprivate func move(_ knob: Knob, to next: Int) {
        let (lo, hi) = knob == .lower ? (min(next, upper), upper) : (lower, max(next, lower))
        guard lo != lower || hi != upper else { return }
        lower = lo
        upper = hi
        setNeedsDisplay()
        sendActions(for: .valueChanged)
    }

    override func draw(_ rect: CGRect) {
        let mid = bounds.midY
        let rail = UIBezierPath(roundedRect: CGRect(x: inset, y: mid - 2, width: bounds.width - 2 * inset, height: 4), cornerRadius: 2)
        UIColor(resource: .border).setFill()
        rail.fill()
        let span = UIBezierPath(roundedRect: CGRect(x: x(lower), y: mid - 2, width: x(upper) - x(lower), height: 4), cornerRadius: 2)
        UIColor(resource: isEnabled ? .accent : .inkMuted).setFill()
        span.fill()
        for (value, element) in [(lower, lowerKnob), (upper, upperKnob)] {
            let frame = CGRect(x: x(value) - knobSide / 2, y: mid - knobSide / 2, width: knobSide, height: knobSide)
            let knob = UIBezierPath(ovalIn: frame.insetBy(dx: 1, dy: 1))
            UIColor.white.setFill()
            knob.fill()
            UIColor(resource: .borderStrong).setStroke()
            knob.lineWidth = 1
            knob.stroke()
            element.accessibilityFrameInContainerSpace = frame.insetBy(dx: -8, dy: -8)
        }
    }

    override var accessibilityElements: [Any]? {
        get {
            lowerKnob.accessibilityValue = describe?(lower)
            upperKnob.accessibilityValue = describe?(upper)
            return [lowerKnob, upperKnob]
        }
        set {}
    }

    /// One knob for VoiceOver: swipe up or down to step it.
    private final class KnobElement: UIAccessibilityElement {
        weak var slider: RangeSlider?
        let knob: Knob

        init(slider: RangeSlider, knob: Knob) {
            self.slider = slider
            self.knob = knob
            super.init(accessibilityContainer: slider)
            accessibilityTraits = .adjustable
        }

        override func accessibilityIncrement() { step(1) }
        override func accessibilityDecrement() { step(-1) }

        private func step(_ by: Int) {
            guard let slider, slider.isEnabled else { return }
            slider.move(knob, to: (knob == .lower ? slider.lower : slider.upper) + by)
        }
    }
}
