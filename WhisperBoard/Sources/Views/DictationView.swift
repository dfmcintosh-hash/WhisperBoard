import SwiftUI
import UIKit

/// Full-screen dictation capture launched by the Action Button / Shortcut (DictateIntent).
/// Records on appear → user taps Stop → on-device WhisperKit transcribes → the text is
/// copied to the clipboard so it can be pasted anywhere.
struct DictationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = TranscriptionService.shared

    @State private var phase: Phase = .recording
    @State private var resultText = ""

    private enum Phase { case recording, transcribing, done }

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 66))
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, isActive: phase == .recording)

            Text(statusText)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if phase == .done && !resultText.isEmpty {
                ScrollView {
                    Text(resultText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }
                .frame(maxHeight: 220)
                .padding(.horizontal)

                Label("Copied to clipboard", systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: primaryAction) {
                Text(primaryLabel)
                    .font(.title3).fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(phase == .recording ? Color.red : Color.blue)
                    .foregroundStyle(.white)
                    .cornerRadius(14)
            }
            .padding(.horizontal)
            .disabled(phase == .transcribing)

            Button("Cancel") {
                service.stopRecording()
                dismiss()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom)
        }
        .onAppear { startRecording() }
        .onChange(of: service.isTranscribing) { _, transcribing in
            // Transcription finished (success or failure) → capture + copy.
            if phase == .transcribing && !transcribing {
                finish()
            }
        }
    }

    // MARK: - Derived UI

    private var iconName: String {
        switch phase {
        case .recording:    return "mic.fill"
        case .transcribing: return "waveform"
        case .done:         return resultText.isEmpty ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
        }
    }
    private var iconColor: Color {
        switch phase {
        case .recording:    return .red
        case .transcribing: return .orange
        case .done:         return resultText.isEmpty ? .orange : .green
        }
    }
    private var statusText: String {
        switch phase {
        case .recording:    return "Listening…\nSpeak, then tap Stop."
        case .transcribing: return "Transcribing…"
        case .done:         return resultText.isEmpty ? "No speech detected." : "Copied to clipboard — paste anywhere."
        }
    }
    private var primaryLabel: String {
        switch phase {
        case .recording:    return "Stop"
        case .transcribing: return "Transcribing…"
        case .done:         return "Done"
        }
    }

    // MARK: - Flow

    private func startRecording() {
        phase = .recording
        service.startDictationRecording()
    }

    private func primaryAction() {
        switch phase {
        case .recording:
            phase = .transcribing
            service.stopRecording()
        case .transcribing:
            break
        case .done:
            dismiss()
        }
    }

    private func finish() {
        resultText = service.lastTranscription
        if !resultText.isEmpty {
            UIPasteboard.general.string = resultText
        }
        phase = .done
    }
}
