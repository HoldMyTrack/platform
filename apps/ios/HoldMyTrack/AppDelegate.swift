import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set before launching ends, or the tap that launched the app isn't handed over.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// The notification posted as the app was swiped away while recording: its tap resumes the
    /// recording once the signed-in screen is up (RecordingResume).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == RecordingController.closedNotification {
            DispatchQueue.main.async { MainActor.assumeIsolated { RecordingResume.ask() } }
        }
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }

    /// iOS relaunched the app for the upload session's events (Uploads).
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Uploads.sessionID else { return completionHandler() }
        Uploads.shared.backgroundCompletion = completionHandler
        Uploads.shared.reconnect()
    }
}
