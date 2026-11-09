import HoldMyTrackCore
import UIKit

/// The Edit window's Photos tab (apps/android/docs/SPEC.md FR-2.10), Android's PhotosTab: the
/// activity's photos as a list, each with Edit and Delete, and Add photos. Nothing is written
/// until the window's Save (save); Cancel throws the draft away. The list and the map (onOverlay)
/// show the photos as Save would leave them.
///
/// Add prepares each picked photo (PhotoPrep) and asks the server where it goes (the placement
/// check, which stores nothing); one it can't place waits at the top with a slider, starting just
/// after the photo picked before it (PhotoTrack.startFraction), until the user puts it somewhere
/// or removes it. Edit opens the same slider on a photo, with its caption. The slider walks the
/// track as drawn, and the photo moves along the map with it.
final class PhotosTabView: UIView {
    private let api: APIClient
    private let images: PhotoImages
    private let format: PanelFormat
    private let activity: Activity
    /// Add photos: the window opens the system photo picker and hands what's picked to add.
    var onPick: (() -> Void)?
    /// How the map should show the draft, or nil for the saved photos as they are.
    var onOverlay: ((PhotoMarkerOverlay?) -> Void)?
    /// The draft changed: the window's tab label follows it.
    var onChange: (() -> Void)?

    private(set) var draft = PhotoDraft()
    /// Any photo write landed: a later failure or a Cancel still reports it.
    private(set) var photosSaved = false
    /// This tab is the one showing: only then does it draw the draft on the map.
    var active = false { didSet { render() } }
    /// The window is saving: nothing here changes meanwhile.
    var busy = false { didSet { render() } }

    private var photos: [Photo] = []
    private var photosLoaded = false
    private var photosError: String?
    private var track: PhotoTrack?
    private var trackError: String?
    private var progress: (done: Int, total: Int)?
    private var failures: [String] = []
    private var editingID: String?
    private var frozenOrder: [String] = []
    /// The waiting photo's slider: which photo it's for, and where it is.
    private var waitingAt: (key: String, fraction: Double)?
    /// What each waiting photo was picked after, and which were removed rather than placed.
    private var anchors: [String: PlaceAnchor?] = [:]
    private var removed: Set<String> = []
    private var rowViews: [String: PhotoRowView] = [:]
    private var nextKey = 0

    private let add = Controls.secondaryButton(String(localized: "Add photos"), id: "photosAdd", icon: Controls.icon(UIImage(resource: .imagePlus), size: 18))
    private let status = Controls.body()
    private let error = Controls.error(id: "photosError")
    private let failuresLabel = Controls.error(id: "photosFailures")
    private let note = Controls.body()
    private let list = Controls.column([], spacing: DesignTokens.Space.s4)
    private let waitingBox = UIView()
    private let waitingThumb = UIImageView()
    private let waitingName = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private let waitingMore = Controls.body()
    private let waitingSlider = PlaceSlider(id: "photoWaitingSlider")
    private let waitingRemove = Controls.textButton(String(localized: "Remove"), id: "photoWaitingRemove")
    private let waitingPlace = Controls.primaryButton(String(localized: "Place here"), id: "photoWaitingPlace")

    init(api: APIClient, images: PhotoImages, format: PanelFormat, activity: Activity) {
        self.api = api
        self.images = images
        self.format = format
        self.activity = activity
        super.init(frame: .zero)
        accessibilityIdentifier = "photosTab"
        add.addAction(UIAction { [weak self] _ in
            guard let self, !self.busy, self.progress == nil else { return }
            self.onPick?()
        }, for: .primaryActionTriggered)
        waitingRemove.addAction(UIAction { [weak self] _ in
            guard let self, let photo = self.draft.waiting.first else { return }
            self.removeNew(photo.key)
        }, for: .primaryActionTriggered)
        waitingPlace.addAction(UIAction { [weak self] _ in self?.placeWaiting() }, for: .primaryActionTriggered)
        waitingSlider.onMove = { [weak self] fraction in
            guard let self, let photo = self.draft.waiting.first else { return }
            self.waitingAt = (photo.key, fraction)
            self.render()
        }
        buildWaiting()
        let column = Controls.column([add, status, error, failuresLabel, waitingBox, note, list], spacing: DesignTokens.Space.s12)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        load()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildWaiting() {
        waitingThumb.contentMode = .scaleAspectFill
        waitingThumb.clipsToBounds = true
        waitingThumb.layer.cornerRadius = DesignTokens.Radius.sm
        waitingThumb.widthAnchor.constraint(equalToConstant: 56).isActive = true
        waitingThumb.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let hint = Controls.body(String(localized: "Couldn't tell where this was taken. Move the slider to its place on the route."))
        let head = UIStackView(arrangedSubviews: [waitingThumb, Controls.column([waitingName, waitingMore], spacing: DesignTokens.Space.s2)])
        head.spacing = DesignTokens.Space.s8
        head.alignment = .center
        let buttons = UIStackView(arrangedSubviews: [waitingRemove, UIView(), waitingPlace])
        buttons.alignment = .center
        let column = Controls.column([head, hint, waitingSlider, buttons], spacing: DesignTokens.Space.s8)
        column.translatesAutoresizingMaskIntoConstraints = false
        waitingBox.addSubview(column)
        waitingBox.backgroundColor = UIColor(resource: .noticeBg)
        waitingBox.layer.cornerRadius = DesignTokens.Radius.md
        waitingBox.accessibilityIdentifier = "photoWaiting"
        let m = DesignTokens.Space.s12
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: waitingBox.topAnchor, constant: m),
            column.bottomAnchor.constraint(equalTo: waitingBox.bottomAnchor, constant: -m),
            column.leadingAnchor.constraint(equalTo: waitingBox.leadingAnchor, constant: m),
            column.trailingAnchor.constraint(equalTo: waitingBox.trailingAnchor, constant: -m),
        ])
    }

    /// The activity's saved photos and its track, for the list and the slider.
    private func load() {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.photos = try await self.api.photos(.activity(self.activity.id))
                self.photosLoaded = true
            } catch {
                self.photosError = (error as? APIError)?.serverMessage ?? String(localized: "The changes couldn't be saved.")
            }
            // The tab's count follows the photos read.
            self.changed()
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let metrics = try await self.api.trackMetrics(self.activity.id)
                if metrics.points.isEmpty {
                    self.trackError = String(localized: "This activity has no track to put photos on.")
                } else {
                    self.track = PhotoTrack(metrics.points.map { TimedPoint(lon: $0.lon, lat: $0.lat, t: $0.time) })
                }
            } catch {
                self.trackError = (error as? APIError)?.serverMessage ?? String(localized: "The changes couldn't be saved.")
            }
            self.render()
        }
    }

    /// How many photos Save would leave: the tab's count.
    var count: Int { photos.count - draft.deleted.count + draft.added.count }

    /// Why Save can't go ahead with the photos, or nil.
    var invalid: String? {
        switch draft.invalid {
        case .waiting: String(localized: "Place every new photo on the route before saving.")
        case .captionTooLong: String(localized: "Caption must be \(PhotoDraft.maxCaption) characters or fewer.")
        case nil: nil
        }
    }

    // MARK: Adding

    /// The picked files, with their names, prepared and placed one at a time; a nil URL is one
    /// the picker couldn't hand over.
    func add(_ files: [(url: URL?, name: String)]) {
        guard !files.isEmpty, !busy, progress == nil else { return }
        failures = []
        Task { [weak self] in
            var previous: PlaceAnchor?
            for (index, file) in files.enumerated() {
                guard let self else { return }
                self.progress = (index, files.count)
                self.render()
                let prepared = await Task.detached { file.url.flatMap { try? PhotoPrep.prepare($0) } }.value
                if let url = file.url { try? FileManager.default.removeItem(at: url) }
                guard let prepared else {
                    self.fail(file.name, String(localized: "This file can't be opened as a photo."))
                    continue
                }
                self.nextKey += 1
                let key = "new-\(self.nextKey)"
                do {
                    switch try await self.api.checkPhotoPlace(activityID: self.activity.id, exif: prepared.exif) {
                    case .at(let t):
                        self.addNew(key, file.name, prepared, routeAt: t)
                        previous = .at(t: t)
                    case .needsPlace:
                        self.anchors[key] = previous
                        self.addNew(key, file.name, prepared, routeAt: nil)
                        previous = .waiting(key)
                    }
                } catch {
                    self.fail(file.name, (error as? APIError)?.serverMessage ?? String(localized: "The changes couldn't be saved."))
                }
            }
            self?.progress = nil
            self?.render()
        }
    }

    private func addNew(_ key: String, _ name: String, _ prepared: PreparedPhoto, routeAt: Double?) {
        if let image = UIImage(data: prepared.thumb) { images.store(image, for: Self.localPath(key)) }
        draft.add(NewPhoto(key: key, name: name, prepared: prepared, routeAt: routeAt))
        changed()
    }

    private func fail(_ name: String, _ message: String) {
        failures.append(String(localized: "\(name): \(message)", comment: "Photos tab: a picked file that couldn't be added, and why."))
        render()
    }

    /// Where a new photo's thumbnail sits in the image cache, for its row and its marker.
    static func localPath(_ key: String) -> String { "local:\(key)" }

    private func placeWaiting() {
        guard let photo = draft.waiting.first, let at = waitingAt, at.key == photo.key, let point = try? track?.point(at: at.fraction) else { return }
        draft.changeNew(photo.key) { $0.routeAt = point.t }
        changed()
    }

    private func removeNew(_ key: String) {
        removed.insert(key)
        if editingID == key { editingID = nil }
        draft.removeNew(key)
        changed()
    }

    private func changed() {
        render()
        onChange?()
    }

    // MARK: Saving

    /// Writes the draft to the activity, one request at a time: uploads, then moves and captions,
    /// then deletes. Each write that lands leaves the draft, so Save again carries on from where
    /// this stopped. progress counts the writes; the answer is the failure, or nil once all is written.
    func save(progress: @escaping (Int, Int) -> Void) async -> Error? {
        let snapshot = draft
        let total = snapshot.size
        var done = 0
        progress(done, total)
        defer { changed() }
        do {
            for photo in snapshot.added {
                _ = try await api.uploadPhoto(activityID: activity.id, photo: photo.prepared, routeAt: photo.routeAt ?? 0,
                                              caption: photo.caption.trimmingCharacters(in: .whitespacesAndNewlines))
                photosSaved = true
                draft.removeNew(photo.key)
                done += 1
                progress(done, total)
            }
            for (id, change) in snapshot.changed where !snapshot.deleted.contains(id) {
                try await api.updatePhoto(id, caption: change.caption?.trimmingCharacters(in: .whitespacesAndNewlines), routeAt: change.routeAt)
                photosSaved = true
                draft.changeWritten(id)
                done += 1
                progress(done, total)
            }
            for id in snapshot.deleted {
                try await api.deletePhoto(id)
                photosSaved = true
                draft.deleteWritten(id)
                done += 1
                progress(done, total)
            }
        } catch {
            return error
        }
        return nil
    }

    // MARK: Rendering

    private func render() {
        let waitingList = draft.waiting
        let waiting = waitingList.first
        // A waiting photo's slider starts just after the photo picked before it, worked out when
        // its turn comes, since the one before may only just have been placed.
        if let waiting, let track, waitingAt?.key != waiting.key {
            var placed: [String: Double?] = [:]
            for p in draft.added { if let t = p.routeAt { placed[p.key] = track.fraction(at: t) } }
            for key in removed { placed[key] = .some(nil) }
            waitingAt = (waiting.key, track.startFraction(anchor: anchors[waiting.key] ?? nil, placed: placed, anchors: anchors))
        }
        if waiting == nil { waitingAt = nil }

        add.isEnabled = !busy && progress == nil && track != nil
        status.text = progress.map { String(localized: "Preparing \($0.done + 1) of \($0.total)…") }
        status.isHidden = progress == nil
        let shownError = photosError ?? trackError
        error.text = shownError
        error.isHidden = shownError == nil
        failuresLabel.text = failures.joined(separator: "\n")
        failuresLabel.isHidden = failures.isEmpty

        waitingBox.isHidden = waiting == nil
        if let waiting {
            waitingThumb.image = images.cached(Self.localPath(waiting.key))
            waitingName.text = waiting.name
            waitingMore.text = waitingList.count > 1 ? String(localized: "More waiting: \(waitingList.count - 1)") : nil
            waitingMore.isHidden = waitingList.count <= 1
            let at = waitingAt?.key == waiting.key ? waitingAt?.fraction : nil
            waitingSlider.bind(fraction: at, time: at.flatMap(clock(at:)), enabled: !busy)
            waitingRemove.isEnabled = !busy
            waitingPlace.isEnabled = !busy && track != nil && at != nil
        }

        let sorted = draft.rows(photos)
        // The list keeps its order while a row is open, so a dragged slider doesn't move its row
        // out from under the finger, and takes up its new place when the row closes.
        if editingID == nil { frozenOrder = sorted.map(\.id) }
        let rows: [DraftRow]
        if editingID == nil {
            rows = sorted
        } else {
            let byID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            rows = frozenOrder.compactMap { byID[$0] } + sorted.filter { !frozenOrder.contains($0.id) }
        }
        if !photosLoaded && photosError == nil {
            note.text = String(localized: "Loading photos…")
        } else if rows.isEmpty && waiting == nil && shownError == nil {
            note.text = String(localized: "No photos yet. Add the ones you took on this activity — each goes on the route where it was taken.")
        } else {
            note.text = nil
        }
        note.isHidden = note.text == nil
        renderRows(rows)
        renderOverlay(rows, waiting: waiting)
    }

    private func renderRows(_ rows: [DraftRow]) {
        let wanted = Set(rows.map(\.id))
        for (id, view) in rowViews where !wanted.contains(id) {
            view.removeFromSuperview()
            rowViews[id] = nil
        }
        for (index, row) in rows.enumerated() {
            let view = rowViews[row.id] ?? makeRow(row.id)
            let label = row.caption.isEmpty ? String(localized: "Photo \(index + 1)") : row.caption
            let open = editingID == row.id && track != nil
            let place = open ? track.map { t in (t.fraction(at: row.routeAt), clock(at: t.fraction(at: row.routeAt)) ?? "") } : nil
            view.bind(row, look: PhotoRowView.Look(label: label, time: format.clock(row.routeAt, zone: activity.timezone), place: place,
                                                  open: open, canEdit: track != nil, busy: busy))
            let path: String
            switch row {
            case .saved(let photo, _, _, _, _): path = photo.thumbURL
            case .new(let photo, _): path = Self.localPath(photo.key)
            }
            if view.thumbFor != path {
                view.setThumb(images.cached(path), for: path)
                images.thumb(path) { [weak view] image in
                    guard let view, view.thumbFor == path else { return }
                    view.setThumb(image, for: path)
                }
            }
            if list.arrangedSubviews.firstIndex(of: view) != index {
                list.removeArrangedSubview(view)
                list.insertArrangedSubview(view, at: index)
            }
        }
    }

    private func makeRow(_ id: String) -> PhotoRowView {
        let view = PhotoRowView()
        view.onEdit = { [weak self] in
            guard let self else { return }
            self.editingID = self.editingID == id ? nil : id
            self.render()
        }
        view.onDone = { [weak self] in
            self?.endEditing(true)
            self?.editingID = nil
            self?.render()
        }
        view.onDelete = { [weak self] in
            guard let self, let row = self.draft.rows(self.photos).first(where: { $0.id == id }) else { return }
            switch row {
            case .new(let photo, _): self.removeNew(photo.key)
            case .saved:
                if self.editingID == id { self.editingID = nil }
                self.draft.setDeleted(id, true)
                self.changed()
            }
        }
        view.onKeep = { [weak self] in
            self?.draft.setDeleted(id, false)
            self?.changed()
        }
        view.onMove = { [weak self] fraction in
            guard let self, let t = try? self.track?.point(at: fraction).t else { return }
            self.edit(id, routeAt: t, caption: nil)
        }
        view.onCaption = { [weak self] text in self?.edit(id, routeAt: nil, caption: text) }
        rowViews[id] = view
        return view
    }

    private func edit(_ id: String, routeAt: Double?, caption: String?) {
        if let photo = photos.first(where: { $0.id == id }) {
            draft.change(photo, routeAt: routeAt, caption: caption)
        } else {
            draft.changeNew(id) { p in
                if let routeAt { p.routeAt = routeAt }
                if let caption { p.caption = caption }
            }
        }
        changed()
    }

    /// The map shows the photos as Save would leave them, while this tab shows.
    private func renderOverlay(_ rows: [DraftRow], waiting: NewPhoto?) {
        guard active, let track else {
            onOverlay?(nil)
            return
        }
        var upserts: [PhotoMarkerItem] = []
        for row in rows {
            if case .saved(_, _, _, let deleted, let changed) = row, deleted || !changed { continue }
            guard let p = try? track.point(at: track.fraction(at: row.routeAt)) else { continue }
            let path = switch row {
            case .saved(let photo, _, _, _, _): photo.thumbURL
            case .new(let photo, _): Self.localPath(photo.key)
            }
            upserts.append(PhotoMarkerItem(id: row.id, lon: p.lon, lat: p.lat, caption: row.caption.isEmpty ? nil : row.caption, thumbPath: path))
        }
        if let waiting, let at = waitingAt, at.key == waiting.key, let p = try? track.point(at: at.fraction) {
            upserts.append(PhotoMarkerItem(id: waiting.key, lon: p.lon, lat: p.lat, caption: nil, thumbPath: Self.localPath(waiting.key)))
        }
        onOverlay?(PhotoMarkerOverlay(upserts: upserts, hidden: Set(draft.deleted), activeID: waiting?.key ?? editingID))
    }

    /// The time of day fraction of the way along the track.
    private func clock(at fraction: Double) -> String? {
        guard let point = try? track?.point(at: fraction) else { return nil }
        return format.clock(point.t, zone: activity.timezone)
    }
}
