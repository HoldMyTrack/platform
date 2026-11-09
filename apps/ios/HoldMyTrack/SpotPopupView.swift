import HoldMyTrackCore
import UIKit

/// A place's popup (root docs/SPEC.md FR-15.3), the web's SpotPopup.tsx: over the map above the
/// place's badge, or under it when there's no room above, following it as the camera moves
/// (place). One at a time; show replaces it. Past six lines a long description or inscription
/// scrolls within it instead of stretching it over the map.
final class SpotPopupView: UIView {
    private(set) var spot: Spot?
    private let title = Controls.label("", font: Typeface.sans(DesignTokens.Text.xl, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private let meta = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let body = Controls.label("", font: Typeface.sans(DesignTokens.Text.md), color: UIColor(resource: .ink))
    private let inscription = Controls.label("", font: Typeface.serif(DesignTokens.Text.md), color: UIColor(resource: .inkSecondary))
    private let address = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let captured = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .ink))
    private let copy = UIButton(type: .system)
    private let wikipedia = UIButton(type: .system)
    /// Starts capture on the place: offered on one not yet captured, and never to the demo.
    let capture = Controls.primaryButton(String(localized: "Capture"), id: "spotCapture")
    var onCapture: ((Spot) -> Void)?
    private var copied: Task<Void, Never>?
    /// The description and inscription, scrolling past six lines; hidden with neither.
    private let texts = UIScrollView()

    /// How long "Copied" shows in place of Copy address.
    private static let copiedFor = Duration.milliseconds(1500)
    /// Half the 30-point badge, and a little air, between the place and the popup's edge.
    private static let offset: CGFloat = 18
    static let width: CGFloat = 272

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(resource: .surface)
        layer.cornerRadius = DesignTokens.Radius.lg
        layer.borderColor = UIColor(resource: .borderPanel).cgColor
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        accessibilityIdentifier = "spotPopup"
        isHidden = true

        let close = Controls.iconButton(Controls.icon(UIImage(resource: .x), size: 18), label: String(localized: "Close"), id: "spotClose")
        close.addAction(UIAction { [weak self] _ in self?.close() }, for: .primaryActionTriggered)
        let titles = Controls.column([title, meta], spacing: DesignTokens.Space.s2)
        let top = UIStackView(arrangedSubviews: [titles, close])
        top.alignment = .top

        let column = Controls.column([body, inscription], spacing: DesignTokens.Space.s6)
        texts.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        let sixLines = (body.font.lineHeight * 6).rounded(.up)
        let fit = texts.heightAnchor.constraint(equalTo: column.heightAnchor)
        fit.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: texts.contentLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: texts.contentLayoutGuide.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: texts.frameLayoutGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: texts.frameLayoutGuide.trailingAnchor),
            texts.heightAnchor.constraint(lessThanOrEqualToConstant: sixLines),
            fit,
        ])

        for (button, title, icon, id) in [(copy, "", UIImage(resource: .copy), "spotCopy"),
                                          (wikipedia, String(localized: "Wikipedia"), UIImage(resource: .externalLink), "spotWikipedia")] {
            var config = UIButton.Configuration.plain()
            config.title = title
            config.image = Controls.icon(icon, size: 14)
            config.imagePadding = DesignTokens.Space.s4
            config.contentInsets = .init(top: DesignTokens.Space.s8, leading: 0, bottom: DesignTokens.Space.s8, trailing: DesignTokens.Space.s12)
            config.baseForegroundColor = UIColor(resource: .accent)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold)
                return a
            }
            button.configuration = config
            button.accessibilityIdentifier = id
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        copy.addAction(UIAction { [weak self] _ in self?.copyAddress() }, for: .primaryActionTriggered)
        wikipedia.addAction(UIAction { [weak self] _ in
            guard let tag = self?.spot?.wikipedia, let url = Spots.wikipediaURL(tag) else { return }
            UIApplication.shared.open(url)
        }, for: .primaryActionTriggered)
        let actions = UIStackView(arrangedSubviews: [copy, wikipedia, UIView()])
        capture.addAction(UIAction { [weak self] _ in
            guard let self, let spot = self.spot else { return }
            self.close()
            self.onCapture?(spot)
        }, for: .primaryActionTriggered)

        let content = Controls.column([top, texts, address, captured, actions, capture], spacing: DesignTokens.Space.s6)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let m = DesignTokens.Space.s12
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: m),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Space.s12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Space.s12),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// capturedOn: the account's capture of it, already formatted, or nil.
    func show(_ next: Spot, capturedOn: String?, canCapture: Bool) {
        spot = next
        let category = SpotCategory(rawValue: next.category).map(Self.label) ?? next.category
        title.text = next.name ?? category
        // Under the title: the category, unless it already is the title, the memorial type, the date.
        let line = [next.name != nil ? category : nil, next.memorial.map(Spots.memorialLabel),
                    next.startDate.map { String(localized: "Since \($0)", comment: "Spot popup: when a place was built or founded.") }]
            .compactMap { $0 }
        set(meta, line.isEmpty ? nil : line.joined(separator: " · "))
        set(body, next.description)
        set(inscription, next.inscription)
        texts.isHidden = next.description == nil && next.inscription == nil
        texts.contentOffset = .zero
        set(address, next.address)
        set(captured, capturedOn.map { String(localized: "Captured \($0)", comment: "Spot popup: the date the account captured this place.") })
        wikipedia.isHidden = next.wikipedia.flatMap(Spots.wikipediaURL) == nil
        wikipedia.updateConfiguration()
        capture.isHidden = capturedOn != nil || !canCapture
        copied?.cancel()
        renderCopy(copied: false)
        isHidden = false
        UIAccessibility.post(notification: .layoutChanged, argument: self)
    }

    func close() {
        spot = nil
        copied?.cancel()
        isHidden = true
    }

    /// Where it sits in its superview, set by place.
    private var left: NSLayoutConstraint?
    private var topEdge: NSLayoutConstraint?

    /// Over the place's point in the superview, or under it when there's no room above top.
    func place(at point: CGPoint, top: CGFloat) {
        guard let parent = superview, spot != nil else { return }
        if left == nil {
            translatesAutoresizingMaskIntoConstraints = false
            left = leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            topEdge = topAnchor.constraint(equalTo: parent.topAnchor)
            NSLayoutConstraint.activate([left!, topEdge!])
        }
        let height = systemLayoutSizeFitting(CGSize(width: Self.width, height: UIView.layoutFittingCompressedSize.height),
                                             withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let gutter = DesignTokens.Space.s12
        left?.constant = min(max(point.x - Self.width / 2, gutter), max(parent.bounds.width - Self.width - gutter, gutter))
        let above = point.y - Self.offset - height
        topEdge?.constant = above >= top ? above : point.y + Self.offset
    }

    /// The category's name in a popup, singular.
    static func label(_ category: SpotCategory) -> String {
        switch category {
        case .playground: String(localized: "Playground")
        case .dogPark: String(localized: "Dog park")
        case .monument: String(localized: "Monument")
        case .viewpoint: String(localized: "Mesmerizing view")
        case .waterfall: String(localized: "Waterfall")
        case .history: String(localized: "History")
        }
    }

    private func set(_ label: UILabel, _ text: String?) {
        label.text = text
        label.isHidden = text == nil
    }

    private func renderCopy(copied: Bool) {
        let title = copied ? String(localized: "Copied")
            : spot?.address != nil ? String(localized: "Copy address") : String(localized: "Copy location")
        copy.configuration?.title = title
        copy.configuration?.image = Controls.icon(UIImage(resource: copied ? .check : .copy), size: 14)
        // Applied now, so the popup measures the new title.
        copy.updateConfiguration()
    }

    private func copyAddress() {
        guard let spot else { return }
        UIPasteboard.general.string = Spots.address(spot)
        renderCopy(copied: true)
        copied?.cancel()
        copied = Task { [weak self] in
            try? await Task.sleep(for: Self.copiedFor)
            guard !Task.isCancelled else { return }
            self?.renderCopy(copied: false)
        }
    }
}