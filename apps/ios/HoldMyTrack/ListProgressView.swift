import UIKit

/// The list's progress bar, the web's `.activities-panel__progress`: a 2-point strip over the rows
/// with an accent segment sliding across while a slow reload is under way. Always 2 points tall,
/// so showing it never moves the list; with Reduce Motion the segment is the whole strip, still.
final class ListProgressView: UIView {
    private let segment = UIView()
    private(set) var running = false

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        segment.backgroundColor = UIColor(resource: .accent)
        addSubview(segment)
        isHidden = true
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Loading…")
        accessibilityTraits = .updatesFrequently
        accessibilityIdentifier = "listProgress"
        heightAnchor.constraint(equalToConstant: 2).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func start() {
        guard !running else { return }
        running = true
        isHidden = false
        setNeedsLayout()
        layoutIfNeeded()
        animate()
    }

    func stop() {
        running = false
        isHidden = true
        segment.layer.removeAllAnimations()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if running { animate() }
    }

    private func animate() {
        segment.layer.removeAllAnimations()
        if UIAccessibility.isReduceMotionEnabled {
            segment.frame = bounds
            segment.alpha = 0.6
            return
        }
        segment.alpha = 1
        let width = bounds.width * 0.4
        segment.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = -width / 2
        slide.toValue = bounds.width * 1.5 + width / 2
        slide.duration = 1.1
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        slide.repeatCount = .infinity
        segment.layer.add(slide, forKey: "slide")
    }
}
