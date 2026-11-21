import UIKit

/// The You tab's glance at the track graph: the last weeks as columns, Sunday at the top, each
/// day shaded by its tracks as the web's grid is (ProfileStats.recentWeeks): none, 1, 2, three
/// or more; a day still to come is left out.
final class RecentWeeksView: UIView {
    private let levels: [Int]
    private static let cell: CGFloat = 8
    private static let gap: CGFloat = 2

    init(levels: [Int]) {
        self.levels = levels
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "you.recentWeeks", defaultValue: "Recent weeks", comment: "The You tab: the small grid of the last weeks' tracks, read out.")
        accessibilityIdentifier = "recentWeeks"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        let weeks = CGFloat(max(1, levels.count / 7))
        return CGSize(width: weeks * (Self.cell + Self.gap) - Self.gap, height: 7 * (Self.cell + Self.gap) - Self.gap)
    }

    override func draw(_ rect: CGRect) {
        let accent = UIColor(resource: .accent).resolvedColor(with: traitCollection)
        let none = UIColor(resource: .surfaceTint).resolvedColor(with: traitCollection)
        for (i, level) in levels.enumerated() where level >= 0 {
            let x = CGFloat(i / 7) * (Self.cell + Self.gap), y = CGFloat(i % 7) * (Self.cell + Self.gap)
            let color = level == 0 ? none : accent.withAlphaComponent([0, 0.4, 0.7, 1][level])
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: y, width: Self.cell, height: Self.cell), cornerRadius: 2).fill()
        }
    }
}
