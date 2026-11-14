import HoldMyTrackCore
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var flow: AppFlow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        Theme.apply(to: window)
        let flow = AppFlow(window: window)
        flow.show()
        window.makeKeyAndVisible()
        self.window = window
        self.flow = flow
        open(connectionOptions.urlContexts)
        #if DEBUG
        // The UI tests' stand-in for a file opened from Files: -hmtUpload <path>.
        if let path = UserDefaults.standard.string(forKey: "hmtUpload") { flow.openFiles([URL(fileURLWithPath: path)]) }
        #endif
    }

    /// A GPX, FIT or TCX file opened from Files or shared from another app (FR-3.4).
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        open(contexts)
    }

    private func open(_ contexts: Set<UIOpenURLContext>) {
        let files = contexts.map(\.url).filter(\.isFileURL)
        if !files.isEmpty { flow?.openFiles(files) }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        flow?.resumed()
    }
}
