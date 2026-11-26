import HoldMyTrackCore
import UIKit

/// The map's top row (apps/docs/SPEC.md FR-2.2): the mode toggle at its start, or in its
/// place the selection bar while rows are checked or the recording's status while one runs; the
/// rail at its end, stepping aside for an editor or checked rows, when the export's camera comes
/// under the selection bar. The tab bar goes while an editor or the export has the screen. The
/// decisions are HoldMyTrackCore's MapChrome.
extension MapViewController {
    var selectionShown: Bool {
        MapChrome.selectionShown(sheetVisible: !sheet.isHidden, selecting: session.panel.selecting,
                                 onTracksTab: panelTab == .tracks, editOpen: editOpen)
    }

    /// Shows what the top row holds now.
    func renderTopRow() {
        // The panel comes after the chrome (viewDidLoad), and renders the row once it's there.
        guard isViewLoaded, tracksPanel != nil else { return }
        let selecting = selectionShown
        let editing = editOpen || privateLocations.open
        modes.isHidden = !MapChrome.modeBarShown(recording: recordingLive, editOpen: editOpen, selectionShown: selecting,
                                                 onTracksTab: panelTab == .tracks)
        tracksPanel.selectionBar.isHidden = !selecting
        recordingCard.isHidden = !recordingLive
        // Room after the toggle, or the row's while it's empty; the bar and the status take it all.
        modesSpacer.isHidden = selecting || recordingLive
        rail.view.isHidden = !MapChrome.railShown(editing: editing, selectionShown: selecting)
        rail.locate.isHidden = recordingLive
        rail.export.isHidden = recordingLive
        underBar.isHidden = !MapChrome.checkedExportShown(editing: editing, selectionShown: selecting, recording: recordingLive)
        // The sheet's room and the credit follow the row's height (viewDidLayoutSubviews).
        view.setNeedsLayout()
        if rail.view.isHidden { dismissMenus() }
        if modes.isHidden { fogLevelMenu.dismissUsers() }
        onBottomBar?(MapChrome.bottomBarShown(editOpen: editOpen, privacyEditing: privateLocations.open, exportOpen: exportOpen))
    }

    /// The recording's status, in words, and the hold's countdown (RecordingController).
    func showRecordingStatus(clock: String, detail: String, paused: Bool) {
        loadViewIfNeeded()
        recordingCard.show(clock: clock, detail: detail, paused: paused)
    }

    func showRecordingHold(_ duration: TimeInterval?) {
        loadViewIfNeeded()
        recordingCard.hold(duration)
    }
}

/// While recording, the status in the mode toggle's place, Android's: a dot, red or amber when
/// paused, the moving time large, the distance or why there's none, and Stop, which asks first.
/// During a hold on the record button it shows the countdown too, where the finger can't hide it.
final class RecordingCard: UIView {
    var onStop: (() -> Void)?
    private let dot = UIView()
    private let clock = Controls.label("", font: Typeface.serif(DesignTokens.Text.xl), color: UIColor(resource: .ink))
    private let detail = Controls.label("", font: Typeface.sans(DesignTokens.Text.md), color: UIColor(resource: .inkSecondary))
    private let track = UIView()
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint!
    private var holding = false
    private var shown: (clock: String, detail: String) = ("", "")

    private static let red = UIColor(red: 0xe5 / 255, green: 0x39 / 255, blue: 0x35 / 255, alpha: 1)
    private static let amber = UIColor(red: 1, green: 0xb3 / 255, blue: 0, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(resource: .surface)
        layer.cornerRadius = DesignTokens.Radius.md
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        dot.layer.cornerRadius = 5
        dot.backgroundColor = Self.red
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        detail.numberOfLines = 1
        track.backgroundColor = UIColor(resource: .border)
        track.layer.cornerRadius = 2
        track.clipsToBounds = true
        track.heightAnchor.constraint(equalToConstant: 4).isActive = true
        track.isHidden = true
        fill.backgroundColor = Self.red
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])
        let column = Controls.column([clock, detail, track], spacing: DesignTokens.Space.s2)
        // VoiceOver and the UI tests read the time and the detail as one line.
        column.isAccessibilityElement = true
        column.accessibilityTraits = .staticText
        column.accessibilityIdentifier = "recordStatus"
        let stop = Controls.secondaryButton(String(localized: "recording.stopButton", defaultValue: "Stop", comment: "The recording's status over the map: stop, which asks first."), id: "recordStop")
        stop.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .primaryActionTriggered)
        stop.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [dot, column, stop])
        row.alignment = .center
        row.spacing = DesignTokens.Space.s12
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: DesignTokens.Space.s4, leading: DesignTokens.Space.s12, bottom: DesignTokens.Space.s4, trailing: DesignTokens.Space.s4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(clock: String, detail: String, paused: Bool) {
        shown = (clock, detail)
        self.clock.text = clock
        dot.backgroundColor = paused ? Self.amber : Self.red
        if !holding { self.detail.text = detail }
        describe()
    }

    /// A hold under way for duration seconds, or none (nil).
    func hold(_ duration: TimeInterval?) {
        holding = duration != nil
        track.isHidden = !holding
        fillWidth.constant = 0
        layoutIfNeeded()
        if let duration {
            detail.text = String(localized: "recording.holding", defaultValue: "Keep holding to stop…", comment: "Recording: the hold that stops is under way.")
            UIView.animate(withDuration: duration, delay: 0, options: .curveLinear) {
                self.fillWidth.constant = self.track.bounds.width
                self.layoutIfNeeded()
            }
        } else {
            fill.layer.removeAllAnimations()
            detail.text = shown.detail
        }
        describe()
    }

    private func describe() {
        let column = clock.superview
        column?.accessibilityLabel = "\(clock.text ?? "") · \(detail.text ?? "")"
    }
}
