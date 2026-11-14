import HoldMyTrackCore
import UIKit

/// The sheet's Stories tab (root docs/SPEC.md FR-13.6, apps/android/docs/SPEC.md FR-2.7): every
/// Story as a folder, newest first, one of them open while the tab shows, the newest until another
/// is tapped. The map screen lists and draws the open Story's activities and hands its rows back
/// (setRows); this tab draws them inside the folder, with × to take one out and the whole Story's
/// numbers under them. Above the folders, copies others sent wait to be accepted or declined
/// (FR-13.7), read with the list and every 3 seconds while an accepted one is arriving.
final class StoriesPanel: NSObject, UITableViewDataSource, UITableViewDelegate {
    enum Event {
        /// Open the Story; collapse brings the sheet down so its tracks show.
        case open(String, collapse: Bool)
        /// No Story is left to open.
        case close
        case select(String)
        case clearFocus
        /// A Story renamed, deleted or changed: the rows' badges name it.
        case storiesChanged
        case removed(String)
        /// An accepted copy arrived: new activities on the map.
        case copyArrived
        case waiting(Int)
    }

    var onEvent: ((Event) -> Void)?
    let content = UIView()
    let head = UIStackView()

    private let api: APIClient
    private let demo: Bool
    private var format: PanelFormat
    private let table = UITableView(frame: .zero, style: .plain)

    private var showing = false
    private var ready = false
    private var error: String?
    private var stories: [Story] = []
    private(set) var openID: String?
    private var openStory: Story?
    private var openError: String?
    private var rows: [ActivityRowCell.Row] = []
    private var rowsNote: (text: String, failed: Bool)?
    private var removeError: String?
    private var sends: [StorySend] = []
    private var copying: [StoryCopying] = []
    private var answering = false
    private var answerError: String?
    private var inboxTask: Task<Void, Never>?

    private enum Item {
        case send(StorySend), copying(StoryCopying), folder(Story, open: Bool), text(String, small: Bool)
        case row(ActivityRowCell.Row, storyID: String), note(String, failed: Bool)
    }
    private var items: [Item] = []

    init(api: APIClient, format: PanelFormat, demo: Bool) {
        self.api = api
        self.format = format
        self.demo = demo
        super.init()
        let title = Controls.label(String(localized: "Stories"), font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink))
        let create = Controls.iconButton(UIImage(resource: .plus), label: demo ? String(localized: "The demo account can't change a Story") : String(localized: "New story"), id: "newStory")
        create.isEnabled = !demo
        create.addAction(UIAction { [weak self] _ in self?.create() }, for: .primaryActionTriggered)
        let row = UIStackView(arrangedSubviews: [title, UIView(), create])
        row.alignment = .center
        head.axis = .vertical
        head.addArrangedSubview(row)
        head.addArrangedSubview(Controls.label(String(localized: "A Story shows its own activities instead of what's on the map."), font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary)))

        table.dataSource = self
        table.delegate = self
        table.register(ActivityRowCell.self, forCellReuseIdentifier: ActivityRowCell.reuse)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
        table.backgroundColor = .clear
        table.accessibilityIdentifier = "storiesList"
        let tapEmpty = UITapGestureRecognizer(target: self, action: #selector(tappedList(_:)))
        tapEmpty.cancelsTouchesInView = false
        table.addGestureRecognizer(tapEmpty)
        table.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: content.topAnchor),
            table.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: Showing

    /// The tab opened: the list read afresh, the newest opened once it's in.
    func start() {
        showing = true
        ready = false
        error = nil
        render()
        loadStories()
        loadInbox()
    }

    func stop() {
        showing = false
        inboxTask?.cancel()
    }

    /// The inbox alone, for the tab's count while it isn't showing.
    func refreshCount() {
        Task {
            guard let inbox = try? await api.storyInbox() else { return }
            onEvent?(.waiting(inbox.sends.count))
        }
    }

    private func loadStories() {
        Task {
            do {
                let read = try await api.stories()
                guard showing else { return }
                read.forEach { ActivityTypes.shared.merge($0.types) }
                stories = read.map(\.story)
                ready = true
                if openID == nil, let newest = stories.first { onEvent?(.open(newest.id, collapse: false)) }
            } catch {
                self.error = Self.message(error, String(localized: "Stories couldn't load."))
            }
            render()
        }
    }

    private func loadInbox() {
        inboxTask?.cancel()
        inboxTask = Task {
            guard let inbox = try? await api.storyInbox(), showing, !Task.isCancelled else { return }
            let arrived = inbox.copying.count < copying.count
            sends = inbox.sends
            copying = inbox.copying
            onEvent?(.waiting(sends.count))
            if arrived {
                loadStories()
                onEvent?(.copyArrived)
            }
            render()
            if !copying.isEmpty {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { loadInbox() }
            }
        }
    }

    /// id is the open Story now, or none; its own copy is read for the numbers.
    func setOpen(_ id: String?) {
        if id != openID {
            openID = id
            openStory = nil
            removeError = nil
        }
        openError = nil
        render()
        reloadOpen()
    }

    /// The open Story read again, after anything that changes its numbers.
    func reloadOpen() {
        guard let id = openID else { return }
        Task {
            do {
                let read = try await api.story(id)
                guard id == openID else { return }
                ActivityTypes.shared.merge(read.types)
                openStory = read.story
                stories = stories.map { $0.id == id ? read.story : $0 }
            } catch {
                guard id == openID else { return }
                openStory = nil
                if case APIError.http(status: 404, _, _) = error {
                    openError = String(localized: "This Story no longer exists.")
                } else {
                    openError = Self.message(error, String(localized: "Stories couldn't load."))
                }
            }
            render()
        }
    }

    /// The open Story's rows, from the map screen's list.
    func setRows(_ next: [ActivityRowCell.Row], note: (text: String, failed: Bool)?, format: PanelFormat) {
        rows = next
        rowsNote = note
        self.format = format
        render()
    }

    func scrollTo(_ activityID: String) {
        guard let index = items.firstIndex(where: { if case .row(let r, _) = $0 { r.activity.id == activityID } else { false } }) else { return }
        table.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: true)
    }

    /// A Story Add to story made: in the list at once, ahead of the next read.
    func added(_ story: Story) {
        stories.removeAll { $0.id == story.id }
        stories.insert(story, at: 0)
        render()
    }

    // MARK: Drawing

    private func render() {
        var next: [Item] = sends.map { .send($0) } + copying.map { .copying($0) }
        if let answerError { next.append(.note(answerError, failed: true)) }
        if let openError, !stories.contains(where: { $0.id == openID }) { next.append(.note(openError, failed: true)) }
        for listed in stories {
            let open = listed.id == openID
            let story = open && openStory?.id == listed.id ? openStory! : listed
            next.append(.folder(story, open: open))
            guard open else { continue }
            if let from = story.from { next.append(.text(String(localized: "From \(from)"), small: true)) }
            if !story.description.isEmpty { next.append(.text(story.description, small: false)) }
            if let removeError { next.append(.note(removeError, failed: true)) }
            next += rows.map { .row($0, storyID: story.id) }
            if let rowsNote {
                next.append(.note(rowsNote.text, failed: rowsNote.failed))
            } else if rows.isEmpty {
                next.append(.note(story.stats.count == 0 ? String(localized: "No activities in this Story yet. Add some with Add to story.") : String(localized: "No activities match these filters."), failed: false))
            }
        }
        if let story = openStory, story.id == openID, story.stats.count > 0 {
            let lines = [line(story.stats)] + story.byType.map { "\(ActivityTypes.shared.label($0.activityType)): \(line($0))" }
            if let at = next.lastIndex(where: { if case .row = $0 { true } else { false } }) {
                next.insert(.text(lines.joined(separator: "\n"), small: true), at: at + 1)
            }
        }
        if let error {
            next.append(.note(error, failed: true))
        } else if !ready && stories.isEmpty {
            next.append(.note(String(localized: "Loading…"), failed: false))
        } else if ready && stories.isEmpty {
            next.append(.note(String(localized: "No Stories yet. Check activities on the Activities tab and use Add to story, or make one with +."), failed: false))
        }
        items = next
        table.reloadData()
    }

    private func line(_ totals: StoryTotals) -> String {
        [format.activityCount(totals.count), format.totalDistance(totals.distanceMeters), String(localized: "\(format.duration(totals.movingSeconds)) moving")].joined(separator: " · ")
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch items[indexPath.row] {
        case .row(let row, let storyID):
            let cell = tableView.dequeueReusableCell(withIdentifier: ActivityRowCell.reuse, for: indexPath) as! ActivityRowCell
            let id = row.activity.id
            cell.bind(row, format: format, openStoryID: storyID, demo: demo, onCheck: nil,
                      onOpenStory: { [weak self] in self?.onEvent?(.open($0, collapse: true)) },
                      onRemove: { [weak self] in self?.remove(storyID: storyID, activityID: id) })
            cell.contentView.directionalLayoutMargins.leading = 36
            return cell
        case .folder(let story, let open):
            return folderCell(story, open: open)
        case .send(let send):
            return inboxCell(String(localized: "\(send.from) sent you a copy of “\(send.storyName)” (\(format.activityCount(send.activityCount))).") , send: send)
        case .copying(let copy):
            return inboxCell(String(localized: "Copying “\(copy.storyName)” from \(copy.from)…"), send: nil)
        case .text(let text, let small):
            return textCell(text, color: UIColor(resource: .inkSecondary), size: small ? DesignTokens.Text.sm : DesignTokens.Text.md)
        case .note(let text, let failed):
            return textCell(text, color: UIColor(resource: failed ? .danger : .inkSecondary), size: DesignTokens.Text.md)
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch items[indexPath.row] {
        case .row(let row, _) where !row.activity.pending: onEvent?(.select(row.activity.id))
        case .folder(let story, let open) where !open: onEvent?(.open(story.id, collapse: true))
        case .note: onEvent?(.clearFocus)
        default: break
        }
    }

    @objc private func tappedList(_ tap: UITapGestureRecognizer) {
        if table.indexPathForRow(at: tap.location(in: table)) == nil { onEvent?(.clearFocus) }
    }

    private func textCell(_ text: String, color: UIColor, size: CGFloat) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "plain")!
        var config = UIListContentConfiguration.cell()
        config.text = text
        config.textProperties.color = color
        config.textProperties.font = Typeface.sans(size)
        config.directionalLayoutMargins.leading = 36
        cell.contentConfiguration = config
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.accessoryView = nil
        return cell
    }

    private func folderCell(_ story: Story, open: Bool) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "plain")!
        var config = UIListContentConfiguration.cell()
        config.text = story.name
        config.image = Controls.icon(UIImage(resource: open ? .chevronDown : .chevronRight), size: 16)
        config.imageProperties.tintColor = UIColor(resource: open ? .accentStrong : .inkSecondary)
        config.textProperties.font = Typeface.sans(DesignTokens.Text.lg, weight: DesignTokens.Weight.semibold)
        config.textProperties.color = UIColor(resource: .ink)
        cell.contentConfiguration = config
        cell.backgroundColor = open ? UIColor(resource: .surfaceTint) : .clear
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = "storyFolder"
        cell.accessibilityValue = open ? String(localized: "Open") : String(localized: "Folded")

        let edit = Controls.iconButton(UIImage(resource: .pencil), label: demo ? String(localized: "The demo account can't change a Story") : String(localized: "Rename \(story.name)"), id: "storyEdit")
        let send = Controls.iconButton(UIImage(resource: .send), label: demo ? String(localized: "The demo account can't change a Story") : String(localized: "Send a copy of \(story.name)"), id: "storySend")
        let delete = Controls.iconButton(UIImage(resource: .trash2), label: demo ? String(localized: "The demo account can't change a Story") : String(localized: "Delete \(story.name)"), id: "storyDelete")
        for b in [edit, send, delete] { b.isEnabled = !demo }
        edit.addAction(UIAction { [weak self] _ in self?.rename(story) }, for: .primaryActionTriggered)
        send.addAction(UIAction { [weak self] _ in self?.sendCopy(story) }, for: .primaryActionTriggered)
        delete.addAction(UIAction { [weak self] _ in self?.confirmDelete(story) }, for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [edit, send, delete])
        buttons.frame = CGRect(x: 0, y: 0, width: 132, height: 44)
        cell.accessoryView = buttons
        return cell
    }

    private func inboxCell(_ text: String, send: StorySend?) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "plain")!
        var config = UIListContentConfiguration.subtitleCell()
        config.text = text
        config.textProperties.font = Typeface.sans(DesignTokens.Text.md)
        config.textProperties.color = UIColor(resource: send == nil ? .inkSecondary : .ink)
        cell.contentConfiguration = config
        cell.backgroundColor = UIColor(resource: .noticeBg)
        cell.selectionStyle = .none
        cell.accessoryView = nil
        if let send {
            let accept = Controls.textButton(String(localized: "Accept"), id: "acceptCopy")
            let decline = Controls.textButton(String(localized: "Decline"), id: "declineCopy")
            for (b, yes) in [(accept, true), (decline, false)] {
                b.isEnabled = !answering
                b.addAction(UIAction { [weak self] _ in self?.answer(send, accept: yes) }, for: .primaryActionTriggered)
            }
            let buttons = UIStackView(arrangedSubviews: [accept, decline])
            buttons.frame = CGRect(x: 0, y: 0, width: 170, height: 44)
            cell.accessoryView = buttons
        }
        return cell
    }

    // MARK: Changing

    private func answer(_ send: StorySend, accept: Bool) {
        guard !answering else { return }
        answering = true
        answerError = nil
        render()
        Task {
            do { try await api.answerStorySend(send.id, accept: accept) } catch {
                answerError = Self.message(error, String(localized: "The Story couldn't be saved."))
            }
            answering = false
            render()
            loadInbox()
        }
    }

    /// × on a row: out of the Story at once, with no confirmation; the activity stays.
    private func remove(storyID: String, activityID: String) {
        Task {
            do {
                let read = try await api.changeStoryActivities(storyID, activityIDs: [activityID], add: false)
                removeError = nil
                stories = stories.map { $0.id == read.story.id ? read.story : $0 }
                if read.story.id == openID { openStory = read.story }
                onEvent?(.removed(activityID))
            } catch {
                removeError = Self.message(error, String(localized: "The Story couldn't be saved."))
            }
            render()
        }
    }

    private func create() {
        StoryDialogs.name(over: table, title: String(localized: "New story"), name: "", description: "", action: String(localized: "Create")) { [weak self] name, description in
            guard let self else { return nil }
            do {
                let read = try await self.api.createStory(name: name, description: description, activityIDs: [])
                self.added(read.story)
                self.onEvent?(.open(read.story.id, collapse: false))
                return nil
            } catch {
                return Self.message(error, String(localized: "The Story couldn't be saved."))
            }
        }
    }

    private func rename(_ story: Story) {
        StoryDialogs.name(over: table, title: String(localized: "Rename story"), name: story.name, description: story.description, action: String(localized: "Save")) { [weak self] name, description in
            guard let self else { return nil }
            do {
                let read = try await self.api.updateStory(story.id, name: name, description: description)
                self.stories = self.stories.map { $0.id == story.id ? read.story : $0 }
                if story.id == self.openID { self.openStory = read.story }
                self.onEvent?(.storiesChanged)
                self.render()
                return nil
            } catch {
                return Self.message(error, String(localized: "The Story couldn't be saved."))
            }
        }
    }

    private func sendCopy(_ story: Story) {
        StoryDialogs.sendCopy(over: table, story: story) { [weak self] email in
            guard let self else { return nil }
            do {
                try await self.api.sendStory(story.id, email: email)
                return nil
            } catch {
                return Self.message(error, String(localized: "The copy couldn't be sent."))
            }
        }
    }

    private func confirmDelete(_ story: Story) {
        StoryDialogs.confirm(over: table, title: String(localized: "Delete this Story?"),
                             message: String(localized: "“\(story.name)” will be deleted. Its activities stay on your map."),
                             action: String(localized: "Delete story")) { [weak self] in
            guard let self else { return nil }
            do {
                try await self.api.deleteStory(story.id)
            } catch {
                return Self.message(error, String(localized: "The Story couldn't be deleted."))
            }
            self.stories.removeAll { $0.id == story.id }
            self.onEvent?(.storiesChanged)
            if story.id == self.openID {
                if let next = self.stories.first { self.onEvent?(.open(next.id, collapse: false)) } else { self.onEvent?(.close) }
            }
            self.render()
            return nil
        }
    }

    static func message(_ error: Error, _ fallback: String) -> String {
        (error as? APIError)?.serverMessage ?? fallback
    }
}