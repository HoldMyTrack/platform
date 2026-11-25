import HoldMyTrackCore
import UIKit

/// A recording's Edit (apps/android/docs/SPEC.md FR-5.2): its name, description and type, kept on the
/// phone until it's sent, with its moving time and distance; the type set becomes the account's
/// for the next recording. The Type picker lists the account's types and this phone's waiting
/// recordings', most used first, then the presets (TypeSearch.recordingKnown). Download GPX is
/// here too. Opened the moment a recording stops, the same form is "Save recording", with Discard,
/// asked first, in Download GPX's place; Cancel keeps the recording as it is.
final class RecordingEditViewController: UIViewController {
    private var track: RecordedTrack
    private let account: Account
    private let recordings: RecordingsSync
    private let api: APIClient
    /// The account's tracks by type, empty until read or when they couldn't be.
    private var serverCounts: [(type: String, count: Int)] = []
    /// The Type picker while open, which the account's types reach if they arrive after it.
    private weak var typePicker: TypePickerViewController?
    /// The Save screen a Stop opens.
    private let justStopped: Bool
    var onGPX: ((RecordedTrack) -> Void)?
    /// Saved from the Save screen: it waits on the phone until Sync sends it, which the map it
    /// returns to doesn't show.
    var onSaved: (() -> Void)?

    private let name = Controls.field(String(localized: "recording.name", defaultValue: "Name", comment: "A recording's Edit: its name, optional."), id: "recordingName")
    private let about = UITextView()
    private let typeButton = Controls.secondaryButton("", id: "recordingType")
    private let error = Controls.error(id: "recordingError")

    init(track: RecordedTrack, account: Account, recordings: RecordingsSync, api: APIClient, justStopped: Bool = false) {
        self.track = track
        self.account = account
        self.recordings = recordings
        self.api = api
        self.justStopped = justStopped
        super.init(nibName: nil, bundle: nil)
        title = justStopped
            ? String(localized: "recording.saveTitle", defaultValue: "Save recording", comment: "The screen a Stop opens: the title.")
            : String(localized: "recording.editTitle", defaultValue: "Edit recording", comment: "A recording's Edit: the screen's title.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let save = UIBarButtonItem(title: String(localized: "recording.save", defaultValue: "Save", comment: "An unfinished recording: keep it as Stop would."), primaryAction: UIAction { [weak self] _ in self?.save() })
        save.accessibilityIdentifier = "recordingSave"
        save.style = .done
        navigationItem.rightBarButtonItem = save
        name.text = track.name
        name.autocapitalizationType = .sentences
        about.text = track.description
        about.font = Typeface.sans(DesignTokens.Text.xl)
        about.adjustsFontForContentSizeCategory = true
        about.backgroundColor = UIColor(resource: .surface)
        about.layer.cornerRadius = DesignTokens.Radius.md
        about.layer.borderWidth = 1
        border()
        // A CGColor doesn't follow the theme: set again on a change.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.border() }
        about.accessibilityIdentifier = "recordingDescription"
        about.accessibilityLabel = String(localized: "recording.description", defaultValue: "Description (optional)", comment: "A recording's Edit: its description.")
        about.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        typeButton.addAction(UIAction { [weak self] _ in self?.openTypePicker() }, for: .primaryActionTriggered)
        renderType()
        Task { [weak self, api] in
            guard let read = try? await api.typeCounts() else { return }
            TrackTypes.shared.merge(read.types)
            guard let self else { return }
            self.serverCounts = read.counts
            self.renderType()
            self.typePicker?.replace(options: self.typeOptions())
        }
        let last: UIButton
        if justStopped {
            last = Controls.textButton(String(localized: "recording.discard", defaultValue: "Discard", comment: "An unfinished recording: delete it."), id: "recordingDiscard")
            last.configuration?.baseForegroundColor = UIColor(resource: .danger)
            last.addAction(UIAction { [weak self] _ in self?.confirmDiscard() }, for: .primaryActionTriggered)
        } else {
            last = Controls.secondaryButton(String(localized: "recording.gpx", defaultValue: "Download GPX", comment: "A recording: save its route as GPX."), id: "recordingGPX")
            last.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onGPX?(self.track)
            }, for: .primaryActionTriggered)
        }
        let column = Controls.column([
            Self.caption(String(localized: "recording.name", defaultValue: "Name", comment: "A recording's Edit: its name, optional.")), name,
            Self.caption(String(localized: "Type")), typeButton,
            Self.caption(String(localized: "recording.description", defaultValue: "Description (optional)", comment: "A recording's Edit: its description.")), about,
            stats(), error, last,
        ])
        Controls.host(column, in: self)
    }

    /// Time and Distance side by side: the moving time and the distance recorded.
    private func stats() -> UIView {
        let format = PanelFormat(account: account)
        func stat(_ label: String, _ value: String, id: String) -> UIView {
            let number = Controls.label(value, font: Typeface.sans(DesignTokens.Text.xl, weight: DesignTokens.Weight.semibold, relativeTo: .title3), color: UIColor(resource: .ink))
            number.accessibilityIdentifier = id
            let column = Controls.column([Self.caption(label), number], spacing: DesignTokens.Space.s4)
            column.isAccessibilityElement = true
            column.accessibilityLabel = "\(label), \(value)"
            return column
        }
        let row = UIStackView(arrangedSubviews: [
            stat(String(localized: "recording.time", defaultValue: "Time", comment: "A recording's Edit: its moving time."), RecordingStatus.clock(track.movingSeconds), id: "recordingTime"),
            stat(String(localized: "recording.distance", defaultValue: "Distance", comment: "A recording's Edit: its distance."), format.distance(track.meters), id: "recordingDistance"),
        ])
        row.distribution = .fillEqually
        row.spacing = DesignTokens.Space.s16
        return row
    }

    /// Discard asks first: the phone's copy is the only one.
    private func confirmDiscard() {
        let alert = UIAlertController(title: String(localized: "recording.discardTitle", defaultValue: "Discard this recording?", comment: "Discarding an unfinished recording: the question."),
                                      message: String(localized: "recording.discardMessage", defaultValue: "The track will be deleted from this device. This can't be undone.", comment: "Discarding an unfinished recording: why it asks."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "recording.discard", defaultValue: "Discard", comment: "An unfinished recording: delete it."), style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.recordings.delete(self.track.id)
            self.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    private func border() {
        about.layer.borderColor = UIColor(resource: .borderStrong).resolvedColor(with: traitCollection).cgColor
    }

    private static func caption(_ text: String) -> UILabel {
        Controls.label(text, font: Typeface.sans(DesignTokens.Text.sm, weight: DesignTokens.Weight.semibold, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    }

    private func renderType() {
        typeButton.configuration?.title = TrackTypes.shared.label(track.type)
    }

    private func typeOptions() -> [TypeSearch.Option] {
        let known = TypeSearch.recordingKnown(server: serverCounts, local: recordings.all.filter { !$0.sent }.map(\.type))
        return TypeSearch.options(current: track.type, known: known, label: TrackTypes.shared.label)
    }

    private func openTypePicker() {
        let format = { (n: Int) in NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
        typePicker = TypePickerViewController.present(over: self, options: typeOptions(), current: track.type, format: format) { [weak self] value in
            self?.track.type = value
            self?.error.isHidden = true
            self?.renderType()
        }
    }

    private func save() {
        let nameText = (name.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let aboutText = about.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invalid = EditPlan.invalid(group: [], type: track.type, name: nameText, description: aboutText) {
            error.text = switch invalid {
            case .typeRequired: String(localized: "Type is required.")
            case .typeTooLong: String(localized: "edit.typeTooLong", defaultValue: "Type must be \(EditPlan.maxType) characters or fewer.", comment: "Edit: the type is past its limit.")
            default: String(localized: "recording.tooLong", defaultValue: "The name or the description is too long.", comment: "A recording's Edit: a field past its limit.")
            }
            error.isHidden = false
            return
        }
        track.name = nameText.isEmpty ? nil : nameText
        track.description = aboutText.isEmpty ? nil : aboutText
        recordings.update(track)
        recordings.setDefaultType(track.type)
        let saved = justStopped ? onSaved : nil
        dismiss(animated: true) { saved?() }
    }
}