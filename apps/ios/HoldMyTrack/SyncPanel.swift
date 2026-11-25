import HoldMyTrackCore
import UIKit

/// The sheet's Sync tab, opened from Library's head (apps/android/docs/SPEC.md FR-3.5): every
/// recording on this phone not on the map yet, newest first. Recordings send themselves
/// (RecordingsSync); each row says how far it got, with Retry over them. Type chips narrow the
/// list; a row swiped aside is hidden, with Undo, and Show hidden brings it back. One sent stays
/// listed, on its way, until it lands. Upload heads it, beside its title. What a row offers is SyncList's. The rows are drawn dashed on the map (SyncLines), the first
/// showing framed; a tap on a row or its line picks it out, and ⓘ says what else covers its time
/// (SyncSimilar, and the server for the account's tracks).
@MainActor
final class SyncPanel: NSObject, UITableViewDataSource, UITableViewDelegate {
    enum Event {
        /// ‹: Library again, in Sync's place.
        case library
        /// Upload, over Sync as a sheet.
        case upload
        /// A row hidden or back: said over the map, with Undo.
        case hid(String, undo: () -> Void)
        /// The rows to draw on the map, highlight picked out.
        case lines([RecordedTrack], highlight: String?)
        /// The camera onto this box.
        case frame([Double])
        /// A message over the map.
        case say(String)
        /// The account's track a row overlaps, opened on the Tracks tab on its day.
        case openOnMap(TrackOverlap)
    }

    var onEvent: ((Event) -> Void)?
    let head = UIStackView()
    let content = UIView()

    private let recordings: RecordingsSync
    private let api: APIClient
    private let account: Account
    private weak var host: UIViewController?
    private let table = UITableView(frame: .zero, style: .plain)
    /// How many recordings aren't sent yet, or that they're going, with Retry.
    private let unsentLine = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold, relativeTo: .body), color: UIColor(resource: .ink))
    private let retry = Controls.iconButton(UIImage(resource: .refreshCw), label: String(localized: "sync.retry", defaultValue: "Send recordings again", comment: "Sync: the button that sends the recordings not sent yet now."), id: "syncRetry")
    private let bar: UIStackView

    private var showing = false
    private var types: Set<String> = []
    private var showHidden = false
    /// Sent recordings whose ingest failed, said over the list until the tab next opens.
    private var failedLines: [String] = []
    private var list = SyncList.of([], hidden: [], showHidden: false, types: [])
    /// The hidden rows as last read, so a render reads the phone's list once.
    private var hidden: Set<String> = []
    /// The types last asked about, so a render asks again only when the list's types change.
    private var describedTypes: Set<String>?
    /// The row picked out on the list and the map.
    private var highlight: String?
    /// The camera framed this showing's rows already.
    private var framed = false
    /// The other waiting rows each one overlaps, by id, as last rendered.
    private var similar: [String: [RecordedTrack]] = [:]
    /// The account's track each row overlaps, as the server last answered, and for which rows.
    private var overlaps: [String: TrackOverlap] = [:]
    private var overlapsAsked: Set<String>?
    private var overlapsTask: Task<Void, Never>?
    /// Delete's question while it's up.
    private weak var deleteAlert: UIAlertController?

    private enum Item {
        case notice(String, id: String, failed: Bool)
        case filters
        case row(RecordedTrack)
        case note(String)
        case showHidden
    }
    private var items: [Item] = []

    init(recordings: RecordingsSync, api: APIClient, account: Account, host: UIViewController) {
        self.recordings = recordings
        self.api = api
        self.account = account
        self.host = host
        unsentLine.numberOfLines = 0
        unsentLine.accessibilityIdentifier = "syncUnsent"
        unsentLine.accessibilityTraits.insert(.updatesFrequently)
        retry.setContentHuggingPriority(.required, for: .horizontal)
        bar = UIStackView(arrangedSubviews: [unsentLine, retry])
        bar.alignment = .center
        super.init()
        head.axis = .vertical
        head.spacing = DesignTokens.Space.s8
        // Sync opens from Library's head (apps/android/docs/SPEC.md FR-4.1); ‹ goes back to it.
        let back = Controls.iconButton(UIImage(resource: .chevronLeft), label: String(localized: "sync.back", defaultValue: "Back to Library", comment: "Sync: the ‹ that goes back to Library."), id: "syncBack")
        back.addAction(UIAction { [weak self] _ in self?.onEvent?(.library) }, for: .primaryActionTriggered)
        // Upload heads the sheet, apart from the recordings' Retry (apps/android/docs/SPEC.md FR-3.5).
        let upload = Controls.secondaryButton(String(localized: "Upload"), id: "syncUpload", icon: UIImage(resource: .upload))
        upload.addAction(UIAction { [weak self] _ in self?.onEvent?(.upload) }, for: .primaryActionTriggered)
        upload.isHidden = account.isDemo
        let title = UIStackView(arrangedSubviews: [back, Controls.label(String(localized: "Sync"), font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink)), UIView(), upload])
        title.alignment = .center
        head.addArrangedSubview(title)
        head.addArrangedSubview(bar)
        retry.addAction(UIAction { [weak self] _ in self?.retryAll() }, for: .primaryActionTriggered)

        table.dataSource = self
        table.delegate = self
        table.register(SyncRowCell.self, forCellReuseIdentifier: SyncRowCell.reuse)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
        table.register(UITableViewCell.self, forCellReuseIdentifier: "filters")
        table.backgroundColor = .clear
        table.accessibilityIdentifier = "sync"
        table.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: content.topAnchor),
            table.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        NotificationCenter.default.addObserver(forName: RecordingsSync.changed, object: recordings, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        NotificationCenter.default.addObserver(forName: TrackTypes.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    // MARK: Showing

    /// The tab showed, from another tab or a launch: every type, hidden rows put away.
    func start() {
        showing = true
        describedTypes = nil
        highlight = nil
        framed = false
        // The account's tracks may have changed since: an answer is asked for again, not kept.
        overlaps = [:]
        overlapsAsked = nil
        types = []
        showHidden = false
        failedLines = []
        takeFailed()
        render()
    }

    func stop() {
        showing = false
        overlapsTask?.cancel()
        onEvent?(.lines([], highlight: nil))
    }

    private func changed() {
        takeFailed()
        render()
    }

    /// Sent recordings whose ingest failed: back on the list, and said over it.
    private func takeFailed() {
        guard showing else { return }
        failedLines += recordings.takeFailed().map {
            String(localized: "sync.rowFailed", defaultValue: "Couldn't add \(Self.date($0)) \(TrackTypes.shared.label($0.type)): something went wrong on our side. It's back on the list to try again.",
                   comment: "Sync: a sent recording's ingest failed; its start and type.")
        }
    }

    func render() {
        guard showing else { return }
        let all = recordings.all
        let listedTypes = Set(all.map(\.type))
        if listedTypes != describedTypes {
            describedTypes = listedTypes
            TrackTypes.shared.refresh(Array(listedTypes), api: api)
        }
        hidden = recordings.hidden
        list = SyncList.of(all, hidden: hidden, showHidden: showHidden, types: types, inFlight: recordings.inFlight)
        types = list.pickedTypes(types)
        similar = SyncSimilar.waiting(list.comparable)
        // An answer about a row no longer compared, hidden since or filtered out, goes.
        let comparable = Set(list.comparable.map(\.id))
        overlaps = overlaps.filter { comparable.contains($0.key) }
        askOverlaps(list.comparable)

        var items: [Item] = []
        if account.isDemo {
            items.append(.notice(String(localized: "sync.demo", defaultValue: "The demo account is read-only — it can't add, edit, or delete tracks. Create an account to sync your own data.", comment: "Sync: the demo account can't send."), id: "syncDemo", failed: false))
        }
        if !failedLines.isEmpty { items.append(.notice(failedLines.joined(separator: "\n"), id: "syncProblems", failed: true)) }
        if list.types.count > 1 { items.append(.filters) }
        items += list.shown.map(Item.row)
        if list.everything.isEmpty {
            items.append(.note(String(localized: "sync.listEmpty", defaultValue: "Nothing waiting. Recordings show up here until they're on your map.", comment: "Sync: nothing on the phone to send.")))
        }
        if list.hiddenCount > 0 || showHidden { items.append(.showHidden) }
        self.items = items
        table.reloadData()
        renderBar()
        let drawn = list.drawn
        onEvent?(.lines(drawn, highlight: highlight))
        if !framed, let box = SyncLines.box(drawn) {
            framed = true
            onEvent?(.frame(box))
        }
    }

    /// The account's track each offered row overlaps (`POST /v2/tracks/overlaps`), asked again
    /// when the rows change, or on the next render after a failure. A hint only: when the server
    /// can't say, the rows go without it.
    private func askOverlaps(_ offered: [RecordedTrack]) {
        let ids = Set(offered.map(\.id))
        guard !account.isDemo, ids != overlapsAsked else { return }
        overlapsAsked = ids
        overlapsTask?.cancel()
        overlapsTask = Task { [weak self, api] in
            let answer = try? await api.trackOverlaps(offered)
            guard !Task.isCancelled, let self else { return }
            guard let answer else {
                self.overlapsAsked = nil
                self.overlaps = [:]
                self.table.reloadData()
                return
            }
            self.overlaps = answer
            self.table.reloadData()
        }
    }

    /// The recordings not sent yet, sent by themselves, or now on Retry.
    private func renderBar() {
        let unsent = RecordingSends.waiting(list.everything, hidden: hidden, isDemo: account.isDemo)
        bar.isHidden = unsent == 0
        unsentLine.text = recordings.sending
            ? String(localized: "sync.sending", defaultValue: "Sending recordings…", comment: "Sync: recordings are being sent now.")
            : String(localized: "sync.unsent", defaultValue: "\(unsent) recordings not sent yet", comment: "Sync: how many recordings aren't sent yet.")
        retry.isEnabled = !recordings.sending
    }

    /// What a row's note says.
    private static func words(_ note: RecordingSends.Note) -> String {
        switch note {
        case .processing: String(localized: "sync.processing", defaultValue: "Adding to your map…", comment: "Sync: a sent row on its way to the map.")
        case .sending: String(localized: "sync.rowSending", defaultValue: "Sending…", comment: "Sync: a recording being sent now.")
        case .waiting: String(localized: "sync.rowWaiting", defaultValue: "Not sent yet. It goes the next time the app opens with a connection.", comment: "Sync: a recording not sent yet, no connection most likely.")
        case .refused(let refusal): String(localized: "sync.rowRefused", defaultValue: "Not sent: \(words(refusal))", comment: "Sync: a recording the server refused, and why.")
        }
    }

    private static func words(_ refusal: RecordingSync.Refusal) -> String {
        switch refusal {
        case .tooManyPoints: String(localized: "sync.tooManyPoints", defaultValue: "over \(RecordingSync.maxPoints) points", comment: "Sync: why a recording wasn't sent: too long, and the limit.")
        case .ingestFailed: String(localized: "sync.ingestFailed", defaultValue: "the server couldn't add it", comment: "Sync: why a recording is back on the list: its processing failed.")
        case .server(let message): message ?? String(localized: "sync.refused", defaultValue: "the server gave no reason", comment: "Sync: the server refused a recording, giving no reason.")
        }
    }

    static func date(_ track: RecordedTrack) -> String { PanelFormat.dateTime(track.startedAt) }

    /// A row's title: the name typed for it, else when it started.
    static func title(_ track: RecordedTrack) -> String {
        if let name = track.name, !name.isEmpty { return name }
        return date(track)
    }

    private func row(_ track: RecordedTrack) -> SyncRowCell.Row {
        let named = !(track.name ?? "").isEmpty
        let format = PanelFormat(account: account)
        let meta = [named ? Self.date(track) : nil, format.distance(track.meters), TrackTypes.shared.label(track.type),
                    String(localized: "sync.recorded", defaultValue: "Recorded on this phone", comment: "Sync: where a row comes from.")]
            .compactMap { $0 }.joined(separator: " · ")
        let hidden = hidden.contains(track.id)
        return SyncRowCell.Row(
            id: track.id, title: Self.title(track), meta: meta,
            note: recordings.note(track).map(Self.words),
            processing: track.sent || recordings.isSending(track.id), kind: TrackTypes.shared.kind(track.type),
            hidden: hidden, editable: list.canEdit(track),
            similar: SyncSimilar.count(track, waiting: similar, onMap: overlaps[track.id] != nil),
            highlighted: track.id == highlight
        )
    }

    // MARK: Actions

    private func retryAll() {
        failedLines = []
        recordings.send(retry: true)
        render()
    }

    /// A row tapped, or its ⓘ's pick: picked out on the list and the map, the camera on it.
    private func pick(_ track: RecordedTrack) {
        highlight = track.id
        render()
        if let box = SyncLines.box([track]) { onEvent?(.frame(box)) }
        scroll(to: track.id)
    }

    /// A line tapped on the map: its row picked out and scrolled to.
    func focus(_ id: String) {
        highlight = id
        render()
        scroll(to: id)
    }

    private func scroll(to id: String) {
        guard let index = items.firstIndex(where: { if case .row(let t) = $0 { t.id == id } else { false } }) else { return }
        table.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: true)
    }

    /// A row's ⓘ: what else covers its time, a waiting row picked out here, the account's track
    /// opened on the map.
    private func showSimilar(_ track: RecordedTrack) {
        guard let host else { return }
        let format = PanelFormat(account: account)
        func meta(_ t: RecordedTrack) -> String {
            [(t.name ?? "").isEmpty ? nil : Self.date(t), format.distance(t.meters), TrackTypes.shared.label(t.type),
             String(localized: "sync.recorded", defaultValue: "Recorded on this phone", comment: "Sync: where a row comes from.")].compactMap { $0 }.joined(separator: " · ")
        }
        let waiting = similar[track.id, default: []].map { other in
            SimilarTracksViewController.Item(kind: TrackTypes.shared.kind(other.type), title: Self.title(other), meta: meta(other)) { [weak self] in self?.pick(other) }
        }
        let onMap = overlaps[track.id].map { o in
            let started = format.moment(o.startedAt, zone: o.timezone ?? "")
            let named = !o.name.trimmingCharacters(in: .whitespaces).isEmpty
            return SimilarTracksViewController.Item(kind: TrackTypes.shared.kind(o.trackType), title: named ? o.name : started,
                                                    meta: [named ? started : nil, TrackTypes.shared.label(o.trackType)].compactMap { $0 }.joined(separator: " · ")) { [weak self] in
                self?.onEvent?(.openOnMap(o))
            }
        }
        let lead = String(localized: "similar.lead", defaultValue: "\(Self.title(track)) (\(meta(track))) covers the same time as:", comment: "Similar tracks: the row asked about, its title and meta line.")
        let sheet = SimilarTracksViewController(lead: lead, waiting: waiting, onMap: onMap)
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        host.present(sheet, animated: true)
    }

    private func toggleType(_ type: String) {
        if types.contains(type) { types.remove(type) } else { types.insert(type) }
        render()
    }

    private func swiped(_ track: RecordedTrack) {
        let wasHidden = hidden.contains(track.id)
        recordings.hidden = SyncHidden.swiped(track.id, in: hidden)
        render()
        let text = wasHidden
            ? String(localized: "sync.unhidden", defaultValue: "Back on the list", comment: "Sync: a hidden row swiped back.")
            : String(localized: "sync.hidden", defaultValue: "Hidden — it won't be offered again", comment: "Sync: a row swiped aside.")
        onEvent?(.hid(text, undo: { [weak self] in
            // One that landed or was deleted meanwhile isn't hidden again: nothing would prune it.
            guard let self, self.recordings.all.contains(where: { $0.id == track.id }) else { return }
            self.recordings.hidden = SyncHidden.setting(track.id, hidden: wasHidden, in: self.recordings.hidden)
            self.render()
        }))
    }

    private func edit(_ track: RecordedTrack) {
        guard let host else { return }
        let editor = RecordingEditViewController(track: track, account: account, recordings: recordings, api: api)
        editor.onGPX = { [weak self] track in self?.downloadGPX(track) }
        host.present(UINavigationController(rootViewController: editor), animated: true)
    }

    /// Why Delete or Discard left a recording; nil for one it deleted.
    static func words(_ deletion: RecordingSends.Deletion) -> String? {
        switch deletion {
        case .sending: String(localized: "sync.deleteSending", defaultValue: "It's already being sent. Once it's on your map, delete it there.", comment: "Sync: Delete on a recording whose send had started.")
        case .landed: String(localized: "sync.deleteLanded", defaultValue: "It's already on your map. Delete it there.", comment: "Sync: Delete on a recording that landed while the question was open.")
        case .deleted: nil
        }
    }

    /// Delete asks first: the phone's copy is the only one. One question at a time.
    private func confirmDelete(_ track: RecordedTrack) {
        guard let host, deleteAlert?.presentingViewController == nil else { return }
        // Kept by the alert's actions, so it goes with the alert.
        let hold = recordings.hold(track.id)
        let alert = UIAlertController(title: String(localized: "sync.deleteTitle", defaultValue: "Delete this recording?", comment: "Sync: deleting a recording, the question."),
                                      message: String(localized: "sync.deleteMessage", defaultValue: "It hasn't reached your account, so this is the only copy. This can't be undone.", comment: "Sync: deleting a recording, why it asks."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in hold.release() })
        alert.addAction(UIAlertAction(title: String(localized: "recording.delete", defaultValue: "Delete", comment: "A recording: delete it from the phone."), style: .destructive) { [weak self] _ in
            if let self, let text = Self.words(self.recordings.delete(track.id)) { self.onEvent?(.say(text)) }
            hold.release()
        })
        deleteAlert = alert
        (host.presentedViewController ?? host).present(alert, animated: true)
    }

    /// The route as GPX, through the share sheet: Save to Files among its choices.
    private func downloadGPX(_ track: RecordedTrack) {
        guard let host else { return }
        let name = Self.title(track)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let file = FileManager.default.temporaryDirectory.appending(path: "\(safe).gpx")
        guard (try? RecordingSync.gpx(track, name: name).write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = host.view
        share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file) }
        (host.presentedViewController ?? host).present(share, animated: true)
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row]
        if case .row(let track) = item {
            let cell = tableView.dequeueReusableCell(withIdentifier: SyncRowCell.reuse, for: indexPath) as! SyncRowCell
            cell.configure(row(track))
            cell.onEdit = { [weak self] in self?.edit(track) }
            cell.onDelete = { [weak self] in self?.confirmDelete(track) }
            cell.onSimilar = { [weak self] in self?.showSimilar(track) }
            return cell
        }
        if case .filters = item {
            // Its own cell, rebuilt each time: a plain row's configuration owns its content view.
            let cell = tableView.dequeueReusableCell(withIdentifier: "filters", for: indexPath)
            cell.backgroundColor = .clear
            cell.selectionStyle = .none
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            filters(in: cell.contentView)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.accessoryType = .none
        var config = UIListContentConfiguration.subtitleCell()
        config.textProperties.font = Typeface.sans(DesignTokens.Text.md, relativeTo: .body)
        config.secondaryTextProperties.color = UIColor(resource: .inkSecondary)
        switch item {
        case .notice(let text, let id, let failed):
            config.text = text
            config.textProperties.color = UIColor(resource: failed ? .danger : .ink)
            cell.accessibilityIdentifier = id
        case .note(let text):
            config.text = text
            config.textProperties.color = UIColor(resource: .inkSecondary)
            cell.accessibilityIdentifier = "syncEmpty"
        case .showHidden:
            config.text = showHidden
                ? String(localized: "sync.dontShowHidden", defaultValue: "Don't show hidden", comment: "Sync: put the hidden rows away.")
                : String(localized: "sync.showHidden", defaultValue: "Show hidden (\(list.hiddenCount))", comment: "Sync: list the hidden rows, and how many.")
            config.textProperties.color = UIColor(resource: .accent)
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "syncShowHidden"
        case .row, .filters: break
        }
        config.imageProperties.tintColor = UIColor(resource: .inkSecondary)
        cell.contentConfiguration = config
        return cell
    }

    /// One chip per type listed; a list with one type has no filters.
    private func filters(in container: UIView) {
        let labels = list.types.sorted { TrackTypes.shared.label($0) < TrackTypes.shared.label($1) }
        let chips = UIStackView(arrangedSubviews: labels.map { type in
            var config = types.contains(type) ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
            config.title = TrackTypes.shared.label(type)
            config.cornerStyle = .capsule
            config.baseBackgroundColor = UIColor(resource: .accent)
            config.baseForegroundColor = types.contains(type) ? UIColor(resource: .onAccent) : UIColor(resource: .ink)
            let chip = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.toggleType(type) })
            chip.accessibilityTraits = types.contains(type) ? [.button, .selected] : .button
            chip.accessibilityIdentifier = "syncType"
            return chip
        })
        chips.spacing = DesignTokens.Space.s8
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.accessibilityLabel = String(localized: "sync.types", defaultValue: "Track types", comment: "Sync: the type chips, read out.")
        chips.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(chips)
        NSLayoutConstraint.activate([
            chips.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            chips.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            chips.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        scroll.heightAnchor.constraint(equalToConstant: 36).isActive = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: DesignTokens.Space.s4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DesignTokens.Space.s4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: DesignTokens.Space.s16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -DesignTokens.Space.s16),
        ])
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch items[indexPath.row] {
        case .row(let track): pick(track)
        case .showHidden:
            showHidden.toggle()
            render()
        case .notice, .note, .filters: break
        }
    }

    /// A swipe either way hides the row, or brings a hidden one back; not while it's being sent or
    /// on its way.
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        swipe(indexPath)
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        swipe(indexPath)
    }

    private func swipe(_ indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .row(let track) = items[indexPath.row], list.canSwipe(track) else { return nil }
        let hidden = hidden.contains(track.id)
        let action = UIContextualAction(style: .normal, title: hidden
            ? String(localized: "sync.unhide", defaultValue: "Show", comment: "Sync: a hidden row's swipe, bringing it back.")
            : String(localized: "sync.hide", defaultValue: "Hide", comment: "Sync: a row's swipe, hiding it.")) { [weak self] _, _, done in
            self?.swiped(track)
            done(true)
        }
        action.image = UIImage(resource: hidden ? .eye : .eyeOff)
        action.backgroundColor = UIColor(resource: .inkSecondary)
        return UISwipeActionsConfiguration(actions: [action])
    }
}