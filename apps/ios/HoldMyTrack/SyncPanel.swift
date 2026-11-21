import HoldMyTrackCore
import UIKit

/// The sheet's Sync tab, the tab bar's Sync (apps/android/docs/SPEC.md FR-3.5): every recording
/// on this phone not on the map yet, newest first, the user's to choose. Nothing starts ticked,
/// and only what's ticked and shown is sent. Type chips narrow the list and Select all ticks
/// what's shown; a row swiped aside is hidden, with Undo, and Show hidden brings it back. One sent
/// stays listed, on its way, until it lands. Under the list, Upload files and Sync history. Which
/// rows are offered is SyncList's. The rows are drawn dashed on the map (SyncLines), the first
/// showing framed; a tap on a row or its line picks it out, and ⓘ says what else covers its time
/// (SyncSimilar, and the server for the account's tracks).
@MainActor
final class SyncPanel: NSObject, UITableViewDataSource, UITableViewDelegate {
    enum Event {
        case upload
        case history
        /// A row hidden or back: said over the map, with Undo.
        case hid(String, undo: () -> Void)
        /// The rows to draw on the map, highlight picked out.
        case lines([RecordedTrack], highlight: String?)
        /// The camera onto this box.
        case frame([Double])
        /// The account's track a row overlaps, opened on the Tracks tab on its day.
        case openOnMap(TrackOverlap)
        /// A message over the map.
        case say(String)
    }

    var onEvent: ((Event) -> Void)?
    let head = UIStackView()
    let content = UIView()

    private let recordings: RecordingsSync
    private let api: APIClient
    private let account: Account
    private weak var host: UIViewController?
    private let table = UITableView(frame: .zero, style: .plain)
    private let send = Controls.primaryButton("", id: "syncSend")
    private let tickedLine = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let bar: UIStackView

    private var showing = false
    private var types: Set<String> = []
    private var showHidden = false
    /// How many the running send started with, for "Sent N of M…".
    private var sendingTotal = 0
    /// Sent recordings whose ingest failed, said over the list until the tab next opens.
    private var failedLines: [String] = []
    private var list = SyncList.of([], hidden: [], showHidden: false, types: [], ticked: [])
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

    private enum Item {
        case notice(String, id: String, failed: Bool)
        case filters
        case row(RecordedTrack)
        case note(String)
        case showHidden
        case upload
        case history
    }
    private var items: [Item] = []

    init(recordings: RecordingsSync, api: APIClient, account: Account, host: UIViewController) {
        self.recordings = recordings
        self.api = api
        self.account = account
        self.host = host
        tickedLine.textAlignment = .center
        tickedLine.accessibilityIdentifier = "syncTicked"
        bar = Controls.column([send, tickedLine], spacing: DesignTokens.Space.s4)
        super.init()
        head.axis = .vertical
        head.spacing = DesignTokens.Space.s8
        head.addArrangedSubview(Controls.label(String(localized: "Sync"), font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink)))
        head.addArrangedSubview(bar)
        bar.isHidden = account.isDemo
        send.addAction(UIAction { [weak self] _ in self?.sendTicked() }, for: .primaryActionTriggered)

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

    /// The tab showed, from another tab or a launch: nothing ticked, every type, hidden rows put
    /// away. A send running keeps its rows (RecordingsSync.inFlight).
    func start() {
        showing = true
        describedTypes = nil
        highlight = nil
        framed = false
        // The account's tracks may have changed since: an answer is asked for again, not kept.
        overlaps = [:]
        overlapsAsked = nil
        recordings.ticked = []
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
            String(localized: "sync.rowFailed", defaultValue: "Couldn't add \(Self.date($0)) \(TrackTypes.shared.label($0.type)) — Sync history says why. It's back on the list.",
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
        recordings.ticked = Set(all.filter { !$0.sent }.map(\.id)).intersection(recordings.ticked)
        list = SyncList.of(all, hidden: hidden, showHidden: showHidden, types: types, ticked: recordings.ticked,
                           isDemo: account.isDemo, inFlight: recordings.inFlight)
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
        if let summary = summaryLine() { items.append(.notice(summary, id: "syncResults", failed: false)) }
        let problems = problemLines()
        if !problems.isEmpty { items.append(.notice(problems.joined(separator: "\n"), id: "syncProblems", failed: true)) }
        if !list.everything.isEmpty { items.append(.filters) }
        items += list.shown.map(Item.row)
        if list.everything.isEmpty {
            items.append(.note(String(localized: "sync.listEmpty", defaultValue: "Nothing waiting. Recordings from the record button show up here.", comment: "Sync: nothing on the phone to send.")))
        }
        if list.hiddenCount > 0 || showHidden { items.append(.showHidden) }
        if !account.isDemo { items.append(.upload) }
        items.append(.history)
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

    private func renderBar() {
        let sendable = list.sendable
        // Two ticked copies of one walk: said in the bar, and still sent if the user goes on.
        let doubled = SyncSimilar.doubled(sendable, waiting: similar)
        if recordings.sending {
            // Each row the run has done, taken or refused, so the count reaches the total.
            let done = (recordings.report?.sent ?? 0) + (recordings.report?.refused.count ?? 0)
            tickedLine.text = String(localized: "sync.progress", defaultValue: "Sent \(done) of \(sendingTotal)…", comment: "Sync: a send in progress, how many so far of how many.")
        } else if doubled > 0 {
            tickedLine.text = String(localized: "sync.tickedSimilar", defaultValue: "\(sendable.count) of \(list.tickable.count) ticked · \(doubled) are similar",
                                     comment: "Sync: how many rows are ticked, of how many can be, and how many of them cover the same time as another ticked one.")
        } else {
            let format = PanelFormat(account: account)
            tickedLine.text = String(localized: "sync.ticked", defaultValue: "\(sendable.count) of \(list.tickable.count) ticked · \(format.totalDistance(list.sendableMeters))",
                                     comment: "Sync: how many rows are ticked, of how many can be, and their distance.")
        }
        send.configuration?.title = sendable.isEmpty
            ? String(localized: "sync.now", defaultValue: "Sync", comment: "Sync: send, with nothing ticked.")
            : String(localized: "sync.send", defaultValue: "Sync \(sendable.count)", comment: "Sync: send the ticked rows, and how many.")
        send.isEnabled = !account.isDemo && !recordings.sending && !sendable.isEmpty
    }

    /// What the last send took.
    private func summaryLine() -> String? {
        guard let report = recordings.report, report.sent > 0 else { return nil }
        return String(localized: "sync.summary", defaultValue: "Sent \(report.sent) tracks. They stay listed until they're on your map.", comment: "Sync: how many the last send took.")
    }

    /// What the last send couldn't do, each refused row with its reason, and failed ingests.
    private func problemLines() -> [String] {
        var lines: [String] = []
        if let report = recordings.report {
            lines += report.refused.map { refused in
                String(localized: "sync.rejected", defaultValue: "Rejected: \(Self.date(refused.track)) \(TrackTypes.shared.label(refused.track.type)) — \(Self.words(refused.refusal))",
                       comment: "Sync: a row the server refused, its start, type and why.")
            }
            if let stopped = report.stopped {
                lines.append(String(localized: "sync.stopped", defaultValue: "Stopped early. \(stopped.shownMessage)", comment: "Sync: a send cut short, and why."))
            }
        }
        return lines + failedLines
    }

    static func words(_ refusal: RecordingSync.Refusal) -> String {
        switch refusal {
        case .tooManyPoints: String(localized: "sync.tooManyPoints", defaultValue: "over \(RecordingSync.maxPoints) points", comment: "Sync: why a recording wasn't sent: too long, and the limit.")
        case .server(let message): message ?? String(localized: "sync.refused", defaultValue: "not sent", comment: "Sync: the server refused a recording, giving no reason.")
        }
    }

    static func date(_ track: RecordedTrack) -> String { track.startedAt.formatted(date: .abbreviated, time: .shortened) }

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
            note: track.sent ? String(localized: "sync.processing", defaultValue: "Adding to your map…", comment: "Sync: a sent row on its way to the map.") : nil,
            processing: track.sent, kind: TrackTypes.shared.kind(track.type), ticked: recordings.ticked.contains(track.id),
            hidden: hidden, tickable: list.canTick(track), editable: list.canEdit(track),
            similar: SyncSimilar.count(track, waiting: similar, onMap: overlaps[track.id] != nil),
            highlighted: track.id == highlight
        )
    }

    // MARK: Actions

    private func sendTicked() {
        let sending = list.sendable
        guard !sending.isEmpty else { return }
        sendingTotal = sending.count
        failedLines = []
        Task { await recordings.send(sending) }
    }

    private func toggle(_ track: RecordedTrack) {
        guard list.canTick(track) else { return }
        if recordings.ticked.contains(track.id) { recordings.ticked.remove(track.id) } else { recordings.ticked.insert(track.id) }
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
        recordings.ticked.remove(track.id)
        render()
        let text = wasHidden
            ? String(localized: "sync.unhidden", defaultValue: "Back on the list", comment: "Sync: a hidden row swiped back.")
            : String(localized: "sync.hidden", defaultValue: "Hidden — it won't be offered again", comment: "Sync: a row swiped aside.")
        onEvent?(.hid(text, undo: { [weak self] in
            // A send started since: its rows stay as they are, as a swipe would leave them.
            guard let self else { return }
            guard !self.recordings.sending else {
                self.onEvent?(.say(String(localized: "sync.undoWhileSending", defaultValue: "Can't undo while tracks are being sent.", comment: "Sync: Undo tapped during a send.")))
                return
            }
            self.recordings.hidden = SyncHidden.setting(track.id, hidden: wasHidden, in: self.recordings.hidden)
            self.render()
        }))
    }

    private func edit(_ track: RecordedTrack) {
        guard let host else { return }
        let editor = RecordingEditViewController(track: track, account: account, recordings: recordings, api: api)
        editor.onGPX = { [weak self] track in self?.downloadGPX(track) }
        editor.onDelete = { [weak self] track in self?.confirmDelete(track) }
        host.present(UINavigationController(rootViewController: editor), animated: true)
    }

    /// The recording Stop just saved, opened for naming.
    func open(_ track: RecordedTrack) { edit(track) }

    /// Delete asks first: the phone's copy is the only one.
    private func confirmDelete(_ track: RecordedTrack) {
        guard let host else { return }
        let alert = UIAlertController(title: String(localized: "sync.deleteTitle", defaultValue: "Delete this recording?", comment: "Sync: deleting a recording, the question."),
                                      message: String(localized: "sync.deleteMessage", defaultValue: "It hasn't been synced, so this is the only copy. This can't be undone.", comment: "Sync: deleting a recording, why it asks."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "recording.delete", defaultValue: "Delete", comment: "A recording: delete it from the phone."), style: .destructive) { [weak self, weak host] _ in
            host?.presentedViewController?.dismiss(animated: true)
            self?.recordings.delete(track.id)
        })
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
            cell.onTick = { [weak self] in self?.toggle(track) }
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
        case .upload:
            (config.text, config.secondaryText, config.image) = (String(localized: "sync.uploadTitle", defaultValue: "Upload files", comment: "Sync: the Upload tile."),
                                                                 String(localized: "sync.uploadSub", defaultValue: "GPX, FIT or TCX files", comment: "Sync: what Upload takes."), UIImage(resource: .upload))
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "syncUpload"
        case .history:
            (config.text, config.secondaryText, config.image) = (String(localized: "Sync history"),
                                                                 String(localized: "sync.historySub", defaultValue: "Every import and how it went", comment: "Sync: what Sync history shows."), UIImage(resource: .history))
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "syncHistory"
        case .row, .filters: break
        }
        config.imageProperties.tintColor = UIColor(resource: .inkSecondary)
        cell.contentConfiguration = config
        return cell
    }

    /// One chip per type listed when there's more than one, then Select all.
    private func filters(in container: UIView) {
        let labels = list.types.sorted { TrackTypes.shared.label($0) < TrackTypes.shared.label($1) }
        var views: [UIView] = []
        if labels.count > 1 {
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
            views.append(scroll)
        }
        if !list.tickable.isEmpty && !account.isDemo {
            let all = Controls.textButton(list.allTicked(recordings.ticked)
                ? String(localized: "sync.selectNone", defaultValue: "Select none", comment: "Sync: untick every row shown.")
                : String(localized: "sync.selectAll", defaultValue: "Select all", comment: "Sync: tick every row shown."), id: "syncSelectAll")
            all.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.recordings.ticked = self.list.toggleAll(self.recordings.ticked)
                self.render()
            }, for: .primaryActionTriggered)
            let row = UIStackView(arrangedSubviews: [UIView(), all])
            views.append(row)
        }
        let column = Controls.column(views, spacing: DesignTokens.Space.s4)
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: DesignTokens.Space.s4),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DesignTokens.Space.s4),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: DesignTokens.Space.s16),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -DesignTokens.Space.s16),
        ])
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch items[indexPath.row] {
        case .row(let track): pick(track)
        case .showHidden:
            showHidden.toggle()
            render()
        case .upload: onEvent?(.upload)
        case .history: onEvent?(.history)
        case .notice, .note, .filters: break
        }
    }

    /// A swipe either way hides the row, or brings a hidden one back; not while it's on its way
    /// or a send runs.
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