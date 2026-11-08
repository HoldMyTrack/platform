import HoldMyTrackCore
import UIKit

/// Shown while a restored token waits for the server's word, so nothing of the account shows
/// before it's confirmed; when the server can't be reached it says so and offers Try again, and
/// Sign out for someone who'd rather not wait.
final class CheckingViewController: UIViewController, SessionCheckScreen {
    private unowned let flow: AppFlow
    private let spinner = UIActivityIndicatorView(style: .large)
    private let status = Controls.body(String(localized: "Checking your session…"))
    private let retry = Controls.primaryButton(String(localized: "Try again"), id: "retry")
    private let signOut = Controls.textButton(String(localized: "Sign out"), id: "signOut")

    init(flow: AppFlow) {
        self.flow = flow
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        status.textAlignment = .center
        status.accessibilityIdentifier = "checkStatus"
        spinner.color = UIColor(resource: .inkSecondary)
        spinner.startAnimating()
        retry.isHidden = true
        signOut.isHidden = true
        retry.addAction(UIAction { [weak self] _ in self?.retried() }, for: .primaryActionTriggered)
        signOut.addAction(UIAction { [weak self] _ in self?.flow.signOut() }, for: .primaryActionTriggered)
        let column = Controls.column([spinner, status, retry, signOut], spacing: DesignTokens.Space.s16)
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            column.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    func checkFailed(_ error: APIError) {
        spinner.stopAnimating()
        status.text = Self.describe(error)
        retry.isHidden = false
        signOut.isHidden = false
    }

    private func retried() {
        spinner.startAnimating()
        status.text = String(localized: "Checking your session…")
        retry.isHidden = true
        signOut.isHidden = true
        flow.check()
    }

    /// What a failure says: the server's own message when it sent one.
    static func describe(_ error: APIError) -> String {
        error.serverMessage ?? String(localized: "Couldn't reach HoldMyTrack. Check your connection and try again.")
    }
}
