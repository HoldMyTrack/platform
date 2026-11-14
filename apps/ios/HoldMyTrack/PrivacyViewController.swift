import HoldMyTrackCore
import SafariServices
import UIKit

/// Privacy (apps/android/docs/SPEC.md FR-1.7): Private locations, read again each time the screen
/// shows, a row or Add opening the editor on the map (MapViewController+PrivateLocations);
/// Download your data; the privacy policy. The demo account sees its Private locations read-only
/// and no download.
final class PrivacyViewController: UITableViewController {
    private unowned let flow: AppFlow
    private let account: Account
    private var locations: [PrivateLocation] = []
    private var note: (text: String, failed: Bool)? = (String(localized: "Loading…"), false)

    private enum Section: Int, CaseIterable { case locations, data }

    init(flow: AppFlow, account: Account) {
        self.flow = flow
        self.account = account
        super.init(style: .insetGrouped)
        title = String(localized: "Privacy")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = UIColor(resource: .bg)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.accessibilityIdentifier = "privacy"
        if !account.isDemo {
            let add = UIBarButtonItem(image: UIImage(resource: .plus), primaryAction: UIAction { [weak self] _ in self?.edit(nil) })
            add.accessibilityLabel = String(localized: "Add a Private location")
            add.accessibilityIdentifier = "addLocation"
            navigationItem.rightBarButtonItem = add
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        Task {
            do {
                locations = try await flow.api.privateLocations()
                note = locations.isEmpty ? (String(localized: "No Private locations yet. Where a track starts or ends inside one, that part is hidden everywhere, your own map included."), false) : nil
            } catch {
                note = ((error as? APIError)?.serverMessage ?? String(localized: "Private locations couldn't load."), true)
            }
            tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section) == .locations ? String(localized: "Private locations") : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .locations: locations.count + (note == nil ? 0 : 1)
        case .data: account.isDemo ? 1 : 2
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var config = UIListContentConfiguration.subtitleCell()
        config.textProperties.font = Typeface.sans(DesignTokens.Text.xl)
        cell.backgroundColor = UIColor(resource: .surface)
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.accessibilityIdentifier = nil
        switch Section(rawValue: indexPath.section)! {
        case .locations:
            if indexPath.row < locations.count {
                let location = locations[indexPath.row]
                config.text = location.name.isEmpty ? String(localized: "Unnamed") : location.name
                config.secondaryText = String(localized: "Radius: \(location.radiusM) m")
                config.image = UIImage(resource: .mapPin)
                cell.accessibilityIdentifier = "privateLocation"
                cell.selectionStyle = account.isDemo ? .none : .default
            } else if let note {
                config.text = note.text
                config.textProperties.font = Typeface.sans(DesignTokens.Text.md)
                config.textProperties.color = UIColor(resource: note.failed ? .danger : .inkSecondary)
                cell.selectionStyle = .none
            }
        case .data:
            if indexPath.row == 0 && !account.isDemo {
                config.text = String(localized: "Download your data")
                config.image = UIImage(resource: .download)
                cell.accessoryType = .disclosureIndicator
                cell.accessibilityIdentifier = "downloadData"
            } else {
                config.text = String(localized: "Privacy policy")
                config.image = UIImage(resource: .shield)
                cell.accessibilityIdentifier = "privacyPolicy"
            }
        }
        config.imageProperties.tintColor = UIColor(resource: .inkSecondary)
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .locations:
            guard indexPath.row < locations.count, !account.isDemo else { return }
            edit(locations[indexPath.row])
        case .data:
            if indexPath.row == 0 && !account.isDemo {
                navigationController?.pushViewController(DataExportViewController(api: flow.api), animated: true)
            } else {
                present(SFSafariViewController(url: flow.api.app.apiBaseURL.appending(path: "privacy")), animated: true)
            }
        }
    }

    /// The map, with the editor on location or a new one (nil): this screen gives way to it.
    private func edit(_ location: PrivateLocation?) {
        (tabBarController as? MainTabBarController)?.editPrivateLocation(location?.id)
    }
}

/// Download your data (root docs/SPEC.md FR-1.13): asks for a copy, checks it every 10 seconds
/// while it's being prepared and the screen shows, and hands each ready part to the share sheet,
/// whose Save to Files keeps it.
final class DataExportViewController: UIViewController {
    private let api: APIClient
    private let status = Controls.body(color: UIColor(resource: .ink))
    private let request = Controls.primaryButton(String(localized: "Prepare a download"), id: "requestExport")
    private let parts = Controls.column([], spacing: DesignTokens.Space.s8)
    private var poll: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Download your data")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        status.accessibilityIdentifier = "exportStatus"
        let about = Controls.body(String(localized: "A copy of your activities, Stories, photos and settings, as zip files. We email you when it's ready; the download lasts 7 days."))
        request.addAction(UIAction { [weak self] _ in self?.ask() }, for: .primaryActionTriggered)
        Controls.host(Controls.column([about, status, request, parts]), in: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        check()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        poll?.cancel()
    }

    private func check() {
        poll?.cancel()
        poll = Task {
            while !Task.isCancelled {
                guard let export = try? await api.exportStatus() else {
                    status.text = String(localized: "The server couldn't be reached.")
                    return
                }
                show(export)
                guard export.state == .preparing else { return }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func ask() {
        request.isEnabled = false
        Task {
            defer { request.isEnabled = true }
            do {
                show(try await api.requestExport())
                check()
            } catch {
                status.text = (error as? APIError)?.serverMessage ?? String(localized: "The download couldn't be prepared.")
            }
        }
    }

    private func show(_ export: ExportStatus) {
        status.textColor = UIColor(resource: export.state == .failed ? .danger : .ink)
        status.text = switch export.state {
        case .none: String(localized: "No download prepared yet.")
        case .preparing: String(localized: "Preparing your download… It can take a few minutes.")
        case .ready: String(localized: "Ready. Save each part to Files.")
        case .failed: String(localized: "The last download couldn't be prepared. Try again.")
        }
        request.isHidden = export.state == .preparing
        var config = request.configuration
        config?.title = export.state == .ready ? String(localized: "Prepare a new download") : String(localized: "Prepare a download")
        request.configuration = config
        parts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard export.state == .ready else { return }
        for part in export.parts {
            let size = ByteCountFormatter.string(fromByteCount: Int64(part.size), countStyle: .file)
            let button = Controls.secondaryButton("\(part.name) (\(size))", id: "exportPart", icon: UIImage(resource: .download))
            button.addAction(UIAction { [weak self] _ in self?.save(part, from: button) }, for: .primaryActionTriggered)
            parts.addArrangedSubview(button)
        }
    }

    private func save(_ part: ExportStatus.Part, from button: UIButton) {
        button.isEnabled = false
        Task {
            defer { button.isEnabled = true }
            do {
                let file = try await api.download(part)
                let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = button
                share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                present(share, animated: true)
            } catch {
                StoryDialogs.inform(over: view, (error as? APIError)?.serverMessage ?? String(localized: "The part couldn't be downloaded."))
            }
        }
    }
}