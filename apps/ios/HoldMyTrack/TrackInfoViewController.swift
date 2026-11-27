import HoldMyTrackCore
import UIKit

/// The toolbar's Info (root docs/SPEC.md FR-5.8), as Android's sheet: the server's lines for the
/// toolbar's target (`POST /v2/tracks/info`), the pace bands' legend while the map draws them, and
/// the server's note under them.
final class TrackInfoViewController: UIViewController {
    private let api: APIClient
    private let trackIDs: [String]
    private let bandColors: [String]?
    private let status = Controls.body(String(localized: "Loading…"))
    private let column = Controls.column([], spacing: DesignTokens.Space.s8)

    init(api: APIClient, trackIDs: [String], bandColors: [String]?) {
        self.api = api
        self.trackIDs = trackIDs
        self.bandColors = bandColors
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .surface)
        view.accessibilityIdentifier = "trackInfo"
        title = String(localized: "info.title", defaultValue: "Info", comment: "The Tracks toolbar's Info sheet: its title.")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        status.numberOfLines = 0
        column.addArrangedSubview(status)
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(column)
        let m = DesignTokens.Space.s16
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: DesignTokens.Space.s8),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -DesignTokens.Space.s20),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: m),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -m),
        ])
        Task { [weak self] in await self?.load() }
    }

    private func load() async {
        do {
            show(try await api.trackInfo(trackIDs))
        } catch {
            let reason = (error as? APIError)?.serverMessage ?? String(localized: "The server couldn't be reached.")
            status.text = String(localized: "info.failed", defaultValue: "Couldn't load the info: \(reason)", comment: "The Tracks toolbar's Info sheet: its lines couldn't be read.")
            status.textColor = UIColor(resource: .danger)
        }
    }

    private func show(_ info: TrackInfo) {
        status.isHidden = true
        for line in info.lines { column.addArrangedSubview(Self.row(line)) }
        if let bandColors { column.addArrangedSubview(Self.legend(bandColors)) }
        if !info.note.isEmpty {
            let note = Controls.label(info.note, font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
            note.numberOfLines = 0
            column.addArrangedSubview(note)
        }
    }

    /// A line: the label, and the value at the end, stacked once both don't fit side by side.
    private static func row(_ line: TrackInfo.Line) -> UIView {
        let label = Controls.label(line.label, font: Typeface.sans(DesignTokens.Text.md, relativeTo: .body), color: UIColor(resource: .inkSecondary))
        let value = Controls.label(line.value, font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold, relativeTo: .body), color: UIColor(resource: .ink))
        for l in [label, value] { l.numberOfLines = 0 }
        value.textAlignment = .right
        value.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, value])
        row.spacing = DesignTokens.Space.s12
        row.alignment = .firstBaseline
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(line.label), \(line.value)"
        return row
    }

    /// The pace bands' legend, slowest to fastest.
    private static func legend(_ colors: [String]) -> UIView {
        let font = Typeface.sans(DesignTokens.Text.xs, relativeTo: .caption2)
        let slower = Controls.label(String(localized: "Slower"), font: font, color: UIColor(resource: .inkSecondary))
        let faster = Controls.label(String(localized: "Faster"), font: font, color: UIColor(resource: .inkSecondary))
        for label in [slower, faster] { label.setContentHuggingPriority(.required, for: .horizontal) }
        let steps = UIStackView()
        steps.spacing = DesignTokens.Space.s2
        steps.distribution = .fillEqually
        steps.heightAnchor.constraint(equalToConstant: 6).isActive = true
        for color in colors {
            let step = UIView()
            step.backgroundColor = CSSColor(color).map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
            step.layer.cornerRadius = 3
            steps.addArrangedSubview(step)
        }
        let row = UIStackView(arrangedSubviews: [slower, steps, faster])
        row.spacing = DesignTokens.Space.s8
        row.alignment = .center
        row.isAccessibilityElement = true
        row.accessibilityLabel = String(localized: "info.bands", defaultValue: "The route on the map, by pace", comment: "The Tracks toolbar's Info sheet: the pace bands' legend, read aloud.")
        row.accessibilityIdentifier = "infoBands"
        return row
    }
}
