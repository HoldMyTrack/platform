import UIKit

/// The map's notices, full width over its top row, one per id: its text, then, as on Android, an
/// optional line of small print and action buttons in a row, and ×. A closed notice stays down
/// until its condition ends (hide), so the toggle and the rail under it can be reached. A screen
/// whose notice is its only way on (SessionCheckMapViewController) leaves × out.
final class MapNotices: UIStackView {
    struct Action {
        let title: String
        let id: String
        let run: () -> Void
    }

    private let closable: Bool

    init(closable: Bool = true) {
        self.closable = closable
        super.init(frame: .zero)
        axis = .vertical
        spacing = DesignTokens.Space.s8
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Notices closed while their condition lasts.
    private var closed: Set<Int> = []

    /// Shows id's notice, or changes its words; × takes it down until hide and then calls onClose.
    func show(_ id: Int, _ text: String, detail: String? = nil, actions: [Action] = [], onClose: (() -> Void)? = nil) {
        if closed.contains(id) { return }
        // Shown again, it keeps its place, its buttons and VoiceOver's quiet; only the words change.
        if let shown = box(id) {
            Self.labels(in: shown).first { $0.accessibilityIdentifier == "notice" }?.text = text
            if let detail { Self.labels(in: shown).first { $0.accessibilityIdentifier == "noticeDetail" }?.text = detail }
            return
        }
        let label = Controls.body(text, color: UIColor(resource: .ink))
        label.accessibilityIdentifier = "notice"
        var column: [UIView] = [label]
        if let detail {
            let small = Controls.label(detail, font: Typeface.sans(DesignTokens.Text.xs, relativeTo: .caption2), color: UIColor(resource: .inkSecondary))
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
        let close = Controls.iconButton(Controls.icon(UIImage(resource: .x), size: 18), label: String(localized: "Close"), id: "noticeClose")
        close.addAction(UIAction { [weak self] _ in
            self?.box(id)?.removeFromSuperview()
            self?.closed.insert(id)
            onClose?()
        }, for: .primaryActionTriggered)
        close.isHidden = !closable
        let box = UIStackView(arrangedSubviews: [content, close])
        box.alignment = .center
        box.spacing = DesignTokens.Space.s8
        box.isLayoutMarginsRelativeArrangement = true
        box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: DesignTokens.Space.s8, leading: DesignTokens.Space.s12, bottom: DesignTokens.Space.s8, trailing: DesignTokens.Space.s4)
        box.tag = id + 1
        box.isHidden = aside.contains(id)
        // Opaque, as Android's: it lies over the toggle and the rail.
        box.backgroundColor = UIColor(resource: .surface)
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

    /// id's condition ended: down if it's up, and shown again when it comes back.
    func hide(_ id: Int) {
        closed.remove(id)
        box(id)?.removeFromSuperview()
    }

    private func box(_ id: Int) -> UIView? {
        arrangedSubviews.first { $0.tag == id + 1 }
    }

    private static func labels(in view: UIView) -> [UILabel] {
        (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }
}