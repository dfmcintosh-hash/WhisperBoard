import Intents

/// Siri's way in for "call Number One on Ruminate". It starts nothing itself: Apple says
/// to pass the call to the app. Any name resolves to Number One's line, and the name Siri
/// heard goes along, because whether an unknown name reaches us is one of the test's questions.
final class IntentHandler: INExtension, INStartCallIntentHandling {
    override func handler(for intent: INIntent) -> Any { self }

    func resolveContacts(for intent: INStartCallIntent,
                         with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        guard let contacts = intent.contacts, !contacts.isEmpty else {
            completion([INStartCallContactResolutionResult(personResolutionResult: .needsValue())])
            return
        }
        completion(contacts.map {
            INStartCallContactResolutionResult(personResolutionResult: .success(with: $0))
        })
    }

    func resolveCallCapability(for intent: INStartCallIntent,
                               with completion: @escaping (INStartCallCallCapabilityResolutionResult) -> Void) {
        completion(.success(with: .audioCall))
    }

    func resolveDestinationType(for intent: INStartCallIntent,
                                with completion: @escaping (INCallDestinationTypeResolutionResult) -> Void) {
        completion(.success(with: .normal))
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        let activity = NSUserActivity(activityType: NSStringFromClass(INStartCallIntent.self))
        if let name = intent.contacts?.first?.displayName {
            activity.userInfo = ["heardName": name]
        }
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
    }
}
