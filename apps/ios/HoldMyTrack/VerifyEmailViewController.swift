import HoldMyTrackCore
import UIKit

/// "Check your email", in place of everything else until the address is confirmed
/// (apps/android/docs/SPEC.md FR-1.4), since the server would refuse the map's every tile. The
/// email's code typed here confirms the address and keeps this session. It asks the server again
/// on Confirm with the field empty and on every return to the app; the code typed on the web ends
/// this session (docs/SPEC.md FR-1.8), and the check then signs out.
/// Changing the address is the web's.
final class VerifyEmailViewController: UIViewController, SessionCheckScreen {
    private unowned let flow: AppFlow
    private let email: String
    private let status = Controls.body()
    private let code = Controls.field(String(localized: "Code from the email"), id: "verifyCode")
    private let proceed = Controls.primaryButton(String(localized: "Confirm"), id: "continue")
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
        let hint = Controls.body(String(localized: "verify.hint", defaultValue: "We sent a 6-digit code to \(email). Enter it below to unlock your account — your map and sync start working as soon as you do.", comment: "Verify your email: where the code went."))
        hint.accessibilityIdentifier = "verifyHint"
        status.isHidden = true
        status.accessibilityIdentifier = "verifyStatus"
        code.keyboardType = .numberPad
        code.textContentType = .oneTimeCode
        proceed.addAction(UIAction { [weak self] _ in self?.confirmTapped() }, for: .primaryActionTriggered)
        resend.addAction(UIAction { [weak self] _ in self?.resendTapped() }, for: .primaryActionTriggered)
        signOut.addAction(UIAction { [weak self] _ in self?.flow.signOut() }, for: .primaryActionTriggered)
        let column = Controls.column([Controls.title(String(localized: "Verify your email")), hint, code, status, proceed, resend, signOut])
        column.setCustomSpacing(DesignTokens.Space.s24, after: status)
        Controls.host(column, in: self)
    }

    /// Quiet: the check on a return wasn't asked for, and Confirm says its own failure.
    func checkFailed(_ error: APIError) {}

    private func show(_ message: String) {
        status.text = message
        status.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func confirmTapped() {
        guard proceed.isEnabled else { return }
        proceed.isEnabled = false
        let action = VerifyAction.of(code.text ?? "")
        Task {
            defer { proceed.isEnabled = true }
            switch action {
            case .submit(let typed):
                do {
                    flow.verified(try await flow.api.verifyCode(typed))
                } catch let error as APIError {
                    if SessionCheck.signsOut(error) {
                        flow.sessionEnded()
                    } else if error != .outdated {
                        show(error.shownMessage)
                    }
                } catch {}
            case .check:
                // Confirmed, the flow moves on and this screen is gone; still here means not yet.
                let failure = await flow.recheck()
                guard viewIfLoaded?.window != nil, failure != .outdated else { return }
                show(failure?.shownMessage ?? String(localized: "Enter the 6-digit code from the email."))
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
                if error != .outdated { show(error.shownMessage) }
            } catch {}
        }
    }
}
