import SwiftUI
import SwiftData

@main
struct WristAssistantWatchApp: App {
    @StateObject private var endpointStore = EndpointStore.shared

    init() {
        // The watch is a receiver for endpoint + key state. It does not
        // republish the catalog back to the phone (which would cause a
        // ping-pong loop). It can still publish conversation + message
        // events when the user creates them locally.
        EndpointStore.isPrimaryForEndpoints = false
        SyncCoordinator.shared.activate()
        // Defer the actual requestEndpoints / requestConversations calls
        // until WCSession reports `.activated` (it is async, and calling
        // sendMessage on a non-activated session throws). The bootstrap
        // fires from the activation callback; the .task block below is
        // left in place as a safety net for the case where activation
        // completes before the .task runs.
        SyncCoordinator.shared.requestBootstrap()
    }

    var body: some Scene {
        WindowGroup {
            rootContent
                .environmentObject(endpointStore)
                .environmentObject(SyncCoordinator.shared)
                .task {
                    // The bootstrap scheduled from `init()` already
                    // fires requestEndpoints / requestAPIKeys /
                    // requestConversations from the activation callback,
                    // but this task re-issues them so a slow activation
                    // (or a watch that came back from a background
                    // pause) still picks up the latest state. The
                    // requestEndpoints reply now carries the API keys
                    // too, so requestAPIKeys is just a belt-and-braces
                    // second pull.
                    SyncCoordinator.shared.requestEndpoints()
                    SyncCoordinator.shared.requestAPIKeys()
                    SyncCoordinator.shared.requestConversations()
                }
        }
        .modelContainer(DataStore.shared)
    }

    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WA_TEST_VOICE_SETTINGS"] == "1" {
            NavigationStack { VoiceSettingsView() }
        } else {
            RootView()
        }
        #else
        RootView()
        #endif
    }
}
