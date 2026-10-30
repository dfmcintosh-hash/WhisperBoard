import Foundation

/// One WebSocket to the test server: level frames up, heartbeats both ways. A pong
/// missing for 3 s reports the link dead and starts reconnecting, even while iOS shows
/// the VPN as Connected. All state lives on `queue`; callbacks arrive on the main queue.
final class ProbeLink {
    enum Event {
        case alive(rttMs: Int?, framesSent: UInt64)
        case dead(gapSeconds: Double)
        case reconnecting(attempt: Int)
        case serverRefused(String)
    }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "com.captainsos.whisperboard.probe-link")
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var running = false
    private var timer: DispatchSourceTimer?
    private var monitor = LinkMonitor(now: ProcessInfo.processInfo.systemUptime)
    private var backoff = ReconnectBackoff()
    private var pingsSent: [Int: TimeInterval] = [:]
    private var pingNumber = 0
    private var seq: UInt64 = 0
    private var framesDropped: UInt64 = 0
    private var reconnects = 0
    private var hello: [String: String] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ProbeConfig.deadAfter
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func start(hello: [String: String]) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            self.hello = hello
            seq = 0
            framesDropped = 0
            reconnects = 0
            backoff.reset()
            connect()
            startTimer()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            generation += 1
            timer?.cancel()
            timer = nil
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
        }
    }

    /// Metadata for the server log. Never free text and never speech.
    func report(_ fields: [String: String]) {
        queue.async { [self] in
            guard monitor.state == .alive else {
                // Not up yet: goes out with the next hello instead of being lost.
                hello.merge(fields) { _, new in new }
                return
            }
            sendJSON(fields.merging(["t": "event"]) { current, _ in current })
        }
    }

    func send(levelDb: Float) {
        queue.async { [self] in
            seq += 1
            guard monitor.state == .alive, let task else {
                framesDropped += 1
                return
            }
            let uptimeMs = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
            let frame = ProbeFrame(seq: seq, capturedMs: uptimeMs, levelDb: levelDb)
            task.send(.data(frame.encoded())) { _ in }
        }
    }

    private func connect() {
        generation += 1
        let current = generation
        monitor.beginConnecting(now: ProcessInfo.processInfo.systemUptime)
        pingsSent.removeAll()
        let next = session.webSocketTask(with: ProbeConfig.serverURL)
        task = next
        next.resume()
        receive(on: next, generation: current)
    }

    private func receive(on socket: URLSessionWebSocketTask, generation current: Int) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard current == self.generation, self.running else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receive(on: socket, generation: current)
                case .success:
                    self.receive(on: socket, generation: current)
                case .failure:
                    self.linkLost(socket)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["t"] as? String else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case "welcome":
            let wasDown = reconnects > 0
            monitor.heard(now: now)
            backoff.reset()
            var fields = hello
            fields["t"] = "hello"
            fields["reconnects"] = String(reconnects)
            fields["frames_dropped"] = String(framesDropped)
            sendJSON(fields)
            post(.alive(rttMs: wasDown ? nil : monitor.rttMs, framesSent: seq))
        case "pong":
            if let number = message["n"] as? Int, let sentAt = pingsSent.removeValue(forKey: number) {
                monitor.pong(now: now, sentAt: sentAt)
            } else {
                monitor.heard(now: now)
            }
            post(.alive(rttMs: monitor.rttMs, framesSent: seq))
        case "refused":
            post(.serverRefused(message["why"] as? String ?? "refused"))
        default:
            break
        }
    }

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.25, repeating: 0.25)
        var sincePing = TimeInterval(0)
        source.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.monitor.tick(now: now) {
                self.post(.dead(gapSeconds: now - self.monitor.lastHeard))
                if let task = self.task { self.linkLost(task) }
                return
            }
            sincePing += 0.25
            if sincePing >= ProbeConfig.pingInterval, self.monitor.state == .alive {
                sincePing = 0
                self.pingNumber += 1
                self.pingsSent[self.pingNumber] = now
                self.sendJSON(["t": "ping", "n": self.pingNumber])
            }
        }
        timer = source
        source.resume()
    }

    private func linkLost(_ socket: URLSessionWebSocketTask) {
        guard socket === task, running else { return }
        socket.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        generation += 1
        reconnects += 1
        let attempt = reconnects
        let delay = backoff.nextDelay()
        post(.reconnecting(attempt: attempt))
        let current = generation
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard running, current == generation else { return }
            connect()
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func post(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
