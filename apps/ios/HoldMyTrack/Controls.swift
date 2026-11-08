import UIKit

/// The controls every screen draws the same way, in the web's palette and type: one place for
/// the look, so a screen only says what it shows.
@MainActor
enum Controls {
    /// The screen's one main action: filled with the accent.
    static func primaryButton(_ title: String, id: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor(resource: .accent)
        config.baseForegroundColor = UIColor(resource: .onAccent)
        config.cornerStyle = .medium
        config.contentInsets = .init(top: DesignTokens.Space.s12, leading: DesignTokens.Space.s16, bottom: DesignTokens.Space.s12, trailing: DesignTokens.Space.s16)
        config.titleTextAttributesTransformer = font(Typeface.sans(DesignTokens.Text.xl, weight: DesignTokens.Weight.semibold))
        config.title = title
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = id
        return button
    }

    /// Another way in or on: outlined, so the primary action stays the obvious one.
    static func secondaryButton(_ title: String, id: String, icon: UIImage? = nil) -> UIButton {
        var config = UIButton.Configuration.bordered()
        config.baseBackgroundColor = UIColor(resource: .surface)
        config.baseForegroundColor = UIColor(resource: .ink)
        config.cornerStyle = .medium
        config.background.strokeColor = UIColor(resource: .borderStrong)
        config.background.strokeWidth = 1
        config.contentInsets = .init(top: DesignTokens.Space.s12, leading: DesignTokens.Space.s16, bottom: DesignTokens.Space.s12, trailing: DesignTokens.Space.s16)
        config.titleTextAttributesTransformer = font(Typeface.sans(DesignTokens.Text.xl))
        config.title = title
        config.image = icon
        config.imagePadding = DesignTokens.Space.s8
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = id
        return button
    }

    /// A link-like action: text in the accent.
    static func textButton(_ title: String, id: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = UIColor(resource: .accent)
        config.titleTextAttributesTransformer = font(Typeface.sans(DesignTokens.Text.lg))
        config.title = title
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = id
        return button
    }

    static func field(_ placeholder: String, id: String) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = Typeface.sans(DesignTokens.Text.xl)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = UIColor(resource: .ink)
        field.backgroundColor = UIColor(resource: .surface)
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.accessibilityIdentifier = id
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return field
    }

    static func title(_ text: String) -> UILabel {
        label(text, font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink))
    }

    static func body(_ text: String = "", color: UIColor = UIColor(resource: .inkSecondary)) -> UILabel {
        label(text, font: Typeface.sans(DesignTokens.Text.lg), color: color)
    }

    /// Where a failure says what went wrong, in the danger color; hidden while empty.
    static func error(id: String) -> UILabel {
        let label = label("", font: Typeface.sans(DesignTokens.Text.lg), color: UIColor(resource: .danger))
        label.accessibilityIdentifier = id
        label.isHidden = true
        return label
    }

    static func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    /// A vertical column of views, the way every screen lays its content out.
    static func column(_ views: [UIView], spacing: CGFloat = DesignTokens.Space.s12) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        return stack
    }

    /// Puts column in a scroll view filling controller's view inside its readable margins, so
    /// a large text size or the keyboard never cuts a screen off.
    static func host(_ column: UIStackView, in controller: UIViewController) {
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(scroll)
        scroll.addSubview(column)
        let margins = controller.view.readableContentGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: controller.view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: DesignTokens.Space.s32),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -DesignTokens.Space.s32),
            column.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
    }

    private static func font(_ font: UIFont) -> UIConfigurationTextAttributesTransformer {
        UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
    }
}
