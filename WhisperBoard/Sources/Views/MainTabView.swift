import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "waveform") }

            BoardChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

#Preview { MainTabView() }
