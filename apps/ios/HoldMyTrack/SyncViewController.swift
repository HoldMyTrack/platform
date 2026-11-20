import HoldMyTrackCore
import UIKit

/// The Sync tab (apps/ios/docs/SPEC.md FR-5.2): the recordings on this phone, newest first, each
/// ticked to send and opened to edit, with Download GPX and Delete; Send for the ticked ones; then
/// Upload and Sync history. A recording sent and awaited isn't listed; the line under the list
/// says how many are on their way. The demo edits and deletes, with nothing to tick or send.
final class SyncViewController: UITableViewController {
    private unowned let flow: AppFlow
    private let account: Account
    private let recordings: RecordingsSync
    /// Sync history's View on map, handed to the page each time it opens.
    var onViewOnMap: ((String, String) -> Void)?

    private enum Row { case recording(RecordedTrack), empty, upload, history }
    private var sections: [[Row]] = []
    private let sendButton = Controls.primaryButton("", id: "syncSend")

    init(flow: AppFlow, account: Account, recordings: RecordingsSync) {
        self.flow = flow
        self.account = account
        self.recordings = recordings
        super.init(style: .insetGrouped)
        title = String(localized: "Sync")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = UIColor(resource: .bg)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.accessibilityIdentifier = "sync"
        sendButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Task { await self.recordings.send() }
        }, for: .primaryActionTriggered)
        NotificationCenter.default.addObserver(forName: RecordingsSync.changed, object: recordings, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private var format: PanelFormat { PanelFormat(account: account) }

    private func reload() {
        let listed = recordings.listed
        // The demo can't upload, as the You tab leaves out too.
        sections = [listed.isEmpty ? [.empty] : listed.map(Row.recording), (account.isDemo ? [] : [.upload]) + [.history]]
        tableView.reloadData()
        renderSend()
    }

    // MARK: Send

    private func renderSend() {
        let count = recordings.ticked.count
        sendButton.configuration?.title = recordings.sending
            ? String(localized: "sync.sending", defaultValue: "Sending…", comment: "Sync: recordings being sent.")
            : String(localized: "sync.send", defaultValue: "Send \(count)", comment: "Sync: send the ticked recordings, and how many.")
        sendButton.isEnabled = !recordings.sending && RecordingSync.canSend(ticked: recordings.ticked, isDemo: recordings.isDemo)
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard section == 0 else { return nil }
        var views: [UIView] = []
        let awaited = recordings.awaited
        if awaited > 0 {
            let line = Controls.body(String(localized: "sync.onTheirWay", defaultValue: "Being added to your map: \(awaited)", comment: "Sync: recordings the server took, still processing, written as label: N."))
            line.accessibilityIdentifier = "syncOnTheirWay"
            views.append(line)
        }
        if !recordings.isDemo, !recordings.listed.isEmpty { views.append(sendButton) }
        guard !views.isEmpty else { return nil }
        let column = Controls.column(views, spacing: DesignTokens.Space.s8)
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: DesignTokens.Space.s12, leading: DesignTokens.Space.s16, bottom: DesignTokens.Space.s12, trailing: DesignTokens.Space.s16)
        return column
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? String(localized: "sync.onThisPhone", defaultValue: "Recorded on this phone", comment: "Sync: the heading over the recordings.") : nil
    }

    // MARK: Rows

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    /// A row's title: the name typed for it, else when it started.
    static func title(_ track: RecordedTrack, format: PanelFormat) -> String {
        if let name = track.name, !name.isEmpty { return name }
        return track.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var config = UIListContentConfiguration.subtitleCell()
        config.textProperties.font = Typeface.sans(DesignTokens.Text.xl)
        config.secondaryTextProperties.color = UIColor(resource: .inkSecondary)
        cell.backgroundColor = UIColor(resource: .surface)
        cell.accessoryView = nil
        cell.accessoryType = .none
        switch sections[indexPath.section][indexPath.row] {
        case .recording(let track):
            config.text = Self.title(track, format: format)
            var detail = [TrackTypes.shared.label(track.type), format.distance(track.meters), format.duration(Int(track.movingSeconds))].joined(separator: " · ")
            if let refusal = recordings.refusals[track.id] { detail += "\n" + Self.words(refusal) }
            config.secondaryText = detail
            config.image = TrackTypes.icon(TrackTypes.shared.kind(track.type))
            config.imageProperties.tintColor = UIColor(resource: .inkSecondary)
            cell.accessibilityIdentifier = "recordingRow"
            if !recordings.isDemo {
                let on = recordings.ticked.contains(track.id)
                let tick = UIButton(type: .system)
                tick.setImage(UIImage(systemName: on ? "checkmark.circle.fill" : "circle"), for: .normal)
                tick.tintColor = UIColor(resource: on ? .accent : .inkMuted)
                tick.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
                tick.accessibilityLabel = String(localized: "sync.tick", defaultValue: "Send", comment: "Sync: a recording's tick box, ticked to send it.")
                tick.accessibilityTraits = on ? [.button, .selected] : .button
                tick.accessibilityIdentifier = "recordingTick"
                tick.addAction(UIAction { [weak self] _ in self?.toggle(track.id) }, for: .primaryActionTriggered)
                cell.accessoryView = tick
            }
        case .empty:
            config.text = String(localized: "sync.empty", defaultValue: "Nothing recorded on this phone. The record button on the tab bar records a track.", comment: "Sync: no recordings.")
            config.textProperties.color = UIColor(resource: .inkSecondary)
            config.textProperties.font = Typeface.sans(DesignTokens.Text.lg)
            cell.accessibilityIdentifier = "syncEmpty"
        case .upload:
            (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Upload"), UIImage(resource: .upload), "syncUpload")
            cell.accessoryType = .disclosureIndicator
        case .history:
            (config.text, config.image, cell.accessibilityIdentifier) = (String(localized: "Sync history"), UIImage(resource: .history), "syncHistory")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = config
        return cell
    }

    static func words(_ refusal: RecordingSync.Refusal) -> String {
        switch refusal {
        case .tooManyPoints: String(localized: "sync.tooManyPoints", defaultValue: "Not sent: over \(RecordingSync.maxPoints) points.", comment: "Sync: a recording too long to send, and the limit.")
        case .server(let message): message ?? String(localized: "sync.refused", defaultValue: "Not sent.", comment: "Sync: the server refused a recording, giving no reason.")
        }
    }

    private func toggle(_ id: String) {
        guard !recordings.sending else { return }
        if recordings.ticked.contains(id) { recordings.ticked.remove(id) } else { recordings.ticked.insert(id) }
        reload()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section][indexPath.row] {
        case .recording(let track):
            guard !recordings.isSending(track.id) else { return }
            edit(track)
        case .empty: break
        case .upload:
            navigationController?.pushViewController(UploadViewController(api: flow.api), animated: true)
        case .history:
            let page = WebPageViewController(flow: flow, page: .syncHistory)
            page.onViewOnMap = onViewOnMap
            navigationController?.pushViewController(page, animated: true)
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .recording(let track) = sections[indexPath.section][indexPath.row], !recordings.isSending(track.id) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "recording.delete", defaultValue: "Delete", comment: "A recording: delete it from the phone.")) { [weak self] _, _, done in
            self?.confirmDelete(track)
            done(false)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .recording(let track) = sections[indexPath.section][indexPath.row], !recordings.isSending(track.id) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "recording.edit", defaultValue: "Edit", comment: "A recording: edit its name, description and type."), image: UIImage(systemName: "pencil")) { _ in self?.edit(track) },
                UIAction(title: String(localized: "recording.gpx", defaultValue: "Download GPX", comment: "A recording: save its route as GPX."), image: UIImage(systemName: "square.and.arrow.down")) { _ in self?.downloadGPX(track) },
                UIAction(title: String(localized: "recording.delete", defaultValue: "Delete", comment: "A recording: delete it from the phone."), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.confirmDelete(track) },
            ])
        })
    }

    // MARK: Actions

    func edit(_ track: RecordedTrack) {
        let editor = RecordingEditViewController(track: track, account: account, recordings: recordings)
        editor.onGPX = { [weak self] track in self?.downloadGPX(track) }
        editor.onDelete = { [weak self] track in self?.confirmDelete(track) }
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    /// Delete asks first: the phone's copy is the only one.
    func confirmDelete(_ track: RecordedTrack) {
        let alert = UIAlertController(title: String(localized: "recording.discardTitle", defaultValue: "Discard this recording?", comment: "Discarding an unfinished recording: the question."),
                                      message: String(localized: "recording.discardMessage", defaultValue: "The track will be deleted from this device. This can't be undone.", comment: "Discarding an unfinished recording: why it asks."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "recording.delete", defaultValue: "Delete", comment: "A recording: delete it from the phone."), style: .destructive) { [weak self] _ in
            self?.presentedViewController?.dismiss(animated: true)
            self?.recordings.delete(track.id)
        })
        (presentedViewController ?? self).present(alert, animated: true)
    }

    /// The route as GPX, through the share sheet: Save to Files among its choices.
    func downloadGPX(_ track: RecordedTrack) {
        let name = Self.title(track, format: format)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let file = FileManager.default.temporaryDirectory.appending(path: "\(safe).gpx")
        do {
            try RecordingSync.gpx(track, name: name).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file) }
        (presentedViewController ?? self).present(share, animated: true)
    }
}