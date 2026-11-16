import Flutter
import UIKit

/// Captures cold-start notification taps before Flutter builds its first route.
class SceneDelegate: FlutterSceneDelegate {
  // UIScene owns cold-start notification taps on current iOS releases.
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions) {
    if let response = connectionOptions.notificationResponse,
       let app = UIApplication.shared.delegate as? AppDelegate {
      _ = app.openPrivateNotification(response)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
