import HoldMyTrackCore
import SafariServices
import UIKit

/// Privacy (apps/android/docs/SPEC.md FR-1.7), in Android's order: what a Private location does;
/// the account's locations, each a row with its circle drawn small (CirclePreviewView) that opens
/// the editor on the map (MapViewController+PrivateLocations), and Add a location on the map, with
/// how many tracks they hide entirely and that a change reprocesses; what HoldMyTrack keeps; then
/// Your data: Download your data and the privacy policy. Read again each time the screen shows.
/// The demo account sees its locations read-only, with no Add and no download.
final class PrivacyViewController: UITableViewController {
    private unowned let flow: AppFlow
    private let account: Account
    private var locations: [PrivateLocation] = []
    private var note: (text: String, failed: Bool)? = (String(localized: "Loading…"), false)
    /// How many tracks lie entirely inside the locations, once read; a failure leaves it out.
    private var hidden: Int?

    private enum Section: Int, CaseIterable { case locations, keeps, data }
    private enum Row { case location(PrivateLocation), note(String, failed: Bool), add, keep(String, ImageResource), download, policy }

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
        let subtitle = Controls.body(String(localized: "privacy.subtitle", defaultValue: "Tracks never start or end inside these circles — the part inside is clipped off every track, so nobody can trace a track back to your door.",
                                            comment: "Privacy: what a Private location does."))
        subtitle.numberOfLines = 0
        let box = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(subtitle)
        NSLayoutConstraint.activate([
            subtitle.topAnchor.constraint(equalTo: box.topAnchor, constant: DesignTokens.Space.s8),
            subtitle.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -DesignTokens.Space.s4),
            subtitle.leadingAnchor.constraint(equalTo: box.layoutMarginsGuide.leadingAnchor, constant: DesignTokens.Space.s8),
            subtitle.trailingAnchor.constraint(equalTo: box.layoutMarginsGuide.trailingAnchor, constant: -DesignTokens.Space.s8),
        ])
        tableView.tableHeaderView = box
        // The circle previews are drawn in this appearance's colours: drawn again on a change.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.tableView.reloadData() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let size = header.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if abs(header.frame.height - size.height) > 0.5 {
            header.frame.size.height = size.height
            tableView.tableHeaderView = header
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
                note = locations.isEmpty ? (String(localized: "privacy.none", defaultValue: "None yet.", comment: "Privacy: no Private locations."), false) : nil
            } catch {
                note = ((error as? APIError)?.serverMessage ?? String(localized: "Private locations couldn't load."), true)
            }
            // The last visit's count could be wrong for the locations just read.
            hidden = nil
            tableView.reloadData()
            // Only a line of context: the screen works without it.
            hidden = locations.isEmpty ? nil : try? await flow.api.hiddenTrackCount()
            tableView.reloadData()
        }
    }

    private func rows(_ section: Section) -> [Row] {
        switch section {
        case .locations:
            return locations.map(Row.location) + (note.map { [Row.note($0.text, failed: $0.failed)] } ?? []) + (PrivacyScreen.offersAdd(demo: account.isDemo) ? [.add] : [])
        case .keeps:
            return [
                .keep(String(localized: "privacy.keepsMap", defaultValue: "Nobody else sees your map.", comment: "What HoldMyTrack keeps: the map is yours."), .eyeOff),
                .keep(String(localized: "privacy.keepsHealth", defaultValue: "No heart rate or other health data is ever read or stored.", comment: "What HoldMyTrack keeps: no health data."), .shield),
                .keep(String(localized: "privacy.keepsPhotos", defaultValue: "Photos are kept as a resized copy, never the original.", comment: "What HoldMyTrack keeps: photos."), .camera),
            ]
        case .data:
            return (PrivacyScreen.offersDownload(demo: account.isDemo) ? [.download] : []) + [.policy]
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .locations: String(localized: "Private locations")
        case .keeps: String(localized: "privacy.keepsTitle", defaultValue: "What HoldMyTrack keeps", comment: "Privacy: the section of what's kept and what isn't.")
        case .data: String(localized: "privacy.yourData", defaultValue: "Your data", comment: "Privacy: the section with the download and the policy.")
        }
    }

    /// Under the locations: how many tracks they hide entirely, and that a change reprocesses.
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .locations,
              let footer = PrivacyScreen.footer(locations: locations.count, hidden: hidden, demo: account.isDemo) else { return nil }
        var lines: [String] = []
        if let hidden = footer.hidden {
            lines.append(hidden == 0
                ? String(localized: "privacy.hiddenNone", defaultValue: "No track lies entirely inside these locations.", comment: "Privacy: no track is wholly private.")
                : String(localized: "privacy.hidden", defaultValue: "\(hidden) tracks lie entirely inside these locations and show as Private.", comment: "Privacy: how many tracks are wholly private."))
        }
        if footer.reprocess {
            lines.append(String(localized: "privacy.reprocess", defaultValue: "Saving a change reprocesses the tracks it touches — they show Pending until done.", comment: "Privacy: what a change to a location does."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows(Section(rawValue: section)!).count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var config = UIListContentConfiguration.subtitleCell()
        config.textProperties.font = Typeface.sans(DesignTokens.Text.xl)
        config.secondaryTextProperties.color = UIColor(resource: .inkSecondary)
        config.imageProperties.tintColor = UIColor(resource: .inkSecondary)
        cell.backgroundColor = UIColor(resource: .surface)
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.accessibilityIdentifier = nil
        switch rows(Section(rawValue: indexPath.section)!)[indexPath.row] {
        case .location(let location):
            config.text = location.name.isEmpty ? String(localized: "Unnamed") : location.name
            config.secondaryText = String(localized: "privacy.rowMeta", defaultValue: "Radius · \(location.radiusM) m", comment: "Privacy: a location's radius.")
            config.image = CirclePreviewView.image(radiusM: location.radiusM)
            config.imageProperties.tintColor = nil
            config.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            cell.accessoryType = account.isDemo ? .none : .disclosureIndicator
            cell.selectionStyle = account.isDemo ? .none : .default
            cell.accessibilityIdentifier = "privateLocation"
        case .note(let text, let failed):
            config.text = text
            config.textProperties.font = Typeface.sans(DesignTokens.Text.md)
            config.textProperties.color = UIColor(resource: failed ? .danger : .inkSecondary)
            cell.selectionStyle = .none
        case .add:
            config = UIListContentConfiguration.cell()
            config.text = String(localized: "privacy.add", defaultValue: "Add a location on the map", comment: "Privacy: add a Private location on the map.")
            config.textProperties.color = UIColor(resource: .accent)
            config.textProperties.font = Typeface.sans(DesignTokens.Text.xl)
            config.image = UIImage(resource: .plus)
            config.imageProperties.tintColor = UIColor(resource: .accent)
            cell.accessibilityIdentifier = "addLocation"
        case .keep(let text, let icon):
            config = UIListContentConfiguration.cell()
            config.text = text
            config.textProperties.font = Typeface.sans(DesignTokens.Text.md)
            config.image = UIImage(resource: icon)
            config.imageProperties.tintColor = UIColor(resource: .inkSecondary)
            cell.selectionStyle = .none
        case .download:
            config.text = String(localized: "Download your data")
            config.secondaryText = String(localized: "privacy.downloadSub", defaultValue: "A copy of everything, emailed when it's ready", comment: "Privacy: what Download your data does.")
            config.image = UIImage(resource: .download)
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "downloadData"
        case .policy:
            config.text = String(localized: "Privacy policy")
            config.image = UIImage(resource: .shield)
            cell.accessibilityIdentifier = "privacyPolicy"
        }
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows(Section(rawValue: indexPath.section)!)[indexPath.row] {
        case .location(let location) where !account.isDemo: edit(location)
        case .add: edit(nil)
        case .download: navigationController?.pushViewController(DataExportViewController(api: flow.api, email: account.email), animated: true)
        case .policy: present(SFSafariViewController(url: flow.api.app.apiBaseURL.appending(path: "privacy")), animated: true)
        default: break
        }
    }

    /// The map, with the editor on location or a new one (nil): this screen gives way to it.
    private func edit(_ location: PrivateLocation?) {
        (tabBarController as? MainTabBarController)?.editPrivateLocation(location?.id)
    }
}

/// A Private location as a picture rather than a map, for its Privacy row: a tile with two
/// streets across it and the circle in the map's purple, larger the larger its radius
/// (PrivateLocation.previewShare), as Android's CirclePreviewView.
enum CirclePreviewView {
    static func image(radiusM: Int, side: CGFloat = 44) -> UIImage {
        let purple = UIColor(red: 0x7a / 255, green: 0x4b / 255, blue: 0xc2 / 255, alpha: 1)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            UIBezierPath(roundedRect: rect, cornerRadius: 10).addClip()
            UIColor(resource: .surfaceTintStrong).setFill()
            context.fill(rect)
            let street = UIBezierPath()
            street.move(to: CGPoint(x: 0, y: side * 0.6)); street.addLine(to: CGPoint(x: side, y: side * 0.5))
            street.move(to: CGPoint(x: side * 0.35, y: 0)); street.addLine(to: CGPoint(x: side * 0.5, y: side))
            street.lineWidth = 3
            UIColor(resource: .surface).setStroke()
            street.stroke()
            let r = 5 + PrivateLocation.previewShare(radiusM: radiusM) * (side / 2 - 7)
            let circle = UIBezierPath(arcCenter: CGPoint(x: side / 2, y: side / 2), radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            purple.withAlphaComponent(0.22).setFill()
            circle.fill()
            purple.setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            // The centre, solid, as Android's.
            purple.setFill()
            UIBezierPath(arcCenter: CGPoint(x: side / 2, y: side / 2), radius: 2.5, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// Download your data (root docs/SPEC.md FR-1.13), a screen of its own as on Android, in its
/// words: asks for a copy, checks it every 10 seconds while it's being prepared and the screen
/// shows, and hands each ready part to the share sheet, whose Save to Files keeps it.
final class DataExportViewController: UIViewController {
    private let api: APIClient
    /// Where the server emails that the archive is ready.
    private let email: String
    private let status = Controls.body(color: UIColor(resource: .ink))
    private let request = Controls.primaryButton(String(localized: "dataExport.request", defaultValue: "Request a download", comment: "Download your data: ask for an archive."), id: "requestExport")
    private let parts = Controls.column([], spacing: DesignTokens.Space.s8)
    private var poll: Task<Void, Never>?

    init(api: APIClient, email: String) {
        self.api = api
        self.email = email
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Download your data")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        status.accessibilityIdentifier = "exportStatus"
        let about = Controls.body(String(localized: "dataExport.hint", defaultValue: "A copy of everything in your account, as zip archives: the files you uploaded or synced, every track as GPX, your photos, and your settings, Trips, Private locations and captured places.",
                                         comment: "Download your data: what the archive holds."))
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
                    showError(String(localized: "The server couldn't be reached."))
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
                showError((error as? APIError)?.serverMessage ?? String(localized: "The download couldn't be prepared."))
            }
        }
    }

    /// An error, shown even when no archive's state had a line.
    private func showError(_ text: String) {
        status.text = text
        status.textColor = UIColor(resource: .danger)
        status.isHidden = false
    }

    private static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    private func show(_ export: ExportStatus) {
        status.textColor = UIColor(resource: export.state == .failed ? .danger : .ink)
        status.text = switch DataExportText.status(export) {
        case .none: ""
        case .preparing: String(localized: "dataExport.preparing", defaultValue: "Preparing your archive. It usually takes a few minutes; we'll email \(email) when it's ready, and it will be here too.", comment: "Download your data: being prepared, and the email told when it's ready.")
        case .ready(let bytes, let until):
            if let until {
                String(localized: "dataExport.ready", defaultValue: "Ready, \(Self.size(bytes)) in all. Download until \(until.formatted(date: .abbreviated, time: .omitted)):", comment: "Download your data: ready, its size and until when.")
            } else {
                String(localized: "dataExport.readyNoDate", defaultValue: "Ready, \(Self.size(bytes)) in all:", comment: "Download your data: ready, and its size, the date unknown.")
            }
        case .failed: String(localized: "dataExport.failed", defaultValue: "Your last download couldn't be prepared. Please try again, and if it fails again, let us know.", comment: "Download your data: the last one failed.")
        }
        status.isHidden = status.text?.isEmpty ?? true
        request.isHidden = !DataExportText.offersRequest(export.state)
        var config = request.configuration
        config?.title = DataExportText.requestsAgain(export.state)
            ? String(localized: "dataExport.again", defaultValue: "Request a new one", comment: "Download your data: ask for a fresh archive.")
            : String(localized: "dataExport.request", defaultValue: "Request a download", comment: "Download your data: ask for an archive.")
        request.configuration = config
        parts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard export.state == .ready else { return }
        for part in export.parts {
            let size = ByteCountFormatter.string(fromByteCount: Int64(part.size), countStyle: .file)
            let button = Controls.secondaryButton(String(localized: "dataExport.download", defaultValue: "Download \(part.n) of \(export.parts.count) (\(size))", comment: "Download your data: one part, of how many, and its size."),
                                                  id: "exportPart", icon: UIImage(resource: .download))
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
                TripDialogs.inform(over: view, (error as? APIError)?.serverMessage ?? String(localized: "The part couldn't be downloaded."))
            }
        }
    }
}