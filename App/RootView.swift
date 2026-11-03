import SwiftUI

struct RootView: View {
    @State private var selection: Tab = .chats

    enum Tab: Hashable {
        case chats
        case settings
    }

    init() {
        #if DEBUG
        if ScreenshotPreview.screen == "settings" {
            _selection = State(initialValue: .settings)
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            ConversationsView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chats)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onOpenURL { url in
            // wristassistant://settings jumps straight to the Settings
            // tab — useful for the "Sync now" affordance and for
            // quick QA via `xcrun simctl openurl`.
            if url.scheme == "wristassistant" && url.host == "settings" {
                selection = .settings
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(EndpointStore.shared)
        .modelContainer(DataStore.shared)
}
