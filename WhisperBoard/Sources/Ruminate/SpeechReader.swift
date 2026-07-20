import Foundation
import AVFoundation
import UIKit

protocol SpeechSynth: AnyObject {
    var onFinish: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    func speak(_ text: String)
    func stop()
}

protocol AudioSessionManaging: AnyObject {
    func activateForSpeech() throws
    func deactivate() throws
}

final class SystemAudioSession: AudioSessionManaging {
    func activateForSpeech() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }
    func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

final class SystemSpeechSynth: NSObject, SpeechSynth, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    override init() { super.init(); synthesizer.delegate = self }
    var isSpeaking: Bool { synthesizer.isSpeaking }
    func speak(_ text: String) { synthesizer.speak(AVSpeechUtterance(string: text)) }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onFinish?() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onFinish?() }
}

@MainActor
final class SpeechReader {
    private let synth: SpeechSynth
    private let session: AudioSessionManaging
    private let store: ChatStore
    private var observers: [NSObjectProtocol] = []

    init(synth: SpeechSynth = SystemSpeechSynth(), session: AudioSessionManaging = SystemAudioSession(), store: ChatStore) {
        self.synth = synth
        self.session = session
        self.store = store
        synth.onFinish = { [weak self] in Task { @MainActor in self?.finished() } }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        ]
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    @discardableResult
    func speak(text: String, turnId: String) -> Bool {
        guard !text.isEmpty else { return false }
        if synth.isSpeaking { synth.stop(); finished() }
        guard AudioActivityGate.shared.acquire(.speech) else { return false }
        do {
            try session.activateForSpeech()
            synth.speak(text)
            return true
        } catch {
            AudioActivityGate.shared.release(.speech)
            return false
        }
    }

    func stop() {
        if synth.isSpeaking { synth.stop() }
        finished()
    }

    func autoReadIfEnabled(turn: LocalTurn, enabled: Bool) async {
        guard enabled, !turn.restoredFromHistory, turn.state == .complete,
              !turn.replySpokenOnce, let reply = turn.reply else { return }
        guard speak(text: reply, turnId: turn.id) else { return }
        try? await store.update(turn.id) { $0.replySpokenOnce = true }
    }

    private func finished() {
        try? session.deactivate()
        AudioActivityGate.shared.release(.speech)
    }
}
