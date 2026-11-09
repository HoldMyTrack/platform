import HoldMyTrackCore
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Edit (root docs/SPEC.md FR-5.10, apps/android/docs/SPEC.md FR-2.7) over the toolbar's target:
/// one activity's type, name and description, or a group's type alone. Save writes only what
/// changed, one activity at a time (EditPlan); a group of mixed types starts with Type empty, and
/// leaving it empty keeps each its own. One activity also has a Track tab (TrackEditorView) and a
/// Photos tab (PhotosTabView), each open only when the server allows it (EditAvailability); the
/// same Save writes the fields, then the photos, then the track edit.
///
/// A sheet that stops at half height with the map live above it, so the track's edits and the
/// Photos tab's slider show on the route in sight.
final class EditActivityViewController: UIViewController, PHPickerViewControllerDelegate {
    private let api: APIClient
    private let group: [Activity]
    /// The range's types with their counts, listed first in the Type menu.
    private let facets: [TypeFacet]
    private let format: PanelFormat
    /// The ids written, and whether any photo was, once Save is done or Cancel follows a partial save.
    private let onDone: ([String], Bool) -> Void
    /// One activity's Photos tab, else nil.
    private let photos: PhotosTabView?
    /// One activity's Track tab, else nil; the map hands it Delete point's and Move point's touches.
    let trackEditor: TrackEditorView?
    /// Why the Track or Photos tab can't be used, shown in its place.
    private let trackBlock: String?
    private let photosBlock: String?
    private let blocked = Controls.body()
    private let onTrackOpened: () -> Void
    private let tabs = UISegmentedControl()
    private let fields = UIStackView()
    private let status = Controls.body()

    private var type: String
    private var written: [String] = []
    private var saving = false
    private let typeButton = UIButton(type: .system)
    private let name = Controls.field(String(localized: "Name"), id: "editName")
    private let about = UITextView()
    private let error = Controls.error(id: "editError")

    init(api: APIClient, group: [Activity], facets: [TypeFacet], format: PanelFormat, images: PhotoImages,
         onOverlay: @escaping (PhotoMarkerOverlay?) -> Void, onTrackDraw: @escaping (TrackEditDrawing.Shape?) -> Void,
         onTrackOpened: @escaping () -> Void, onDone: @escaping ([String], Bool) -> Void) {
        self.api = api
        self.group = group
        self.facets = facets
        self.format = format
        self.onDone = onDone
        self.onTrackOpened = onTrackOpened
        let single = group.count == 1 ? group[0] : nil
        let trackBlock = EditAvailability.track(group).map(EditActivityViewController.message)
        let photosBlock = EditAvailability.photos(group).map(EditActivityViewController.message)
        self.trackBlock = trackBlock
        self.photosBlock = photosBlock
        trackEditor = single.flatMap { trackBlock == nil ? TrackEditorView(api: api, format: format, activity: $0) : nil }
        trackEditor?.onDraw = onTrackDraw
        photos = single.flatMap { photosBlock == nil ? PhotosTabView(api: api, images: images, format: format, activity: $0) : nil }
        photos?.onOverlay = onOverlay
        type = EditPlan.initialType(group)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        let single = group.count == 1 ? group[0] : nil
        title = single != nil ? String(localized: "Edit activity") : String(localized: "Edit activities: \(group.count)")
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        let save = UIBarButtonItem(title: String(localized: "Save"), primaryAction: UIAction { [weak self] _ in self?.save() })
        save.style = .done
        save.accessibilityIdentifier = "editSave"
        navigationItem.rightBarButtonItem = save
        isModalInPresentation = true

        let subtitle = Controls.body(single.map(format.label) ?? String(localized: "Changing the type changes it for every one of them."))
        var config = UIButton.Configuration.bordered()
        config.baseForegroundColor = UIColor(resource: .ink)
        config.image = Controls.icon(UIImage(resource: .chevronDown), size: 12)
        config.imagePlacement = .trailing
        typeButton.configuration = config
        typeButton.contentHorizontalAlignment = .leading
        typeButton.showsMenuAsPrimaryAction = true
        typeButton.accessibilityIdentifier = "editType"

        name.text = single?.name
        name.autocapitalizationType = .sentences
        name.isEnabled = single != nil
        about.text = single?.description
        about.font = Typeface.sans(DesignTokens.Text.xl)
        about.adjustsFontForContentSizeCategory = true
        about.backgroundColor = UIColor(resource: .surface)
        about.layer.cornerRadius = DesignTokens.Radius.sm
        about.layer.borderWidth = 1
        about.layer.borderColor = UIColor(resource: .border).cgColor
        about.isEditable = single != nil
        about.accessibilityIdentifier = "editDescription"
        about.accessibilityLabel = String(localized: "Description")
        about.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        var views: [UIView] = [Self.caption(String(localized: "Type")), typeButton]
        if single != nil {
            views += [Self.caption(String(localized: "Name")), name, Self.caption(String(localized: "Description")), about]
        } else {
            views.append(Controls.body(String(localized: "Name and description stay each activity's own.")))
        }
        for v in views { fields.addArrangedSubview(v) }
        fields.axis = .vertical
        fields.spacing = DesignTokens.Space.s12
        var column: [UIView] = [subtitle]
        if single != nil {
            tabs.insertSegment(withTitle: String(localized: "Activity"), at: 0, animated: false)
            tabs.insertSegment(withTitle: String(localized: "Track"), at: 1, animated: false)
            tabs.insertSegment(withTitle: String(localized: "Photos"), at: 2, animated: false)
            tabs.selectedSegmentIndex = 0
            tabs.accessibilityIdentifier = "editTabs"
            tabs.addAction(UIAction { [weak self] _ in self?.showTab() }, for: .valueChanged)
            photos?.onPick = { [weak self] in self?.pick() }
            photos?.onChange = { [weak self] in self?.renderTabs() }
            trackEditor?.onChange = { [weak self] in self?.renderTabs() }
            blocked.accessibilityIdentifier = "editTabBlocked"
            column += [tabs, fields, trackEditor, photos, blocked].compactMap { $0 }
            showTab()
        } else {
            column.append(fields)
        }
        status.isHidden = true
        column += [status, error]
        Controls.host(Controls.column(column), in: self)
        renderType()
        renderTabs()
    }

    /// The tab picked: the Track tab draws its edit on the map and the Photos tab its draft while
    /// each shows; one the server doesn't allow says why in its place.
    private func showTab() {
        let tab = tabs.selectedSegmentIndex
        view.endEditing(true)
        fields.isHidden = tab != 0
        trackEditor?.isHidden = tab != 1
        photos?.isHidden = tab != 2
        photos?.active = tab == 2
        if tab == 1, let trackEditor {
            trackEditor.open()
            onTrackOpened()
        } else {
            trackEditor?.hide()
        }
        let reason = tab == 1 ? trackBlock : tab == 2 ? photosBlock : nil
        blocked.text = reason
        blocked.isHidden = reason == nil
    }

    /// The tabs' labels: Track and Photos marked while they have unsaved changes, Photos with
    /// the count Save would leave.
    private func renderTabs() {
        let trackChanged = trackEditor?.session?.changed == true
        tabs.setTitle(trackChanged ? String(localized: "Track •", comment: "Edit window's tab with unsaved track changes.") : String(localized: "Track"), forSegmentAt: 1)
        if let photos {
            let count = format.count(photos.count)
            let title = photos.draft.isEmpty ? String(localized: "Photos: \(count)", comment: "Edit window's tab: the activity's photos, written as label: N.")
                : String(localized: "Photos: \(count) •", comment: "Edit window's tab with unsaved photo changes.")
            tabs.setTitle(title, forSegmentAt: 2)
        }
        let unsaved = [trackChanged ? String(localized: "Track, with unsaved changes") : nil,
                       photos?.draft.isEmpty == false ? String(localized: "Photos, with unsaved changes") : nil].compactMap { $0 }
        tabs.accessibilityValue = unsaved.isEmpty ? nil : unsaved.joined(separator: ", ")
    }

    /// Why a tab can't be used, in the server's terms (EditAvailability).
    private static func message(_ block: EditBlock) -> String {
        switch block {
        case .checkOne: String(localized: "Check exactly one activity to edit its track")
        case .pending: String(localized: "This track is still being processed")
        case .isPrivate: String(localized: "Entirely inside one of your private locations, so it isn't on the map and has no distance. Moving or removing that location brings it back.")
        case .noOriginal: String(localized: "This activity's original recording isn't stored, so its track can't be edited")
        case .badTimes: String(localized: "This track's points have no usable times, so it can't be edited")
        }
    }

    // MARK: Picking photos

    /// iOS's own picker, which needs no Photos access: the current representation, so the file
    /// keeps the EXIF the placement check reads.
    private func pick() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        Task {
            var files: [(url: URL?, name: String)] = []
            for result in results {
                files.append((await Self.copy(result.itemProvider), result.itemProvider.suggestedName ?? String(localized: "Photo")))
            }
            photos?.add(files)
        }
    }

    /// The picked file copied somewhere it outlives the provider's callback, or nil.
    private static func copy(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let copy = FileManager.default.temporaryDirectory.appending(path: "pick-\(UUID().uuidString)-\(url.lastPathComponent)")
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: copy)) == nil ? nil : copy)
            }
        }
    }

    private static func caption(_ text: String) -> UILabel {
        Controls.label(text, font: Typeface.sans(DesignTokens.Text.sm, weight: DesignTokens.Weight.semibold, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    }

    /// The range's types with how many use each, then every other type the server described.
    private func renderType() {
        let types = ActivityTypes.shared
        var config = typeButton.configuration
        config?.title = type.isEmpty ? String(localized: "Mixed types") : types.label(type)
        typeButton.configuration = config
        let pick = { [weak self] (value: String) in
            self?.type = value
            self?.error.isHidden = true
            self?.renderType()
        }
        let inRange = facets.map { f in
            UIAction(title: types.label(f.type), subtitle: format.count(f.count), image: ActivityTypes.icon(types.kind(f.type)), state: f.type == type ? .on : .off) { _ in pick(f.type) }
        }
        let shown = Set(facets.map(\.type))
        let others = types.known.filter { !shown.contains($0) }.map { t in
            UIAction(title: types.label(t), image: ActivityTypes.icon(types.kind(t)), state: t == type ? .on : .off) { _ in pick(t) }
        }
        typeButton.menu = UIMenu(children: [UIMenu(options: .displayInline, children: inRange), UIMenu(options: .displayInline, children: others)])
    }

    private func save() {
        guard !saving else { return }
        let nameText = name.text ?? "", aboutText = about.text ?? ""
        if let invalid = photos?.invalid {
            show(invalid)
            return
        }
        if let invalid = EditPlan.invalid(group: group, type: type, name: nameText, description: aboutText) {
            let message = switch invalid {
            case .typeRequired: String(localized: "Pick a type.")
            case .typeTooLong: String(localized: "The type can be at most \(EditPlan.maxType) characters.")
            case .nameTooLong: String(localized: "The name can be at most \(EditPlan.maxName) characters.")
            case .descriptionTooLong: String(localized: "The description can be at most \(EditPlan.maxDescription) characters.")
            }
            show(message)
            return
        }
        let writes = EditPlan.writes(group: group, type: type, name: nameText, description: aboutText).filter { !written.contains($0.id) }
        let trackChanged = trackEditor?.session?.changed == true
        guard !writes.isEmpty || photos?.draft.isEmpty == false || trackChanged else { return finish() }
        saving = true
        photos?.busy = true
        trackEditor?.busy = true
        error.isHidden = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        view.endEditing(true)
        Task {
            defer {
                saving = false
                photos?.busy = false
                trackEditor?.busy = false
                status.isHidden = true
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            for write in writes {
                do {
                    _ = try await api.updateActivity(write)
                    written.append(write.id)
                } catch {
                    show((error as? APIError)?.serverMessage ?? String(localized: "The changes couldn't be saved."))
                    return
                }
            }
            if let photos, !photos.draft.isEmpty {
                let failure = await photos.save { [weak self] done, total in
                    self?.status.text = String(localized: "Saving photos \(min(done + 1, total)) of \(total)…")
                    self?.status.isHidden = false
                }
                if let failure {
                    show((failure as? APIError)?.serverMessage ?? String(localized: "The changes couldn't be saved."))
                    return
                }
            }
            if trackChanged, !(await saveTrack(allowHidden: false)) { return }
            finish()
        }
    }

    /// The track edit, once the fields and photos are in; false when it isn't written. A split
    /// leaving a part inside a Private location asks first (root docs/SPEC.md FR-5.17).
    private func saveTrack(allowHidden: Bool) async -> Bool {
        guard let id = group.first?.id, let session = trackEditor?.session else { return true }
        do {
            switch try await api.saveTrackEdit(id, edit: session.pending, splitAt: session.splitAt, allowHidden: allowHidden) {
            case .queued:
                written.append(id)
                return true
            case .splitHidesPart(let message):
                confirmHiddenSplit(message)
                return false
            }
        } catch {
            show((error as? APIError)?.serverMessage ?? String(localized: "The changes couldn't be saved."))
            return false
        }
    }

    private func confirmHiddenSplit(_ message: String) {
        let alert = UIAlertController(title: String(localized: "Split into a private location?"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Split anyway"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.saving = true
            self.trackEditor?.busy = true
            Task {
                let done = await self.saveTrack(allowHidden: true)
                self.saving = false
                self.trackEditor?.busy = false
                if done { self.finish() }
            }
        })
        present(alert, animated: true)
    }

    /// Cancel asks first when photo changes would be thrown away.
    private func cancel() {
        guard !saving else { return }
        guard photos?.draft.isEmpty == false || trackEditor?.session?.changed == true else { return finish() }
        let alert = UIAlertController(title: String(localized: "Discard changes?"),
                                      message: String(localized: "The photos and track changes in this window haven't been saved yet."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Keep editing"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Discard"), style: .destructive) { [weak self] _ in self?.finish() })
        present(alert, animated: true)
    }

    private func finish() {
        let done = written, photosSaved = photos?.photosSaved ?? false
        photos?.active = false
        trackEditor?.hide()
        dismiss(animated: true) { self.onDone(done, photosSaved) }
    }

    private func show(_ message: String) {
        error.text = message
        error.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}