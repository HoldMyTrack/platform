import HoldMyTrackCore
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var flow: AppFlow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let flow = AppFlow(window: window)
        flow.show()
        window.makeKeyAndVisible()
        self.window = window
        self.flow = flow
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        flow?.resumed()
    }
}
