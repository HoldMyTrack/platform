import HoldMyTrackCore
import SafariServices
import UIKit

/// The theme, kept on the phone rather than the account (root docs/SPEC.md FR-4.8), so the
/// demo account can change it too.
@MainActor
enum Theme: String, CaseIterable {
    case system, light, dark

    static var current: Theme {
        get { Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "theme")
            for scene in UIApplication.shared.connectedScenes {
                (scene as? UIWindowScene)?.windows.forEach(apply)
            }
        }
    }

    static func apply(to window: UIWindow) {
        window.overrideUserInterfaceStyle = switch current {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

/// The You tab (apps/android/docs/SPEC.md FR-2.9), in Android's order: the account (avatar, name,
/// email, "country · timezone · units") over its all-time numbers and recent weeks, the halves
/// opening Settings and Track graph & trends; Privacy with its count; App: Theme inline,
/// Language and Take a tour; HoldMyTrack's About, Help and Contacts as tiles; Sign out and
/// Delete account…; the build. The numbers and the Private locations are read on each showing.
/// No Donate: App Review allows payment links only through Apple's purchase system.
final class YouViewController: UITableViewController {
    private unowned let flow: AppFlow
    private var account: Account
    private var avatar: UIImage?
    /// Take a tour (TourController.request).
    var onTour: (() -> Void)?
    /// The account's tile version as the map last read it: a sync, upload, delete or edit moves
    /// it, so the numbers are read again (YouRefresh).
    var tileVersion: () -> String = { "" }
    /// When the account was last read.
    private var accountReadAtMs: Int64?
    /// When the numbers were last read, and against what.
    private var numbersRead: YouRefresh.Mark?
    /// A page was pushed over this one, or the app left: the next showing is a return.
    private var resumed = false
    private var numbersTask: Task<Void, Never>?
    private var privacyTask: Task<Void, Never>?

    private enum Row { case settings, profile, privacy, theme, language, tour, web, delete, signOut }
    private var sections: [[Row]] {
        [
            [.settings, .profile],
            [.privacy],
            [.theme, .language, .tour],
            [.web],
            [.signOut] + (account.isDemo ? [] : [.delete]),
        ]
    }

    /// The all-time numbers and recent weeks, once read (ProfileStats).
    private var totals: ProfileStats.Totals?
    private var weeks: [Int] = []
    /// How many Private locations, once read.
    private var privateCount: Int?
    /// About four months: as many weeks as fit beside the link on a phone.
    private static let recentWeeks = 16

    init(flow: AppFlow, account: Account) {
        self.flow = flow
        self.account = account
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = UIColor(resource: .bg)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.accessibilityIdentifier = "you"
        // The tab's title over the card, as Android's.
        let title = Controls.label(String(localized: "You"), font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink))
        title.accessibilityTraits = .header
        tableView.tableHeaderView = wrap(title, top: DesignTokens.Space.s8)
        tableView.tableFooterView = footer()
        loadAvatar()
        // A return to the app while You shows is a return, read as one.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.viewIfLoaded?.window != nil else { return }
                self.resumed = true
                self.load()
                self.resumed = false
            }
        }
        NotificationCenter.default.addObserver(forName: AppFlow.accountChanged, object: nil, queue: .main) { [weak self] note in
            let changed = note.userInfo?["account"] as? Account
            MainActor.assumeIsolated {
                guard let self, let account = changed else { return }
                self.account = account
                // A removed photo goes back to the initials.
                self.avatarView.image = nil
                self.loadAvatar()
                self.tableView.reloadData()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
        resumed = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resumed = navigationController.map { $0.topViewController !== self } ?? false
    }

    /// The account, which the web can change, and its numbers when they could have changed
    /// (YouRefresh), and the Private locations on every
    /// showing, since the map's editor changes them. A read overtaken by a newer one is dropped.
    private func load() {
        let zone = TimeZone(identifier: account.timezone) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let p = calendar.dateComponents([.year, .month, .day], from: Date())
        let today = String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
        let now = YouRefresh.Mark(atMs: Int64(Date().timeIntervalSince1970 * 1000), tileVersion: tileVersion(), today: today)
        let reads = YouRefresh.of(numbers: numbersRead, accountAtMs: accountReadAtMs, now: now, resumed: resumed)
        if reads.account {
            accountReadAtMs = now.atMs
            // A failed read is made again on the next showing.
            flow.refreshAccount { [weak self] read in
                // Not a newer read's mark: only this one's failure is made again.
                if !read, self?.accountReadAtMs == now.atMs { self?.accountReadAtMs = nil }
            }
        }
        if reads.numbers {
            numbersRead = now
            numbersTask?.cancel()
            numbersTask = Task { [weak self, api = flow.api!] in
                let days = try? await api.trackDays(from: "1970-01-01", to: "\(p.year!)-12-31")
                guard !Task.isCancelled, let self else { return }
                // A failed read is made again on the next showing.
                guard let days else { return self.numbersRead = nil }
                self.totals = ProfileStats.totals(days)
                self.weeks = ProfileStats.recentWeeks(days, today: today, weeks: Self.recentWeeks)
                self.tableView.reloadData()
            }
        }
        privacyTask?.cancel()
        privacyTask = Task { [weak self, api = flow.api!] in
            let locations = try? await api.privateLocations()
            guard !Task.isCancelled, let self, let locations else { return }
            self.privateCount = locations.count
            self.tableView.reloadData()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for view in [tableView.tableHeaderView, tableView.tableFooterView].compactMap({ $0 }) {
            let size = view.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            if abs(view.frame.height - size.height) > 0.5 {
                view.frame.size.height = size.height
                if view === tableView.tableHeaderView { tableView.tableHeaderView = view } else { tableView.tableFooterView = view }
            }
        }
    }

    /// Take a tour's row, scrolled into view, for the tour's last step to point at.
    func revealTour() {
        guard let path = tourPath else { return }
        tableView.scrollToRow(at: path, at: .middle, animated: false)
    }

    var tourCell: UITableViewCell? { tourPath.flatMap(tableView.cellForRow(at:)) }

    private var tourPath: IndexPath? {
        guard isViewLoaded else { return nil }
        for (section, rows) in sections.enumerated() {
            if let row = rows.firstIndex(of: .tour) { return IndexPath(row: row, section: section) }
        }
        return nil
    }

    // MARK: The account and its numbers

    private let avatarView = UIImageView()

    /// The account's half of the card: avatar, name, email and "country · timezone · units".
    private func accountView() -> UIView {
        avatarView.tintColor = UIColor(resource: .inkSecondary)
        avatarView.backgroundColor = UIColor(resource: .surfaceTint)
        avatarView.contentMode = .scaleAspectFill
        avatarView.layer.cornerRadius = 28
        avatarView.clipsToBounds = true
        avatarView.isAccessibilityElement = false
        let initials = Controls.label(AccountCard.initials(account.displayName.isEmpty ? account.email : account.displayName),
                                      font: Typeface.sans(DesignTokens.Text.lg, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .inkSecondary))
        initials.textAlignment = .center
        initials.isHidden = avatarView.image != nil
        let face = UIView()
        for v in [avatarView, initials] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            face.addSubview(v)
            NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: face.topAnchor), v.bottomAnchor.constraint(equalTo: face.bottomAnchor),
                                         v.leadingAnchor.constraint(equalTo: face.leadingAnchor), v.trailingAnchor.constraint(equalTo: face.trailingAnchor)])
        }
        face.widthAnchor.constraint(equalToConstant: 56).isActive = true
        face.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let name = Controls.label(account.isDemo ? String(localized: "The demo account") : (account.displayName.isEmpty ? account.email : account.displayName),
                                  font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink))
        name.accessibilityIdentifier = "account"
        var lines: [UIView] = [name]
        if !account.isDemo && !account.displayName.isEmpty { lines.append(Controls.body(account.email)) }
        let country = account.country.isEmpty ? nil : Locale.current.localizedString(forRegionCode: account.country) ?? account.country
        if let text = AccountCard.place(country: country, timezone: account.timezone, unit: PanelFormat(account: account).unit) {
            let place = Controls.label(text, font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
            place.numberOfLines = 0
            lines.append(place)
        }
        let text = Controls.column(lines, spacing: DesignTokens.Space.s2)
        let row = UIStackView(arrangedSubviews: [face, text])
        row.spacing = DesignTokens.Space.s16
        row.alignment = .center
        return row
    }

    /// The numbers' half: Tracks, Distance, Active days and Longest streak, the recent weeks
    /// and the link to Track graph & trends.
    private func statsView() -> UIView {
        let format = PanelFormat(account: account)
        func stat(_ label: String, _ value: String?) -> UIView {
            let number = Controls.label(value ?? "—", font: Typeface.sans(DesignTokens.Text.xl, weight: DesignTokens.Weight.semibold, relativeTo: .title3), color: UIColor(resource: .ink))
            number.adjustsFontSizeToFitWidth = true
            number.minimumScaleFactor = 0.6
            number.numberOfLines = 1
            let caption = Controls.label(label, font: Typeface.sans(DesignTokens.Text.xs, relativeTo: .caption2), color: UIColor(resource: .inkSecondary))
            caption.numberOfLines = 2
            let column = Controls.column([number, caption], spacing: 2)
            column.isAccessibilityElement = true
            column.accessibilityLabel = "\(label), \(value ?? "—")"
            return column
        }
        let t = totals
        let numbers = UIStackView(arrangedSubviews: [
            stat(String(localized: "you.tracks", defaultValue: "Tracks", comment: "The You tab's numbers: how many tracks."), t.map { format.count($0.count) }),
            stat(String(localized: "you.distance", defaultValue: "Distance", comment: "The You tab's numbers: the distance of them all."), t.map { format.totalDistance($0.distanceMeters) }),
            stat(String(localized: "you.activeDays", defaultValue: "Active days", comment: "The You tab's numbers: days with a track."), t.map { format.count($0.activeDays) }),
            stat(String(localized: "you.longestStreak", defaultValue: "Longest streak", comment: "The You tab's numbers: the most days in a row with a track."), t.map { format.count($0.longestStreakDays) }),
        ])
        numbers.distribution = .fillEqually
        numbers.spacing = DesignTokens.Space.s8
        numbers.accessibilityIdentifier = "youNumbers"
        let link = Controls.label(String(localized: "you.graphLink", defaultValue: "Track graph & trends", comment: "The You tab: the link to the track graph."),
                                  font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold, relativeTo: .body), color: UIColor(resource: .accent))
        let bottom = UIStackView(arrangedSubviews: [RecentWeeksView(levels: weeks), UIView(), link])
        bottom.alignment = .center
        bottom.spacing = DesignTokens.Space.s12
        return Controls.column([numbers, bottom], spacing: DesignTokens.Space.s12)
    }

    /// The version and the commit, how a report names the build.
    private func footer() -> UIView {
        let app = flow.api.app
        let label = Controls.label(String(localized: "Version \(app.version) (\(app.build)), commit \(app.commit)"),
                                   font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
        label.textAlignment = .center
        label.accessibilityIdentifier = "build"
        #if DEBUG
        // Whether the dev stack answers, which is how a Debug build shows where it points.
        let server = Controls.label(app.apiBaseURL.absoluteString, font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
        server.textAlignment = .center
        server.accessibilityIdentifier = "server"
        Task {
            let status = await ServerCheck.run(app, language: AppLanguage.current)
            server.text = "\(app.apiBaseURL.absoluteString): \(status)"
        }
        return wrap(Controls.column([label, server], spacing: DesignTokens.Space.s4), top: DesignTokens.Space.s8)
        #else
        return wrap(label, top: DesignTokens.Space.s8)
        #endif
    }

    private func wrap(_ content: UIView, top: CGFloat) -> UIView {
        let box = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: top),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -DesignTokens.Space.s16),
            content.leadingAnchor.constraint(equalTo: box.layoutMarginsGuide.leadingAnchor, constant: DesignTokens.Space.s8),
            content.trailingAnchor.constraint(equalTo: box.layoutMarginsGuide.trailingAnchor, constant: -DesignTokens.Space.s8),
        ])
        return box
    }

    private func loadAvatar() {
        guard !account.avatarURL.isEmpty else { return }
        Task {
            guard let data = try? await flow.api.data(path: account.avatarURL), let image = UIImage(data: data) else { return }
            avatarView.image = image
            tableView.reloadData()
        }
    }

    // MARK: Rows

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section].first {
        case .theme: String(localized: "you.sectionApp", defaultValue: "App", comment: "The You tab: the section for this app's settings.")
        case .web: "HoldMyTrack"
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.contentView.subviews.filter { $0.tag == Self.customTag }.forEach { $0.removeFromSuperview() }
        cell.contentConfiguration = nil
        cell.accessoryType = .disclosureIndicator
        cell.accessoryView = nil
        cell.selectionStyle = .default
        cell.backgroundColor = UIColor(resource: .surface)
        var config = UIListContentConfiguration.valueCell()
        config.textProperties.font = Typeface.sans(DesignTokens.Text.xl)
        config.imageProperties.tintColor = UIColor(resource: .inkSecondary)
        let row = sections[indexPath.section][indexPath.row]
        switch row {
        case .settings:
            host(accountView(), in: cell)
            cell.accessibilityIdentifier = "youSettings"
            return cell
        case .profile:
            host(statsView(), in: cell)
            cell.accessoryType = .none
            cell.accessibilityIdentifier = "youProfile"
            return cell
        case .privacy:
            config = UIListContentConfiguration.subtitleCell()
            config.textProperties.font = Typeface.sans(DesignTokens.Text.xl)
            config.secondaryTextProperties.color = UIColor(resource: .inkSecondary)
            (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Privacy"), UIImage(resource: .shield), "youPrivacy")
            config.secondaryText = privateCount.flatMap { $0 > 0 ? String(localized: "you.privacyCount", defaultValue: "\($0) private locations · your data", comment: "The You tab's Privacy row: how many Private locations.") : nil }
                ?? String(localized: "you.privacySub", defaultValue: "Private locations and your data", comment: "The You tab's Privacy row: what's there.")
            config.imageProperties.tintColor = UIColor(resource: .inkSecondary)
        case .theme:
            (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Theme"), UIImage(resource: .contrast), "youTheme")
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.accessoryView = themeControl()
        case .language:
            (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Language"), UIImage(resource: .globe), "youLanguage")
            config.secondaryText = Locale.current.localizedString(forLanguageCode: AppLanguage.current)?.localizedCapitalized
        case .tour: (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "you.tour", defaultValue: "Take a tour", comment: "The You tab: start the tour again."), UIImage(resource: .navigation), "youTour")
        case .web:
            host(webTiles(), in: cell)
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "youWeb"
            return cell
        case .delete:
            (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "you.delete", defaultValue: "Delete account…", comment: "The You tab: open Delete account."), UIImage(resource: .trash2), "youDelete")
            config.textProperties.color = UIColor(resource: .danger)
            config.imageProperties.tintColor = UIColor(resource: .danger)
            cell.accessoryType = .none
        case .signOut:
            (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Sign out"), nil, "signOut")
            cell.accessoryType = .none
        }
        cell.contentConfiguration = config
        return cell
    }

    private static let customTag = 4242

    /// A custom row's content inside its cell's margins.
    private func host(_ content: UIView, in cell: UITableViewCell) {
        content.tag = Self.customTag
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: DesignTokens.Space.s12),
            content.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -DesignTokens.Space.s12),
            content.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    /// Theme inline, as Android's toggle: this phone's choice, applied at once.
    private func themeControl() -> UISegmentedControl {
        let control = UISegmentedControl(items: Theme.allCases.map(\.title))
        control.selectedSegmentIndex = Theme.allCases.firstIndex(of: Theme.current) ?? 0
        control.accessibilityIdentifier = "themeControl"
        control.addAction(UIAction { action in
            guard let control = action.sender as? UISegmentedControl else { return }
            Theme.current = Theme.allCases[control.selectedSegmentIndex]
        }, for: .valueChanged)
        control.sizeToFit()
        return control
    }

    /// About, Help and Contacts side by side, as Android's tiles.
    private func webTiles() -> UIView {
        func tile(_ title: String, _ icon: ImageResource, id: String, _ run: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.tinted()
            config.image = Controls.icon(UIImage(resource: icon), size: 20)
            config.imagePlacement = .top
            config.imagePadding = DesignTokens.Space.s6
            config.title = title
            config.baseForegroundColor = UIColor(resource: .ink)
            config.baseBackgroundColor = UIColor(resource: .surfaceTint)
            config.cornerStyle = .medium
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in run() })
            button.accessibilityIdentifier = id
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            return button
        }
        let row = UIStackView(arrangedSubviews: [
            tile(String(localized: "About"), .info, id: "youAbout") { [weak self] in
                guard let self else { return }
                self.navigationController?.pushViewController(WebPageViewController(flow: self.flow, page: .about), animated: true)
            },
            tile(String(localized: "Help"), .circleHelp, id: "youHelp") { [weak self] in self?.browse("/help") },
            tile(String(localized: "Contacts"), .mail, id: "youContacts") { [weak self] in self?.browse("/contacts") },
        ])
        row.distribution = .fillEqually
        row.spacing = DesignTokens.Space.s8
        return row
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section][indexPath.row] {
        case .settings: navigationController?.pushViewController(WebPageViewController(flow: flow, page: .settings), animated: true)
        case .profile: navigationController?.pushViewController(WebPageViewController(flow: flow, page: .profile), animated: true)
        case .privacy: navigationController?.pushViewController(PrivacyViewController(flow: flow, account: account), animated: true)
        // D11: the app's language is iOS's per-app setting, in the system's Settings.
        case .language: UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        case .tour: onTour?()
        case .delete: confirmDelete()
        case .signOut: flow.signOut()
        case .theme, .web: break
        }
    }

    /// A page of the site over the app, as Android's browser tab.
    private func browse(_ path: String) {
        present(SFSafariViewController(url: flow.api.app.apiBaseURL.appending(path: String(path.dropFirst()))), animated: true)
    }

    // MARK: Delete account (root docs/SPEC.md FR-1.12)

    /// Android's dialog: what goes, and how to confirm, by typing the account's email. The
    /// server judges the email; a refusal brings the dialog back with why. On success the phone
    /// forgets the account and Sign in says it was deleted. An Apple-linked account's
    /// authorization is revoked by the server.
    private func confirmDelete(error: String? = nil) {
        let hint = String(localized: "delete.hint", defaultValue: "Deletes your account and everything in it, for good: every track and the files you uploaded, your photos, Trips, Private locations and captured places, and the recordings on this phone that haven't synced. It can't be undone, and backups keep it for up to 8 weeks.",
                          comment: "Delete account: what goes.")
        let confirm = String(localized: "delete.confirm", defaultValue: "You'll be signed out everywhere, and everything in the account will be gone within a few minutes. To confirm, type your email address, \(account.email).",
                             comment: "Delete account: how to confirm, with the account's email.")
        let alert = UIAlertController(title: String(localized: "delete.title", defaultValue: "Delete account", comment: "Delete account: the dialog's title."),
                                      message: [hint, confirm, error].compactMap { $0 }.joined(separator: "\n\n"), preferredStyle: .alert)
        var deleteAction: UIAlertAction!
        alert.addTextField { field in
            field.placeholder = String(localized: "delete.email", defaultValue: "Email address", comment: "Delete account: the email field.")
            field.keyboardType = .emailAddress
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "deleteEmail"
            field.addAction(UIAction { _ in
                deleteAction.isEnabled = !(field.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }, for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        deleteAction = UIAlertAction(title: String(localized: "delete.submit", defaultValue: "Delete", comment: "Delete account: the button."), style: .destructive) { [weak self, weak alert] _ in
            guard let self else { return }
            let typed = alert?.textFields?.first?.text ?? ""
            Task {
                do {
                    try await self.flow.api.deleteAccount(email: typed.trimmingCharacters(in: .whitespaces))
                    self.flow.accountDeleted()
                } catch {
                    self.confirmDelete(error: (error as? APIError)?.serverMessage ?? String(localized: "The account couldn't be deleted. Try again."))
                }
            }
        }
        deleteAction.isEnabled = false
        alert.addAction(deleteAction)
        present(alert, animated: true)
    }
}