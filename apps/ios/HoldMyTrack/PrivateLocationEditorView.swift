import HoldMyTrackCore
import UIKit

/// The Private location editor's card along the bottom of the map (root docs/SPEC.md FR-7.1),
/// Android's PrivateLocationEditor card: Name, the radius in 10 m steps, Delete for a saved one,
/// Cancel and Save. It draws the draft MapViewController+PrivateLocations hands it and reports
/// each change; the map moves the circle.
final class PrivateLocationEditorView: UIView {
    private let title = Controls.label("", font: Typeface.sans(DesignTokens.Text.xl, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    let name = Controls.field(String(localized: "Name"), id: "locationName")
    private let radius = Controls.label("", font: Typeface.sans(DesignTokens.Text.md), color: UIColor(resource: .ink))
    private let slider = UISlider()
    private let note = Controls.label(
        String(localized: "Drag the centre to move it. Don't centre it exactly on your door: a circle's middle is the first place anyone looks.",
               comment: "Private location editor: how to move the circle, and why not onto the door."),
        font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let error = Controls.error(id: "locationError")
    private let delete = Controls.textButton(String(localized: "Delete"), id: "locationDelete")
    private let cancel = Controls.secondaryButton(String(localized: "Cancel"), id: "locationCancel")
    private let save = Controls.primaryButton(String(localized: "Save"), id: "locationSave")

    var onName: ((String) -> Void)?
    var onRadius: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onDelete: (() -> Void)?

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(resource: .surface)
        layer.cornerRadius = DesignTokens.Radius.lg
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        accessibilityIdentifier = "locationEditor"
        isHidden = true

        name.autocapitalizationType = .sentences
        name.returnKeyType = .done
        name.addAction(UIAction { [weak self] _ in self?.onName?(self?.name.text ?? "") }, for: .editingChanged)
        name.addAction(UIAction { [weak self] _ in self?.name.resignFirstResponder() }, for: .editingDidEndOnExit)
        let range = PrivateLocation.radiusRange
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.minimumTrackTintColor = UIColor(resource: .accent)
        slider.accessibilityIdentifier = "locationRadius"
        slider.accessibilityLabel = String(localized: "Radius")
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onRadius?(PrivateLocationEditing.radius(Double(self.slider.value)))
        }, for: .valueChanged)
        delete.configuration?.baseForegroundColor = UIColor(resource: .danger)
        delete.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .primaryActionTriggered)
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .primaryActionTriggered)
        save.addAction(UIAction { [weak self] _ in self?.onSave?() }, for: .primaryActionTriggered)
        error.isHidden = true

        let buttons = UIStackView(arrangedSubviews: [delete, UIView(), cancel, save])
        buttons.spacing = DesignTokens.Space.s8
        buttons.alignment = .center
        let content = Controls.column([title, name, radius, slider, note, error, buttons], spacing: DesignTokens.Space.s8)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let m = DesignTokens.Space.s16
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: m),
            content.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -DesignTokens.Space.s8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A draft opening: its name goes into the field, which the user types into from then.
    func open(_ draft: PrivateLocationEditing.Draft) {
        title.text = draft.id == nil ? String(localized: "New Private location") : String(localized: "Private location")
        name.text = draft.name
        show(error: nil)
        isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: title)
    }

    func render(_ draft: PrivateLocationEditing.Draft, dirty: Bool, busy: Bool) {
        radius.text = String(localized: "Radius: \(draft.radiusM) m")
        if !slider.isTracking { slider.value = Float(draft.radiusM) }
        slider.accessibilityValue = radius.text
        delete.isHidden = draft.id == nil
        save.configuration?.title = busy ? String(localized: "Saving…") : String(localized: "Save")
        save.isEnabled = dirty && !busy
        for control in [name, slider, cancel, delete] as [UIControl] { control.isEnabled = !busy }
    }

    func show(error text: String?) {
        error.text = text
        error.isHidden = text == nil
    }

    func close() {
        name.resignFirstResponder()
        isHidden = true
    }
}