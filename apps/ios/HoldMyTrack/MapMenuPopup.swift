import HoldMyTrackCore
import UIKit

/// A map menu's popup, Android's `MenuPopup`: a panel under its button, its end edge on the
/// button's. A tap on the button opens it; a tap outside it closes it, the button's own included.
/// The tour can hold it open view-only (hold), letting go of touches so the tour's card under it
/// keeps working, and at most 40% of the screen tall so it can't cover that card. build makes the
/// content on each opening and refresh.
@MainActor
final class MapMenuPopup {
    private unowned let host: UIView
    private unowned let anchor: UIView
    private let build: () -> UIView
    private var panel: UIView?
    private let scroll = UIScrollView()
    private var catcher: UIView?
    private var held = false
    private var wantHeld = false

    var isOpen: Bool { panel != nil }
    /// The open panel, for the tour's ring.
    var content: UIView? { panel }

    /// The web panel's 14rem.
    static let width: CGFloat = 224
    /// The share of the screen's height a held menu takes.
    static let heldHeight: CGFloat = 0.4
    /// Around the content, inside the panel.
    static let inset = DesignTokens.Space.s8

    init(host: UIView, anchor: UIView, build: @escaping () -> UIView) {
        self.host = host
        self.anchor = anchor
        self.build = build
    }

    func open() {
        if panel == nil { show(interactive: true) }
    }

    func dismiss() {
        panel?.removeFromSuperview()
        catcher?.removeFromSuperview()
        panel = nil
        catcher = nil
        held = false
    }

    /// Closes the user's own menu; a held one stays for the tour to let go of.
    func dismissUsers() {
        if !held { dismiss() }
    }

    /// Holds the menu open for the tour, or lets go of it (MenuHold).
    func hold(_ open: Bool) {
        wantHeld = open
        switch MenuHold.next(isOpen: isOpen, held: held, want: open, canOpen: true) {
        case .none: break
        case .close: dismiss()
        case .openHeld: show(interactive: false)
        case .reopenHeld:
            dismiss()
            show(interactive: false)
        }
    }

    /// The content made again from the state, where the menu is open.
    func refresh() {
        guard panel != nil else { return }
        setContent()
        place()
    }

    /// Under the button, its end edge on the button's; laid out again on every layout pass.
    func place() {
        guard let panel else { return }
        let below = anchor.convert(anchor.bounds, to: host)
        let top = below.maxY + DesignTokens.Space.s6
        let room = host.bounds.height - host.safeAreaInsets.bottom - top - DesignTokens.Space.s8
        let cap = held ? (host.window?.bounds.height ?? host.bounds.height) * Self.heldHeight : room
        let fitting = (scroll.subviews.first?.systemLayoutSizeFitting(
            CGSize(width: Self.width - 2 * Self.inset, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height ?? 0) + 2 * Self.inset
        let height = max(0, min(fitting, cap, room))
        let x = min(max(below.maxX - Self.width, DesignTokens.Space.s8), host.bounds.width - Self.width - DesignTokens.Space.s8)
        panel.frame = CGRect(x: x, y: top, width: Self.width, height: height)
        catcher?.frame = host.bounds
    }

    private func show(interactive: Bool) {
        let panel = UIView()
        panel.backgroundColor = UIColor(resource: .surface)
        panel.layer.cornerRadius = DesignTokens.Radius.lg
        panel.layer.borderWidth = 1
        panel.layer.borderColor = UIColor(resource: .borderPanel).resolvedColor(with: host.traitCollection).cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.2
        panel.layer.shadowRadius = 8
        panel.layer.shadowOffset = CGSize(width: 0, height: 2)
        panel.isUserInteractionEnabled = interactive
        panel.accessibilityViewIsModal = interactive
        scroll.frame = panel.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.layer.cornerRadius = DesignTokens.Radius.lg
        scroll.alwaysBounceVertical = false
        panel.addSubview(scroll)
        if interactive {
            let catcher = UIView()
            catcher.backgroundColor = .clear
            catcher.isAccessibilityElement = false
            catcher.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(outside)))
            host.addSubview(catcher)
            self.catcher = catcher
        }
        host.addSubview(panel)
        self.panel = panel
        held = !interactive
        setContent()
        place()
        if interactive { UIAccessibility.post(notification: .screenChanged, argument: panel) }
    }

    private func setContent() {
        for view in scroll.subviews { view.removeFromSuperview() }
        let content = build()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        let inset = Self.inset
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -inset),
        ])
    }

    @objc private func outside() { dismiss() }
}

/// A map menu's rows, Android's popup layouts: switches, check boxes, headings and the legend key.
@MainActor
enum MenuRows {
    /// A label at the start and a switch at the end; disabled, why under the label.
    static func toggle(_ title: String, on: Bool, enabled: Bool = true, disabledHint: String? = nil, id: String,
                       action: @escaping (Bool) -> Void) -> UIView {
        let label = Controls.label(title, font: Typeface.sans(DesignTokens.Text.md), color: UIColor(resource: .ink))
        let toggle = UISwitch()
        toggle.isOn = on
        toggle.isEnabled = enabled
        toggle.onTintColor = UIColor(resource: .accent)
        toggle.accessibilityLabel = title
        toggle.accessibilityIdentifier = id
        toggle.addAction(UIAction { [weak toggle] _ in action(toggle?.isOn ?? false) }, for: .valueChanged)
        var text: [UIView] = [label]
        if !enabled, let disabledHint {
            text.append(Controls.label(disabledHint, font: Typeface.sans(DesignTokens.Text.xs), color: UIColor(resource: .inkMuted)))
            toggle.accessibilityHint = disabledHint
        }
        label.numberOfLines = 0
        let column = Controls.column(text, spacing: DesignTokens.Space.s2)
        let row = UIStackView(arrangedSubviews: [column, toggle])
        row.alignment = .center
        row.spacing = DesignTokens.Space.s8
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: DesignTokens.Space.s4, bottom: 0, trailing: 0)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return row
    }

    /// A check box and its label, with an image at the end where one is given.
    static func check(_ title: String, on: Bool, trailing: UIImage? = nil, action: @escaping () -> Void) -> UIView {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: on ? "checkmark.square.fill" : "square")
        config.imagePadding = DesignTokens.Space.s12
        config.baseForegroundColor = UIColor(resource: .ink)
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: DesignTokens.Space.s4, bottom: 0, trailing: 0)
        config.imageColorTransformer = UIConfigurationColorTransformer { _ in UIColor(resource: on ? .accent : .inkMuted) }
        // Its look is the box's; a checked row has no highlight of its own.
        config.background.backgroundColorTransformer = UIConfigurationColorTransformer { _ in .clear }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Typeface.sans(DesignTokens.Text.md)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.isSelected = on
        button.accessibilityIdentifier = title
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        guard let trailing else { return button }
        let row = UIStackView(arrangedSubviews: [button, UIImageView(image: trailing)])
        row.alignment = .center
        row.spacing = DesignTokens.Space.s8
        return row
    }

    /// A small-caps heading over a group of entries.
    static func heading(_ title: String) -> UIView {
        let label = Controls.label(title.uppercased(), font: Typeface.sans(DesignTokens.Text.xs, weight: DesignTokens.Weight.bold),
                                   color: UIColor(resource: .inkMuted))
        label.accessibilityTraits = .header
        label.accessibilityLabel = title
        let box = UIStackView(arrangedSubviews: [label])
        box.isLayoutMarginsRelativeArrangement = true
        box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: DesignTokens.Space.s8, leading: DesignTokens.Space.s2, bottom: DesignTokens.Space.s4, trailing: DesignTokens.Space.s2)
        return box
    }

    /// A rule between groups.
    static func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor(resource: .border)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let box = UIStackView(arrangedSubviews: [line])
        box.isLayoutMarginsRelativeArrangement = true
        box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: DesignTokens.Space.s4, leading: 0, bottom: DesignTokens.Space.s4, trailing: 0)
        return box
    }

    /// A muted line, then entries each with its image before it.
    static func key(_ title: String, _ entries: [(String, UIImage?)]) -> UIView {
        let lead = Controls.label(title, font: Typeface.sans(DesignTokens.Text.sm), color: UIColor(resource: .inkMuted))
        lead.numberOfLines = 0
        let items = entries.map { text, image -> UIView in
            let label = Controls.label(text, font: Typeface.sans(DesignTokens.Text.sm), color: UIColor(resource: .inkMuted))
            let row = UIStackView(arrangedSubviews: (image.map { [UIImageView(image: $0)] } ?? []) + [label])
            row.alignment = .center
            row.spacing = DesignTokens.Space.s4
            return row
        }
        let line = UIStackView(arrangedSubviews: items)
        line.spacing = DesignTokens.Space.s16
        let column = Controls.column([lead, line], spacing: DesignTokens.Space.s4)
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: DesignTokens.Space.s4, leading: DesignTokens.Space.s2, bottom: 0, trailing: DesignTokens.Space.s2)
        return column
    }
}
