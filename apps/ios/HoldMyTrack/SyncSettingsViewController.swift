import CoreLocation
import UIKit
import UserNotifications

/// Settings › Sync (apps/android/docs/SPEC.md FR-3.1), from the You tab: where journeys come
/// from. iOS has one source, the record button, always on, with whether location and
/// notifications are allowed yet; Choose what to sync goes on to the Sync tab. Health (HealthKit)
/// joins it in the roadmap's step 7c.
final class SyncSettingsViewController: UIViewController {
    /// Choose what to sync: the Sync tab.
    var onOpenList: (() -> Void)?

    private let status = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let icon = UIImageView(image: Controls.icon(UIImage(resource: .circleDot), size: 24))

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "sync.settingsTitle", defaultValue: "Sync", comment: "Settings › Sync: the screen's title.")
        view.backgroundColor = UIColor(resource: .bg)
        let intro = Controls.body(String(localized: "sync.sourcesIntro", defaultValue: "Where your journeys come from.", comment: "Settings › Sync: what the screen is for."))
        let section = Controls.label(String(localized: "sync.recorded", defaultValue: "Recorded on this phone", comment: "Sync: where a row comes from."),
                                     font: Typeface.sans(DesignTokens.Text.sm, weight: DesignTokens.Weight.semibold, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
        let name = Controls.label(String(localized: "sync.recordedTitle", defaultValue: "The record button", comment: "Settings › Sync: the record button as a source."),
                                  font: Typeface.sans(DesignTokens.Text.lg, weight: DesignTokens.Weight.semibold, relativeTo: .body), color: UIColor(resource: .ink))
        let sub = Controls.body(String(localized: "sync.recordedSub", defaultValue: "Always on. Recordings wait on the Sync tab until you send them.", comment: "Settings › Sync: the record button's note."))
        status.numberOfLines = 0
        status.accessibilityIdentifier = "recordedStatus"
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let text = Controls.column([name, sub, status], spacing: DesignTokens.Space.s4)
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = DesignTokens.Space.s12
        row.alignment = .top
        let card = UIStackView(arrangedSubviews: [row])
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        card.backgroundColor = UIColor(resource: .surface)
        card.layer.cornerRadius = DesignTokens.Radius.md
        let open = Controls.primaryButton(String(localized: "sync.openList", defaultValue: "Choose what to sync", comment: "Settings › Sync: go to the Sync tab."), id: "syncOpenList")
        open.addAction(UIAction { [weak self] _ in self?.onOpenList?() }, for: .primaryActionTriggered)
        Controls.host(Controls.column([intro, section, card, open], spacing: DesignTokens.Space.s16), in: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        renderStatus()
    }

    /// Allowed once location while in use and notifications both are; else they're asked for on
    /// the first recording.
    private func renderStatus() {
        let location = CLLocationManager().authorizationStatus
        Task { [weak self] in
            let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard let self else { return }
            let allowed = SyncSources.recordingAllowed(location: [.authorizedWhenInUse, .authorizedAlways].contains(location),
                                                       notifications: [.authorized, .provisional, .ephemeral].contains(notifications))
            self.status.text = allowed
                ? String(localized: "sync.recordedAllowed", defaultValue: "Location and notifications allowed", comment: "Settings › Sync: the record button can record.")
                : String(localized: "sync.recordedNotYet", defaultValue: "Location and notifications are asked for on your first recording.", comment: "Settings › Sync: the record button hasn't been allowed yet.")
            self.status.textColor = UIColor(resource: allowed ? .success : .inkSecondary)
            self.icon.tintColor = UIColor(resource: allowed ? .success : .inkSecondary)
        }
    }
}

/// What Settings › Sync says about its sources.
enum SyncSources {
    /// The record button can record: location and notifications both allowed.
    static func recordingAllowed(location: Bool, notifications: Bool) -> Bool { location && notifications }
}
