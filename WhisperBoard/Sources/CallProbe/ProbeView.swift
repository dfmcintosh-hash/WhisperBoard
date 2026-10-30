import SwiftUI

/// The Call Test tab: run the probe by hand and read back what happened.
/// `@StateObject` keeps the call stack, CallKit included, unbuilt until this tab is opened,
/// so a launch that only dictates never touches it.
struct ProbeView: View {
    @StateObject private var call = ProbeCallController.shared
    @State private var setupText = "Not set up yet"

    var body: some View {
        NavigationStack {
            List {
                Section("Set up once") {
                    Button("Prepare for Siri") {
                        Task { setupText = await ProbeSiriSetup.prepare() }
                    }
                    Text(setupText).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Test call to \(ProbeConfig.lineName)") {
                    if call.phase == .starting || call.phase == .connected {
                        Button("Hang up", role: .destructive) { call.hangUp() }
                        Button(call.isMuted ? "Unmute" : "Mute") { call.toggleMute() }
                    } else {
                        Button("Start test call") {
                            Task { await call.start(source: .inApp) }
                        }
                    }
                    LabeledContent("Call", value: phaseText)
                    LabeledContent("Link", value: call.linkText)
                    LabeledContent("Round trip", value: call.rttMs.map { "\($0) ms" } ?? "–")
                    LabeledContent("Frames sent", value: "\(call.framesSent)")
                    LabeledContent("Mic level", value: String(format: "%.0f dB", call.levelDb))
                    LabeledContent("Route", value: call.routeText)
                }
                Section("What happened") {
                    Button("Clear the log") { call.clearLog() }
                    ForEach(Array(call.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Call Test")
        }
    }

    private var phaseText: String {
        switch call.phase {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .connected: return "On a call"
        case .ended(let message): return message
        }
    }
}
