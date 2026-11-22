import HoldMyTrackCore
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Edit (root docs/SPEC.md FR-5.5, apps/android/docs/SPEC.md FR-2.7) over the toolbar's target:
/// one track's type, name and description, or a group's type alone. Save writes only what
/// changed, one track at a time (EditPlan); a group of mixed types starts with Type empty, and
/// leaving it empty keeps each its own. One track also has a Route tab (RouteEditorView) and a
/// Photos tab (PhotosTabView), each open only when the server allows it (EditAvailability); the
/// same Save writes the fields, then the photos, then the route edit.
///
/// A sheet as tall as its content up to EditSheet's share, with the map live above it, so the
/// track's edits and the Photos tab's slider show on the route in sight. Route and Photos show
/// for several tracks too, dimmed like a tab the server doesn't allow; a tap on one says why
/// under the tabs and stays where it is.
final class EditTrackViewController: UIViewController, PHPickerViewControllerDelegate, UIGestureRecognizerDelegate {
    /// The sheet's own detent, sized by fittingHeight.
    static let fitted = UISheetPresentationController.Detent.Identifier("editFitted")

    private let api: APIClient
    private let group: [Track]
    /// The range's types with their counts, the Type picker's list.
    private let facets: [TypeFacet]
    private let format: PanelFormat
    /// The ids written, and whether any photo was, once Save is done or Cancel follows a partial save.
    private let onDone: ([String], Bool) -> Void
    /// One track's Photos tab, else nil.
    private let photos: PhotosTabView?
    /// One track's Route tab, else nil; the map hands it Delete point's and Move point's touches.
    let routeEditor: RouteEditorView?
    /// Why the Track or Photos tab can't be used, shown in its place.
    private let routeBlock: String?
    private let photosBlock: String?
    private let blocked = Controls.body()
    /// The Route tab opened: the map frames the track above the sheet's height (covered).
    private let onRouteOpened: (_ covered: CGFloat) -> Void
    private let tabs = UISegmentedControl()
    private let fields = UIStackView()
    private var column: UIStackView?
    /// The fitting height last handed to the sheet, so a layout pass resizes it only on a change.
    private var lastFitting: CGFloat = 0
    /// The Route tab just opened: the map frames the track once the sheet has its new height.
    private var framePending = false
    private let status = Controls.body()

    private var type: String
    private var written: [String] = []
    private var saving = false
    private let typeButton = UIButton(type: .system)
    private let name = Controls.field(String(localized: "Name"), id: "editName")
    private let about = UITextView()
    private let error = Controls.error(id: "editError")

    init(api: APIClient, group: [Track], facets: [TypeFacet], format: PanelFormat, images: PhotoImages,
         onOverlay: @escaping (PhotoMarkerOverlay?) -> Void, onRouteDraw: @escaping (RouteEditDrawing.Shape?) -> Void,
         onRouteOpened: @escaping (CGFloat) -> Void, onDone: @escaping ([String], Bool) -> Void) {
        self.api = api
        self.group = group
        self.facets = facets
        self.format = format
        self.onDone = onDone
        self.onRouteOpened = onRouteOpened
        let single = group.count == 1 ? group[0] : nil
        let routeBlock = EditAvailability.route(group).map {
            EditTrackViewController.message($0, checkOne: String(localized: "Check exactly one track to edit its route"))
        }
        let photosBlock = EditAvailability.photos(group).map {
            EditTrackViewController.message($0, checkOne: String(localized: "edit.photosCheckOne", defaultValue: "Photos belong to one track — check just one to add or change them.",
                                                                 comment: "Edit over several tracks: why the Photos tab can't be opened."))
        }
        self.routeBlock = routeBlock
        self.photosBlock = photosBlock
        routeEditor = single.flatMap { routeBlock == nil ? RouteEditorView(api: api, format: format, track: $0) : nil }
        routeEditor?.onDraw = onRouteDraw
        photos = single.flatMap { photosBlock == nil ? PhotosTabView(api: api, images: images, format: format, track: $0) : nil }
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
        title = single != nil ? String(localized: "Edit track") : String(localized: "edit.titleMany", defaultValue: "Edit \(group.count) tracks", comment: "Edit window's title for several tracks.")
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        let save = UIBarButtonItem(title: String(localized: "Save"), primaryAction: UIAction { [weak self] _ in self?.save() })
        save.style = .done
        save.accessibilityIdentifier = "editSave"
        navigationItem.rightBarButtonItem = save
        isModalInPresentation = true

        let subtitle = Controls.body(single.map(format.label) ?? String(localized: "edit.multiSubtitle", defaultValue: "Type and Trips apply to every checked track; name and description are per-track.",
                                                                        comment: "Edit over several tracks: what the window changes."))
        var config = UIButton.Configuration.bordered()
        config.baseForegroundColor = UIColor(resource: .ink)
        config.image = Controls.icon(UIImage(resource: .chevronDown), size: 12)
        config.imagePlacement = .trailing
        typeButton.configuration = config
        typeButton.contentHorizontalAlignment = .leading
        typeButton.addAction(UIAction { [weak self] _ in self?.openTypePicker() }, for: .primaryActionTriggered)
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

        // Several tracks show Name and Description greyed out, with why, as on Android.
        var views: [UIView] = [Self.caption(String(localized: "Type")), typeButton,
                               Self.caption(String(localized: "Name")), name, Self.caption(String(localized: "Description")), about]
        if single == nil {
            name.alpha = 0.5
            about.alpha = 0.5
            about.isSelectable = false
            about.accessibilityTraits.insert(.notEnabled)
            let note = Controls.body(String(localized: "edit.multiReason", defaultValue: "Editing multiple tracks changes their type and Trips — name and description are per-track.",
                                            comment: "Edit over several tracks: why Name and Description are greyed out."))
            note.accessibilityIdentifier = "editMultiNote"
            views.append(note)
        }
        for v in views { fields.addArrangedSubview(v) }
        fields.axis = .vertical
        fields.spacing = DesignTokens.Space.s12
        tabs.insertSegment(withTitle: String(localized: "Track"), at: 0, animated: false)
        tabs.insertSegment(withTitle: String(localized: "Route"), at: 1, animated: false)
        tabs.insertSegment(withTitle: String(localized: "Photos"), at: 2, animated: false)
        tabs.selectedSegmentIndex = 0
        tabs.setEnabled(routeBlock == nil, forSegmentAt: 1)
        tabs.setEnabled(photosBlock == nil, forSegmentAt: 2)
        tabs.accessibilityIdentifier = "editTabs"
        let reasons = [routeBlock, photosBlock].compactMap { $0 }
        tabs.accessibilityHint = reasons.isEmpty ? nil : reasons.joined(separator: " ")
        tabs.addAction(UIAction { [weak self] _ in self?.showTab() }, for: .valueChanged)
        // A disabled segment takes no tap of its own; this one hears it and says why.
        let blockedTap = UITapGestureRecognizer(target: self, action: #selector(tappedTabs(_:)))
        blockedTap.cancelsTouchesInView = false
        blockedTap.delegate = self
        tabs.addGestureRecognizer(blockedTap)
        photos?.onPick = { [weak self] in self?.pick() }
        photos?.onChange = { [weak self] in self?.renderTabs() }
        routeEditor?.onChange = { [weak self] in self?.renderTabs() }
        routeEditor?.onLoaded = { [weak self] in
            if self?.tabs.selectedSegmentIndex == 1 { self?.frameRoute() }
        }
        blocked.accessibilityIdentifier = "editTabBlocked"
        blocked.textColor = UIColor(resource: .inkSecondary)
        blocked.isHidden = true
        status.isHidden = true
        let content = Controls.column([subtitle, tabs, blocked, fields, routeEditor, photos, status, error].compactMap { $0 })
        column = content
        Controls.host(content, in: self)
        showTab()
        renderType()
        renderTabs()
    }

    /// The tab picked: the Route tab draws its edit on the map and the Photos tab its draft while
    /// each shows. A tab that can't apply is disabled, so it's never the one picked.
    private func showTab() {
        let tab = tabs.selectedSegmentIndex
        view.endEditing(true)
        blocked.isHidden = true
        fields.isHidden = tab != 0
        routeEditor?.isHidden = tab != 1
        photos?.isHidden = tab != 2
        photos?.active = tab == 2
        if tab == 1, let routeEditor {
            routeEditor.open()
            // Framed once the editor has its points and the sheet its height (onLoaded).
            if routeEditor.session != nil { frameRoute() }
        } else {
            routeEditor?.hide()
        }
    }

    /// The map frames the track above the sheet after the next layout, which sizes the sheet.
    private func frameRoute() {
        framePending = true
        view.setNeedsLayout()
    }

    /// A tap on a disabled tab: its reason under the tabs, read out, the tab picked unchanged.
    @objc private func tappedTabs(_ tap: UITapGestureRecognizer) {
        let width = tabs.bounds.width / CGFloat(tabs.numberOfSegments)
        guard width > 0 else { return }
        let index = min(tabs.numberOfSegments - 1, max(0, Int(tap.location(in: tabs).x / width)))
        guard !tabs.isEnabledForSegment(at: index), let reason = index == 1 ? routeBlock : index == 2 ? photosBlock : nil else { return }
        blocked.text = reason
        blocked.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: reason)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// The most the sheet's detent may take on this screen, as the sheet last said.
    var detentMaximum: CGFloat = 0

    /// The least the fitted detent takes, about one field, so the one being typed into stays in sight.
    private static let minimumSheet: CGFloat = 160

    /// The fitted detent's height for the content now (EditSheet).
    var detentHeight: CGFloat {
        CGFloat(EditSheet.height(content: Double(fittingHeight), maximum: Double(detentMaximum), minimum: Double(Self.minimumSheet)))
    }

    /// How much of the map the fitted sheet takes, the home indicator's inset under it included;
    /// expanded, it covers the map anyway, and the track waits above where it comes back down to.
    private var coveredHeight: CGFloat {
        detentHeight + (view.window?.safeAreaInsets.bottom ?? 0)
    }

    /// The sheet's content height: the navigation bar and the column with its margins.
    var fittingHeight: CGFloat {
        guard isViewLoaded, let column, view.bounds.width > 0 else { return 0 }
        let width = column.bounds.width > 0 ? column.bounds.width : view.readableContentGuide.layoutFrame.width
        let body = column.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        return (navigationController?.navigationBar.frame.maxY ?? 56) + body + 2 * DesignTokens.Space.s32
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A tab or a note changing the content resizes the sheet to it.
        let height = fittingHeight
        if abs(height - lastFitting) > 1, let sheet = navigationController?.sheetPresentationController {
            lastFitting = height
            sheet.animateChanges { sheet.invalidateDetents() }
        }
        // The height the sheet is about to take, not its frame mid-change.
        guard framePending else { return }
        framePending = false
        onRouteOpened(coveredHeight)
    }

    /// The tabs' labels: Route and Photos marked while they have unsaved changes, Photos with
    /// the count Save would leave.
    private func renderTabs() {
        let routeChanged = routeEditor?.session?.changed == true
        tabs.setTitle(routeChanged ? String(localized: "Route •", comment: "Edit window's tab with unsaved route changes.") : String(localized: "Route"), forSegmentAt: 1)
        if let photos {
            let count = format.count(photos.count)
            let title = photos.draft.isEmpty ? String(localized: "Photos: \(count)", comment: "Edit window's tab: the track's photos, written as label: N.")
                : String(localized: "Photos: \(count) •", comment: "Edit window's tab with unsaved photo changes.")
            tabs.setTitle(title, forSegmentAt: 2)
        }
        let unsaved = [routeChanged ? String(localized: "Route, with unsaved changes") : nil,
                       photos?.draft.isEmpty == false ? String(localized: "Photos, with unsaved changes") : nil].compactMap { $0 }
        tabs.accessibilityValue = unsaved.isEmpty ? nil : unsaved.joined(separator: ", ")
    }

    /// Why a tab can't be used, in the server's terms (EditAvailability).
    private static func message(_ block: EditBlock, checkOne: String) -> String {
        switch block {
        case .checkOne: checkOne
        case .pending: String(localized: "This track is still being processed")
        case .isPrivate: String(localized: "Entirely inside one of your private locations, so it isn't on the map and has no distance. Moving or removing that location brings it back.")
        case .noOriginal: String(localized: "This track's original recording isn't stored, so its route can't be edited")
        case .badTimes: String(localized: "This route's points have no usable times, so it can't be edited")
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

    private func renderType() {
        var config = typeButton.configuration
        config?.title = type.isEmpty ? String(localized: "Mixed types — pick one to set it for all") : TrackTypes.shared.label(type)
        typeButton.configuration = config
    }

    /// The range's types with how many use each, and the current type when none of them is it.
    private func openTypePicker() {
        guard !saving else { return }
        let types = TrackTypes.shared
        let options = TypeSearch.options(current: type, known: facets.map { (type: $0.type, count: $0.count) }, label: types.label)
        TypePickerViewController.present(over: self, options: options, current: type, format: format.count) { [weak self] value in
            self?.type = value
            self?.error.isHidden = true
            self?.renderType()
        }
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
            case .typeRequired: String(localized: "Type is required.")
            case .typeTooLong: String(localized: "edit.typeTooLong", defaultValue: "Type must be \(EditPlan.maxType) characters or fewer.", comment: "Edit: the type is past its limit.")
            case .nameTooLong: String(localized: "edit.nameTooLong", defaultValue: "Name must be \(EditPlan.maxName) characters or fewer.", comment: "Edit: the name is past its limit.")
            case .descriptionTooLong: String(localized: "edit.descriptionTooLong", defaultValue: "Description must be \(EditPlan.maxDescription) characters or fewer.", comment: "Edit: the description is past its limit.")
            }
            show(message)
            return
        }
        let writes = EditPlan.writes(group: group, type: type, name: nameText, description: aboutText).filter { !written.contains($0.id) }
        let routeChanged = routeEditor?.session?.changed == true
        guard !writes.isEmpty || photos?.draft.isEmpty == false || routeChanged else { return finish() }
        saving = true
        photos?.busy = true
        routeEditor?.busy = true
        error.isHidden = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        view.endEditing(true)
        Task {
            defer {
                saving = false
                photos?.busy = false
                routeEditor?.busy = false
                status.isHidden = true
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            for write in writes {
                do {
                    _ = try await api.updateTrack(write)
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
            if routeChanged, !(await saveRoute(allowHidden: false)) { return }
            finish()
        }
    }

    /// The route edit, once the fields and photos are in; false when it isn't written. A split
    /// leaving a part inside a Private location asks first (root docs/SPEC.md FR-5.9).
    private func saveRoute(allowHidden: Bool) async -> Bool {
        guard let id = group.first?.id, let session = routeEditor?.session else { return true }
        do {
            switch try await api.saveRouteEdit(id, edit: session.pending, splitAt: session.splitAt, allowHidden: allowHidden) {
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
            self.routeEditor?.busy = true
            Task {
                let done = await self.saveRoute(allowHidden: true)
                self.saving = false
                self.routeEditor?.busy = false
                if done { self.finish() }
            }
        })
        present(alert, animated: true)
    }

    /// Cancel asks first when photo changes would be thrown away.
    private func cancel() {
        guard !saving else { return }
        guard photos?.draft.isEmpty == false || routeEditor?.session?.changed == true else { return finish() }
        let alert = UIAlertController(title: String(localized: "Discard changes?"),
                                      message: String(localized: "The photos and route changes in this window haven't been saved yet."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Keep editing"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Discard"), style: .destructive) { [weak self] _ in self?.finish() })
        present(alert, animated: true)
    }

    private func finish() {
        let done = written, photosSaved = photos?.photosSaved ?? false
        photos?.active = false
        routeEditor?.hide()
        dismiss(animated: true) { self.onDone(done, photosSaved) }
    }

    private func show(_ message: String) {
        error.text = message
        error.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}