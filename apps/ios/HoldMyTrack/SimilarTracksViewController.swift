import HoldMyTrackCore
import UIKit

/// A Sync row's ⓘ (docs/SPEC.md FR-3.5, apps/docs/SPEC.md FR-3.2): what else covers the
/// same time as it, the rows waiting on this phone (SyncSimilar), each picked out on the map when
/// tapped, and the account's track it overlaps the most, opened on the Tracks tab. It says what
/// sending both does and chooses nothing.
final class SimilarTracksViewController: UIViewController {
    struct Item {
        let kind: TrackKind
        let title: String
        let meta: String
        let run: () -> Void
    }

    private let lead: String
    private let waiting: [Item]
    private let onMap: Item?

    init(lead: String, waiting: [Item], onMap: Item?) {
        self.lead = lead
        self.waiting = waiting
        self.onMap = onMap
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .surface)
        var views: [UIView] = [
            Controls.label(String(localized: "similar.title", defaultValue: "Hey, there are similar tracks", comment: "Similar tracks: the sheet's title."),
                           font: Typeface.serif(DesignTokens.Text.xxl), color: UIColor(resource: .ink)),
            Controls.body(lead, color: UIColor(resource: .ink)),
        ]
        if !waiting.isEmpty {
            views.append(heading(String(localized: "similar.waiting", defaultValue: "Waiting here", comment: "Similar tracks: the rows on this phone.")))
            views += waiting.map(row)
        }
        if let onMap {
            views.append(heading(String(localized: "similar.onMap", defaultValue: "Already on your map", comment: "Similar tracks: the account's track.")))
            views.append(row(onMap))
        }
        views.append(Controls.body(String(localized: "similar.note", defaultValue: "Each one sent becomes a track of its own. Nothing is chosen for you — delete the one you don't want.",
                                          comment: "Similar tracks: what sending both does.")))
        let close = Controls.secondaryButton(String(localized: "Close"), id: "similarClose")
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        views.append(close)
        for label in views.compactMap({ $0 as? UILabel }) { label.numberOfLines = 0 }
        Controls.host(Controls.column(views), in: self)
    }

    private func heading(_ text: String) -> UILabel {
        Controls.label(text, font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    }

    private func row(_ item: Item) -> UIView {
        var config = UIButton.Configuration.plain()
        config.image = Controls.icon(TrackTypes.icon(item.kind), size: 18)
        config.imagePadding = DesignTokens.Space.s12
        config.title = item.title
        config.subtitle = item.meta
        config.baseForegroundColor = UIColor(resource: .ink)
        config.contentInsets = .zero
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true) { item.run() }
        })
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = String(localized: "similar.show", defaultValue: "Show \(item.title), \(item.meta)", comment: "Similar tracks: a row, read out.")
        button.accessibilityIdentifier = "similarRow"
        return button
    }
}