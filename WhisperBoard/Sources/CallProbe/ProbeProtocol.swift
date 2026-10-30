import Foundation

/// Voice proxy Phase 0 (ORDER-1667): the fixed facts of the device probe.
/// This build talks only to a throwaway test server. Nothing here reaches a seat.
enum ProbeConfig {
    static let serverURL = URL(string: "ws://100.91.102.23:8774/probe")!
    static let lineName = "Number One"
    static let pingInterval: TimeInterval = 1.0
    /// No pong for this long means the link is dead, whatever iOS says about the VPN.
    static let deadAfter: TimeInterval = 3.0
    static let didActivateTimeout: TimeInterval = 5.0
    static let didActivateRetries = 1
    static let levelChunkSeconds: Double = 0.02
}

/// One mic frame: the LEVEL only, never audio. The padding stays zero, and the server
/// refuses a frame whose padding isn't. 60 bytes every 20 ms is the size of 24 kbit/s
/// Opus, so the link carries the load Phase 1 will put on it.
struct ProbeFrame: Equatable {
    static let byteCount = 60
    private static let magic: [UInt8] = [0x43, 0x50] // "CP"
    private static let version: UInt8 = 1

    var seq: UInt64
    var capturedMs: UInt64
    var levelDb: Float

    func encoded() -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.byteCount)
        bytes[0] = Self.magic[0]
        bytes[1] = Self.magic[1]
        bytes[2] = Self.version
        Self.put(seq, at: 4, in: &bytes)
        Self.put(capturedMs, at: 12, in: &bytes)
        let level = levelDb.bitPattern
        for i in 0..<4 { bytes[20 + i] = UInt8((level >> UInt32(24 - 8 * i)) & 0xff) }
        return Data(bytes)
    }

    static func decoded(from data: Data) -> ProbeFrame? {
        let bytes = [UInt8](data)
        guard bytes.count == byteCount, bytes[0] == magic[0], bytes[1] == magic[1], bytes[2] == version,
              bytes[24...].allSatisfy({ $0 == 0 }) else { return nil }
        var level: UInt32 = 0
        for i in 0..<4 { level = (level << 8) | UInt32(bytes[20 + i]) }
        return ProbeFrame(seq: get(at: 4, in: bytes), capturedMs: get(at: 12, in: bytes),
                          levelDb: Float(bitPattern: level))
    }

    private static func put(_ value: UInt64, at offset: Int, in bytes: inout [UInt8]) {
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> UInt64(56 - 8 * i)) & 0xff) }
    }

    private static func get(at offset: Int, in bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(bytes[offset + i]) }
        return value
    }
}

/// Decides when the link is dead. Pure and clock-injected, so the 3 s rule is testable.
struct LinkMonitor: Equatable {
    enum State: Equatable { case connecting, alive, dead }

    let deadAfter: TimeInterval
    private(set) var state: State = .connecting
    private(set) var lastHeard: TimeInterval
    private(set) var rttMs: Int?

    init(deadAfter: TimeInterval = ProbeConfig.deadAfter, now: TimeInterval) {
        self.deadAfter = deadAfter
        lastHeard = now
    }

    mutating func beginConnecting(now: TimeInterval) {
        state = .connecting
        lastHeard = now
    }

    mutating func heard(now: TimeInterval) {
        state = .alive
        lastHeard = now
    }

    mutating func pong(now: TimeInterval, sentAt: TimeInterval) {
        heard(now: now)
        rttMs = Int(((now - sentAt) * 1000).rounded())
    }

    /// True exactly once, on the tick that crosses the limit.
    mutating func tick(now: TimeInterval) -> Bool {
        guard state != .dead, now - lastHeard >= deadAfter else { return false }
        state = .dead
        return true
    }
}

/// Which tone he should be hearing. Every way the link can go down leads through `down()`,
/// a missed heartbeat and a socket error alike, so the good-line beep can't outlive the line.
struct LinkTone: Equatable {
    private(set) var isAlive = false

    /// True when the tone has to change to the good-line beep.
    mutating func up() -> Bool {
        defer { isAlive = true }
        return !isAlive
    }

    /// True when the tone has to change to the dead-line beep.
    mutating func down() -> Bool {
        defer { isAlive = false }
        return isAlive
    }
}

/// 0.5, 1, 2, then 4 s for as long as it takes.
struct ReconnectBackoff: Equatable {
    private(set) var attempt = 0

    mutating func nextDelay() -> TimeInterval {
        let delay = min(4.0, 0.5 * pow(2.0, Double(attempt)))
        attempt += 1
        return delay
    }

    mutating func reset() { attempt = 0 }
}

enum LevelMeter {
    static let floorDb: Float = -120

    /// RMS of a run of samples, in dB relative to full scale.
    static func decibels(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return floorDb }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        guard rms > 0 else { return floorDb }
        return max(floorDb, 20 * log10(rms))
    }
}

/// Number One's line, as far as Siri is concerned. Any name resolves to it, because
/// the test wants to see what Siri really passes; the app records the name it heard.
enum ProbeLine {
    static let customIdentifier = "number-one"

    static func isExactMatch(_ spoken: String) -> Bool {
        let folded = spoken.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["numberone", "number1", "no1", "ruminate"].contains(folded)
    }
}
