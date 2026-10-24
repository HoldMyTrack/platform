import UIKit

/// The project's first screen until the app has its own (apps/ios/docs/ROADMAP.md, phase 5): the
/// build and whether the API answers, which is how a Debug build shows it reached a dev stack.
/// Drawn with the palette, the typefaces and an icon, it is also the sample the visual language
/// is checked on in both themes.
final class BuildInfoViewController: UIViewController {
    private let app: AppInfo
    private let server = UILabel()

    init(app: AppInfo) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)

        let title = UILabel()
        title.text = "HoldMyTrack"
        title.font = Typeface.serif(DesignTokens.Text.xxl)
        title.textColor = UIColor(resource: .ink)
        title.adjustsFontForContentSizeCategory = true

        let build = UILabel()
        build.text = app.userAgent
        build.font = Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote)
        build.textColor = UIColor(resource: .inkSecondary)
        build.adjustsFontForContentSizeCategory = true
        build.accessibilityIdentifier = "build"

        let icon = UIImageView(image: UIImage(resource: .info))
        icon.tintColor = UIColor(resource: .accent)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        server.text = app.apiBaseURL.absoluteString
        server.font = Typeface.sans(DesignTokens.Text.md)
        server.textColor = UIColor(resource: .ink)
        server.numberOfLines = 0
        server.adjustsFontForContentSizeCategory = true
        server.accessibilityIdentifier = "server"
        let serverRow = UIStackView(arrangedSubviews: [icon, server])
        serverRow.spacing = DesignTokens.Space.s8
        serverRow.alignment = .center

        let card = UIStackView(arrangedSubviews: [title, build, serverRow])
        card.axis = .vertical
        card.spacing = DesignTokens.Space.s12
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = .init(top: DesignTokens.Space.s20, leading: DesignTokens.Space.s20, bottom: DesignTokens.Space.s20, trailing: DesignTokens.Space.s20)
        card.backgroundColor = UIColor(resource: .surface)
        card.layer.cornerRadius = DesignTokens.Radius.lg
        card.layer.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        updateBorder(card)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateBorder(card)
        }

        Task { [app, server] in
            let status = await ServerCheck.run(app)
            server.text = "\(app.apiBaseURL.absoluteString): \(Self.describe(status))"
        }
    }

    /// A layer's border color is a CGColor, which doesn't follow the theme by itself.
    private func updateBorder(_ card: UIView) {
        card.layer.borderColor = UIColor(resource: .border).resolvedColor(with: traitCollection).cgColor
    }

    private static func describe(_ status: ServerStatus) -> String {
        switch status {
        case .reachable(let version): String(localized: "reachable, build \(version)")
        case .refused(let code): String(localized: "answered \(code)")
        case .unreadable: String(localized: "answered something other than /healthz")
        case .unreachable: String(localized: "unreachable")
        }
    }
}
