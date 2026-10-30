import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "waveform") }

            BoardChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

            ProbeView()
                .tabItem { Label("Call Test", systemImage: "phone") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

#Preview { MainTabView() }
