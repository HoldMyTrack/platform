import UIKit

/// The map's notices at its top, beside the rail, one per id: its text, then, as on Android, an
/// optional line of small print and action buttons in a row, and × when onClose is given.
final class MapNotices: UIStackView {
    struct Action {
        let title: String
        let id: String
        let run: () -> Void
    }

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = DesignTokens.Space.s8
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows id's notice, or changes its words; × takes it down and then calls onClose.
    func show(_ id: Int, _ text: String, detail: String? = nil, actions: [Action] = [], onClose: (() -> Void)? = nil) {
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
        let buttons = actions.map { action in
            let button = Controls.textButton(action.title, id: action.id)
            button.addAction(UIAction { _ in action.run() }, for: .primaryActionTriggered)
            return button
        }
        if buttons.count == 1 {
            column += buttons
        } else if buttons.count > 1 {
            let row = UIStackView(arrangedSubviews: buttons)
            row.spacing = DesignTokens.Space.s16
            let centered = UIStackView(arrangedSubviews: [row])
            centered.axis = .vertical
            centered.alignment = .center
            column.append(centered)
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
        box.isHidden = aside.contains(id)
        box.backgroundColor = UIColor(resource: .noticeBg)
        box.layer.cornerRadius = DesignTokens.Radius.md
        box.layer.masksToBounds = true
        addArrangedSubview(box)
        if !box.isHidden { UIAccessibility.post(notification: .announcement, argument: text) }
    }

    func shown(_ id: Int) -> Bool { box(id) != nil }

    /// Notices kept but stepping aside, shown again once they leave the set.
    var aside: Set<Int> = [] {
        didSet { for view in arrangedSubviews { view.isHidden = aside.contains(view.tag - 1) } }
    }

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