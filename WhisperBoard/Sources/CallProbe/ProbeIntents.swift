import AppIntents
import ActivityKit
import Foundation

/// The plain start, for the Action Button and the App Shortcut phrases. It brings the app
/// forward, because CallKit refuses a plain intent's start from the background.
struct StartTestCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Test call to Number One"
    static var description = IntentDescription("Starts the voice proxy test call. It reaches no seat.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        await ProbeCallController.shared.start(source: .shortcut)
        return .result()
    }
}

// The iOS 27 call schema. A build on an older SDK must fail, not quietly lose this path.
#if compiler(>=6.4)
/// Every conformance here is needed together, as reported on a locked iOS 27.2 phone:
/// the schema, AudioRecordingIntent, LiveActivityIntent, background mode, alwaysAllowed.
@available(iOS 27.0, *)
@AppIntent(schema: .phone.startCall)
struct CallNumberOneIntent: AudioRecordingIntent, LiveActivityIntent {
    static let supportedModes: IntentModes = [.background]
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    var destination: CallDestination
    var audioVisualMode: CallMode // the schema requires it; a video request is placed as voice

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await ProbeCallController.shared.start(source: .schema)
        return .result()
    }
}

@available(iOS 27.0, *)
@UnionValue
enum CallDestination {
    case line(ProbeLineEntity)
}

@available(iOS 27.0, *)
@AppEnum(schema: .phone.audioVisualMode)
enum CallMode: String {
    case audio
    case video

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.audio: "Audio", .video: "Video"]
}

@available(iOS 27.0, *)
@AppEntity(schema: .phone.phonePerson)
struct ProbeLineEntity {
    static let defaultQuery = ProbeLineQuery()

    let id: String
    var person: IntentPerson

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(ProbeConfig.lineName)") }

    init() {
        id = ProbeLine.customIdentifier
        person = IntentPerson(identifier: .applicationDefined(ProbeLine.customIdentifier),
                              name: .displayName(ProbeConfig.lineName), handle: nil)
    }
}

@available(iOS 27.0, *)
struct ProbeLineQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ProbeLineEntity] {
        identifiers.contains(ProbeLine.customIdentifier) ? [ProbeLineEntity()] : []
    }

    func suggestedEntities() async throws -> [ProbeLineEntity] { [ProbeLineEntity()] }

    func entities(matching string: String) async throws -> [ProbeLineEntity] { [ProbeLineEntity()] }

    func defaultResult() async -> ProbeLineEntity? { ProbeLineEntity() }
}
#else
#error("The iOS 27 call schema needs Xcode 27. Pick that Xcode in the workflow.")
#endif
