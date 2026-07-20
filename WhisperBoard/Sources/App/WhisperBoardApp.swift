import SwiftUI

@main
struct WhisperBoardApp: App {

    init() {
        // Start the transcription service so it's ready for keyboard requests
        TranscriptionService.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Hosts ContentView and presents the dictation capture screen when the Action Button /
/// Shortcut (DictateIntent) requests it via DictationLauncher.
private struct RootView: View {
    @ObservedObject private var launcher = DictationLauncher.shared

    var body: some View {
        MainTabView()
            .fullScreenCover(isPresented: $launcher.pendingDictation) {
                DictationView()
            }
    }
}
