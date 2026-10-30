import ActivityKit
import AVFoundation
import CallKit
import Combine
import Intents
import UIKit

/// How a test call began. The whole point of Phase 0 is finding out which of these works
/// on a locked phone, so every start and its outcome goes in the on-screen log.
enum ProbeStartSource: String {
    case inApp = "in-app button"
    case siriKit = "Siri (SiriKit)"
    case schema = "iOS 27 call schema"
    case shortcut = "App Shortcut or Action Button"
}

/// An outgoing CallKit call to nobody: a tone into the call, the mic level on screen and
/// on the socket. No PushKit. Calls stay out of the Phone app's Recents.
@MainActor
final class ProbeCallController: ObservableObject {
    static let shared = ProbeCallController()

    enum Phase: Equatable { case idle, starting, connected, ended(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isMuted = false
    @Published private(set) var levelDb: Float = LevelMeter.floorDb
    @Published private(set) var linkText = "No link"
    @Published private(set) var rttMs: Int?
    @Published private(set) var framesSent: UInt64 = 0
    @Published private(set) var routeText = "–"
    @Published private(set) var log: [String] = []

    private var provider: CXProvider?
    private let bridge = ProbeProviderBridge()
    private let callKit = CXCallController()
    private let audio = ProbeAudio()
    private let link = ProbeLink()
    private var callUUID: UUID?
    private var source: ProbeStartSource = .inApp
    private var heardName: String?
    private var retriesLeft = ProbeConfig.didActivateRetries
    private var fulfilledAt: TimeInterval?
    private var watchdog: Task<Void, Never>?
    private var activity: Activity<ProbeCallAttributes>?
    private var routeObserver: NSObjectProtocol?
    private var linkAlive = false

    private init() {
        bridge.owner = self
        link.onEvent = { [weak self] event in self?.handle(event) }
        let link = self.link
        audio.onLevel = { [weak self] level in
            link.send(levelDb: level)
            self?.noteLevel(level)
        }
        audio.onConfigurationChange = { [weak self] in self?.restartAudio() }
        log = UserDefaults.standard.stringArray(forKey: Self.logKey) ?? []
    }

    private nonisolated func noteLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in self?.levelDb = level }
    }

    // MARK: Starting

    func start(source: ProbeStartSource, heardName: String? = nil) async {
        guard callUUID == nil else {
            record("Second start ignored (\(source.rawValue)): a call is already up")
            return
        }
        let uuid = UUID()
        callUUID = uuid // claim before the first await, or a double press starts two
        self.source = source
        self.heardName = heardName
        retriesLeft = ProbeConfig.didActivateRetries
        phase = .starting
        record("Start via \(source.rawValue). \(Self.deviceState())"
               + (heardName.map { " Siri heard: \($0)" } ?? ""))
        guard await AVAudioApplication.requestRecordPermission() else {
            callUUID = nil
            phase = .ended("Microphone is off in Settings.")
            record("Stopped: no microphone permission")
            return
        }
        startLiveActivity()
        await request(uuid)
    }

    private func request(_ uuid: UUID) async {
        let current = freshProvider()
        current.configuration = current.configuration // Apple's workaround for a stale audio session id
        let handle = CXHandle(type: .generic, value: ProbeConfig.lineName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = false
        do {
            try await callKit.request(CXTransaction(action: action))
            record("CallKit accepted the start")
        } catch {
            let code = (error as NSError).code
            record("CallKit REFUSED the start: code \(code) (6 means no proven user intent)")
            callUUID = nil
            phase = .ended("CallKit refused the start (code \(code)).")
            endLiveActivity()
        }
    }

    /// Lazily created, per Apple's advice for the first-unlock race.
    private func freshProvider() -> CXProvider {
        if let provider { return provider }
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        let created = CXProvider(configuration: configuration)
        created.setDelegate(bridge, queue: nil)
        provider = created
        return created
    }

    // MARK: Ending

    func hangUp() {
        guard let uuid = callUUID else { return }
        Task {
            do {
                try await callKit.request(CXTransaction(action: CXEndCallAction(call: uuid)))
            } catch {
                finish("Call ended.")
            }
        }
    }

    func toggleMute() {
        guard let uuid = callUUID else { return }
        let muted = !isMuted
        Task { try? await callKit.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) }
    }

    private func finish(_ message: String) {
        watchdog?.cancel()
        watchdog = nil
        link.stop()
        audio.stop()
        removeRouteObserver()
        endLiveActivity()
        callUUID = nil
        fulfilledAt = nil
        isMuted = false
        linkAlive = false
        linkText = "No link"
        phase = .ended(message)
        record(message)
    }

    // MARK: CallKit callbacks, through the bridge

    func didReset() {
        provider = nil
        finish("CallKit reset the call.")
    }

    func perform(start action: CXStartCallAction, on provider: CXProvider) {
        guard action.callUUID == callUUID else { return action.fail() }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
        } catch {
            record("Audio session setup failed: \((error as NSError).code)")
        }
        link.start(hello: ["source": source.rawValue])
        action.fulfill()
        fulfilledAt = ProcessInfo.processInfo.systemUptime
        armWatchdog(for: action.callUUID)
    }

    func perform(end action: CXEndCallAction) {
        action.fulfill()
        finish("Call ended.")
    }

    func perform(mute action: CXSetMutedCallAction) {
        audio.setMuted(action.isMuted)
        isMuted = action.isMuted
        action.fulfill()
    }

    func didActivate(on provider: CXProvider) {
        watchdog?.cancel()
        watchdog = nil
        let waited = fulfilledAt.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? -1
        record("Audio live \(waited) ms after CallKit took the call")
        do {
            try audio.start()
        } catch {
            record("Audio engine failed: \(error)")
        }
        audio.play(linkAlive ? .alive : .dead)
        noteRoute(reason: "activated")
        observeRoute()
        if let uuid = callUUID { provider.reportOutgoingCall(with: uuid, connectedAt: nil) }
        phase = .connected
        link.report(["did_activate_ms": String(waited)])
    }

    func didDeactivate() {
        audio.stop()
        record("Audio session released")
    }

    // MARK: The didActivate watchdog

    private func armWatchdog(for uuid: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ProbeConfig.didActivateTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.didActivateTimedOut(uuid)
        }
    }

    private func didActivateTimedOut(_ uuid: UUID) async {
        guard uuid == callUUID, let provider else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
        link.stop()
        guard retriesLeft > 0 else {
            finish("CallKit never activated the audio. Gave up after a retry.")
            return
        }
        retriesLeft -= 1
        record("CallKit never activated the audio. Retrying once.")
        let next = UUID()
        callUUID = next
        await request(next)
    }

    // MARK: Link and route

    private func handle(_ event: ProbeLink.Event) {
        switch event {
        case .alive(let rtt, let frames):
            if !linkAlive {
                linkAlive = true
                audio.play(.alive)
                record("Link up")
            }
            rttMs = rtt ?? rttMs
            framesSent = frames
            linkText = "Link alive"
        case .dead(let gap):
            linkAlive = false
            audio.play(.dead)
            linkText = "LINK DEAD"
            record(String(format: "LINK DEAD: nothing heard for %.1f s", gap))
        case .reconnecting(let attempt):
            linkAlive = false
            linkText = "Reconnecting (\(attempt))"
        case .serverRefused(let why):
            record("Server refused: \(why)")
        }
    }

    private func restartAudio() {
        guard phase == .connected else { return }
        do {
            try audio.start()
            audio.play(linkAlive ? .alive : .dead)
            audio.setMuted(isMuted)
        } catch {
            record("Audio restart failed: \(error)")
        }
        noteRoute(reason: "engine changed")
    }

    private func observeRoute() {
        removeRouteObserver()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteRoute(reason: "route changed") }
        }
    }

    private func removeRouteObserver() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
    }

    private func noteRoute(reason: String) {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let input = session.currentRoute.inputs.first
        routeText = "\(input?.portName ?? "no mic") → \(output?.portName ?? "no output")"
        let rate = Int(audio.inputSampleRate)
        record("Route (\(reason)): \(routeText), mic \(rate) Hz")
        link.report(["route_in": input?.portType.rawValue ?? "none",
                     "route_out": output?.portType.rawValue ?? "none",
                     "mic_hz": String(rate)])
    }

    // MARK: Live Activity

    private func startLiveActivity() {
        guard activity == nil else { return }
        let state = ProbeCallAttributes.ContentState(status: "Test call", startedAt: Date())
        do {
            activity = try Activity.request(attributes: ProbeCallAttributes(line: ProbeConfig.lineName),
                                            content: ActivityContent(state: state, staleDate: nil),
                                            pushType: nil)
            record("Live Activity started")
        } catch {
            record("Live Activity refused: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    private func endLiveActivity() {
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: The log he reads back

    private static let logKey = "callProbeLog"
    private static let logLimit = 200

    func clearLog() {
        log = []
        UserDefaults.standard.removeObject(forKey: Self.logKey)
    }

    private func record(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        log.insert("\(formatter.string(from: Date()))  \(line)", at: 0)
        if log.count > Self.logLimit { log.removeLast(log.count - Self.logLimit) }
        UserDefaults.standard.set(log, forKey: Self.logKey)
    }

    private static func deviceState() -> String {
        let application = UIApplication.shared
        let state: String
        switch application.applicationState {
        case .active: state = "App in front"
        case .inactive: state = "App inactive"
        case .background: state = "App in background"
        @unknown default: state = "App state unknown"
        }
        return "\(state), phone \(application.isProtectedDataAvailable ? "unlocked" : "LOCKED")."
    }
}

/// CallKit's delegate. `setDelegate(_, queue: nil)` delivers on the main queue, which is
/// what makes `assumeIsolated` safe here.
final class ProbeProviderBridge: NSObject, CXProviderDelegate {
    weak var owner: ProbeCallController?

    func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { owner?.didReset() }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated { owner?.perform(start: action, on: provider) }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated { owner?.perform(end: action) }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated { owner?.perform(mute: action) }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { owner?.didActivate(on: provider) }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { owner?.didDeactivate() }
    }
}

/// Everything Siri needs once, run from the Prepare button.
enum ProbeSiriSetup {
    @MainActor
    static func prepare() async -> String {
        let mic = await AVAudioApplication.requestRecordPermission()
        let siri = await withCheckedContinuation { continuation in
            INPreferences.requestSiriAuthorization { continuation.resume(returning: $0) }
        }
        registerVocabulary()
        let person = INPerson(
            personHandle: INPersonHandle(value: ProbeLine.customIdentifier, type: .unknown),
            nameComponents: nil, displayName: ProbeConfig.lineName, image: nil,
            contactIdentifier: nil, customIdentifier: ProbeLine.customIdentifier
        )
        let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
                                       destinationType: .normal, contacts: [person], callCapability: .audioCall)
        try? await INInteraction(intent: intent, response: nil).donate()
        return "Microphone \(mic ? "on" : "OFF"), Siri \(siri == .authorized ? "on" : "OFF")"
    }

    static func registerVocabulary() {
        INVocabulary.shared().setVocabularyStrings(NSOrderedSet(array: [ProbeConfig.lineName]), of: .contactName)
    }
}
