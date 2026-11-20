import HoldMyTrackCore
import UIKit

/// A recording's Edit (apps/android/docs/SPEC.md FR-5.2): its name, description and type, kept on the
/// phone until it's sent; the type set becomes the account's for the next recording. The type
/// menu lists the types this phone's recordings use, most used first, then every type the server
/// described, and Other… types a new one. Download GPX and Delete are here too.
final class RecordingEditViewController: UIViewController {
    private var track: RecordedTrack
    private let account: Account
    private let recordings: RecordingsSync
    var onGPX: ((RecordedTrack) -> Void)?
    var onDelete: ((RecordedTrack) -> Void)?

    private let name = Controls.field(String(localized: "recording.name", defaultValue: "Name", comment: "A recording's Edit: its name, optional."), id: "recordingName")
    private let about = UITextView()
    private let typeButton = Controls.secondaryButton("", id: "recordingType")
    private let error = Controls.error(id: "recordingError")

    init(track: RecordedTrack, account: Account, recordings: RecordingsSync) {
        self.track = track
        self.account = account
        self.recordings = recordings
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "recording.editTitle", defaultValue: "Edit recording", comment: "A recording's Edit: the screen's title.")
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
        typeButton.showsMenuAsPrimaryAction = true
        renderType()
        let gpx = Controls.secondaryButton(String(localized: "recording.gpx", defaultValue: "Download GPX", comment: "A recording: save its route as GPX."), id: "recordingGPX")
        gpx.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onGPX?(self.track)
        }, for: .primaryActionTriggered)
        let delete = Controls.textButton(String(localized: "recording.delete", defaultValue: "Delete", comment: "A recording: delete it from the phone."), id: "recordingDelete")
        delete.configuration?.baseForegroundColor = UIColor(resource: .danger)
        delete.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onDelete?(self.track)
        }, for: .primaryActionTriggered)
        let column = Controls.column([
            Self.caption(String(localized: "recording.name", defaultValue: "Name", comment: "A recording's Edit: its name, optional.")), name,
            Self.caption(String(localized: "Type")), typeButton,
            Self.caption(String(localized: "recording.description", defaultValue: "Description (optional)", comment: "A recording's Edit: its description.")), about,
            error, gpx, delete,
        ])
        Controls.host(column, in: self)
    }

    private func border() {
        about.layer.borderColor = UIColor(resource: .borderStrong).resolvedColor(with: traitCollection).cgColor
    }

    private static func caption(_ text: String) -> UILabel {
        Controls.label(text, font: Typeface.sans(DesignTokens.Text.sm, weight: DesignTokens.Weight.semibold, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    }

    /// The phone's recordings' types by use, then the server's others, then Other….
    private func renderType() {
        let types = TrackTypes.shared
        typeButton.configuration?.title = types.label(track.type)
        let pick = { [weak self] (value: String) in
            self?.track.type = value
            self?.error.isHidden = true
            self?.renderType()
        }
        let counts = Dictionary(recordings.all.map { ($0.type, 1) }, uniquingKeysWith: +)
        let used = counts.keys.filter { $0 != "unknown" }.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
        let mine = used.map { t in
            UIAction(title: types.label(t), image: TrackTypes.icon(types.kind(t)), state: t == track.type ? .on : .off) { _ in pick(t) }
        }
        let others = types.known.filter { !used.contains($0) }.map { t in
            UIAction(title: types.label(t), image: TrackTypes.icon(types.kind(t)), state: t == track.type ? .on : .off) { _ in pick(t) }
        }
        let other = UIAction(title: String(localized: "recording.otherType", defaultValue: "Other…", comment: "A recording's type menu: type a new one."), image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.typeNew(pick)
        }
        typeButton.menu = UIMenu(children: [UIMenu(options: .displayInline, children: mine), UIMenu(options: .displayInline, children: others), other])
    }

    /// A type of the user's own, kept as typed, up to the server's limit.
    private func typeNew(_ pick: @escaping (String) -> Void) {
        let alert = UIAlertController(title: String(localized: "recording.otherTypeTitle", defaultValue: "Track type", comment: "A recording's new type: the prompt's title."), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.autocapitalizationType = .sentences }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "recording.otherTypeAdd", defaultValue: "Use", comment: "A recording's new type: use what was typed."), style: .default) { [weak alert] _ in
            let typed = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !typed.isEmpty { pick(typed) }
        })
        present(alert, animated: true)
    }

    private func save() {
        let nameText = (name.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let aboutText = about.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invalid = EditPlan.invalid(group: [], type: track.type, name: nameText, description: aboutText) {
            error.text = switch invalid {
            case .typeRequired: String(localized: "Pick a type.")
            case .typeTooLong: String(localized: "The type can be at most \(EditPlan.maxType) characters.")
            default: String(localized: "recording.tooLong", defaultValue: "The name or the description is too long.", comment: "A recording's Edit: a field past its limit.")
            }
            error.isHidden = false
            return
        }
        track.name = nameText.isEmpty ? nil : nameText
        track.description = aboutText.isEmpty ? nil : aboutText
        recordings.update(track)
        recordings.setDefaultType(track.type)
        dismiss(animated: true)
    }
}