import HoldMyTrackCore
import UIKit

/// "Check your email", in place of everything else until the address is confirmed
/// (apps/android/docs/SPEC.md FR-1.4), since the server would refuse the map's every tile. It
/// asks the server again on Continue and on every return to the app; confirming in the phone's
/// browser ends this session (docs/SPEC.md FR-1.8), and the check then signs out. Changing the
/// address is the web's.
final class VerifyEmailViewController: UIViewController, SessionCheckScreen {
    private unowned let flow: AppFlow
    private let email: String
    private let status = Controls.body()
    private let proceed = Controls.primaryButton(String(localized: "Continue"), id: "continue")
    private let resend = Controls.secondaryButton(String(localized: "Resend verification email"), id: "resend")
    private let signOut = Controls.textButton(String(localized: "Sign out"), id: "signOut")

    init(flow: AppFlow, email: String) {
        self.flow = flow
        self.email = email
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        let hint = Controls.body(String(localized: "We sent a confirmation link to \(email). Open it to unlock your account — your map starts working as soon as you do."))
        hint.accessibilityIdentifier = "verifyHint"
        status.isHidden = true
        status.accessibilityIdentifier = "verifyStatus"
        proceed.addAction(UIAction { [weak self] _ in self?.continueTapped() }, for: .primaryActionTriggered)
        resend.addAction(UIAction { [weak self] _ in self?.resendTapped() }, for: .primaryActionTriggered)
        signOut.addAction(UIAction { [weak self] _ in self?.flow.signOut() }, for: .primaryActionTriggered)
        let column = Controls.column([Controls.title(String(localized: "Verify your email")), hint, status, proceed, resend, signOut])
        column.setCustomSpacing(DesignTokens.Space.s24, after: status)
        Controls.host(column, in: self)
    }

    func checkFailed(_ error: APIError) {
        show(CheckingViewController.describe(error))
    }

    private func show(_ message: String) {
        status.text = message
        status.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func continueTapped() {
        proceed.isEnabled = false
        Task {
            defer { proceed.isEnabled = true }
            // Confirmed, the flow moves on and this screen is gone; still here means not yet.
            if await flow.recheck() == nil, viewIfLoaded?.window != nil {
                show(String(localized: "Your email isn't confirmed yet. Open the link in the email we sent, then tap Continue."))
            }
        }
    }

    private func resendTapped() {
        resend.isEnabled = false
        Task {
            defer { resend.isEnabled = true }
            do {
                show(try await flow.api.resendVerification())
            } catch let error as APIError {
                if error != .outdated { show(CheckingViewController.describe(error)) }
            } catch {}
        }
    }
}
