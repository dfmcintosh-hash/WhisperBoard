import UIKit

/// App delegate for handling system-level events.
/// Wired up via `@UIApplicationDelegateAdaptor` in WhisperBoardApp.
/// TranscriptionService is started directly in WhisperBoardApp.init().

class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        ProbeSiriSetup.registerVocabulary()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ProbeSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        MainActor.assumeIsolated { ProbeStartRouter.route(userActivity) }
        return userActivity.activityType == ProbeStartRouter.activityType
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Keep transcription service alive briefly for any in-progress work
        let taskID = application.beginBackgroundTask {
            // Expiration handler – nothing critical to do
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            application.endBackgroundTask(taskID)
        }
    }
}
