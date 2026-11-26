import HoldMyTrackCore
import UIKit

/// The sheet's Library tab (apps/android/docs/SPEC.md FR-4.1, root docs/SPEC.md FR-17.1): every
/// track the account keeps, a page of 100 at a time, not tied to the map's area. The search, the
/// sort and the Type, Dates, Distance and Trip filters ask the server for the page
/// (LibraryRules); the rows are the Tracks tab's. A row's tap opens it on the map; its tile checks
/// it, and the Checked tracks, which stay within the page, can be downloaded or deleted. The +
/// beside the search opens Sync, how more tracks come in.
@MainActor
final class LibraryPanel: NSObject, UITableViewDataSource, UITableViewDelegate {
    enum Event {
        /// A row was tapped: the Tracks tab shows it, focused, on its day.
        case open(track: String, day: String)
        /// Tracks were deleted: the map and the other lists are out of date.
        case deleted([String])
        /// The + was tapped: Sync opens in Library's place.
        case sync
        case say(String)
        /// The search took the keyboard: the sheet rises above it, so the filters and rows show.
        case searching
    }

    var onEvent: ((Event) -> Void)?
    let head = UIStackView()
    let content = UIView()

    private let api: APIClient
    /// The map's account as it is now: Settings may change its units or zone.
    private let currentAccount: () -> Account
    private var account: Account { currentAccount() }
    private var format: PanelFormat { PanelFormat(account: account) }
    private let downloads: TrackDownload

    /// The + that opens Sync, with the count of recordings waiting to be sent beside it.
    private let addButton = UIButton(type: .system)
    private let search = UISearchTextField()
    private let sortButton = UIButton(type: .system)
    private let typeButton = UIButton(type: .system)
    private let datesButton = UIButton(type: .system)
    private let distanceButton = UIButton(type: .system)
    private let tripButton = UIButton(type: .system)
    private let resetButton = Controls.textButton(String(localized: "panel.resetFilters", defaultValue: "Reset", comment: "Tracks tab: clears the Type and Distance filters."), id: "libraryReset")
    private let count = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let checkedBar = UIStackView()
    private let checkedLine = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private let downloadButton = Controls.iconButton(UIImage(resource: .download), label: String(localized: "panel.moreDownload", defaultValue: "Download as GPX", comment: "Tracks tab: the ⋯ menu's Download."), id: "libraryDownload")
    private let deleteButton = Controls.iconButton(UIImage(resource: .trash2), label: String(localized: "Delete"), id: "libraryDelete")
    private let table = UITableView(frame: .zero, style: .plain)
    private let empty = Controls.body()
    private let firstPage = Controls.textButton(String(localized: "library.firstPage", defaultValue: "Go to the first page", comment: "Library: a button under a page past the last one."), id: "libraryFirstPage")
    private let pagerRow = UIStackView()
    private let range = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let prevButton = Controls.iconButton(UIImage(resource: .chevronLeft), label: String(localized: "library.prev", defaultValue: "Previous page", comment: "Library: the pager's back button."), id: "libraryPrev")
    private let nextButton = Controls.iconButton(UIImage(resource: .chevronRight), label: String(localized: "library.next", defaultValue: "Next page", comment: "Library: the pager's forward button."), id: "libraryNext")
    private let progress = UIActivityIndicatorView(style: .medium)
    /// The checked bar's and the empty note's rows in the column, hidden whole.
    private var checkedRow = UIView()
    private var emptyRow = UIView()
    private weak var datesSheet: DatesViewController?

    private var state = LibraryRules.State()
    private var page: TrackPage?
    private var checked: Set<String> = []
    private var trips: [Trip] = []
    private var failed: String?
    private var reading: Task<Void, Never>?
    /// The search's and the Distance slider's waits, apart, so one never drops the other's change.
    private var searchSoon: Task<Void, Never>?
    private var distanceSoon: Task<Void, Never>?

    init(api: APIClient, account: @escaping () -> Account, downloads: TrackDownload) {
        self.api = api
        self.currentAccount = account
        self.downloads = downloads
        super.init()
        buildHead()
        buildContent()
    }

    // MARK: Showing

    /// The tab came to the front: the page is read again, since tracks may have come or gone.
    /// A search typed but not yet asked for when the tab left is asked for now.
    func start() {
        let q = (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if q != state.q { state = state.withFilter { $0.q = q } }
        read()
        Task {
            guard let read = try? await api.trips() else { return }
            trips = read.map(\.trip)
            render()
        }
    }

    func stop() {
        searchSoon?.cancel()
        search.resignFirstResponder()
        datesSheet?.dismiss(animated: true)
    }

    /// The recordings on the phone waiting to be sent (RecordingSends.waiting), as the tab bar's Library
    /// badge counts them.
    func setSyncWaiting(_ waiting: Int) {
        addButton.configuration?.title = waiting > 0 ? format.count(waiting) : nil
        addButton.accessibilityLabel = waiting > 0
            ? String(localized: "library.syncWaiting", defaultValue: "Add tracks, \(waiting) recordings waiting to be sent", comment: "Library: the + that opens Sync, with how many recordings wait to be sent.")
            : String(localized: "library.add", defaultValue: "Add tracks", comment: "Library: the + that opens Sync.")
    }

    // MARK: Building

    private func buildHead() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(resource: .plus)
        config.baseForegroundColor = UIColor(resource: .accent)
        config.imagePadding = DesignTokens.Space.s4
        addButton.configuration = config
        addButton.accessibilityIdentifier = "librarySync"
        addButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        addButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        addButton.addAction(UIAction { [weak self] _ in self?.onEvent?(.sync) }, for: .primaryActionTriggered)
        setSyncWaiting(0)
        search.placeholder = String(localized: "library.search", defaultValue: "Search names and descriptions", comment: "Library: the search field's hint.")
        search.accessibilityIdentifier = "librarySearch"
        search.returnKeyType = .search
        search.addAction(UIAction { [weak self] _ in self?.searchChanged() }, for: .editingChanged)
        search.addAction(UIAction { [weak self] _ in self?.onEvent?(.searching) }, for: .editingDidBegin)
        search.addAction(UIAction { [weak self] _ in self?.search.resignFirstResponder() }, for: .editingDidEndOnExit)
        // No title, as on Android: the tab bar names the tab. The search, and + beside it.
        let row = UIStackView(arrangedSubviews: [search, addButton])
        row.alignment = .center
        row.spacing = DesignTokens.Space.s8
        head.axis = .vertical
        head.addArrangedSubview(row)
    }

    private func buildContent() {
        for (button, id) in [(sortButton, "librarySort"), (typeButton, "libraryType"), (datesButton, "libraryDates"),
                             (distanceButton, "libraryDistance"), (tripButton, "libraryTrip")] {
            Controls.styleFilter(button, id: id)
        }
        sortButton.showsMenuAsPrimaryAction = true
        typeButton.showsMenuAsPrimaryAction = true
        tripButton.showsMenuAsPrimaryAction = true
        datesButton.addAction(UIAction { [weak self] _ in self?.showDates() }, for: .primaryActionTriggered)
        distanceButton.addAction(UIAction { [weak self] _ in self?.showDistance() }, for: .primaryActionTriggered)
        resetButton.addAction(UIAction { [weak self] _ in self?.reset() }, for: .primaryActionTriggered)
        // Reset first: the row scrolls sideways, and a Reset at its end would be off screen.
        let filters = UIStackView(arrangedSubviews: [resetButton, sortButton, typeButton, datesButton, distanceButton, tripButton])
        filters.spacing = DesignTokens.Space.s8
        filters.alignment = .center
        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        filters.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(filters)
        NSLayoutConstraint.activate([
            filters.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            filters.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            filters.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: DesignTokens.Space.s16),
            filters.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -DesignTokens.Space.s16),
            filters.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            scroller.heightAnchor.constraint(equalToConstant: 44),
        ])

        let uncheck = Controls.iconButton(UIImage(resource: .x), label: String(localized: "Uncheck all"), id: "libraryUncheck")
        uncheck.addAction(UIAction { [weak self] _ in self?.setChecked([]) }, for: .primaryActionTriggered)
        downloadButton.addAction(UIAction { [weak self] _ in self?.downloadChecked() }, for: .primaryActionTriggered)
        deleteButton.addAction(UIAction { [weak self] _ in self?.confirmDelete() }, for: .primaryActionTriggered)
        deleteButton.configuration?.baseForegroundColor = UIColor(resource: .danger)
        deleteButton.isHidden = account.isDemo
        for v in [uncheck, checkedLine, UIView(), downloadButton, deleteButton] { checkedBar.addArrangedSubview(v) }
        checkedBar.alignment = .center
        checkedBar.accessibilityIdentifier = "libraryChecked"

        count.accessibilityIdentifier = "libraryCount"
        let countRow = UIStackView(arrangedSubviews: [count, UIView(), progress])
        countRow.alignment = .center
        progress.hidesWhenStopped = true

        empty.numberOfLines = 0
        empty.textAlignment = .center
        empty.accessibilityIdentifier = "libraryEmpty"
        firstPage.addAction(UIAction { [weak self] _ in self?.goTo(1) }, for: .primaryActionTriggered)
        let emptyBox = Controls.column([empty, firstPage], spacing: DesignTokens.Space.s8)
        emptyBox.alignment = .center

        prevButton.addAction(UIAction { [weak self] _ in self?.goTo((self?.state.page ?? 2) - 1) }, for: .primaryActionTriggered)
        nextButton.addAction(UIAction { [weak self] _ in self?.goTo((self?.state.page ?? 0) + 1) }, for: .primaryActionTriggered)
        range.accessibilityIdentifier = "libraryRange"
        for v in [UIView(), prevButton, range, nextButton, UIView()] { pagerRow.addArrangedSubview(v) }
        pagerRow.alignment = .center
        pagerRow.spacing = DesignTokens.Space.s8
        pagerRow.isHidden = true

        table.dataSource = self
        table.delegate = self
        table.register(TrackRowCell.self, forCellReuseIdentifier: TrackRowCell.reuse)
        table.backgroundColor = .clear
        table.keyboardDismissMode = .onDrag
        table.accessibilityIdentifier = "libraryList"

        let inset = { (v: UIView) -> UIView in
            let box = UIView()
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: box.topAnchor), v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: DesignTokens.Space.s16),
                v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -DesignTokens.Space.s16),
            ])
            return box
        }
        // The column collapses only its own subviews: the inset boxes are what hide.
        checkedRow = inset(checkedBar)
        emptyRow = inset(emptyBox)
        checkedRow.isHidden = true
        emptyRow.isHidden = true
        let column = UIStackView(arrangedSubviews: [scroller, inset(countRow), checkedRow, emptyRow, table, pagerRow])
        column.axis = .vertical
        column.spacing = DesignTokens.Space.s4
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: Reading

    private func change(_ block: (inout LibraryRules.State) -> Void) {
        let next = state.withFilter(block)
        guard next != state else { return }
        state = next
        read()
    }

    private func goTo(_ page: Int) {
        state.page = page
        table.setContentOffset(.zero, animated: false)
        read()
    }

    private func searchChanged() {
        searchSoon?.cancel()
        searchSoon = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            let q = (self.search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.change { $0.q = q }
        }
    }

    private func reset() {
        search.text = ""
        searchSoon?.cancel()
        distanceSoon?.cancel()
        let kept = state
        change { $0 = LibraryRules.State(sort: kept.sort, desc: kept.desc) }
    }

    /// Reads the page state asks for; a newer read replaces one under way. Checked stays within
    /// the page, so a read clears it.
    private func read() {
        reading?.cancel()
        checked = []
        guard let query = LibraryRules.pageQuery(state, allTypes: page?.typeCounts.map(\.type) ?? []) else {
            // Every type left out matches nothing: no need to ask.
            page = page?.withNoRows
            failed = nil
            progress.stopAnimating()
            render()
            return
        }
        progress.startAnimating()
        render()
        reading = Task { [weak self, api] in
            do {
                let read = try await api.trackPage(query)
                guard let self, !Task.isCancelled else { return }
                TrackTypes.shared.merge(read.types)
                self.page = read
                self.failed = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.failed = (error as? APIError)?.serverMessage ?? String(localized: "The server couldn't be reached.")
            }
            self?.progress.stopAnimating()
            self?.render()
        }
    }

    // MARK: Drawing

    private var rows: [Track] { page?.tracks ?? [] }

    private func render() {
        let page = page
        let sorts: [(LibraryRules.Sort, Bool)] = [(.started, true), (.started, false), (.distance, true), (.distance, false),
                                                  (.moving, true), (.moving, false), (.added, true), (.added, false)]
        sortButton.configuration?.title = Self.sortLabel(state.sort, desc: state.desc)
        sortButton.menu = UIMenu(title: String(localized: "library.sortTitle", defaultValue: "Sort", comment: "Library: the sort menu's title."), children: sorts.map { sort, desc in
            UIAction(title: Self.sortLabel(sort, desc: desc), state: sort == state.sort && desc == state.desc ? .on : .off) { [weak self] _ in
                self?.change { $0.sort = sort; $0.desc = desc }
            }
        })

        let types = page?.typeCounts ?? []
        typeButton.configuration?.title = state.exclude.isEmpty ? String(localized: "Type") : String(localized: "Type •")
        typeButton.isEnabled = !types.isEmpty
        let all = UIAction(title: String(localized: "All types"), state: state.exclude.isEmpty ? .on : .off) { [weak self] _ in self?.change { $0.exclude = [] } }
        typeButton.menu = UIMenu(children: [all, UIMenu(options: .displayInline, children: types.map { type in
            UIAction(title: TrackTypes.shared.label(type.type), subtitle: format.count(type.count), image: TrackTypes.icon(TrackTypes.shared.kind(type.type)),
                     state: state.exclude.contains(type.type) ? .off : .on) { [weak self] _ in
                self?.change { $0.exclude.formSymmetricDifference([type.type]) }
            }
        })])

        let datesSet = state.after != nil || state.before != nil
        let datesText = DateFilter(after: state.after, before: state.before).buttonText(today: today)
        datesButton.configuration?.title = datesSet ? "\(datesText) •" : datesText
        datesButton.accessibilityLabel = String(localized: "Filter by dates")

        distanceButton.isHidden = page?.distance.map { $0.lowerBound >= $0.upperBound } ?? true
        if let band = state.distance {
            let top = band.max.map(format.distanceValue) ?? "∞"
            distanceButton.configuration?.title = String(localized: "\(format.distanceValue(band.min))–\(top) \(format.unit)")
        } else {
            distanceButton.configuration?.title = String(localized: "Any distance")
        }

        let tripName = state.trip.flatMap { id in trips.first { $0.id == id }?.name }
        tripButton.configuration?.title = tripName.map { "\($0) •" } ?? String(localized: "library.trip", defaultValue: "Trip", comment: "Library: the Trip filter.")
        tripButton.isEnabled = !trips.isEmpty || state.trip != nil
        tripButton.menu = UIMenu(children: [UIAction(title: String(localized: "library.anyTrip", defaultValue: "Any trip", comment: "Library: the Trip filter's no-filter choice."),
                                                     state: state.trip == nil ? .on : .off) { [weak self] _ in self?.change { $0.trip = nil } }]
            + trips.map { trip in
                UIAction(title: trip.name, state: state.trip == trip.id ? .on : .off) { [weak self] _ in self?.change { $0.trip = trip.id } }
            })
        resetButton.isHidden = !state.anyFilter

        let accountTotal = types.reduce(0) { $0 + $1.count }
        count.text = page.map { page in
            state.anyFilter
                ? String(localized: "library.countFiltered", defaultValue: "\(page.total) of \(accountTotal) tracks", comment: "Library: how many tracks pass the filters, of how many the account keeps.")
                : String(localized: "library.count", defaultValue: "\(page.total) tracks", comment: "Library: how many tracks the account keeps.")
        }

        // A failed read keeps the last page's rows, which aren't state.page's: the note shows alone.
        table.isHidden = failed != nil
        let pager = page.flatMap { LibraryRules.pager(page: state.page, total: $0.total, pageSize: $0.pageSize) }
        pagerRow.isHidden = failed != nil || !(pager.map { $0.prev || $0.next } ?? false)
        if let pager, let page {
            range.text = String(localized: "library.range", defaultValue: "\(pager.from)–\(pager.to) of \(page.total)", comment: "Library: the rows this page shows, of how many.")
            prevButton.isEnabled = pager.prev
            nextButton.isEnabled = pager.next
        }

        let reason = page.map { LibraryRules.emptyReason(state, total: $0.total, anyTrack: !$0.typeCounts.isEmpty) }
        let showEmpty = failed != nil || (page != nil && rows.isEmpty)
        emptyRow.isHidden = !showEmpty
        empty.text = failed.map { String(localized: "library.failed", defaultValue: "Couldn't load Library: \($0)", comment: "Library: the page couldn't be read, and why.") }
            ?? reason.map(emptyText)
        firstPage.isHidden = failed != nil || reason != .pastLast || !rows.isEmpty

        checked = LibraryRules.keepListed(checked, rows: rows.map(\.id))
        checkedRow.isHidden = checked.isEmpty
        checkedLine.text = String(localized: "panel.checkedCount", defaultValue: "\(checked.count) checked tracks", comment: "Tracks tab: the checked tracks an action applies to.")
        deleteButton.isEnabled = !rows.contains { checked.contains($0.id) && $0.pending }
        table.reloadData()
    }

    private var today: String { DateFilter.today(in: account.timezone) }

    private func emptyText(_ reason: LibraryRules.EmptyReason) -> String {
        switch reason {
        case .noTracks: String(localized: "library.emptyNoTracks", defaultValue: "No tracks yet. Add some with + above.", comment: "Library: the account keeps no track.")
        case .pastLast: String(localized: "library.emptyPastLast", defaultValue: "This page is past the last one.", comment: "Library: a page past the last, as after deleting the last page's tracks.")
        case .search: String(localized: "library.emptySearch", defaultValue: "No track's name or description has “\(state.q)”.", comment: "Library: the search matches nothing.")
        case .searchAndFilters: String(localized: "library.emptySearchAndFilters", defaultValue: "No track with “\(state.q)” passes these filters.", comment: "Library: the search and the filters together match nothing.")
        case .filters: String(localized: "library.emptyFilters", defaultValue: "No track passes these filters.", comment: "Library: the filters match nothing.")
        }
    }

    private static func sortLabel(_ sort: LibraryRules.Sort, desc: Bool) -> String {
        switch (sort, desc) {
        case (.started, true): String(localized: "library.sortStartedDesc", defaultValue: "Newest first", comment: "Library: a sort.")
        case (.started, false): String(localized: "library.sortStartedAsc", defaultValue: "Oldest first", comment: "Library: a sort.")
        case (.distance, true): String(localized: "library.sortDistanceDesc", defaultValue: "Longest first", comment: "Library: a sort.")
        case (.distance, false): String(localized: "library.sortDistanceAsc", defaultValue: "Shortest first", comment: "Library: a sort.")
        case (.moving, true): String(localized: "library.sortMovingDesc", defaultValue: "Most moving time first", comment: "Library: a sort.")
        case (.moving, false): String(localized: "library.sortMovingAsc", defaultValue: "Least moving time first", comment: "Library: a sort.")
        case (.added, true): String(localized: "library.sortAddedDesc", defaultValue: "Recently added first", comment: "Library: a sort.")
        case (.added, false): String(localized: "library.sortAddedAsc", defaultValue: "First added first", comment: "Library: a sort.")
        }
    }

    // MARK: Filters that open a sheet

    private func presenter() -> UIViewController? {
        var top = content.window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private func showDates() {
        guard let page else { return }
        let bounds = DateFilter.bounds(earliest: page.firstDate, latest: page.lastDate, today: today)
        let sheet = DatesViewController(filter: DateFilter(after: state.after, before: state.before), bounds: bounds, earliest: page.firstDate, today: today) { [weak self] end, value in
            guard let self else { return }
            let next = DateFilter(after: self.state.after, before: self.state.before).setting(end, to: value, bounds: bounds).filter
            self.datesSheet?.update(next)
            self.change { $0.after = next.after; $0.before = next.before }
        }
        datesSheet = sheet
        let nav = UINavigationController(rootViewController: sheet)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        presenter()?.present(nav, animated: true)
    }

    private func showDistance() {
        guard let span = page?.distance, span.lowerBound < span.upperBound else { return }
        let bounds = DistanceRange(min: span.lowerBound, max: span.upperBound)
        let current = state.distance.map { LibraryRules.sliderRange($0, bounds: bounds) }
        let picker = DistanceFilterViewController(bounds: bounds, current: current, format: format) { [weak self] next in
            guard let self else { return }
            // The slider moves in steps: read once it rests, not at every step.
            self.distanceSoon?.cancel()
            self.distanceSoon = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.change { $0.distance = next.map { LibraryRules.Distance(min: $0.min, max: $0.max) } }
            }
        }
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = distanceButton
        picker.popoverPresentationController?.delegate = picker
        presenter()?.present(picker, animated: true)
    }

    // MARK: Checked

    private func setChecked(_ next: Set<String>) {
        checked = next
        render()
    }

    private func toggle(_ id: String) {
        setChecked(checked.symmetricDifference([id]))
    }

    private func downloadChecked() {
        let picked = rows.filter { checked.contains($0.id) }
        if let blocked = LibraryRules.downloadBlocked(picked.map { ($0.id, $0.routeEdit) }), let track = picked.first(where: { $0.id == blocked.id }) {
            let why = switch blocked.why {
            case .pending: String(localized: "library.blockedPending", defaultValue: "it's still being processed", comment: "Library: why Download can't take a track.")
            case .private: String(localized: "library.blockedPrivate", defaultValue: "it's entirely inside a Private location", comment: "Library: why Download can't take a track.")
            case .noOriginal: String(localized: "library.blockedNoOriginal", defaultValue: "its original file isn't kept", comment: "Library: why Download can't take a track.")
            }
            onEvent?(.say(String(localized: "library.downloadBlocked", defaultValue: "\(format.label(track)) can't be downloaded: \(why)", comment: "Library: a checked track Download can't take, and why.")))
            return
        }
        guard let host = presenter() else { return }
        downloads.start(picked.map(\.id), from: host) { [weak self] in self?.onEvent?(.say($0)) }
    }

    private func confirmDelete() {
        let group = rows.filter { checked.contains($0.id) }
        guard !group.isEmpty, !account.isDemo else { return }
        let name = group.count == 1 ? String(localized: "“\(format.label(group[0]))”", comment: "Tracks tab: one track named as an action's target.")
            : String(localized: "panel.checkedCount", defaultValue: "\(group.count) checked tracks", comment: "Tracks tab: the checked tracks an action applies to.")
        let summary = "\(name) (\(format.totalDistance(group.compactMap(\.distanceMeters).reduce(0, +))))"
        let title = group.count == 1 ? String(localized: "Delete this track?") : String(localized: "Delete this group?")
        let message = group.count == 1
            ? String(localized: "\(summary) will be permanently deleted — its route, fog coverage, and any performance records it contributed to. This can't be undone.")
            : String(localized: "\(summary) will be permanently deleted — their routes, fog coverage, and any performance records they contributed to. This can't be undone.")
        var done: [String] = []
        TripDialogs.confirm(over: content, title: title, message: message, action: String(localized: "Delete")) { [weak self, api] in
            defer {
                if !done.isEmpty {
                    self?.onEvent?(.deleted(done))
                    self?.read()
                }
            }
            for track in group where !done.contains(track.id) {
                do {
                    try await api.deleteTrack(track.id)
                    done.append(track.id)
                } catch {
                    let reason = (error as? APIError)?.serverMessage ?? String(localized: "The server couldn't be reached.")
                    return String(localized: "Deleted: \(done.count). The rest couldn't be deleted: \(reason)")
                }
            }
            return nil
        }
    }

    // MARK: The list

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TrackRowCell.reuse, for: indexPath) as! TrackRowCell
        let track = rows[indexPath.row]
        let row = TrackRowCell.Row(track: track, checked: checked.contains(track.id), focused: false, hidden: false, selecting: !checked.isEmpty)
        cell.bind(row, format: format, openTripID: nil, demo: account.isDemo,
                  onCheck: { [weak self] in self?.toggle(track.id) },
                  onOpenTrip: { [weak self] id in self?.change { $0.trip = id } },
                  onRemove: nil)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let track = rows[indexPath.row]
        // While rows are checked, a tap checks too, as on the Tracks tab.
        if !checked.isEmpty {
            toggle(track.id)
            return
        }
        guard let day = TrackZone.day(startedAt: track.startedAt, own: track.timezone, account: account.timezone) else { return }
        search.resignFirstResponder()
        onEvent?(.open(track: track.id, day: day))
    }
}
