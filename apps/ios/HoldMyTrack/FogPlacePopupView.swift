import HoldMyTrackCore
import UIKit

/// Fog's place popup (root docs/SPEC.md FR-4.2), the web's place tooltip: a tapped outline's name,
/// its kind and the places it lies in, whether it's explored, and of each level below it how many
/// of its places are. Over the tap, or under it when there's no room above, following it as the
/// camera moves (MapViewController+Fog).
final class FogPlacePopupView: UIView {
    private let name = Controls.label("", font: Typeface.sans(DesignTokens.Text.lg, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private let detail = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let explored = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .ink))
    var onClose: (() -> Void)?

    /// The web popup's 14px offset from the pointer.
    private static let offset: CGFloat = 14
    static let width: CGFloat = 256

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
        accessibilityIdentifier = "fogPlacePopup"
        isHidden = true

        let close = Controls.iconButton(Controls.icon(UIImage(resource: .x), size: 18), label: String(localized: "Close"), id: "fogPlaceClose")
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)
        let titles = Controls.column([name, detail], spacing: DesignTokens.Space.s2)
        let top = UIStackView(arrangedSubviews: [titles, close])
        top.alignment = .top
        let content = Controls.column([top, explored], spacing: DesignTokens.Space.s6)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let m = DesignTokens.Space.s12
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: m),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -m),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ label: FogPlaceLabel.Label) {
        name.text = label.name
        detail.text = [FogWords.string(label.kindKey), label.within.isEmpty ? nil : label.within].compactMap { $0 }.joined(separator: " · ")
        // Explored, and of each level below, how many of its places in it are: 34 of 88 counties.
        let state = FogWords.string(label.visitedKey) ?? ""
        explored.text = label.visited ? ([state] + label.counts.compactMap(FogWords.count)).joined(separator: " · ") : state
        isHidden = false
        UIAccessibility.post(notification: .layoutChanged, argument: self)
    }

    func close() {
        isHidden = true
    }

    private var left: NSLayoutConstraint?
    private var topEdge: NSLayoutConstraint?

    /// Over point in the superview, or under it when there's no room above top.
    func place(at point: CGPoint, top: CGFloat) {
        guard let parent = superview, !isHidden else { return }
        if left == nil {
            translatesAutoresizingMaskIntoConstraints = false
            left = leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            topEdge = topAnchor.constraint(equalTo: parent.topAnchor)
            NSLayoutConstraint.activate([left!, topEdge!])
        }
        let height = systemLayoutSizeFitting(CGSize(width: Self.width, height: UIView.layoutFittingCompressedSize.height),
                                             withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let gutter = DesignTokens.Space.s8
        left?.constant = min(max(point.x - Self.width / 2, gutter), max(parent.bounds.width - Self.width - gutter, gutter))
        let above = point.y - Self.offset - height
        topEdge?.constant = above >= top ? above : point.y + Self.offset
    }
}

/// The web's Fog catalog keys (`map.fog.type.*`, `map.fog.level.*`, `map.fog.place.*`, and the
/// plural `map.fog.count.*`), which Localizable.xcstrings holds under the same keys. A key it
/// doesn't hold is one the catalog doesn't have.
enum FogWords {
    private static let missing = "\u{1}"

    static func string(_ key: String) -> String? {
        let text = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
        return text == missing ? nil : text
    }

    /// Whether the catalog has key, as the web's `hasKey`: a plural is had by its `.other` form.
    static func has(_ key: String) -> Bool {
        string(key.hasSuffix(".other") ? String(key.dropLast(".other".count)) : key) != nil
    }

    /// "34 of 88 counties", in the count's plural.
    static func count(_ count: FogPlaceLabel.Count) -> String? {
        guard let format = string(count.key) else { return nil }
        let explored = count.explored.formatted(), total = count.total.formatted()
        return String.localizedStringWithFormat(format, explored, total, count.total)
    }
}