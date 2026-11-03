import SwiftUI
import SwiftData

@main
struct WristAssistantApp: App {
    @StateObject private var endpointStore = EndpointStore.shared
    private let modelContainer: ModelContainer

    init() {
        #if DEBUG
        if ScreenshotPreview.screen != nil {
            modelContainer = ScreenshotPreview.makeContainer()
            return
        }
        #endif
        modelContainer = DataStore.shared
        // The iPhone is the source of truth for endpoint catalog + API
        // keys. Marking this here makes every EndpointStore.save / setActive
        // / setAPIKey call publish through SyncCoordinator.
        EndpointStore.isPrimaryForEndpoints = true

        #if DEBUG
        // Test hook: if WA_TEST_API_KEY is set, write it to the
        // MiniMax (Anthropic-compatible) endpoint's keychain entry.
        // That is the endpoint the user has been actively testing, so
        // hardcoding `endpoints.first` (which is Open WebUI local) was
        // putting the key on the wrong row. Falls back to the OpenAI-
        // compatible MiniMax variant, then to the first endpoint, so
        // the hook still works in any seed order. Stripped from the
        // App Store build via #if DEBUG.
        if let key = ProcessInfo.processInfo.environment["WA_TEST_API_KEY"],
           !key.isEmpty {
            let target = EndpointStore.shared.endpoints.first(where: { $0.name == "MiniMax (Anthropic-compatible)" })
                ?? EndpointStore.shared.endpoints.first(where: { $0.name == "MiniMax" })
                ?? EndpointStore.shared.endpoints.first
            if let target {
                EndpointStore.shared.setAPIKey(key, for: target.id)
            }
        }
        #endif

        // Activate the WatchConnectivity session, then schedule a
        // deferred bootstrap. The publish is intentionally NOT made
        // synchronously here: WCSession.activate() is async, so a
        // direct call to `publishEndpoints` / `transferUserInfo`
        // right after activate() throws "WatchConnectivity session
        // has not been activated". `requestBootstrap()` records the
        // intent and the coordinator drains it from the activation
        // callback once the session is actually `.activated`.
        SyncCoordinator.shared.activate()
        SyncCoordinator.shared.requestBootstrap()
    }

    var body: some Scene {
        WindowGroup {
            rootContent
                .environmentObject(endpointStore)
                .environmentObject(SyncCoordinator.shared)
        }
        .modelContainer(modelContainer)
    }

    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WA_TEST_VOICE_SETTINGS"] == "1" {
            NavigationStack { PhoneVoiceSettingsView() }
        } else {
            RootView()
        }
        #else
        RootView()
        #endif
    }
}
