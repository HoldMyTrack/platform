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
        Uploads.shared.api = api
        Uploads.shared.reconnect()
        NotificationCenter.default.addObserver(forName: Uploads.outdated, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showUpdate() }
        }
    }

    /// Files opened or shared from another app wait here until the signed-in app shows.
    private var openedFiles: [URL] = []

    /// Upload, over the signed-in app, for files from Files or another app; kept until signed in.
    func openFiles(_ urls: [URL]) {
        openedFiles += urls
        presentOpenedFiles()
    }

    private func presentOpenedFiles() {
        guard !openedFiles.isEmpty, let tabs = window.rootViewController as? MainTabBarController else { return }
        let files = openedFiles
        openedFiles = []
        tabs.upload(files)
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
        case .onboarding:
            // The first run: Settings, and only its save, which reaches the map, gets past it.
            let settings = UINavigationController(rootViewController: WebPageViewController(flow: self, page: .settings, onboarding: true))
            settings.isModalInPresentation = true
            setRoot(settings)
        case .home:
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

    /// Posted with the account, read again after a site page closed, when it changed.
    static let accountChanged = Notification.Name("AppFlow.accountChanged")

    /// The account read again once a site page closes, since Settings can change the units, the
    /// name, the Country or the language; the screens that show it hear accountChanged.
    func refreshAccount() {
        guard store.route == .home else { return }
        let before = store.confirmed
        Task {
            guard let account = try? await api.me() else { return }
            store.confirm(account)
            if store.route != .home { return show() }
            if account != before { NotificationCenter.default.post(name: Self.accountChanged, object: nil, userInfo: ["account": account]) }
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
        presentOpenedFiles()
    }

    /// The account was deleted: the phone forgets what it kept for it and signs out, with no
    /// logout request, since the server ended every session.
    func accountDeleted() {
        if let stored = store.stored {
            MapDocuments.forget(account: AccountKey.of(email: stored.email, isDemo: stored.isDemo))
        }
        store.clear()
        show()
    }
}

/// A screen that shows why a session check failed and offers Try again.
@MainActor
protocol SessionCheckScreen: AnyObject {
    func checkFailed(_ error: APIError)
}
