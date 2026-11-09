import HoldMyTrackCore
import UIKit

/// A slider along the track and the time at its point: a waiting photo's place, or an open row's.
/// onMove gets the user's moves, as a fraction of the way along.
final class PlaceSlider: UIView {
    let slider = UISlider()
    private let time = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    var onMove: ((Double) -> Void)?

    init(id: String) {
        super.init(frame: .zero)
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = UIColor(resource: .accent)
        slider.accessibilityLabel = String(localized: "Place on the route")
        slider.accessibilityIdentifier = id
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onMove?(Double(self.slider.value))
        }, for: .valueChanged)
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [slider, time])
        row.spacing = DesignTokens.Space.s8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// At fraction, unless the finger has it, with the time there.
    func bind(fraction: Double?, time text: String?, enabled: Bool) {
        slider.isEnabled = fraction != nil && enabled
        if let fraction, !slider.isTracking { slider.value = Float(fraction) }
        time.text = text
        slider.accessibilityValue = text
    }
}

/// One row of the Photos tab's list, kept for as long as its photo is listed, so an open row's
/// slider and caption survive every render under the finger: the thumbnail, the caption or
/// "Photo 3", the time on the route, a badge for New, Changed or Will be deleted, Edit and Delete
/// (Keep this photo once deleted), and while open, the caption and the place slider.
final class PhotoRowView: UIView, UITextFieldDelegate {
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onKeep: (() -> Void)?
    var onDone: (() -> Void)?
    var onCaption: ((String) -> Void)?
    var onMove: ((Double) -> Void)?

    private let thumb = UIImageView()
    private let title = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private let time = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let badge = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, weight: DesignTokens.Weight.semibold, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let edit = Controls.iconButton(Controls.icon(UIImage(resource: .pencil), size: 18), label: "", id: "photoRowEdit")
    private let delete = Controls.iconButton(Controls.icon(UIImage(resource: .trash2), size: 18), label: "", id: "photoRowDelete")
    private let keep = Controls.iconButton(Controls.icon(UIImage(resource: .undo2), size: 18), label: String(localized: "Keep this photo"), id: "photoRowKeep")
    private let editor = UIStackView()
    private let caption = Controls.field(String(localized: "Add a caption"), id: "photoCaption")
    private let slider = PlaceSlider(id: "photoRowSlider")
    private(set) var thumbFor: String?

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = DesignTokens.Radius.md
        accessibilityIdentifier = "photoRow"
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = DesignTokens.Radius.sm
        thumb.backgroundColor = UIColor(resource: .surfaceTint)
        thumb.widthAnchor.constraint(equalToConstant: 48).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 48).isActive = true
        title.numberOfLines = 2
        edit.addAction(UIAction { [weak self] _ in self?.onEdit?() }, for: .primaryActionTriggered)
        delete.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .primaryActionTriggered)
        keep.addAction(UIAction { [weak self] _ in self?.onKeep?() }, for: .primaryActionTriggered)
        delete.configuration?.baseForegroundColor = UIColor(resource: .danger)

        let meta = UIStackView(arrangedSubviews: [time, badge, UIView()])
        meta.spacing = DesignTokens.Space.s8
        let texts = Controls.column([title, meta], spacing: DesignTokens.Space.s2)
        let top = UIStackView(arrangedSubviews: [thumb, texts, edit, delete, keep])
        top.alignment = .center
        top.spacing = DesignTokens.Space.s8

        caption.delegate = self
        caption.returnKeyType = .done
        caption.addAction(UIAction { [weak self] _ in self?.onCaption?(self?.caption.text ?? "") }, for: .editingChanged)
        slider.onMove = { [weak self] in self?.onMove?($0) }
        let done = Controls.textButton(String(localized: "Done"), id: "photoRowDone")
        done.contentHorizontalAlignment = .trailing
        done.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .primaryActionTriggered)
        for v in [caption, slider, done] as [UIView] { editor.addArrangedSubview(v) }
        editor.axis = .vertical
        editor.spacing = DesignTokens.Space.s6

        let column = Controls.column([top, editor], spacing: DesignTokens.Space.s8)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let m = DesignTokens.Space.s6
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -m),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    struct Look {
        let label: String
        let time: String
        /// The place slider's fraction and time, while open.
        let place: (fraction: Double, time: String)?
        let open: Bool
        let canEdit: Bool
        let busy: Bool
    }

    func bind(_ row: DraftRow, look: Look) {
        let deleted: Bool
        let badgeText: String?
        switch row {
        case .new:
            deleted = false
            badgeText = String(localized: "New", comment: "Photos tab: a photo added, not yet saved.")
        case .saved(_, _, _, let isDeleted, let changed):
            deleted = isDeleted
            badgeText = isDeleted ? String(localized: "Will be deleted") : changed ? String(localized: "Changed", comment: "Photos tab: a photo moved or captioned, not yet saved.") : nil
        }
        title.attributedText = NSAttributedString(string: look.label, attributes: deleted ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue] : [:])
        title.alpha = deleted ? 0.45 : 1
        thumb.alpha = deleted ? 0.45 : 1
        time.text = look.time
        badge.text = badgeText
        badge.isHidden = badgeText == nil
        badge.textColor = UIColor(resource: deleted ? .danger : .inkSecondary)
        edit.isHidden = deleted
        delete.isHidden = deleted
        keep.isHidden = !deleted
        edit.isEnabled = look.canEdit && !look.busy
        delete.isEnabled = !look.busy
        keep.isEnabled = !look.busy
        edit.accessibilityLabel = String(localized: "Edit \(look.label)", comment: "Photos tab: edits the named photo.")
        delete.accessibilityLabel = String(localized: "Delete \(look.label)", comment: "Photos tab: deletes the named photo.")
        backgroundColor = look.open ? UIColor(resource: .surfaceTint) : .clear
        editor.isHidden = !look.open
        if look.open {
            slider.bind(fraction: look.place?.fraction, time: look.place?.time, enabled: !look.busy)
            if caption.text != row.caption, !caption.isFirstResponder { caption.text = row.caption }
            caption.isEnabled = !look.busy
        }
    }

    /// The thumbnail, set once per photo.
    func setThumb(_ image: UIImage?, for key: String) {
        thumbFor = key
        thumb.image = image
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
