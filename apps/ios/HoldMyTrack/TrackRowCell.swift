import HoldMyTrackCore
import UIKit

/// One track row (root docs/SPEC.md FR-5.1, the web's ActivityRow), on the Tracks tab and
/// under an open Trip: the title, "[date ·] distance · duration · type", dimmed with a Pending
/// or Hidden badge, a Private badge, and a Trip badge for the Trips it's in but the open one.
/// Its kind's tile is its checkbox: a tap on it, or a long press on the row, checks it.
final class TrackRowCell: UITableViewCell {
    static let reuse = "track"

    struct Row {
        let track: Track
        let checked: Bool
        let focused: Bool
        let hidden: Bool
        let selecting: Bool
    }

    private let tile = UIButton(type: .custom)
    private let title = Controls.label("", font: Typeface.sans(DesignTokens.Text.lg, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private let meta = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let badges = UIStackView()
    private let remove = UIButton(type: .system)
    private var onCheck: (() -> Void)?
    private var onRemove: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        var tileConfig = UIButton.Configuration.filled()
        tileConfig.cornerStyle = .medium
        tile.configuration = tileConfig
        tile.widthAnchor.constraint(equalToConstant: 40).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 40).isActive = true
        tile.addAction(UIAction { [weak self] _ in self?.onCheck?() }, for: .primaryActionTriggered)
        tile.accessibilityIdentifier = "rowTile"

        title.numberOfLines = 2
        meta.numberOfLines = 2
        badges.spacing = DesignTokens.Space.s6
        badges.alignment = .center

        var removeConfig = UIButton.Configuration.plain()
        removeConfig.image = UIImage(resource: .x)
        removeConfig.baseForegroundColor = UIColor(resource: .inkSecondary)
        remove.configuration = removeConfig
        remove.widthAnchor.constraint(equalToConstant: 44).isActive = true
        remove.accessibilityIdentifier = "removeFromTrip"
        remove.addAction(UIAction { [weak self] _ in self?.onRemove?() }, for: .primaryActionTriggered)

        let text = Controls.column([title, meta, badges], spacing: DesignTokens.Space.s2)
        let row = UIStackView(arrangedSubviews: [tile, text, remove])
        row.spacing = DesignTokens.Space.s12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignTokens.Space.s8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -DesignTokens.Space.s8),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        contentView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// onCheck nil leaves the tile a plain icon (an open Trip's rows); onRemove shows the ×
    /// that takes the row out of the open Trip; openStoryID's badge is left off.
    func bind(_ row: Row, format: PanelFormat, openTripID: String?, demo: Bool,
              onCheck: (() -> Void)?, onOpenTrip: @escaping (String) -> Void, onRemove: (() -> Void)?) {
        let track = row.track
        let types = TrackTypes.shared
        let label = format.label(track)
        title.text = label
        var parts: [String] = []
        if track.title != nil { parts.append(format.startedAt(track)) }
        // A private track has no track: "0.0 km · 0m" would read as broken data.
        if !track.isPrivate { parts += [format.distance(track.distanceMeters), format.duration(track.movingSeconds)] }
        parts.append(types.label(track.activityType))
        meta.text = parts.joined(separator: " · ")
        let dim: CGFloat = track.pending ? 0.45 : row.hidden ? 0.55 : 1
        title.alpha = dim
        meta.alpha = dim
        contentView.backgroundColor = row.focused ? UIColor(resource: .surfaceTint) : .clear

        badges.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if track.pending { badges.addArrangedSubview(Self.badge(String(localized: "Pending"), id: "badgePending")) }
        if row.hidden { badges.addArrangedSubview(Self.badge(String(localized: "Hidden"), id: "badgeHidden")) }
        if track.isPrivate && !track.pending {
            badges.addArrangedSubview(Self.badge(String(localized: "Private"), id: "badgePrivate", icon: UIImage(resource: .lock)))
        }
        let others = track.trips.filter { $0.id != openTripID }
        if !others.isEmpty { badges.addArrangedSubview(tripBadge(others, onOpenTrip: onOpenTrip)) }
        badges.isHidden = badges.arrangedSubviews.isEmpty
        // Each badge as wide as its word.
        badges.addArrangedSubview(UIView())

        self.onCheck = onCheck
        let ticked = row.checked && onCheck != nil
        var config = tile.configuration ?? .filled()
        config.image = ticked ? UIImage(resource: .check) : TrackTypes.icon(types.kind(track.activityType))
        config.baseBackgroundColor = ticked ? UIColor(resource: .accent) : UIColor(resource: .surfaceTint)
        config.baseForegroundColor = ticked ? UIColor(resource: .onAccent) : UIColor(resource: .inkSecondary)
        tile.configuration = config
        // A Pending row can't be checked until its reprocess lands; a checked one can be unchecked.
        let checkable = onCheck != nil && (!track.pending || row.checked)
        tile.isEnabled = checkable
        tile.isAccessibilityElement = onCheck != nil
        tile.accessibilityLabel = row.checked ? String(localized: "Uncheck \(label)") : String(localized: "Check \(label)")

        remove.isHidden = onRemove == nil
        remove.isEnabled = !demo
        remove.accessibilityLabel = demo ? String(localized: "The demo account can't change a Trip") : String(localized: "Take \(label) out of this Trip")
        self.onRemove = onRemove

        accessibilityIdentifier = "trackRow"
        contentView.accessibilityLabel = [label, meta.text].compactMap { $0 }.joined(separator: ". ")
    }

    @objc private func longPress(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, tile.isEnabled else { return }
        onCheck?()
    }

    private func tripBadge(_ trips: [TripRef], onOpenTrip: @escaping (String) -> Void) -> UIButton {
        let text = trips.count == 1 ? String(localized: "Trip") : String(localized: "Trips: \(trips.count)")
        let button = Self.badge(text, id: "badgeTrip", icon: UIImage(resource: .bookOpen), accent: true)
        if trips.count == 1 {
            button.addAction(UIAction { _ in onOpenTrip(trips[0].id) }, for: .primaryActionTriggered)
            button.accessibilityLabel = String(localized: "Open the Trip \(trips[0].name)")
        } else {
            button.menu = UIMenu(children: trips.map { ref in UIAction(title: ref.name) { _ in onOpenTrip(ref.id) } })
            button.showsMenuAsPrimaryAction = true
            button.accessibilityLabel = String(localized: "In Trips: \(trips.map(\.name).joined(separator: ", "))")
        }
        return button
    }

    private static func badge(_ text: String, id: String, icon: UIImage? = nil, accent: Bool = false) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = text
        config.image = icon.map { Controls.icon($0, size: 11) }
        config.imagePadding = 3
        config.cornerStyle = .capsule
        config.contentInsets = .init(top: 2, leading: 6, bottom: 2, trailing: 6)
        config.baseBackgroundColor = accent ? UIColor(resource: .surfaceTintStrong) : UIColor(resource: .surfaceTint)
        config.baseForegroundColor = accent ? UIColor(resource: .accentStrong) : UIColor(resource: .inkSecondary)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Typeface.sans(DesignTokens.Text.xs, weight: DesignTokens.Weight.semibold, relativeTo: .caption2)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = id
        button.isUserInteractionEnabled = accent
        return button
    }
}