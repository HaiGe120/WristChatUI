import SwiftUI

struct WatchConnectionHelpView: View {
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        List {
            Section("Connection") {
                Text(sync.isCompanionReachable ? "iPhone available for sync" : "iPhone not currently available for sync")
                Text("Chat requests start on the Watch. watchOS can use the nearby iPhone, Watch Wi-Fi, or cellular. Sync availability does not identify the route used for a chat request.")
            }
            Section("If iPhone works") {
                Text("A working iPhone VPN does not confirm that this Watch request follows the same route or VPN rules.")
                Text("Check the connection icon in Watch Control Center: iPhone or Wi-Fi. Keep the phone nearby and Bluetooth enabled.")
            }
            Section("Compare once") {
                Text("Use the same endpoint, API format and model on both devices. Turn Search off for this check so only the chat connection is tested.")
                Text("Retry once on Watch, then check your VPN app's connection log for the endpoint host, matched rule and outbound connection. Compare a successful iPhone request.")
                Text("No log entry can be a clue, but it does not prove the cause. DNS, TLS, VPN routing and server delays can all prevent a reply.")
            }
            Section("Retry safely") {
                Text("A timeout releases the conversation. Retry reuses the question; a new message starts a separate turn. No timed-out request is automatically resent.")
            }
        }
        .font(.caption)
        .navigationTitle("Connection help")
    }
}
