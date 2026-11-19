import HoldMyTrackCore
import UIKit

/// The tour drawn over the whole app (apps/ios/docs/SPEC.md FR-2.12), in one of two looks:
///
/// - **A step** (dim): the screen dimmed but for a ring around each of the step's views, every
///   touch taken so nothing under it changes, and the card across the top or bottom
///   (TourSteps.edge).
/// - **A card** (a first-time card or the offer): no dim, under or over its target, touches outside
///   it passing through to the app, the first of them closing it.
///
/// The views are read every frame, since the sheet slides and the tab bar switches tabs; a step
/// whose views haven't shown within missingFrames calls onMissing once.
final class TourOverlay: UIView {
    let card = UIView()
    let title = Controls.label("", font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink))
    let progress = Controls.label("", font: Typeface.sans(DesignTokens.Text.md), color: UIColor(resource: .inkMuted))
    let body = Controls.body()
    let skipButton = Controls.textButton("", id: "tourSkip")
    let backButton = Controls.secondaryButton(String(localized: "tour.back", defaultValue: "Back", comment: "The tour: the previous step."), id: "tourBack")
    let nextButton = Controls.primaryButton("", id: "tourNext")

    /// Called on a press outside the card in the card look.
    var onOutside: (() -> Void)?

    private let dim: Bool
    private var targets: () -> [UIView] = { [] }
    private var onMissing: (() -> Void)?
    private var holes: [CGRect] = []
    private var absent = 0
    private var link: CADisplayLink?
    private let scrim = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var top: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!

    private static let missingFrames = 30
    private static let pad: CGFloat = DesignTokens.Space.s6
    private static let gap: CGFloat = DesignTokens.Space.s12

    init(dim: Bool) {
        self.dim = dim
        super.init(frame: .zero)
        accessibilityViewIsModal = dim
        if dim {
            scrim.fillRule = .evenOdd
            layer.addSublayer(scrim)
            ring.fillColor = UIColor.clear.cgColor
            ring.lineWidth = 3
            layer.addSublayer(ring)
        }
        card.backgroundColor = UIColor(resource: .surface)
        card.layer.cornerRadius = DesignTokens.Radius.lg
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.2
        card.layer.shadowRadius = 12
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.accessibilityIdentifier = "tourCard"
        title.accessibilityIdentifier = "tourTitle"
        progress.accessibilityIdentifier = "tourProgress"
        let head = UIStackView(arrangedSubviews: [title, progress])
        head.alignment = .firstBaseline
        head.spacing = DesignTokens.Space.s8
        progress.setContentHuggingPriority(.required, for: .horizontal)
        progress.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = UIView()
        let buttons = UIStackView(arrangedSubviews: [skipButton, spacer, backButton, nextButton])
        buttons.spacing = DesignTokens.Space.s8
        buttons.alignment = .center
        let column = Controls.column([head, body, buttons], spacing: DesignTokens.Space.s12)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        let inset = DesignTokens.Space.s16
        top = card.topAnchor.constraint(equalTo: topAnchor)
        bottom = card.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            card.leadingAnchor.constraint(equalTo: readableContentGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: readableContentGuide.trailingAnchor),
            top,
        ])
        traitsChanged()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.traitsChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func traitsChanged() {
        // The web's --fm-tour-scrim, ink at 45%.
        scrim.fillColor = UIColor(resource: .ink).resolvedColor(with: traitCollection).withAlphaComponent(0.45).cgColor
        ring.strokeColor = UIColor(resource: .accent).resolvedColor(with: traitCollection).cgColor
    }

    /// Points at targets, then follows them; called again for every step.
    func point(at targets: @escaping () -> [UIView], onMissing: (() -> Void)?) {
        self.targets = targets
        self.onMissing = onMissing
        absent = 0
        holes = []
        // Hidden until placed, so neither a tap nor VoiceOver finds it where it isn't yet.
        card.isHidden = true
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let wanted = targets()
        let rects = wanted.compactMap(rect(of:))
        if !wanted.isEmpty && rects.isEmpty {
            absent += 1
            if absent == Self.missingFrames { onMissing?() }
            return
        }
        absent = 0
        guard rects != holes || card.isHidden else { return }
        holes = rects
        place()
        draw()
    }

    /// view's frame in this view's space, nil while it isn't on screen.
    private func rect(of view: UIView) -> CGRect? {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        var at: UIView? = view
        while let current = at, current !== window {
            if current.isHidden || current.alpha < 0.01 { return nil }
            at = current.superview
        }
        let rect = view.convert(view.bounds, to: self)
        return rect.intersects(bounds) ? rect : nil
    }

    /// The card across the top or bottom for a step; under or over the target for a card.
    private func place() {
        layoutIfNeeded()
        let height = card.systemLayoutSizeFitting(CGSize(width: card.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let topInset = safeAreaInsets.top + Self.gap
        let target = holes.reduce(CGRect.null) { $0.union($1) }
        let targetTop = target.isNull ? nil : Double(target.minY), targetBottom = target.isNull ? nil : Double(target.maxY)
        NSLayoutConstraint.deactivate([top, bottom])
        if dim {
            let edge = TourSteps.edge(targetTop: targetTop, cardHeight: height, topInset: topInset, gap: Self.gap)
            top.constant = topInset
            bottom.constant = -(safeAreaInsets.bottom + Self.gap)
            (edge == .top ? top : bottom).isActive = true
        } else {
            top.constant = TourSteps.cardTop(targetTop: targetTop, targetBottom: targetBottom, cardHeight: height,
                                             height: bounds.height, topInset: topInset, gap: Self.gap)
            top.isActive = true
        }
        card.isHidden = false
    }

    private func draw() {
        guard dim else { return }
        let rings = UIBezierPath()
        for hole in holes {
            rings.append(UIBezierPath(roundedRect: hole.insetBy(dx: -Self.pad, dy: -Self.pad), cornerRadius: DesignTokens.Radius.lg))
        }
        let path = UIBezierPath(rect: bounds)
        path.append(rings)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.path = path.cgPath
        ring.path = rings.cgPath
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        draw()
    }

    /// A step takes every touch; a card lets those outside it through, the first closing it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if dim { return hit ?? self }
        if card.frame.contains(point) { return hit }
        if let onOutside {
            self.onOutside = nil
            DispatchQueue.main.async { onOutside() }
        }
        return nil
    }
}