import HoldMyTrackCore
import SafariServices
import UIKit

/// The theme, kept on the phone rather than the account (root docs/SPEC.md FR-4.12), so the
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

/// The You tab (apps/android/docs/SPEC.md FR-2.9): the account, Upload, Privacy, the theme,
/// Language, About, Help and Contacts, the build, Delete account and Sign out. No Donate: App
/// Review allows payment links only through Apple's purchase system.
final class YouViewController: UITableViewController {
    private unowned let flow: AppFlow
    private let account: Account
    private var avatar: UIImage?

    private enum Row { case upload, privacy, theme, language, about, help, contacts, delete, signOut }
    private var sections: [[Row]] {
        let real = !account.isDemo
        return [
            (real ? [.upload] : []) + [.privacy],
            [.theme, .language],
            [.about, .help, .contacts],
            (real ? [.delete] : []) + [.signOut],
        ]
    }

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
        tableView.tableHeaderView = header()
        tableView.tableFooterView = footer()
        loadAvatar()
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

    // MARK: Header and footer

    private let avatarView = UIImageView()

    /// The account card: avatar, name and email.
    private func header() -> UIView {
        avatarView.image = UIImage(resource: .user)
        avatarView.tintColor = UIColor(resource: .inkSecondary)
        avatarView.backgroundColor = UIColor(resource: .surfaceTint)
        avatarView.contentMode = .scaleAspectFill
        avatarView.layer.cornerRadius = 28
        avatarView.clipsToBounds = true
        avatarView.widthAnchor.constraint(equalToConstant: 56).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: 56).isActive = true
        avatarView.isAccessibilityElement = false
        let name = Controls.label(account.isDemo ? String(localized: "The demo account") : (account.displayName.isEmpty ? account.email : account.displayName),
                                  font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink))
        name.accessibilityIdentifier = "account"
        var lines: [UIView] = [name]
        if !account.isDemo && !account.displayName.isEmpty { lines.append(Controls.body(account.email)) }
        let text = Controls.column(lines, spacing: DesignTokens.Space.s2)
        let row = UIStackView(arrangedSubviews: [avatarView, text])
        row.spacing = DesignTokens.Space.s16
        row.alignment = .center
        return wrap(row, top: DesignTokens.Space.s24)
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
        }
    }

    /// Upload with files already picked; the demo account is told it can't.
    func upload(_ files: [URL]) {
        guard !account.isDemo else {
            StoryDialogs.inform(over: view, String(localized: "The demo account can't upload. Sign up to add your own activities."))
            return
        }
        navigationController?.popToRootViewController(animated: false)
        let screen = UploadViewController(api: flow.api)
        navigationController?.pushViewController(screen, animated: true)
        screen.send(files)
    }

    // MARK: Rows

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var config = UIListContentConfiguration.valueCell()
        config.textProperties.font = Typeface.sans(DesignTokens.Text.xl)
        config.imageProperties.tintColor = UIColor(resource: .inkSecondary)
        cell.accessoryType = .disclosureIndicator
        cell.accessoryView = nil
        cell.backgroundColor = UIColor(resource: .surface)
        let row = sections[indexPath.section][indexPath.row]
        switch row {
        case .upload: (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Upload"), UIImage(resource: .upload), "youUpload")
        case .privacy: (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Privacy"), UIImage(resource: .shield), "youPrivacy")
        case .theme:
            (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Theme"), UIImage(resource: .contrast), "youTheme")
            config.secondaryText = Theme.current.title
            cell.accessoryType = .none
        case .language:
            (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Language"), UIImage(resource: .globe), "youLanguage")
            config.secondaryText = Locale.current.localizedString(forLanguageCode: AppLanguage.current)?.localizedCapitalized
        case .about: (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "About"), UIImage(resource: .info), "youAbout")
        case .help: (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Help"), UIImage(resource: .circleHelp), "youHelp")
        case .contacts: (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Contacts"), UIImage(resource: .mail), "youContacts")
        case .delete:
            (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Delete account"), UIImage(resource: .trash2), "youDelete")
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

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section][indexPath.row] {
        case .upload: navigationController?.pushViewController(UploadViewController(api: flow.api), animated: true)
        case .privacy: navigationController?.pushViewController(PrivacyViewController(flow: flow, account: account), animated: true)
        case .theme: pickTheme(at: indexPath)
        // D11: the app's language is iOS's per-app setting, in the system's Settings.
        case .language: UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        case .about: present(SFSafariViewController(url: page("/about")), animated: true)
        case .help: UIApplication.shared.open(page("/help"))
        case .contacts: UIApplication.shared.open(page("/contacts"))
        case .delete: confirmDelete()
        case .signOut: flow.signOut()
        }
    }

    private func page(_ path: String) -> URL { flow.api.app.apiBaseURL.appending(path: String(path.dropFirst())) }

    private func pickTheme(at indexPath: IndexPath) {
        let sheet = UIAlertController(title: String(localized: "Theme"), message: nil, preferredStyle: .actionSheet)
        for theme in Theme.allCases {
            let action = UIAlertAction(title: theme.title, style: .default) { [weak self] _ in
                Theme.current = theme
                self?.tableView.reloadRows(at: [indexPath], with: .none)
            }
            action.setValue(theme == Theme.current, forKey: "checked")
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        present(sheet, animated: true)
    }

    // MARK: Delete account (root docs/SPEC.md FR-1.11)

    /// Confirmed by typing the account's email; on success the phone forgets the account and
    /// signs out. An Apple-linked account's authorization is revoked by the server.
    private func confirmDelete(error: String? = nil) {
        let alert = UIAlertController(
            title: String(localized: "Delete your account?"),
            message: error ?? String(localized: "Your activities, Stories, photos and settings are deleted for good. Type \(account.email) to confirm."),
            preferredStyle: .alert
        )
        var deleteAction: UIAlertAction!
        alert.addTextField { [account] field in
            field.placeholder = String(localized: "Email")
            field.keyboardType = .emailAddress
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "deleteEmail"
            field.addAction(UIAction { _ in
                deleteAction.isEnabled = AccountKey.confirms(typed: field.text ?? "", email: account.email)
            }, for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        deleteAction = UIAlertAction(title: String(localized: "Delete account"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await self.flow.api.deleteAccount(email: self.account.email)
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