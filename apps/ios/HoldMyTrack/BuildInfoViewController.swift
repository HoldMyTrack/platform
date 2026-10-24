import UIKit

/// The project's first screen until the app has its own (apps/ios/docs/ROADMAP.md, phase 5): the
/// build and whether the API answers, which is how a Debug build shows it reached a dev stack.
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
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "HoldMyTrack"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        let build = UILabel()
        build.text = app.userAgent
        build.font = .preferredFont(forTextStyle: .footnote)
        build.accessibilityIdentifier = "build"
        server.text = app.apiBaseURL.absoluteString
        server.font = .preferredFont(forTextStyle: .body)
        server.numberOfLines = 0
        server.accessibilityIdentifier = "server"

        let stack = UIStackView(arrangedSubviews: [title, build, server])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        Task { [app, server] in
            let status = await ServerCheck.run(app)
            server.text = "\(app.apiBaseURL.absoluteString): \(Self.describe(status))"
        }
    }

    private static func describe(_ status: ServerStatus) -> String {
        switch status {
        case .reachable(let version): "reachable, build \(version)"
        case .refused(let code): "answered \(code)"
        case .unreadable: "answered something other than /healthz"
        case .unreachable: "unreachable"
        }
    }
}
