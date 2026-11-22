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
        case send(TripSend), copying(TripCopying), folder(Trip, open: Bool), text(String, small: Bool), stats(Trip)
        case row(TrackRowCell.Row, tripID: String), note(String, failed: Bool)
    }
    private var items: [Item] = []

    init(api: APIClient, format: PanelFormat, demo: Bool) {
        self.api = api
        self.format = format
        self.demo = demo
        super.init()
        // As on Android, no +: a Trip is made from tracks, with Add to trip.
        let title = Controls.label(String(localized: "Trips"), font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink))
        head.axis = .vertical
        head.addArrangedSubview(title)
        let subtext = Controls.label(String(localized: "trips.subtext", defaultValue: "Hand-picked sets of your tracks. Only you can see them.", comment: "The Trips tab: what a Trip is."),
                                     font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
        subtext.numberOfLines = 0
        head.addArrangedSubview(subtext)

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
                self.error = Self.message(error, String(localized: "Could not load your trips"))
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
                    openError = String(localized: "This trip doesn't exist, or isn't yours.")
                } else {
                    openError = Self.message(error, String(localized: "Could not load your trips"))
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
                next.append(.note(trip.stats.count == 0 ? String(localized: "trips.noTracks", defaultValue: "No tracks in this trip.", comment: "An open Trip with no tracks.") : String(localized: "No tracks here match the current filters."), failed: false))
            }
        }
        // The whole Trip's numbers, and each type's share, under its rows (Android's footer).
        if let trip = openTrip, trip.id == openID, trip.stats.count > 0,
           let at = next.lastIndex(where: { if case .row = $0 { true } else { false } }) {
            next.insert(.stats(trip), at: at + 1)
        }
        if let error {
            next.append(.note(error, failed: true))
        } else if !ready && trips.isEmpty {
            next.append(.note(String(localized: "Loading…"), failed: false))
        } else if ready && trips.isEmpty {
            next.append(.note(String(localized: "trips.empty", defaultValue: "No trips yet. On the Tracks tab, check the tracks you want, or tap one, then choose Add to trip.", comment: "The Trips tab with no Trips."), failed: false))
        }
        items = next
        table.reloadData()
    }

    /// "3 tracks · 58 km · 3h 26m moving": the Trip's, or one type's share of it.
    private func line(_ totals: TripTotals) -> String {
        String(localized: "trips.stats", defaultValue: "\(format.trackCount(totals.count)) · \(format.totalDistance(totals.distanceMeters)) · \(format.duration(totals.movingSeconds)) moving",
               comment: "A Trip's numbers: its tracks, distance and moving time.")
    }

    /// The open Trip's line, then By track type: each type's label beside its share.
    private func statsCell(_ trip: Trip) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "stats") ?? UITableViewCell(style: .default, reuseIdentifier: "stats")
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        // Indented as the Trip's rows it totals.
        cell.contentView.directionalLayoutMargins.leading = 36
        let small = Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote)
        let whole = Controls.label(line(trip.stats), font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold, relativeTo: .subheadline), color: UIColor(resource: .ink))
        whole.numberOfLines = 0
        whole.accessibilityIdentifier = "tripStats"
        var views: [UIView] = [whole]
        var typeLabels: [UILabel] = []
        if !trip.byType.isEmpty {
            views.append(Controls.label(String(localized: "trips.byType", defaultValue: "By track type", comment: "A Trip's numbers: the heading over each type's."), font: small, color: UIColor(resource: .inkSecondary)))
            // The types as one column, as Android's table has them: every label as wide as the widest.
            for type in trip.byType {
                let label = Controls.label(TrackTypes.shared.label(type.trackType), font: small, color: UIColor(resource: .inkSecondary))
                let value = Controls.label(line(type), font: small, color: UIColor(resource: .inkSecondary))
                label.numberOfLines = 0
                // Below the column's width, above the numbers', so the numbers take what's left.
                label.setContentHuggingPriority(UILayoutPriority(700), for: .horizontal)
                typeLabels.append(label)
                value.numberOfLines = 0
                let row = UIStackView(arrangedSubviews: [label, value])
                row.spacing = DesignTokens.Space.s12
                row.alignment = .firstBaseline
                views.append(row)
            }
        }
        let column = Controls.column(views, spacing: DesignTokens.Space.s4)
        column.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: DesignTokens.Space.s12),
            column.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -DesignTokens.Space.s12),
            column.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
        ])
        // Every type label as wide as the widest, measured, so the shares line up as a column; but
        // never past 40% of the row, so a long label or large text wraps rather than squeezing
        // the numbers out.
        let widest = typeLabels.map { ceil((($0.text ?? "") as NSString).size(withAttributes: [.font: small]).width) }.max() ?? 0
        for label in typeLabels {
            let wide = label.widthAnchor.constraint(equalToConstant: widest)
            wide.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([wide, label.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor, multiplier: 0.4)])
        }
        return cell
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
            return inboxCell(String(localized: "\(send.from) sent you a copy of “\(send.tripName)” · \(format.trackCount(send.trackCount))") , send: send)
        case .copying(let copy):
            return inboxCell(String(localized: "Copying “\(copy.tripName)” from \(copy.from)…"), send: nil)
        case .text(let text, let small):
            return textCell(text, color: UIColor(resource: .inkSecondary), size: small ? DesignTokens.Text.sm : DesignTokens.Text.md)
        case .stats(let trip):
            return statsCell(trip)
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

        // Each named for its Trip, since VoiceOver reads a folder's buttons on their own.
        func named(_ action: String) -> String { demo ? String(localized: "Not available for demo accounts — create an account to change trips") : "\(action): \(trip.name)" }
        let edit = Self.chip(.pencil, named(String(localized: "trips.edit", defaultValue: "Edit name and description", comment: "A Trip's folder: rename it.")), id: "tripEdit")
        let send = Self.chip(.send, named(String(localized: "trips.send", defaultValue: "Send a copy", comment: "A Trip's folder: send someone a copy.")), id: "tripSend")
        let delete = Self.chip(.trash2, named(String(localized: "trips.delete", defaultValue: "Delete trip", comment: "A Trip's folder: delete it.")), id: "tripDelete")
        for b in [edit, send, delete] { b.isEnabled = !demo }
        edit.addAction(UIAction { [weak self] _ in self?.rename(trip) }, for: .primaryActionTriggered)
        send.addAction(UIAction { [weak self] _ in self?.sendCopy(trip) }, for: .primaryActionTriggered)
        delete.addAction(UIAction { [weak self] _ in self?.confirmDelete(trip) }, for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [edit, send, delete])
        buttons.spacing = DesignTokens.Space.s6
        buttons.frame = CGRect(x: 0, y: 0, width: 3 * 36 + 2 * DesignTokens.Space.s6, height: 36)
        cell.accessoryView = buttons
        return cell
    }

    /// A folder's action in its own box, as Android's panel chips.
    private static func chip(_ icon: ImageResource, _ label: String, id: String) -> UIButton {
        var config = UIButton.Configuration.bordered()
        config.image = Controls.icon(UIImage(resource: icon), size: 16)
        config.cornerStyle = .medium
        config.baseForegroundColor = UIColor(resource: .ink)
        config.baseBackgroundColor = UIColor(resource: .surface)
        config.background.strokeColor = UIColor(resource: .border)
        config.background.strokeWidth = 1
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
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
                answerError = Self.message(error, String(localized: "Could not save the trip"))
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
                removeError = Self.message(error, String(localized: "Could not save the trip"))
            }
            render()
        }
    }

    private func rename(_ trip: Trip) {
        TripDialogs.name(over: table, title: String(localized: "trips.editTitle", defaultValue: "Edit trip", comment: "The dialog renaming a Trip: its title."), name: trip.name, description: trip.description, action: String(localized: "Save")) { [weak self] name, description in
            guard let self else { return nil }
            do {
                let read = try await self.api.updateTrip(trip.id, name: name, description: description)
                self.trips = self.trips.map { $0.id == trip.id ? read.trip : $0 }
                if trip.id == self.openID { self.openTrip = read.trip }
                self.onEvent?(.tripsChanged)
                self.render()
                return nil
            } catch {
                return Self.message(error, String(localized: "Could not save the trip"))
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
        TripDialogs.confirm(over: table, title: String(localized: "trips.deleteTitle", defaultValue: "Delete trip", comment: "Deleting a Trip: the dialog's title."),
                             message: String(localized: "trips.deleteMessage", defaultValue: "Delete “\(trip.name)”? Its tracks stay.", comment: "Deleting a Trip: the question, with its name."),
                             action: String(localized: "trips.deleteButton", defaultValue: "Delete trip", comment: "Deleting a Trip: the button.")) { [weak self] in
            guard let self else { return nil }
            do {
                try await self.api.deleteTrip(trip.id)
            } catch {
                return Self.message(error, String(localized: "Could not delete the trip"))
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