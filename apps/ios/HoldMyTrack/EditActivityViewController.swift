import HoldMyTrackCore
import UIKit

/// Edit (root docs/SPEC.md FR-5.10, apps/android/docs/SPEC.md FR-2.7) over the toolbar's target:
/// one activity's type, name and description, or a group's type alone. Save writes only what
/// changed, one activity at a time (EditPlan); a group of mixed types starts with Type empty, and
/// leaving it empty keeps each its own.
final class EditActivityViewController: UIViewController {
    private let api: APIClient
    private let group: [Activity]
    /// The range's types with their counts, listed first in the Type menu.
    private let facets: [TypeFacet]
    private let format: PanelFormat
    /// The ids written, once Save is done or Cancel follows a partial save.
    private let onDone: ([String]) -> Void

    private var type: String
    private var written: [String] = []
    private var saving = false
    private let typeButton = UIButton(type: .system)
    private let name = Controls.field(String(localized: "Name"), id: "editName")
    private let about = UITextView()
    private let error = Controls.error(id: "editError")

    init(api: APIClient, group: [Activity], facets: [TypeFacet], format: PanelFormat, onDone: @escaping ([String]) -> Void) {
        self.api = api
        self.group = group
        self.facets = facets
        self.format = format
        self.onDone = onDone
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

        var views: [UIView] = [subtitle, Self.caption(String(localized: "Type")), typeButton]
        if single != nil {
            views += [Self.caption(String(localized: "Name")), name, Self.caption(String(localized: "Description")), about]
        } else {
            views.append(Controls.body(String(localized: "Name and description stay each activity's own.")))
        }
        views.append(error)
        Controls.host(Controls.column(views), in: self)
        renderType()
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
        guard !writes.isEmpty else { return finish() }
        saving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        view.endEditing(true)
        Task {
            defer {
                saving = false
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
            finish()
        }
    }

    private func cancel() {
        guard !saving else { return }
        finish()
    }

    private func finish() {
        let done = written
        dismiss(animated: true) { self.onDone(done) }
    }

    private func show(_ message: String) {
        error.text = message
        error.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}