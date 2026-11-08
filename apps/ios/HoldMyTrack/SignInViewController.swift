import AuthenticationServices
import HoldMyTrackCore
import SafariServices
import UIKit

/// Sign in, sign up, the demo, and Google and Facebook, against the web's endpoints
/// (apps/android/docs/SPEC.md FR-1.1). Sign in and sign up are two modes of one screen. The app
/// checks only that both fields are filled; every other rule is the server's, and its message is
/// shown as sent. Google and Facebook show only when the server reports them configured, and run
/// the server's own flow in ASWebAuthenticationSession (apps/ios/docs/ARCHITECTURE.md §1, D7).
final class SignInViewController: UIViewController, ASWebAuthenticationPresentationContextProviding {
    private unowned let flow: AppFlow
    private var signingUp = false
    private var busy = false { didSet { updateEnabled() } }
    /// The browser sign-in in flight, kept so it isn't released while its sheet shows.
    private var browserSession: ASWebAuthenticationSession?

    private let titleLabel = Controls.title("")
    private let intro = Controls.body(String(localized: "Sign in to see your tracks, fog of war and heatmap on the map. The demo needs no signup: a shared, ready-made account you can look around but not change."))
    private let email = Controls.field(String(localized: "Email"), id: "email")
    private let password = Controls.field(String(localized: "Password"), id: "password")
    private let errorLabel = Controls.error(id: "signInError")
    private let primary = Controls.primaryButton("", id: "primary")
    private let forgot = Controls.textButton(String(localized: "Forgot password?"), id: "forgot")
    private let switchMode = Controls.textButton("", id: "switchMode")
    private let or = Controls.body(String(localized: "or"))
    private let google = Controls.secondaryButton(String(localized: "Continue with Google"), id: "google")
    private let facebook = Controls.secondaryButton(String(localized: "Continue with Facebook"), id: "facebook")
    private let demo = Controls.secondaryButton(String(localized: "Try the demo"), id: "demo")

    init(flow: AppFlow) {
        self.flow = flow
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)

        email.keyboardType = .emailAddress
        email.textContentType = .username
        email.returnKeyType = .next
        password.isSecureTextEntry = true
        password.returnKeyType = .go
        email.addAction(UIAction { [weak self] _ in self?.password.becomeFirstResponder() }, for: .editingDidEndOnExit)
        password.addAction(UIAction { [weak self] _ in self?.submit() }, for: .editingDidEndOnExit)
        for field in [email, password] {
            field.addAction(UIAction { [weak self] _ in self?.updateEnabled() }, for: .editingChanged)
        }

        primary.addAction(UIAction { [weak self] _ in self?.submit() }, for: .primaryActionTriggered)
        switchMode.addAction(UIAction { [weak self] _ in self?.toggleMode() }, for: .primaryActionTriggered)
        forgot.addAction(UIAction { [weak self] _ in self?.openForgot() }, for: .primaryActionTriggered)
        demo.addAction(UIAction { [weak self] _ in self?.startDemo() }, for: .primaryActionTriggered)
        google.addAction(UIAction { [weak self] _ in self?.browserSignIn(.google) }, for: .primaryActionTriggered)
        facebook.addAction(UIAction { [weak self] _ in self?.browserSignIn(.facebook) }, for: .primaryActionTriggered)
        or.textAlignment = .center
        for provider in [or, google, facebook] { provider.isHidden = true }

        let links = UIStackView(arrangedSubviews: [forgot, UIView(), switchMode])
        links.alignment = .center
        let column = Controls.column([titleLabel, intro, email, password, errorLabel, primary, links, or, google, facebook, demo])
        column.setCustomSpacing(DesignTokens.Space.s24, after: intro)
        column.setCustomSpacing(DesignTokens.Space.s24, after: links)
        Controls.host(column, in: self)
        applyMode()
        loadProviders()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
    }

    // MARK: Modes

    private func toggleMode() {
        signingUp.toggle()
        applyMode()
    }

    private func applyMode() {
        titleLabel.text = signingUp ? String(localized: "Create your account") : String(localized: "Sign in to HoldMyTrack")
        primary.configuration?.title = signingUp ? String(localized: "Create account") : String(localized: "Sign in")
        switchMode.configuration?.title = signingUp ? String(localized: "Already have an account? Sign in") : String(localized: "Don't have an account? Create one")
        password.textContentType = signingUp ? .newPassword : .password
        forgot.isHidden = signingUp
        showError(nil)
        updateEnabled()
    }

    private func updateEnabled() {
        let filled = !(email.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty && !(password.text ?? "").isEmpty
        primary.isEnabled = filled && !busy
        for button in [demo, google, facebook, switchMode] { button.isEnabled = !busy }
    }

    private func showError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = message == nil
        if let message { UIAccessibility.post(notification: .announcement, argument: message) }
    }

    // MARK: Ways in

    private func loadProviders() {
        Task {
            // A failed request shows neither provider (apps/android/docs/SPEC.md FR-1.1).
            let providers = (try? await flow.api.providers()) ?? .none
            google.isHidden = !providers.google
            facebook.isHidden = !providers.facebook
            or.isHidden = !(providers.google || providers.facebook)
        }
    }

    private func submit() {
        guard primary.isEnabled else { return }
        let address = (email.text ?? "").trimmingCharacters(in: .whitespaces)
        let secret = password.text ?? ""
        let signingUp = signingUp
        run {
            signingUp
                ? try await $0.signup(email: address, password: secret, timezone: TimeZone.current.identifier)
                : try await $0.login(email: address, password: secret)
        }
    }

    private func startDemo() {
        run { try await $0.demo() }
    }

    /// Runs a sign-in, showing the server's message when it refuses.
    private func run(_ signIn: @escaping @MainActor (APIClient) async throws -> SessionGrant) {
        busy = true
        showError(nil)
        Task {
            defer { busy = false }
            do {
                flow.signedIn(try await signIn(flow.api))
            } catch let error as APIError {
                if error != .outdated {
                    showError(error.serverMessage ?? String(localized: "Could not sign in."))
                }
            } catch {
                showError(String(localized: "Could not sign in."))
            }
        }
    }

    /// The server's own Google or Facebook flow in the system's browser sheet, started with the
    /// challenge of a verifier only this screen holds; the code it ends with is redeemed with
    /// that verifier (root docs/IMPLEMENTATION.md §4.9).
    private func browserSignIn(_ provider: OAuth.Provider) {
        let verifier = OAuth.newVerifier()
        let start = OAuth.startURL(provider, base: flow.api.app.apiBaseURL, timezone: TimeZone.current.identifier, challenge: OAuth.challenge(for: verifier))
        let done: ASWebAuthenticationSession.CompletionHandler = { [weak self] url, error in
            Task { @MainActor in self?.finishBrowserSignIn(provider, verifier: verifier, url: url, error: error) }
        }
        let session = if #available(iOS 17.4, *) {
            ASWebAuthenticationSession(url: start, callback: .customScheme(OAuth.callbackScheme), completionHandler: done)
        } else {
            ASWebAuthenticationSession(url: start, callbackURLScheme: OAuth.callbackScheme, completionHandler: done)
        }
        session.presentationContextProvider = self
        browserSession = session
        busy = true
        showError(nil)
        if !session.start() {
            busy = false
            showError(Self.message(.failed(provider)))
        }
    }

    private func finishBrowserSignIn(_ provider: OAuth.Provider, verifier: String, url: URL?, error: Error?) {
        browserSession = nil
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            busy = false
            return
        }
        switch url.map({ OAuthRedirect.of($0, hasVerifier: true) }) ?? .showError(nil) {
        case .exchange(let code):
            busy = false
            run { try await $0.handoff(code: code, verifier: verifier) }
        case .showError(let code):
            busy = false
            showError(Self.message(OAuthFailure.of(code, provider: provider)))
        case .ignore:
            busy = false
        }
    }

    private static func message(_ failure: OAuthFailure) -> String {
        switch failure {
        case .noEmail:
            String(localized: "Your Facebook account didn't share an email address, and HoldMyTrack needs one. Try again and allow access to your email, or sign up with email and password.")
        case .emailInUse:
            String(localized: "An account with this email already exists. Sign in the way you usually do, or use “Forgot password?” to set a password.")
        case .failed(.google):
            String(localized: "Couldn't sign in with Google. Please try again.")
        case .failed(.facebook):
            String(localized: "Couldn't sign in with Facebook. Please try again.")
        }
    }

    private func openForgot() {
        present(SFSafariViewController(url: flow.api.app.apiBaseURL.appending(path: "forgot")), animated: true)
    }
}
