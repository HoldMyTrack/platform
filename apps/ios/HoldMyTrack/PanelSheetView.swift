import HoldMyTrackCore
import UIKit

/// The sheet over the bottom of the map (apps/android/docs/SPEC.md FR-2.7): a handle, a head and
/// the tab's content, resting at its head alone, half the map or nearly all of it (SheetRules).
/// Dragged by its handle or head, so the list inside scrolls on its own; a tap on the handle opens
/// it halfway or closes it.
///
/// Hand-made rather than a presented UISheetPresentationController: a presented sheet would cover
/// the tab bar and leave with the map's tab, where this one is part of the map screen.
final class PanelSheetView: UIView, UIGestureRecognizerDelegate {
    let head = UIStackView()
    let content = UIView()
    /// The sheet came to rest at another detent, or its head changed height.
    var onChange: (() -> Void)?

    private(set) var detent = SheetDetent.collapsed
    private let handle = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint!
    /// Collapsed, the content takes no room and the sheet is its handle and head, as tall as
    /// they lay out.
    private var collapsedConstraint: NSLayoutConstraint!
    private var container: CGFloat = 0
    private var topInset: CGFloat = 0
    private var dragStart: CGFloat?
    private var lastHeadHeight: CGFloat = 0

    private static let handleHeight: CGFloat = 22

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(resource: .surface)
        layer.cornerRadius = DesignTokens.Radius.lg
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -1)
        accessibilityIdentifier = "panel"

        var config = UIButton.Configuration.plain()
        config.background.backgroundColor = .clear
        handle.configuration = config
        let grip = UIView()
        grip.backgroundColor = UIColor(resource: .borderStrong)
        grip.layer.cornerRadius = 2.5
        grip.isUserInteractionEnabled = false
        grip.translatesAutoresizingMaskIntoConstraints = false
        handle.addSubview(grip)
        handle.accessibilityIdentifier = "panelHandle"
        handle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setDetent(SheetRules.toggled(self.detent), animated: true)
        }, for: .primaryActionTriggered)

        head.axis = .vertical
        head.spacing = DesignTokens.Space.s4
        head.isLayoutMarginsRelativeArrangement = true
        head.directionalLayoutMargins = .init(top: 0, leading: DesignTokens.Space.s12, bottom: DesignTokens.Space.s8, trailing: DesignTokens.Space.s12)
        content.clipsToBounds = true

        for v in [handle, head, content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        heightConstraint = heightAnchor.constraint(equalToConstant: 120)
        collapsedConstraint = content.heightAnchor.constraint(equalToConstant: 0)
        collapsedConstraint.isActive = true
        NSLayoutConstraint.activate([
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.leadingAnchor.constraint(equalTo: leadingAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.heightAnchor.constraint(equalToConstant: Self.handleHeight),
            grip.centerXAnchor.constraint(equalTo: handle.centerXAnchor),
            grip.centerYAnchor.constraint(equalTo: handle.centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 36),
            grip.heightAnchor.constraint(equalToConstant: 5),
            head.topAnchor.constraint(equalTo: handle.bottomAnchor),
            head.leadingAnchor.constraint(equalTo: leadingAnchor),
            head.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: head.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for v in [handle, head] as [UIView] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            pan.delegate = self
            v.addGestureRecognizer(pan)
        }
        updateHandleLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The room the sheet has: its parent's height above the tab bar, and the top row to keep
    /// clear when it's open all the way.
    func setRoom(container: CGFloat, topInset: CGFloat) {
        guard container != self.container || topInset != self.topInset else { return }
        self.container = container
        self.topInset = topInset
        apply(animated: false)
    }

    func setDetent(_ next: SheetDetent, animated: Bool) {
        let changed = next != detent
        detent = next
        apply(animated: animated)
        updateHandleLabel()
        if changed { onChange?() }
    }

    /// The sheet's height at rest, what the camera frames above.
    var restingHeight: CGFloat { CGFloat(heights()[detent] ?? 0) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let headHeight = measuredHead()
        if abs(headHeight - lastHeadHeight) > 0.5, dragStart == nil {
            lastHeadHeight = headHeight
            apply(animated: false)
            onChange?()
        }
    }

    /// The handle and head as laid out: never squeezed, since the content gives way first.
    private func measuredHead() -> CGFloat {
        if head.frame.maxY > Self.handleHeight { return head.frame.maxY }
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let size = head.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return Self.handleHeight + size.height
    }

    private func heights() -> [SheetDetent: Double] {
        SheetRules.heights(container: Double(container), topInset: Double(topInset), head: Double(measuredHead()))
    }

    private func apply(animated: Bool) {
        let collapsed = detent == .collapsed && dragStart == nil
        heightConstraint.isActive = !collapsed
        collapsedConstraint.isActive = collapsed
        let height = restingHeight
        guard height > 0 else { return }
        heightConstraint.constant = height
        guard animated, superview != nil else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.superview?.layoutIfNeeded()
        }
    }

    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        let h = heights()
        switch pan.state {
        case .began:
            dragStart = bounds.height
            heightConstraint.constant = bounds.height
            collapsedConstraint.isActive = false
            heightConstraint.isActive = true
        case .changed:
            guard let start = dragStart else { return }
            let low = CGFloat(h[.collapsed] ?? 0), high = CGFloat(h[.expanded] ?? 0)
            heightConstraint.constant = min(high, max(low, start - pan.translation(in: self).y))
        case .ended, .cancelled:
            dragStart = nil
            let next = SheetRules.resting(height: Double(heightConstraint.constant), velocity: Double(-pan.velocity(in: self).y), heights: h)
            setDetent(next, animated: true)
        default: break
        }
    }

    /// Only an up or down drag moves the sheet, so the date slider in the head still scrubs.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: self)
        return abs(v.y) > abs(v.x)
    }

    private func updateHandleLabel() {
        handle.accessibilityLabel = detent == .collapsed ? String(localized: "Open the panel") : String(localized: "Close the panel")
    }
}