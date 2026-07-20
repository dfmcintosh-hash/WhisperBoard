import AppIntents
import SwiftUI

/// Bridges the "Dictate with WhisperBoard" App Intent (Shortcuts / Action Button) to the
/// app UI. The intent sets `pendingDictation`; the root view presents the dictation sheet
/// in response. Recording requires the app to be on screen, so the intent foregrounds it.
@MainActor
final class DictationLauncher: ObservableObject {
    static let shared = DictationLauncher()
    @Published var pendingDictation = false
    private init() {}
}

/// App Intent: open WhisperBoard and start an on-device dictation capture. The transcription
/// (vocab-aware, on-device) is copied to the clipboard so it can be pasted anywhere.
/// Assign to a Shortcut or the Action Button.
struct DictateIntent: AppIntent {
    static var title: LocalizedStringResource = "Dictate with WhisperBoard"
    static var description = IntentDescription(
        "Record and transcribe speech on-device with WhisperBoard. The text is copied to your clipboard so you can paste it anywhere."
    )
    // Recording needs the app in the foreground, so bring it up when run.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DictationLauncher.shared.pendingDictation = true
        return .result()
    }
}

/// Exposes the intent to Shortcuts / the Action Button, with spoken phrases.
struct WhisperBoardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start \(.applicationName) dictation"
            ],
            shortTitle: "Dictate",
            systemImageName: "mic.fill"
        )
    }
}
