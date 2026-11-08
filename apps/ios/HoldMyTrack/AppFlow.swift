import HoldMyTrackCore
import UIKit

/// Which screen the window shows, from the session's route (SessionRoute), and the moves between
/// them: signing in, confirming a restored token, signing out, and the Update screen.
@MainActor
final class AppFlow {
    private let window: UIWindow
    let store = SessionStore()
    private(set) var api: APIClient!
    private var checking = false
    private var updateShown = false

    init(window: UIWindow) {
        self.window = window
        let token = store.token
        api = APIClient(
            app: .current,
            language: AppLanguage.current,
            token: { token.get() },
            onOutdated: { [weak self] in Task { @MainActor in self?.showUpdate() } }
        )
        MapNetwork.install(api: api)
    }

    /// Shows the screen the session's route calls for; a restored token is checked first.
    func show() {
        switch store.route {
        case .signIn:
            setRoot(SignInViewController(flow: self))
        case .verify:
            setRoot(CheckingViewController(flow: self))
            check()
        case .verifyEmail:
            if let account = store.confirmed { setRoot(VerifyEmailViewController(flow: self, email: account.email)) }
        case .onboarding, .home:
            // The first run's Settings page comes with the site's pages (ROADMAP.md, phase 6);
            // until then the first run goes to the map too.
            if let account = store.confirmed { setRoot(MainTabBarController(flow: self, account: account)) }
        }
    }

    /// A sign-in succeeded.
    func signedIn(_ grant: SessionGrant) {
        store.start(grant)
        show()
    }

    /// Asks the server about the kept token. Only a 401 ends the session; any other failure keeps
    /// it and says so, for Try again or the next return to the app (apps/android/docs/SPEC.md
    /// FR-1.2).
    func check() {
        Task { await recheck() }
    }

    /// The check, for a screen that waits on its answer: nil once the server has confirmed the
    /// account, the failure otherwise. The screen changes only when the route does, so a screen
    /// that asked keeps its place to say "not yet".
    @discardableResult
    func recheck() async -> APIError? {
        guard !checking, store.stored != nil else { return nil }
        checking = true
        defer { checking = false }
        let before = store.route
        do {
            store.confirm(try await api.me())
            if store.route != before { show() }
            return nil
        } catch let error as APIError {
            if SessionCheck.signsOut(error) {
                store.clear()
                show()
            } else {
                (window.rootViewController as? SessionCheckScreen)?.checkFailed(error)
            }
            return error
        } catch {
            return .unreachable
        }
    }

    /// The app came back to the foreground: a session not yet confirmed, or an email not yet
    /// verified, is asked about again.
    func resumed() {
        switch store.route {
        case .verify, .verifyEmail: check()
        default: break
        }
    }

    /// Ends the session on the server and forgets it on the phone at once, whether or not the
    /// server heard (apps/android/docs/SPEC.md FR-1.3).
    func signOut() {
        if let token = store.stored?.token {
            let api = api!
            Task.detached { try? await api.logout(token: token) }
        }
        store.clear()
        show()
    }

    /// The server turned this build away: the Update screen over whatever shows, once, and over
    /// every screen after it for the rest of the run (apps/android/docs/SPEC.md FR-1.8).
    func showUpdate() {
        guard !updateShown else { return }
        updateShown = true
        presentUpdate(animated: true)
    }

    private func presentUpdate(animated: Bool) {
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard !(top is UpdateViewController) else { return }
        let update = UpdateViewController()
        update.modalPresentationStyle = .fullScreen
        update.isModalInPresentation = true
        top?.present(update, animated: animated)
    }

    private func setRoot(_ controller: UIViewController) {
        // The sign-in keyboard would otherwise stay up over the next screen's bottom for a moment.
        window.endEditing(true)
        window.rootViewController = controller
        if updateShown { presentUpdate(animated: false) }
    }
}

/// A screen that shows why a session check failed and offers Try again.
@MainActor
protocol SessionCheckScreen: AnyObject {
    func checkFailed(_ error: APIError)
}
