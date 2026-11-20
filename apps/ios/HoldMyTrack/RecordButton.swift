import HoldMyTrackCore
import UIKit

/// The record button over the tab bar's middle (apps/ios/docs/SPEC.md FR-5.1): a red dot to
/// start, pause bars while recording, a play mark while paused. A tap starts, pauses or resumes;
/// holding it two seconds while a recording runs stops it, a ring filling as it counts, and
/// letting go sooner stops nothing. VoiceOver stops it through a custom action instead.
final class RecordButton: UIControl {
    var onTap: (() -> Void)?
    var onStop: (() -> Void)?
    /// The hold began or ended, for the status line's "Keep holding".
    var onHolding: ((Bool) -> Void)?

    var recordingState: RecordingState = .idle {
        didSet {
            guard recordingState != oldValue else { return }
            setNeedsDisplay()
            describe()
        }
    }

    private let ring = CAShapeLayer()
    private var pressedAt: CFTimeInterval?
    private var holdTimer: Timer?
    private static let tapLimit: CFTimeInterval = 0.4
    static let side: CGFloat = 60

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityIdentifier = "record"
        accessibilityTraits = .button
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.cgColor
        ring.lineWidth = 4
        ring.lineCap = .round
        ring.strokeEnd = 0
        layer.addSublayer(ring)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        describe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.side, height: Self.side) }

    private static let red = UIColor(red: 0xd6 / 255.0, green: 0x2f / 255.0, blue: 0x2f / 255.0, alpha: 1)

    override func draw(_ rect: CGRect) {
        let disc = bounds.insetBy(dx: 2, dy: 2)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        switch recordingState {
        case .idle:
            UIColor(resource: .surface).setFill()
            UIBezierPath(ovalIn: disc).fill()
            Self.red.setFill()
            UIBezierPath(ovalIn: disc.insetBy(dx: disc.width * 0.28, dy: disc.height * 0.28)).fill()
        case .recording:
            Self.red.setFill()
            UIBezierPath(ovalIn: disc).fill()
            UIColor.white.setFill()
            let w = disc.width * 0.1, h = disc.height * 0.34
            for dx in [-w * 1.1, w * 1.1] {
                UIBezierPath(roundedRect: CGRect(x: c.x + dx - w / 2, y: c.y - h / 2, width: w, height: h), cornerRadius: w / 3).fill()
            }
        case .paused:
            Self.red.setFill()
            UIBezierPath(ovalIn: disc).fill()
            UIColor.white.setFill()
            let s = disc.width * 0.2
            let play = UIBezierPath()
            play.move(to: CGPoint(x: c.x - s * 0.7, y: c.y - s))
            play.addLine(to: CGPoint(x: c.x + s, y: c.y))
            play.addLine(to: CGPoint(x: c.x - s * 0.7, y: c.y + s))
            play.close()
            play.fill()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 6,
                                startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)
        ring.path = path.cgPath
        ring.frame = bounds
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        pressedAt = CACurrentMediaTime()
        guard recordingState != .idle else { return }
        // The ring and the stop wait for a press longer than a tap.
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.tapLimit, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginHold() }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        let short = pressedAt.map { CACurrentMediaTime() - $0 < Self.tapLimit } ?? false
        let inside = touches.first.map { bounds.insetBy(dx: -20, dy: -20).contains($0.location(in: self)) } ?? false
        endHold()
        if short && inside { onTap?() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        endHold()
    }

    private func beginHold() {
        onHolding?(true)
        let remaining = Recording.holdToStop - Self.tapLimit
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0
        fill.toValue = 1
        fill.duration = remaining
        ring.strokeEnd = 1
        ring.add(fill, forKey: "hold")
        holdTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.endHold()
                self.onStop?()
            }
        }
    }

    private func endHold() {
        let wasHolding = holdTimer != nil && ring.strokeEnd == 1
        holdTimer?.invalidate()
        holdTimer = nil
        pressedAt = nil
        ring.removeAnimation(forKey: "hold")
        ring.strokeEnd = 0
        if wasHolding { onHolding?(false) }
    }

    // MARK: VoiceOver

    private func describe() {
        switch recordingState {
        case .idle:
            accessibilityLabel = String(localized: "record.start", defaultValue: "Start recording", comment: "The record button, nothing recording.")
            accessibilityCustomActions = nil
        case .recording, .paused:
            accessibilityLabel = recordingState == .recording
                ? String(localized: "record.pause", defaultValue: "Pause recording", comment: "The record button while recording.")
                : String(localized: "record.resume", defaultValue: "Resume recording", comment: "The record button while paused.")
            accessibilityHint = String(localized: "record.holdHint", defaultValue: "Hold to stop.", comment: "The record button while a recording runs: a two-second hold stops it.")
            let stop = String(localized: "record.stop", defaultValue: "Stop recording", comment: "VoiceOver's action on the record button that stops the recording.")
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: stop) { [weak self] _ in
                self?.onStop?()
                return true
            }]
        }
        if recordingState == .idle { accessibilityHint = nil }
    }

    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }
}