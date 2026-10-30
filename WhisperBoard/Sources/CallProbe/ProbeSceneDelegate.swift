import Intents
import SwiftUI
import UIKit

/// SiriKit hands a call to the app as an NSUserActivity. It can arrive at launch, in the
/// app delegate, or in a scene, so every door leads to the same place, and
/// `ProbeCallController.start` drops a duplicate.
enum ProbeStartRouter {
    static let activityType = NSStringFromClass(INStartCallIntent.self)

    @MainActor
    static func route(_ activity: NSUserActivity) {
        guard activity.activityType == activityType else { return }
        let heard = activity.userInfo?["heardName"] as? String
        Task { await ProbeCallController.shared.start(source: .siriKit, heardName: heard) }
    }
}

final class ProbeSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        for activity in connectionOptions.userActivities {
            MainActor.assumeIsolated { ProbeStartRouter.route(activity) }
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        MainActor.assumeIsolated { ProbeStartRouter.route(userActivity) }
    }
}
