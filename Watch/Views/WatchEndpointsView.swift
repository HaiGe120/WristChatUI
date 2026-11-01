import SwiftUI
import SwiftData

struct WatchEndpointsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var endpoints: EndpointStore
    @EnvironmentObject private var sync: SyncCoordinator
    @State private var presentingNew = false
    @State private var editing: EndpointConfig?

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: sync.isCompanionReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                        .foregroundStyle(sync.isCompanionReachable ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sync.isCompanionReachable ? "iPhone reachable" : "iPhone not reachable")
                            .font(.caption)
                        if endpoints.endpoints.isEmpty {
                            Text("Pull endpoints from iPhone to start.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(endpoints.endpoints.count) endpoint\(endpoints.endpoints.count == 1 ? "" : "s") synced")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        SyncCoordinator.shared.requestEndpoints()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                NavigationLink("Connection help") {
                    WatchConnectionHelpView()
                }
            }
            Section("Configured") {
                if endpoints.endpoints.isEmpty {
                    Text("No endpoints yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(endpoints.endpoints) { e in
                        Button {
                            editing = e
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.name)
                                    Text(e.model)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if e.id == endpoints.activeEndpointID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            endpoints.delete(endpoints.endpoints[index].id)
                        }
                    }
                }
            }
            Section {
                Button {
                    presentingNew = true
                } label: {
                    Label("Add endpoint", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Endpoints")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $presentingNew) {
            NavigationStack {
                WatchEndpointEditor(endpoint: nil)
            }
        }
        .sheet(item: $editing) { endpoint in
            NavigationStack {
                WatchEndpointEditor(endpoint: endpoint)
            }
        }
    }
}

struct WatchEndpointEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var endpoints: EndpointStore

    private let original: EndpointConfig
    private let isNew: Bool
    @State private var edit: EndpointProfileEdit
    @State private var apiKey = ""
    @State private var hasExistingKey = false
    @State private var saveError: String?

    init(endpoint: EndpointConfig?) {
        let source = endpoint ?? EndpointConfig(name: "", providerType: .openAICompatible,
                                                baseURLString: "", model: "")
        original = source
        isNew = endpoint == nil
        _edit = State(initialValue: EndpointProfileEdit(source))
    }

    private var currentEndpoint: EndpointConfig {
        endpoints.endpoints.first(where: { $0.id == original.id }) ?? original
    }

    private var isAccountConnection: Bool { currentEndpoint.authentication != .apiKey }

    var body: some View {
        Form {
            if isAccountConnection {
                Section {
                    Label("ChatGPT account", systemImage: "person.crop.circle")
                    Text("Manage this account on iPhone. Direct ChatGPT sign-in is still in development.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Section("Profile") {
                    TextField("Name", text: $edit.name)
                    Picker("API format", selection: $edit.apiFormat) {
                        ForEach(APIFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                }
                Section {
                    TextField("Base URL", text: $edit.baseURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model", text: $edit.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key (optional)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if hasExistingKey && apiKey.isEmpty {
                        Text("Saved key on file. Leave blank to keep.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Requests run from Apple Watch. watchOS chooses the network route.")
                }
                Section("Web search") {
                    Picker("Default", selection: $edit.searchMode) {
                        Text("Off").tag(SearchMode.off)
                        Text("Auto").tag(SearchMode.auto)
                    }
                    Text("Auto uses the selected search source. Native search depends on this connection and model.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Behavior") {
                    TextField("System prompt", text: $edit.systemPrompt, axis: .vertical)
                        .lineLimit(1...3)
                    HStack {
                        Text("Temp")
                        Spacer()
                        Text(String(format: "%.2f", edit.temperature))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $edit.temperature, in: 0...2, step: 0.1)
                }
            }
            if let saveError {
                Text(saveError).font(.caption2).foregroundStyle(.red)
            }
        }
        .navigationTitle(isNew ? "New Endpoint" : "Edit Endpoint")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if !isAccountConnection {
                    Button("Save") { save() }
                        .disabled(!edit.hasRequiredFields)
                }
            }
        }
        .onAppear {
            if !isAccountConnection {
                hasExistingKey = !(endpoints.apiKey(for: original.id) ?? "").isEmpty
            }
        }
    }

    private func save() {
        // Use the latest synced profile for hidden fields so editing on Watch
        // cannot erase a concurrent iPhone update to headers or token limits.
        guard let config = edit.applying(to: currentEndpoint) else {
            saveError = "Manage this account on iPhone."
            return
        }
        endpoints.save(config)
        if !apiKey.isEmpty {
            endpoints.setAPIKey(apiKey, for: config.id)
        } else if isNew {
            endpoints.setAPIKey("", for: config.id)
        }
        if endpoints.activeEndpointID == nil { endpoints.setActive(config.id) }
        dismiss()
    }
}
