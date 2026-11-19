import HoldMyTrackCore
import UIKit

/// The export viewfinder over the map (apps/ios/docs/SPEC.md FR-2.11): the map dimmed outside
/// the window, a corner handle at each corner, the toolbar over the window, the image's size or
/// what went wrong under it, and the stats card previewed where the image will carry it. Only
/// the toolbar, the lines and the handles take touches; the map under the window still pans and
/// zooms. The window's geometry is Viewfinder's; the owner (MapViewController+Export) decides.
final class ExportViewfinderView: UIView {
    let closeButton = Controls.iconButton(Controls.icon(UIImage(resource: .x), size: 20), label: String(localized: "Close"), id: "exportClose")
    let choiceButton = Controls.secondaryButton("", id: "exportChoice")
    let statsButton = Controls.secondaryButton(String(localized: "export.showStats", defaultValue: "Show stats", comment: "Map image export: draw the checked tracks' stats card on the image."), id: "exportStats")
    let captureButton = Controls.primaryButton("", id: "exportCapture")
    let spinner = UIActivityIndicatorView(style: .medium)
    let sizeLabel = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    let errorLabel = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .danger))
    private let toolbar = UIView()
    private let statsPreview = UIImageView()
    private let scrim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let corners = CAShapeLayer()
    private var handles: [ViewfinderCorner: UIView] = [:]
    private var animation: CADisplayLink?
    private var animationFrom = ViewfinderBox(x: 0, y: 0, w: 0, h: 0)
    private var animationTo = ViewfinderBox(x: 0, y: 0, w: 0, h: 0)
    private var animationStart: CFTimeInterval = 0

    /// The window, in this view's points.
    private(set) var box = ViewfinderBox(x: 0, y: 0, w: 0, h: 0)
    /// The image's pixel size under the window, for the stats card's preview.
    var imageSize = (width: 0, height: 0) { didSet { placeStats() } }
    var statsCard: UIImage? { didSet { placeStats() } }
    /// While capturing: the handles don't crop.
    var locked = false

    /// A corner's drag: started with the window as it was, moved by (dx, dy), ended.
    var onCrop: ((_ start: ViewfinderBox, _ corner: ViewfinderCorner, _ dx: Double, _ dy: Double) -> Void)?
    var onCropEnd: ((_ start: ViewfinderBox) -> Void)?
    private var dragStart: ViewfinderBox?

    private static let handleSize: CGFloat = 44
    private static let cornerArm: CGFloat = 18
    private static let gap: CGFloat = DesignTokens.Space.s8

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "exportViewfinder"
        scrim.fillRule = .evenOdd
        layer.addSublayer(scrim)
        border.fillColor = UIColor.clear.cgColor
        border.lineWidth = 1.5
        layer.addSublayer(border)
        corners.fillColor = UIColor.clear.cgColor
        corners.lineWidth = 4
        corners.lineCap = .round
        layer.addSublayer(corners)
        statsPreview.contentMode = .scaleToFill
        statsPreview.isAccessibilityElement = true
        statsPreview.accessibilityIdentifier = "exportStatsCard"
        addSubview(statsPreview)

        toolbar.backgroundColor = UIColor(resource: .surface)
        toolbar.layer.cornerRadius = DesignTokens.Radius.lg
        toolbar.layer.shadowColor = UIColor.black.cgColor
        toolbar.layer.shadowOpacity = 0.2
        toolbar.layer.shadowRadius = 8
        toolbar.layer.shadowOffset = CGSize(width: 0, height: 2)
        captureButton.configuration?.image = Controls.icon(UIImage(resource: .camera), size: 20)
        captureButton.accessibilityLabel = String(localized: "export.capture", defaultValue: "Save and share", comment: "Map image export: make the image, save it to Photos and share it.")
        choiceButton.accessibilityHint = String(localized: "export.shape", defaultValue: "Image shape and size", comment: "Map image export: the menu of the image's shapes and sizes.")
        choiceButton.showsMenuAsPrimaryAction = true
        for button in [choiceButton, statsButton, captureButton] {
            button.configuration?.contentInsets = .init(top: DesignTokens.Space.s8, leading: DesignTokens.Space.s12, bottom: DesignTokens.Space.s8, trailing: DesignTokens.Space.s12)
        }
        spinner.hidesWhenStopped = true
        captureButton.addSubview(spinner)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView(arrangedSubviews: [closeButton, choiceButton, statsButton, captureButton])
        row.spacing = DesignTokens.Space.s6
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(row)
        let pad = DesignTokens.Space.s6
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: pad),
            row.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -pad),
            row.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: pad),
            row.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -pad),
            spinner.centerXAnchor.constraint(equalTo: captureButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),
            captureButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        addSubview(toolbar)
        for label in [sizeLabel, errorLabel] {
            label.textAlignment = .center
            label.backgroundColor = UIColor(resource: .surface)
            label.layer.cornerRadius = DesignTokens.Radius.md
            label.layer.masksToBounds = true
            addSubview(label)
        }
        sizeLabel.accessibilityIdentifier = "exportSize"
        errorLabel.accessibilityIdentifier = "exportError"
        errorLabel.isHidden = true
        for corner in ViewfinderCorner.allCases {
            let handle = UIView()
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
            handles[corner] = handle
            addSubview(handle)
        }
        traitsChanged()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.traitsChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func traitsChanged() {
        scrim.fillColor = UIColor.black.withAlphaComponent(0.45).cgColor
        border.strokeColor = UIColor.white.cgColor
        corners.strokeColor = UIColor(resource: .accent).resolvedColor(with: traitCollection).cgColor
    }

    /// The window at once; the owner keeps the size line and the stats preview in step.
    func set(_ next: ViewfinderBox) {
        stopAnimation()
        box = next
        setNeedsLayout()
    }

    /// The window eased to next over duration, as the map zooms alongside.
    func animate(to next: ViewfinderBox, duration: CFTimeInterval) {
        stopAnimation()
        animationFrom = box
        animationTo = next
        animationStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        animation = link
        animationDuration = duration
    }

    private var animationDuration: CFTimeInterval = 0.3

    @objc private func step(_ link: CADisplayLink) {
        let t = min(1, (CACurrentMediaTime() - animationStart) / animationDuration)
        let e = 1 - pow(1 - t, 3)
        let a = animationFrom, b = animationTo
        box = ViewfinderBox(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e, w: a.w + (b.w - a.w) * e, h: a.h + (b.h - a.h) * e)
        setNeedsLayout()
        if t >= 1 { stopAnimation() }
    }

    private func stopAnimation() {
        animation?.invalidate()
        animation = nil
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopAnimation() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dim = UIBezierPath(rect: bounds)
        dim.append(UIBezierPath(rect: rect))
        scrim.path = dim.cgPath
        border.path = UIBezierPath(rect: rect).cgPath
        let arms = UIBezierPath()
        let arm = Self.cornerArm
        for (x, y, sx, sy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            arms.move(to: CGPoint(x: x + sx * arm, y: y))
            arms.addLine(to: CGPoint(x: x, y: y))
            arms.addLine(to: CGPoint(x: x, y: y + sy * arm))
        }
        corners.path = arms.cgPath
        CATransaction.commit()
        let half = Self.handleSize / 2
        let points: [ViewfinderCorner: CGPoint] = [.nw: CGPoint(x: rect.minX, y: rect.minY), .ne: CGPoint(x: rect.maxX, y: rect.minY),
                                                   .sw: CGPoint(x: rect.minX, y: rect.maxY), .se: CGPoint(x: rect.maxX, y: rect.maxY)]
        for (corner, point) in points { handles[corner]?.frame = CGRect(x: point.x - half, y: point.y - half, width: 2 * half, height: 2 * half) }
        // The toolbar centred over the window, clear of the sides; the lines centred under it.
        let side = DesignTokens.Space.s8
        let size = toolbar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let width = min(size.width, bounds.width - 2 * side)
        toolbar.frame = CGRect(x: min(max(side, rect.midX - width / 2), bounds.width - width - side), y: rect.minY - size.height - Self.gap, width: width, height: size.height)
        for label in [sizeLabel, errorLabel] {
            let fit = label.sizeThatFits(CGSize(width: bounds.width - 2 * side, height: .greatestFiniteMagnitude))
            let w = min(fit.width + 2 * DesignTokens.Space.s8, bounds.width - 2 * side)
            label.frame = CGRect(x: max(side, rect.midX - w / 2), y: rect.maxY + Self.gap, width: w, height: fit.height + DesignTokens.Space.s4)
        }
        placeStats()
    }

    /// The card at the image's placement, scaled from the image's pixels to the window's points.
    private func placeStats() {
        guard let card = statsCard?.cgImage, imageSize.width > 0 else {
            statsPreview.isHidden = true
            return
        }
        let scale = box.w / Double(imageSize.width)
        let at = ExportStats.placement(width: imageSize.width, height: imageSize.height, cardWidth: card.width, cardHeight: card.height)
        statsPreview.image = statsCard
        statsPreview.frame = CGRect(x: box.x + at.x * scale, y: box.y + at.y * scale, width: Double(card.width) * scale, height: Double(card.height) * scale)
        statsPreview.isHidden = false
    }

    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        guard !locked, let corner = handles.first(where: { $0.value === pan.view })?.key else { return }
        switch pan.state {
        case .began:
            stopAnimation()
            dragStart = box
        case .changed:
            guard let start = dragStart else { return }
            let t = pan.translation(in: self)
            onCrop?(start, corner, t.x, t.y)
        case .ended, .cancelled, .failed:
            guard let start = dragStart else { return }
            dragStart = nil
            onCropEnd?(start)
        default: break
        }
    }

    /// The toolbar, the lines and the handles take touches; the rest reach the map.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === statsPreview ? nil : hit
    }
}