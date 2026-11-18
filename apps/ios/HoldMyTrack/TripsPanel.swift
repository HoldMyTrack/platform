import HoldMyTrackCore
import UIKit

/// The sheet's Trips tab (root docs/SPEC.md FR-13.6, apps/android/docs/SPEC.md FR-2.7): every
/// Trip as a folder, newest first, one of them open while the tab shows, the newest until another
/// is tapped. The map screen lists and draws the open Trip's tracks and hands its rows back
/// (setRows); this tab draws them inside the folder, with × to take one out and the whole Trip's
/// numbers under them. Above the folders, copies others sent wait to be accepted or declined
/// (FR-13.7), read with the list and every 3 seconds while an accepted one is arriving.
final class TripsPanel: NSObject, UITableViewDataSource, UITableViewDelegate {
    enum Event {
        /// Open the Trip; collapse brings the sheet down so its tracks show.
        case open(String, collapse: Bool)
        /// No Trip is left to open.
        case close
        case select(String)
        case clearFocus
        /// A Trip renamed, deleted or changed: the rows' badges name it.
        case tripsChanged
        case removed(String)
        /// An accepted copy arrived: new tracks on the map.
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
    private var trips: [Trip] = []
    private(set) var openID: String?
    private var openTrip: Trip?
    private var openError: String?
    private var rows: [TrackRowCell.Row] = []
    private var rowsNote: (text: String, failed: Bool)?
    private var removeError: String?
    private var sends: [TripSend] = []
    private var copying: [TripCopying] = []
    private var answering = false
    private var answerError: String?
    private var inboxTask: Task<Void, Never>?

    private enum Item {
        case send(TripSend), copying(TripCopying), folder(Trip, open: Bool), text(String, small: Bool)
        case row(TrackRowCell.Row, tripID: String), note(String, failed: Bool)
    }
    private var items: [Item] = []

    init(api: APIClient, format: PanelFormat, demo: Bool) {
        self.api = api
        self.format = format
        self.demo = demo
        super.init()
        let title = Controls.label(String(localized: "Trips"), font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink))
        let create = Controls.iconButton(UIImage(resource: .plus), label: demo ? String(localized: "The demo account can't change a Trip") : String(localized: "New trip"), id: "newTrip")
        create.isEnabled = !demo
        create.addAction(UIAction { [weak self] _ in self?.create() }, for: .primaryActionTriggered)
        let row = UIStackView(arrangedSubviews: [title, UIView(), create])
        row.alignment = .center
        head.axis = .vertical
        head.addArrangedSubview(row)
        head.addArrangedSubview(Controls.label(String(localized: "A Trip shows its own tracks instead of what's on the map."), font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary)))

        table.dataSource = self
        table.delegate = self
        table.register(TrackRowCell.self, forCellReuseIdentifier: TrackRowCell.reuse)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
        table.backgroundColor = .clear
        table.accessibilityIdentifier = "tripsList"
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
        loadTrips()
        loadInbox()
    }

    func stop() {
        showing = false
        inboxTask?.cancel()
    }

    /// The inbox alone, for the tab's count while it isn't showing.
    func refreshCount() {
        Task {
            guard let inbox = try? await api.tripInbox() else { return }
            onEvent?(.waiting(inbox.sends.count))
        }
    }

    private func loadTrips() {
        Task {
            do {
                let read = try await api.trips()
                guard showing else { return }
                read.forEach { TrackTypes.shared.merge($0.types) }
                trips = read.map(\.trip)
                ready = true
                if openID == nil, let newest = trips.first { onEvent?(.open(newest.id, collapse: false)) }
            } catch {
                self.error = Self.message(error, String(localized: "Trips couldn't load."))
            }
            render()
        }
    }

    private func loadInbox() {
        inboxTask?.cancel()
        inboxTask = Task {
            guard let inbox = try? await api.tripInbox(), showing, !Task.isCancelled else { return }
            let arrived = inbox.copying.count < copying.count
            sends = inbox.sends
            copying = inbox.copying
            onEvent?(.waiting(sends.count))
            if arrived {
                loadTrips()
                onEvent?(.copyArrived)
            }
            render()
            if !copying.isEmpty {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { loadInbox() }
            }
        }
    }

    /// id is the open Trip now, or none; its own copy is read for the numbers.
    func setOpen(_ id: String?) {
        if id != openID {
            openID = id
            openTrip = nil
            removeError = nil
        }
        openError = nil
        render()
        reloadOpen()
    }

    /// The open Trip read again, after anything that changes its numbers.
    func reloadOpen() {
        guard let id = openID else { return }
        Task {
            do {
                let read = try await api.trip(id)
                guard id == openID else { return }
                TrackTypes.shared.merge(read.types)
                openTrip = read.trip
                trips = trips.map { $0.id == id ? read.trip : $0 }
            } catch {
                guard id == openID else { return }
                openTrip = nil
                if case APIError.http(status: 404, _, _) = error {
                    openError = String(localized: "This Trip no longer exists.")
                } else {
                    openError = Self.message(error, String(localized: "Trips couldn't load."))
                }
            }
            render()
        }
    }

    /// The open Trip's rows, from the map screen's list.
    func setRows(_ next: [TrackRowCell.Row], note: (text: String, failed: Bool)?, format: PanelFormat) {
        rows = next
        rowsNote = note
        self.format = format
        render()
    }

    func scrollTo(_ trackID: String) {
        guard let index = items.firstIndex(where: { if case .row(let r, _) = $0 { r.track.id == trackID } else { false } }) else { return }
        table.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: true)
    }

    /// A Trip Add to trip made: in the list at once, ahead of the next read.
    func added(_ trip: Trip) {
        trips.removeAll { $0.id == trip.id }
        trips.insert(trip, at: 0)
        render()
    }

    // MARK: Drawing

    private func render() {
        var next: [Item] = sends.map { .send($0) } + copying.map { .copying($0) }
        if let answerError { next.append(.note(answerError, failed: true)) }
        if let openError, !trips.contains(where: { $0.id == openID }) { next.append(.note(openError, failed: true)) }
        for listed in trips {
            let open = listed.id == openID
            let trip = open && openTrip?.id == listed.id ? openTrip! : listed
            next.append(.folder(trip, open: open))
            guard open else { continue }
            if let from = trip.from { next.append(.text(String(localized: "From \(from)"), small: true)) }
            if !trip.description.isEmpty { next.append(.text(trip.description, small: false)) }
            if let removeError { next.append(.note(removeError, failed: true)) }
            next += rows.map { .row($0, tripID: trip.id) }
            if let rowsNote {
                next.append(.note(rowsNote.text, failed: rowsNote.failed))
            } else if rows.isEmpty {
                next.append(.note(trip.stats.count == 0 ? String(localized: "No tracks in this Trip yet. Add some with Add to trip.") : String(localized: "No tracks match these filters."), failed: false))
            }
        }
        if let trip = openTrip, trip.id == openID, trip.stats.count > 0 {
            let lines = [line(trip.stats)] + trip.byType.map { "\(TrackTypes.shared.label($0.trackType)): \(line($0))" }
            if let at = next.lastIndex(where: { if case .row = $0 { true } else { false } }) {
                next.insert(.text(lines.joined(separator: "\n"), small: true), at: at + 1)
            }
        }
        if let error {
            next.append(.note(error, failed: true))
        } else if !ready && trips.isEmpty {
            next.append(.note(String(localized: "Loading…"), failed: false))
        } else if ready && trips.isEmpty {
            next.append(.note(String(localized: "No Trips yet. Check tracks on the Tracks tab and use Add to trip, or make one with +."), failed: false))
        }
        items = next
        table.reloadData()
    }

    private func line(_ totals: TripTotals) -> String {
        [format.trackCount(totals.count), format.totalDistance(totals.distanceMeters), String(localized: "\(format.duration(totals.movingSeconds)) moving")].joined(separator: " · ")
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch items[indexPath.row] {
        case .row(let row, let tripID):
            let cell = tableView.dequeueReusableCell(withIdentifier: TrackRowCell.reuse, for: indexPath) as! TrackRowCell
            let id = row.track.id
            cell.bind(row, format: format, openTripID: tripID, demo: demo, onCheck: nil,
                      onOpenTrip: { [weak self] in self?.onEvent?(.open($0, collapse: true)) },
                      onRemove: { [weak self] in self?.remove(tripID: tripID, trackID: id) })
            cell.contentView.directionalLayoutMargins.leading = 36
            return cell
        case .folder(let trip, let open):
            return folderCell(trip, open: open)
        case .send(let send):
            return inboxCell(String(localized: "\(send.from) sent you a copy of “\(send.tripName)” (\(format.trackCount(send.trackCount))).") , send: send)
        case .copying(let copy):
            return inboxCell(String(localized: "Copying “\(copy.tripName)” from \(copy.from)…"), send: nil)
        case .text(let text, let small):
            return textCell(text, color: UIColor(resource: .inkSecondary), size: small ? DesignTokens.Text.sm : DesignTokens.Text.md)
        case .note(let text, let failed):
            return textCell(text, color: UIColor(resource: failed ? .danger : .inkSecondary), size: DesignTokens.Text.md)
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch items[indexPath.row] {
        case .row(let row, _) where !row.track.pending: onEvent?(.select(row.track.id))
        case .folder(let trip, let open) where !open: onEvent?(.open(trip.id, collapse: true))
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

    private func folderCell(_ trip: Trip, open: Bool) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "plain")!
        var config = UIListContentConfiguration.cell()
        config.text = trip.name
        config.image = Controls.icon(UIImage(resource: open ? .chevronDown : .chevronRight), size: 16)
        config.imageProperties.tintColor = UIColor(resource: open ? .accentStrong : .inkSecondary)
        config.textProperties.font = Typeface.sans(DesignTokens.Text.lg, weight: DesignTokens.Weight.semibold)
        config.textProperties.color = UIColor(resource: .ink)
        cell.contentConfiguration = config
        cell.backgroundColor = open ? UIColor(resource: .surfaceTint) : .clear
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = "tripFolder"
        cell.accessibilityValue = open ? String(localized: "Open") : String(localized: "Folded")

        let edit = Controls.iconButton(UIImage(resource: .pencil), label: demo ? String(localized: "The demo account can't change a Trip") : String(localized: "Rename \(trip.name)"), id: "tripEdit")
        let send = Controls.iconButton(UIImage(resource: .send), label: demo ? String(localized: "The demo account can't change a Trip") : String(localized: "Send a copy of \(trip.name)"), id: "tripSend")
        let delete = Controls.iconButton(UIImage(resource: .trash2), label: demo ? String(localized: "The demo account can't change a Trip") : String(localized: "Delete \(trip.name)"), id: "tripDelete")
        for b in [edit, send, delete] { b.isEnabled = !demo }
        edit.addAction(UIAction { [weak self] _ in self?.rename(trip) }, for: .primaryActionTriggered)
        send.addAction(UIAction { [weak self] _ in self?.sendCopy(trip) }, for: .primaryActionTriggered)
        delete.addAction(UIAction { [weak self] _ in self?.confirmDelete(trip) }, for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [edit, send, delete])
        buttons.frame = CGRect(x: 0, y: 0, width: 132, height: 44)
        cell.accessoryView = buttons
        return cell
    }

    private func inboxCell(_ text: String, send: TripSend?) -> UITableViewCell {
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

    private func answer(_ send: TripSend, accept: Bool) {
        guard !answering else { return }
        answering = true
        answerError = nil
        render()
        Task {
            do { try await api.answerTripSend(send.id, accept: accept) } catch {
                answerError = Self.message(error, String(localized: "The Trip couldn't be saved."))
            }
            answering = false
            render()
            loadInbox()
        }
    }

    /// × on a row: out of the Trip at once, with no confirmation; the track stays.
    private func remove(tripID: String, trackID: String) {
        Task {
            do {
                let read = try await api.changeTripTracks(tripID, trackIDs: [trackID], add: false)
                removeError = nil
                trips = trips.map { $0.id == read.trip.id ? read.trip : $0 }
                if read.trip.id == openID { openTrip = read.trip }
                onEvent?(.removed(trackID))
            } catch {
                removeError = Self.message(error, String(localized: "The Trip couldn't be saved."))
            }
            render()
        }
    }

    private func create() {
        TripDialogs.name(over: table, title: String(localized: "New trip"), name: "", description: "", action: String(localized: "Create")) { [weak self] name, description in
            guard let self else { return nil }
            do {
                let read = try await self.api.createTrip(name: name, description: description, trackIDs: [])
                self.added(read.trip)
                self.onEvent?(.open(read.trip.id, collapse: false))
                return nil
            } catch {
                return Self.message(error, String(localized: "The Trip couldn't be saved."))
            }
        }
    }

    private func rename(_ trip: Trip) {
        TripDialogs.name(over: table, title: String(localized: "Rename trip"), name: trip.name, description: trip.description, action: String(localized: "Save")) { [weak self] name, description in
            guard let self else { return nil }
            do {
                let read = try await self.api.updateTrip(trip.id, name: name, description: description)
                self.trips = self.trips.map { $0.id == trip.id ? read.trip : $0 }
                if trip.id == self.openID { self.openTrip = read.trip }
                self.onEvent?(.tripsChanged)
                self.render()
                return nil
            } catch {
                return Self.message(error, String(localized: "The Trip couldn't be saved."))
            }
        }
    }

    private func sendCopy(_ trip: Trip) {
        TripDialogs.sendCopy(over: table, trip: trip) { [weak self] email in
            guard let self else { return nil }
            do {
                try await self.api.sendTrip(trip.id, email: email)
                return nil
            } catch {
                return Self.message(error, String(localized: "The copy couldn't be sent."))
            }
        }
    }

    private func confirmDelete(_ trip: Trip) {
        TripDialogs.confirm(over: table, title: String(localized: "Delete this Trip?"),
                             message: String(localized: "“\(trip.name)” will be deleted. Its tracks stay on your map."),
                             action: String(localized: "Delete trip")) { [weak self] in
            guard let self else { return nil }
            do {
                try await self.api.deleteTrip(trip.id)
            } catch {
                return Self.message(error, String(localized: "The Trip couldn't be deleted."))
            }
            self.trips.removeAll { $0.id == trip.id }
            self.onEvent?(.tripsChanged)
            if trip.id == self.openID {
                if let next = self.trips.first { self.onEvent?(.open(next.id, collapse: false)) } else { self.onEvent?(.close) }
            }
            self.render()
            return nil
        }
    }

    static func message(_ error: Error, _ fallback: String) -> String {
        (error as? APIError)?.serverMessage ?? fallback
    }
}