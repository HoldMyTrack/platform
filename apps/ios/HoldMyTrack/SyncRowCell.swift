import HoldMyTrackCore
import UIKit

/// One Sync row (apps/android/docs/SPEC.md FR-3.4), as Android draws it: the type's tile, a
/// check while ticked and a spinner while on its way; the title, the meta line and a note; Edit
/// and Delete for a recording still on the phone; dimmed with an eye while hidden.
final class SyncRowCell: UITableViewCell {
    static let reuse = "syncRow"

    struct Row: Equatable {
        let id: String
        let title: String
        let meta: String
        /// "Adding to your map…" while it's on its way.
        let note: String?
        let processing: Bool
        let kind: TrackKind
        let ticked: Bool
        let hidden: Bool
        let tickable: Bool
        /// Edit and Delete: on the phone and not being sent (SyncList.canEdit).
        let editable: Bool
    }

    var onTick: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private let tile = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let title = Controls.label("", font: Typeface.sans(DesignTokens.Text.lg, relativeTo: .body), color: UIColor(resource: .ink))
    private let meta = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let note = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .accent))
    private let hiddenMark = UIImageView(image: Controls.icon(UIImage(resource: .eyeOff), size: 16))
    private let edit = Controls.iconButton(Controls.icon(UIImage(resource: .pencil), size: 18), label: "", id: "recordingEdit")
    private let delete = Controls.iconButton(Controls.icon(UIImage(resource: .trash2), size: 18), label: "", id: "recordingDelete")

    private static let tileSide: CGFloat = 36
    private static let hiddenAlpha: CGFloat = 0.55

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        accessibilityIdentifier = "recordingRow"
        tile.layer.cornerRadius = Self.tileSide / 2
        tile.accessibilityIdentifier = "recordingTick"
        tile.addAction(UIAction { [weak self] _ in self?.onTick?() }, for: .primaryActionTriggered)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(spinner)
        for label in [title, meta, note] { label.numberOfLines = 0 }
        note.accessibilityIdentifier = "syncRowNote"
        hiddenMark.tintColor = UIColor(resource: .inkMuted)
        hiddenMark.setContentHuggingPriority(.required, for: .horizontal)
        edit.tintColor = UIColor(resource: .inkSecondary)
        delete.tintColor = UIColor(resource: .danger)
        edit.addAction(UIAction { [weak self] _ in self?.onEdit?() }, for: .primaryActionTriggered)
        delete.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .primaryActionTriggered)

        let text = Controls.column([title, meta, note], spacing: 2)
        let row = UIStackView(arrangedSubviews: [tile, text, hiddenMark, edit, delete])
        row.alignment = .center
        row.spacing = DesignTokens.Space.s8
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: Self.tileSide),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSide),
            spinner.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignTokens.Space.s8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -DesignTokens.Space.s8),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: DesignTokens.Space.s16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -DesignTokens.Space.s8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ row: Row) {
        title.text = row.title
        meta.text = row.meta
        note.text = row.note
        note.isHidden = row.note == nil
        let alpha = row.hidden ? Self.hiddenAlpha : 1
        for label in [title, meta, note] { label.alpha = alpha }
        hiddenMark.isHidden = !row.hidden

        tile.setImage(row.processing ? nil : Controls.icon(row.ticked ? UIImage(resource: .check) : TrackTypes.icon(row.kind), size: 18), for: .normal)
        tile.backgroundColor = row.ticked ? UIColor(resource: .accent) : UIColor(resource: .surfaceTint)
        tile.tintColor = row.ticked ? UIColor(resource: .onAccent) : UIColor(resource: .inkSecondary)
        tile.isEnabled = row.tickable
        if row.processing { spinner.startAnimating() } else { spinner.stopAnimating() }
        tile.accessibilityLabel = row.processing ? row.note
            : row.ticked ? String(localized: "sync.untickRow", defaultValue: "Untick \(row.title)", comment: "Sync: a ticked row's tick, read out.")
            : String(localized: "sync.tickRow", defaultValue: "Tick \(row.title)", comment: "Sync: a row's tick, read out.")
        tile.accessibilityTraits = row.ticked ? [.button, .selected] : .button

        // Named per row, since VoiceOver reads each control on its own.
        edit.isHidden = !row.editable
        delete.isHidden = !row.editable
        edit.accessibilityLabel = String(localized: "sync.editRow", defaultValue: "Edit \(row.title)", comment: "Sync: a recording's Edit, read out with its title.")
        delete.accessibilityLabel = String(localized: "sync.deleteRow", defaultValue: "Delete \(row.title)", comment: "Sync: a recording's Delete, read out with its title.")
    }
}