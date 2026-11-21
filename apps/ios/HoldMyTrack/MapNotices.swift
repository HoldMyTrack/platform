import UIKit

/// The map's notices under its top row, one per id: its text, then, as on Android, an optional
/// line of small print and an action button, and × when onClose is given.
final class MapNotices: UIStackView {
    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = DesignTokens.Space.s8
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows id's notice, or changes its words; × takes it down and then calls onClose.
    func show(_ id: Int, _ text: String, detail: String? = nil, action: (title: String, run: () -> Void)? = nil, onClose: (() -> Void)? = nil) {
        // Shown again, it keeps its place, its buttons and VoiceOver's quiet; only the words change.
        if let shown = box(id) {
            Self.labels(in: shown).first { $0.accessibilityIdentifier == "notice" }?.text = text
            if let detail { Self.labels(in: shown).first { $0.accessibilityIdentifier == "noticeDetail" }?.text = detail }
            return
        }
        let label = Controls.body(text, color: UIColor(resource: .ink))
        label.textAlignment = .center
        label.accessibilityIdentifier = "notice"
        var column: [UIView] = [label]
        if let detail {
            let small = Controls.label(detail, font: Typeface.sans(DesignTokens.Text.xs, relativeTo: .caption2), color: UIColor(resource: .inkSecondary))
            small.textAlignment = .center
            small.accessibilityIdentifier = "noticeDetail"
            column.append(small)
        }
        if let action {
            let button = Controls.textButton(action.title, id: "noticeAction")
            button.addAction(UIAction { _ in action.run() }, for: .primaryActionTriggered)
            column.append(button)
        }
        let content: UIView = column.count == 1 ? label : Controls.column(column, spacing: DesignTokens.Space.s4)
        let box: UIView
        if let onClose {
            let close = Controls.iconButton(Controls.icon(UIImage(resource: .x), size: 18), label: String(localized: "Close"), id: "noticeClose")
            close.addAction(UIAction { [weak self] _ in
                self?.hide(id)
                onClose()
            }, for: .primaryActionTriggered)
            let row = UIStackView(arrangedSubviews: [content, close])
            row.alignment = .center
            row.spacing = DesignTokens.Space.s8
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: DesignTokens.Space.s12, bottom: 0, trailing: DesignTokens.Space.s4)
            box = row
        } else if column.count > 1 {
            let wrap = UIStackView(arrangedSubviews: [content])
            wrap.isLayoutMarginsRelativeArrangement = true
            wrap.directionalLayoutMargins = NSDirectionalEdgeInsets(top: DesignTokens.Space.s8, leading: DesignTokens.Space.s12, bottom: DesignTokens.Space.s4, trailing: DesignTokens.Space.s12)
            box = wrap
        } else {
            box = label
        }
        box.tag = id + 1
        box.backgroundColor = UIColor(resource: .noticeBg)
        box.layer.cornerRadius = DesignTokens.Radius.md
        box.layer.masksToBounds = true
        addArrangedSubview(box)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    func shown(_ id: Int) -> Bool { box(id) != nil }

    func hide(_ id: Int) {
        box(id)?.removeFromSuperview()
    }

    private func box(_ id: Int) -> UIView? {
        arrangedSubviews.first { $0.tag == id + 1 }
    }

    private static func labels(in view: UIView) -> [UILabel] {
        (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }
}