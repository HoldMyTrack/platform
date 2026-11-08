import HoldMyTrackCore
import SafariServices
import UIKit
import WebKit

/// One of the site's own pages in the app (root docs/SPEC.md FR-10.8, ADR-0042): Settings, a new
/// account's first run included, Activity graph & trends, Sync history and About. The server
/// renders a page for the app when it carries the `hmt_app` cookie; this screen hands the web view
/// the session as the cookie a browser would hold (apps/ios/docs/IMPLEMENTATION.md §1.4).
///
/// Where a link goes is the shared webPageRoute rule (WebPageSession.route): the page's own path
/// stays, the map closes the page onto the native map, anything else opens in Safari. A failed
/// load shows an error with Try again, never a blank page. The page follows the app's theme: a
/// web view answers `prefers-color-scheme` from its own trait collection.
final class WebPageViewController: UIViewController, WKNavigationDelegate {
    private unowned let flow: AppFlow
    let page: SitePage
    private let onboarding: Bool
    /// Sync history's View on map; the map takes it from there.
    var onViewOnMap: ((_ activity: String, _ day: String) -> Void)?

    private var web: WKWebView!
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let errorView = UIStackView()
    private let errorText = Controls.body(color: UIColor(resource: .ink))
    /// Set once a navigation has sent the user elsewhere: one can arrive twice.
    private var leaving = false
    private var failed = false
    private var loadedOnce = false

    init(flow: AppFlow, page: SitePage, onboarding: Bool = false) {
        self.flow = flow
        self.page = page
        self.onboarding = onboarding
        super.init(nibName: nil, bundle: nil)
        title = onboarding ? String(localized: "Set up your account") : Self.title(page)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func title(_ page: SitePage) -> String {
        switch page {
        case .settings: String(localized: "Settings")
        case .profile: String(localized: "Activity graph & trends")
        case .syncHistory: String(localized: "Sync history")
        case .about: String(localized: "About")
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        // A store of its own, gone with the page: the session cookie never outlives a sign-out
        // or reaches another account.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: view.bounds, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = UIColor(resource: .bg)
        web.scrollView.backgroundColor = UIColor(resource: .bg)
        web.accessibilityIdentifier = "webPage"
        web.allowsBackForwardNavigationGestures = false

        errorView.axis = .vertical
        errorView.spacing = DesignTokens.Space.s12
        errorView.alignment = .center
        errorText.textAlignment = .center
        errorText.accessibilityIdentifier = "webPageError"
        let retry = Controls.secondaryButton(String(localized: "Try again"), id: "webPageRetry")
        retry.addAction(UIAction { [weak self] _ in self?.load() }, for: .primaryActionTriggered)
        errorView.addArrangedSubview(errorText)
        errorView.addArrangedSubview(retry)
        errorView.isHidden = true

        for v in [web!, spinner, errorView] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: guide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            errorView.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if loadedOnce && page.refreshOnReturn && !failed { web.reload() }
        loadedOnce = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Settings may have changed the units, the name, the Country or the language.
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true { flow.refreshAccount() }
    }

    /// The cookies first, then the page.
    private func load() {
        failed = false
        errorView.isHidden = true
        web.isHidden = false
        spinner.startAnimating()
        guard let token = flow.store.stored?.token else { return close() }
        let base = flow.api.app.apiBaseURL
        let secure = base.scheme == "https"
        let store = web.configuration.websiteDataStore.httpCookieStore
        let cookies = WebPageSession.cookies(token: token, language: AppLanguage.current).compactMap { cookie -> HTTPCookie? in
            var props: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value, .domain: base.host ?? "", .path: "/", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax]
            if secure { props[.secure] = "TRUE" }
            if cookie.httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: props)
        }
        Task {
            for cookie in cookies { await store.setCookie(cookie) }
            web.load(URLRequest(url: base.appending(path: String(page.path.dropFirst()))))
        }
    }

    // MARK: Where links go

    /// Acts on where a navigation to url goes; true when this screen took it from the web view.
    private func route(_ url: URL) -> Bool {
        let route = WebPageSession.route(url, base: flow.api.app.apiBaseURL, page: page, leaving: leaving, onboarding: onboarding)
        switch route {
        case .stay: return false
        case .ignore: break
        case .outside: openOutside(url)
        case .close:
            leaving = true
            close()
        case .viewOnMap(let activity, let day):
            leaving = true
            onViewOnMap?(activity, day)
            if navigationController?.viewControllers.first !== self { close() }
            leaving = false
        // The map gates on a Country only the server has heard of: the session is read first.
        case .onboarded:
            leaving = true
            flow.check()
        }
        return true
    }

    /// The sign-in pages or the map: back to the app, whose session check knows what to do.
    private func close() {
        if onboarding {
            flow.check()
        } else if let nav = navigationController, nav.viewControllers.first !== self {
            nav.popViewController(animated: true)
        } else if presentingViewController != nil {
            dismiss(animated: true)
        } else {
            flow.check()
            leaving = false
        }
    }

    private func openOutside(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            present(SFSafariViewController(url: url), animated: true)
        } else {
            UIApplication.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame ?? true, let url = action.request.url else { return .allow }
        // A link that opens a new window has no frame: it's outside by definition.
        if action.targetFrame == nil {
            openOutside(url)
            return .cancel
        }
        return route(url) ? .cancel : .allow
    }

    /// A form's redirect, Settings' first-run save going on to `/`, is checked here too.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url, route(url) { webView.stopLoading() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    /// Offline or failing: an error with Try again, never the web view's blank page. A load this
    /// screen cancelled itself isn't one.
    private func fail(_ error: Error) {
        spinner.stopAnimating()
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled, code != 102 /* WebKitErrorFrameLoadInterruptedByPolicyChange */ else { return }
        failed = true
        web.isHidden = true
        errorText.text = String(localized: "This page couldn't load. Check your connection and try again.")
        errorView.isHidden = false
    }
}