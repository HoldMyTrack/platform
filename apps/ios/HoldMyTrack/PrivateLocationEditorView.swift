import HoldMyTrackCore
import UIKit

/// The Private location editor's sheet along the bottom of the map (root docs/SPEC.md FR-7.1),
/// Android's PrivateLocationEditor sheet: a header with Cancel, the title and Save over Name, the
/// radius in 10 m steps and Delete for a saved one, which scroll when the keyboard leaves too
/// little room, so the header and its Save stay on screen. It draws the draft
/// MapViewController+PrivateLocations hands it and reports each change; the map moves the circle.
final class PrivateLocationEditorView: UIView {
    private let title = Controls.label("", font: Typeface.sans(DesignTokens.Text.xl, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    let name = Controls.field(String(localized: "Name"), id: "locationName")
    private let radius = Controls.label("", font: Typeface.sans(DesignTokens.Text.md), color: UIColor(resource: .ink))
    private let slider = UISlider()
    private let note = Controls.label(
        String(localized: "Drag the center to move it. Don't center it exactly on your door — a circle's middle is the first place anyone looks.",
               comment: "Private location editor: how to move the circle, and why not onto the door."),
        font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let error = Controls.error(id: "locationError")
    private let delete = Controls.textButton(String(localized: "Delete"), id: "locationDelete")
    private let cancel = Controls.textButton(String(localized: "Cancel"), id: "locationCancel")
    private let save = Controls.primaryButton(String(localized: "Save"), id: "locationSave")

    private let scroll = UIScrollView()
    /// The fields' bottom kept above the window's safe area: the home indicator while the sheet
    /// sits at the screen's edge (didMoveToWindow).
    private var aboveHomeIndicator: NSLayoutConstraint?

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

        title.textAlignment = .center
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        for button in [cancel, save] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let header = UIStackView(arrangedSubviews: [cancel, title, save])
        header.spacing = DesignTokens.Space.s8
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false

        let deleteRow = UIStackView(arrangedSubviews: [delete, UIView()])
        let fields = Controls.column([name, radius, slider, note, error, deleteRow], spacing: DesignTokens.Space.s8)
        fields.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(fields)
        addSubview(header)
        addSubview(scroll)
        let m = DesignTokens.Space.s16
        // The fields' own height, given up first when the sheet's top meets the top of the screen
        // (bindPrivateEditor); then they scroll under the header. Below the labels' resistance to
        // squashing (750), or they'd be squashed instead.
        let natural = scroll.heightAnchor.constraint(equalTo: fields.heightAnchor)
        natural.priority = UILayoutPriority(700)
        // A gap under the fields, which grows past the home indicator at the screen's edge.
        let gap = scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Space.s8)
        gap.priority = UILayoutPriority(600)
        NSLayoutConstraint.activate([
            gap,
            scroll.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -DesignTokens.Space.s8),
            header.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Space.s8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Space.s8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Space.s8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            fields.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            fields.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            fields.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: m),
            fields.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -m),
            natural,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The sheet reaches the screen's edge, with the tab bar hidden behind it, or rides on the
    /// keyboard. The window's safe area, unlike the map's, leaves out the hidden tab bar, so the
    /// fields clear only the home indicator, and the keyboard sits above that anyway.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        aboveHomeIndicator?.isActive = false
        aboveHomeIndicator = window.map {
            scroll.bottomAnchor.constraint(lessThanOrEqualTo: $0.safeAreaLayoutGuide.bottomAnchor, constant: -DesignTokens.Space.s8)
        }
        aboveHomeIndicator?.isActive = true
    }

    /// A draft opening: its name goes into the field, which the user types into from then.
    func open(_ draft: PrivateLocationEditing.Draft) {
        title.text = draft.id == nil ? String(localized: "New private location") : String(localized: "Edit private location")
        name.text = draft.name
        show(error: nil)
        isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: title)
    }

    func render(_ draft: PrivateLocationEditing.Draft, dirty: Bool, busy: Bool, format: PanelFormat) {
        radius.text = String(localized: "Radius · \(format.radius(draft.radiusM))")
        if !slider.isTracking { slider.value = Float(draft.radiusM) }
        slider.accessibilityValue = radius.text
        delete.isHidden = draft.id == nil
        save.configuration?.title = busy ? String(localized: "Saving…") : String(localized: "Save")
        save.isEnabled = dirty && !busy
        for control in [name, slider, cancel, delete] as [UIControl] { control.isEnabled = !busy }
    }

    /// The error line sits under the fields, which can scroll it out of sight while Save, in the
    /// header, stays in view: it's scrolled to as it shows.
    func show(error text: String?) {
        error.text = text
        error.isHidden = text == nil
        guard text != nil else { return }
        layoutIfNeeded()
        scroll.scrollRectToVisible(error.convert(error.bounds, to: scroll), animated: true)
    }

    func close() {
        name.resignFirstResponder()
        isHidden = true
    }
}