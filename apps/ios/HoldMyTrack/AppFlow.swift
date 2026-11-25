import HoldMyTrackCore
import UIKit

/// Which screen the window shows, from the session's route (SessionRoute), and the moves between
/// them: signing in, confirming a restored token, signing out, and the Update screen.
@MainActor
final class AppFlow {
    private let window: UIWindow
    let store = SessionStore()
    private(set) var api: APIClient!
    /// The check under way, which a second caller waits for.
    private var checking: Task<APIError?, Never>?
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
        api.forgetCookies(in: .shared)
        MapNetwork.install(api: api)
        Uploads.shared.api = api
        Uploads.shared.reconnect()
        NotificationCenter.default.addObserver(forName: Uploads.outdated, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showUpdate() }
        }
    }

    /// Files opened or shared from another app wait here until the signed-in app shows.
    private var openedFiles: [URL] = []

    /// The Live Activity's Stop: the signed-in screen asks first.
    func askToStopRecording() {
        (window.rootViewController as? MainTabBarController)?.askToStop()
    }

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

    /// The phone forgets the session, and the uploads it queued go with it.
    private func endSession() {
        if let token = store.stored?.token { Uploads.shared.drop(token: token) }
        store.clear()
    }

    /// Shows the screen the session's route calls for; a restored token is checked first.
    func show() {
        switch store.route {
        case .signIn:
            setRoot(SignInViewController(flow: self, notice: signInNotice))
            signInNotice = nil
        case .verify:
            if let stored = store.stored { setRoot(SessionCheckMapViewController(flow: self, stored: stored)) }
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
        if let checking { return await checking.value }
        guard store.stored != nil else { return nil }
        let check = Task { await runCheck() }
        checking = check
        defer { checking = nil }
        return await check.value
    }

    private func runCheck() async -> APIError? {
        let token = store.stored?.token
        (window.rootViewController as? SessionCheckScreen)?.checkStarted()
        let before = store.route
        do {
            let account = try await api.me()
            guard store.stored?.token == token else { return nil }
            store.confirm(account)
            if store.route != before { show() }
            return nil
        } catch let error as APIError {
            // Signed out meanwhile: the answer is the last session's.
            guard store.stored?.token == token else { return nil }
            if SessionCheck.signsOut(error) {
                endSession()
                show()
            } else {
                (window.rootViewController as? SessionCheckScreen)?.checkFailed(error)
            }
            return error
        } catch {
            (window.rootViewController as? SessionCheckScreen)?.checkFailed(.unreachable)
            return .unreachable
        }
    }

    /// The account the server answered a verification code with: confirmed, the flow moves on
    /// without asking again, which a check already running would skip.
    func verified(_ account: Account) {
        store.confirm(account)
        show()
    }

    /// A request refused for the session itself: the phone forgets it, as the check does.
    func sessionEnded() {
        endSession()
        show()
    }

    /// Posted with the account, read again (refreshAccount), when it changed.
    static let accountChanged = Notification.Name("AppFlow.accountChanged")

    /// The account read again once a site page closes or You shows, since Settings, here or on the
    /// web, can change the units, the name, the Country or the language; the screens that show it hear accountChanged.
    /// done hears whether it was read.
    func refreshAccount(done: ((Bool) -> Void)? = nil) {
        guard store.route == .home else { return }
        let token = store.stored?.token
        Task {
            let read = try? await api.me()
            // Signed out meanwhile: the answer is the last session's.
            guard store.stored?.token == token else { return }
            done?(read != nil)
            guard let account = read else { return }
            let before = store.confirmed
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
        endSession()
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

    /// Whether the signed-in screen going next keeps a recording in progress, as Stop would:
    /// false only for a deleted account.
    private var keepsRecording = true

    private func setRoot(_ controller: UIViewController) {
        // The sign-in keyboard would otherwise stay up over the next screen's bottom for a moment.
        window.endEditing(true)
        (window.rootViewController as? MainTabBarController)?.endRecording(save: keepsRecording)
        window.rootViewController = controller
        if updateShown { presentUpdate(animated: false) }
        presentOpenedFiles()
    }

    /// Said once on the next Sign in, such as after Delete account.
    private var signInNotice: String?

    /// The account was deleted: the phone forgets what it kept for it and signs out, with no
    /// logout request, since the server ended every session.
    func accountDeleted() {
        if let stored = store.stored {
            let account = AccountKey.of(email: stored.email, isDemo: stored.isDemo)
            MapDocuments.forget(account: account)
            EmptyNoticeDismissal.forget(account: account)
            RecordingController.defaultStore.forget(account: account)
        }
        endSession()
        keepsRecording = false
        signInNotice = String(localized: "account.deleted", defaultValue: "Your account was deleted. Everything in it will be gone within a few minutes.", comment: "Sign in, after Delete account.")
        show()
        keepsRecording = true
    }
}

/// A screen that shows why a session check failed and offers Try again.
@MainActor
protocol SessionCheckScreen: AnyObject {
    func checkStarted()
    func checkFailed(_ error: APIError)
}

extension SessionCheckScreen {
    func checkStarted() {}
}

extension APIError {
    /// What a failed request says on a screen: the server's own message when it sent one.
    var shownMessage: String {
        serverMessage ?? String(localized: "Couldn't reach HoldMyTrack. Check your connection and try again.")
    }
}
