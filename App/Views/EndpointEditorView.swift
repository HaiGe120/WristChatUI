import SwiftUI

struct EndpointEditorView: View {
    @EnvironmentObject private var endpoints: EndpointStore
    @Environment(\.dismiss) private var dismiss

    @State private var id: UUID = UUID()
    @State private var name: String = ""
    @State private var apiFormat: APIFormat = .chatCompletions
    @State private var searchMode: SearchMode = .off
    @State private var baseURLString: String = ""
    @State private var model: String = ""
    @State private var systemPrompt: String = ""
    @State private var temperature: Double = 0.7
    @State private var apiKey: String = ""
    @State private var hasExistingKey: Bool = false
    @State private var isTestingConnection = false
    @State private var testResult: String?
    @State private var fetchedModels: [String] = []
    @State private var useCustomModel: Bool = false
    @State private var isNew: Bool = true

    private let existing: EndpointConfig?

    init(endpoint: EndpointConfig?) {
        self.existing = endpoint
        _id = State(initialValue: endpoint?.id ?? UUID())
        _name = State(initialValue: endpoint?.name ?? "")
        // Collapse legacy .openAI / .anthropic to their compat equivalents
        // so the picker — which only offers the two compat cases — has a
        // matching tag for the current selection. On save, the migrated
        // type is what gets persisted.
        _apiFormat = State(initialValue: endpoint?.apiFormat ?? .chatCompletions)
        _searchMode = State(initialValue: endpoint?.searchMode ?? .off)
        _baseURLString = State(initialValue: endpoint?.baseURLString ?? "")
        _model = State(initialValue: endpoint?.model ?? "")
        _systemPrompt = State(initialValue: endpoint?.systemPrompt ?? "")
        _temperature = State(initialValue: endpoint?.temperature ?? 0.7)
        _isNew = State(initialValue: endpoint == nil)
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name (e.g. My Open WebUI)", text: $name)
                Picker("API format", selection: $apiFormat) {
                    ForEach(APIFormat.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .onChange(of: apiFormat) { _, _ in
                    // No more auto-filled base URL: every endpoint now
                    // requires the user to type the URL. We still clear
                    // any server-fetched model list because the model
                    // catalog is per-shape.
                    fetchedModels = []
                    useCustomModel = false
                }
                .onChange(of: baseURLString) { _, _ in
                    fetchedModels = []
                    useCustomModel = false
                }
            }
            Section("Connection") {
                TextField("Base URL", text: $baseURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if fetchedModels.isEmpty || useCustomModel {
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !fetchedModels.isEmpty {
                        Button("Pick from \(fetchedModels.count) loaded models") {
                            useCustomModel = false
                        }
                        .font(.caption)
                    }
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(fetchedModels, id: \.self) { name in
                            Text(name).tag(name)
                        }
                        Text("Custom…").tag("__custom__")
                    }
                    .onChange(of: model) { _, new in
                        if new == "__custom__" {
                            useCustomModel = true
                            // Restore the previous non-custom value so the
                            // field isn't blank when the user comes back.
                            if let last = fetchedModels.first(where: { $0 != "__custom__" }) {
                                model = last
                            } else {
                                model = ""
                            }
                        }
                    }
                }
                SecureField(apiKeyPlaceholder, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if hasExistingKey && apiKey.isEmpty {
                    Text("An API key is saved. Leave blank to keep it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Web search") {
                Picker("Default", selection: $searchMode) {
                    Text("Off").tag(SearchMode.off)
                    Text("Auto").tag(SearchMode.auto)
                }
                Text("Auto lets a supported model use native search. A separate selected search source retrieves references before the model answers. Search availability depends on this connection and model.")
                    .font(.caption).foregroundStyle(.secondary)
                if apiFormat == .chatCompletions {
                    Text("Generic Chat Completions does not establish native search support. Choose a search source in Settings or use a verified Responses/Messages connection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Recheck native search on next question") {
                    NativeSearchCapabilities.shared.clear(for: configuredEndpoint)
                    testResult = "Native search will be checked on your next question with Web search enabled."
                }
            }
            Section("Behavior") {
                TextField("System prompt (optional)", text: $systemPrompt, axis: .vertical)
                    .lineLimit(1...4)
                VStack(alignment: .leading) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.2f", temperature))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $temperature, in: 0...2, step: 0.05)
                }
            }
            Section {
                Button {
                    testConnection()
                } label: {
                    HStack {
                        if isTestingConnection { ProgressView() }
                        Text(isTestingConnection ? "Testing…" : "Test connection & load models")
                    }
                }
                .disabled(model.isEmpty || isTestingConnection)
                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(isNew ? "New Endpoint" : "Edit Endpoint")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            // Surface the "Set as Active" affordance here too so the
            // user can promote an existing endpoint to active without
            // going through the row's context menu. The button is a
            // no-op when this endpoint is already active.
            ToolbarItem(placement: .topBarLeading) {
                if endpoints.activeEndpointID != id {
                    Button {
                        endpoints.setActive(id)
                    } label: {
                        Label("Set active", systemImage: "checkmark.circle")
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.isEmpty || model.isEmpty)
            }
        }
        .onAppear {
            if !isNew, let existing {
                let stored = endpoints.apiKey(for: existing.id) ?? ""
                hasExistingKey = !stored.isEmpty
                if apiKey.isEmpty {
                    apiKey = stored
                }
            }
            // No auto-fill of the base URL: the user enters it.
            // (Previously this defaulted to api.openai.com / api.anthropic
            // for the now-removed native cases.)
        }
    }

    private var providerType: AIProviderType {
        apiFormat == .anthropicMessages ? .anthropicCompatible : .openAICompatible
    }

    private var configuredEndpoint: EndpointConfig {
        var config = existing ?? EndpointConfig(name: name, providerType: providerType,
                                                 baseURLString: baseURLString, model: model)
        config.id = id
        config.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.providerType = providerType
        config.apiFormat = apiFormat
        config.authentication = .apiKey
        config.searchMode = searchMode
        config.baseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.systemPrompt = systemPrompt
        config.temperature = temperature
        return config
    }

    private var apiKeyPlaceholder: String {
        switch providerType {
        case .openAI, .openAICompatible: return "API key (sk-…, or leave blank for local servers)"
        case .anthropic, .anthropicCompatible: return "API key (sk-ant-…, or leave blank for local servers)"
        }
    }

    private func save() {
        let config = configuredEndpoint
        endpoints.save(config)
        if !apiKey.isEmpty {
            endpoints.setAPIKey(apiKey, for: id)
        } else if isNew {
            endpoints.setAPIKey("", for: id)
        }
        if endpoints.activeEndpointID == nil {
            endpoints.setActive(id)
        }
        dismiss()
    }

    private func testConnection() {
        testResult = nil
        fetchedModels = []
        useCustomModel = false
        isTestingConnection = true
        let testEndpoint = configuredEndpoint
        let key = apiKey.isEmpty ? endpoints.apiKey(for: id) : apiKey
        let provider = ProviderRegistry.provider(for: testEndpoint)
        Task {
            do {
                let models = try await provider.listModels(endpoint: testEndpoint, apiKey: key)
                await MainActor.run {
                    fetchedModels = models
                    if models.isEmpty {
                        testResult = "Server reachable, but no models returned. The endpoint may require a different auth scheme, or the /v1/models path may be disabled."
                    } else {
                        testResult = "✓ Loaded \(models.count) model\(models.count == 1 ? "" : "s")."
                        if !models.contains(model) {
                            // Snap to the first server-confirmed model so the
                            // picker is ready to use; user can still override.
                            model = models.first ?? model
                        }
                    }
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    testResult = "✗ \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    isTestingConnection = false
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        EndpointEditorView(endpoint: nil)
            .environmentObject(EndpointStore.shared)
    }
}
