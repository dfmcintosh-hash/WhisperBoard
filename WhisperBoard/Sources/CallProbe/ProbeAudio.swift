import AVFoundation

/// The call's sound: Voice Processing IO, a quiet tone into the call, and a mic level
/// every 20 ms. It reads the mic to measure it and passes on only the number.
/// Start only from `didActivate`; CallKit owns the session.
final class ProbeAudio {
    enum Tone { case alive, dead }

    /// Called on the audio thread.
    var onLevel: ((Float) -> Void)?
    /// Called on the main queue when the route changes the engine under us.
    var onConfigurationChange: (() -> Void)?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var toneFormat: AVAudioFormat?
    private var observer: NSObjectProtocol?

    /// The rate and route the mic really came up on, for the test log.
    private(set) var inputSampleRate: Double = 0

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ProbeAudioError.noInput }
        inputSampleRate = format.sampleRate

        let chunk = max(1, Int(format.sampleRate * ProbeConfig.levelChunkSeconds))
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(chunk * 4), format: format) { [weak self] buffer, _ in
            guard let self, let samples = buffer.floatChannelData?[0] else { return }
            var offset = 0
            let total = Int(buffer.frameLength)
            while offset < total {
                let count = min(chunk, total - offset)
                let run = UnsafeBufferPointer(start: samples + offset, count: count)
                self.onLevel?(LevelMeter.decibels(run))
                offset += count
            }
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        let toneRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let toneFormat = AVAudioFormat(standardFormatWithSampleRate: toneRate > 0 ? toneRate : 48_000,
                                             channels: 1) else { throw ProbeAudioError.noOutput }
        engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.player = player
        self.toneFormat = toneFormat
        player.play()
        play(.dead)

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        toneFormat = nil
    }

    func setMuted(_ muted: Bool) {
        engine?.inputNode.isVoiceProcessingInputMuted = muted
    }

    /// A soft beep every 2 s while the link is good, a fast double beep while it's dead,
    /// so he can hear the link's state with the phone in his pocket.
    func play(_ tone: Tone) {
        guard let player, let format = toneFormat,
              let buffer = Self.pattern(tone, format: format) else { return }
        player.scheduleBuffer(buffer, at: nil, options: [.loops, .interruptsAtLoop], completionHandler: nil)
    }

    private static func pattern(_ tone: Tone, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let beeps: [(start: Double, length: Double, hertz: Double)]
        let period: Double
        switch tone {
        case .alive:
            period = 2.0
            beeps = [(0, 0.12, 660)]
        case .dead:
            period = 1.0
            beeps = [(0, 0.1, 330), (0.2, 0.1, 330)]
        }
        let frames = AVAudioFrameCount(rate * period)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for index in 0..<Int(frames) { samples[index] = 0 }
        for beep in beeps {
            let first = Int(beep.start * rate)
            let count = Int(beep.length * rate)
            for index in 0..<count where first + index < Int(frames) {
                let time = Double(index) / rate
                let fade = min(1, min(time, beep.length - time) / 0.01)
                samples[first + index] = Float(sin(2 * .pi * beep.hertz * time) * 0.12 * fade)
            }
        }
        return buffer
    }
}

enum ProbeAudioError: Error {
    case noInput
    case noOutput
}
