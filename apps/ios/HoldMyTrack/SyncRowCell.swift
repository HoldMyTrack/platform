import HoldMyTrackCore
import UIKit

/// One Sync row (apps/android/docs/SPEC.md FR-3.2), as Android draws it: the type's tile, a
/// spinner while being sent or on its way; the title, the meta line and a note; Edit
/// and Delete for a recording still on the phone; ⓘ while other tracks cover the same time;
/// dimmed with an eye while hidden.
final class SyncRowCell: UITableViewCell {
    static let reuse = "syncRow"

    struct Row: Equatable {
        let id: String
        let title: String
        let meta: String
        /// How far its send got.
        let note: String?
        let processing: Bool
        let kind: TrackKind
        let hidden: Bool
        /// Edit and Delete: on the phone and not being sent (SyncList.canEdit).
        let editable: Bool
        /// How many tracks cover the same time: other rows, and the account's track it overlaps.
        let similar: Int
        /// Picked out on the map.
        let highlighted: Bool
    }

    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSimilar: (() -> Void)?

    private let tile = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let title = Controls.label("", font: Typeface.sans(DesignTokens.Text.lg, relativeTo: .body), color: UIColor(resource: .ink))
    private let meta = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let note = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .accent))
    private let hiddenMark = UIImageView(image: Controls.icon(UIImage(resource: .eyeOff), size: 16))
    private let edit = Controls.iconButton(Controls.icon(UIImage(resource: .pencil), size: 18), label: "", id: "recordingEdit")
    private let delete = Controls.iconButton(Controls.icon(UIImage(resource: .trash2), size: 18), label: "", id: "recordingDelete")
    private let similar = Controls.iconButton(Controls.icon(UIImage(resource: .info), size: 18), label: "", id: "recordingSimilar")

    private static let tileSide: CGFloat = 36
    private static let hiddenAlpha: CGFloat = 0.55

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        accessibilityIdentifier = "recordingRow"
        tile.layer.cornerRadius = Self.tileSide / 2
        tile.contentMode = .center
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
        similar.tintColor = UIColor(resource: .accent)
        similar.addAction(UIAction { [weak self] _ in self?.onSimilar?() }, for: .primaryActionTriggered)

        let text = Controls.column([title, meta, note], spacing: 2)
        let row = UIStackView(arrangedSubviews: [tile, text, hiddenMark, similar, edit, delete])
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
        contentView.backgroundColor = row.highlighted ? UIColor(resource: .surfaceTint) : .clear
        if row.highlighted { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
        title.text = row.title
        meta.text = row.meta
        note.text = row.note
        note.isHidden = row.note == nil
        let alpha = row.hidden ? Self.hiddenAlpha : 1
        for label in [title, meta, note] { label.alpha = alpha }
        hiddenMark.isHidden = !row.hidden

        tile.image = row.processing ? nil : Controls.icon(TrackTypes.icon(row.kind), size: 18)
        // On a picked row's tinted background, the tile takes the plain surface so it still shows.
        tile.backgroundColor = UIColor(resource: row.highlighted ? .surface : .surfaceTint)
        tile.tintColor = UIColor(resource: .inkSecondary)
        if row.processing { spinner.startAnimating() } else { spinner.stopAnimating() }
        similar.isHidden = row.similar == 0
        similar.accessibilityLabel = String(localized: "sync.similarRow", defaultValue: "\(row.title): \(row.similar) similar tracks", comment: "Sync: a row's ⓘ, read out with its title and how many tracks cover the same time.")
        // Named per row, since VoiceOver reads each control on its own.
        edit.isHidden = !row.editable
        delete.isHidden = !row.editable
        edit.accessibilityLabel = String(localized: "sync.editRow", defaultValue: "Edit \(row.title)", comment: "Sync: a recording's Edit, read out with its title.")
        delete.accessibilityLabel = String(localized: "sync.deleteRow", defaultValue: "Delete \(row.title)", comment: "Sync: a recording's Delete, read out with its title.")
    }
}