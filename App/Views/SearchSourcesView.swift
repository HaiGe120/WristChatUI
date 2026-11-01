import SwiftUI

struct SearchSourcesView: View {
    @ObservedObject private var store = SearchSourceStore.shared
    @State private var adding = false
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Button { store.select(nil) } label: {
                    HStack {
                        Label("Native search", systemImage: "globe")
                        Spacer()
                        if store.selectedSourceID == nil { Image(systemName: "checkmark") }
                    }
                }
                Text("Uses the selected chat endpoint's server search tool when Web search is Auto. Availability depends on its model and account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Independent search sources") {
                ForEach(store.sources) { source in
                    NavigationLink {
                        SearchSourceEditorView(profile: source)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(source.name)
                                if source.id == store.selectedSourceID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            }
                            Text(source.kind.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.sources[$0].id }
                    do { for id in ids { try store.delete(id) } }
                    catch { self.error = error.localizedDescription }
                }
                Button { adding = true } label: { Label("Add search source", systemImage: "plus") }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section {
                Text("When Web search is enabled, your question goes to the selected source for references and your chat model writes the answer. Search credentials are separate from chat endpoint credentials. Sources and their credentials sync securely to your paired Watch, which connects directly to the remote server.")
                Text("Custom MCP supports remote HTTPS Streamable HTTP, bearer tokens, and API headers. Desktop npx/uvx/stdio commands require a separately hosted HTTP bridge. Interactive MCP OAuth and client actions are not supported.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Search Sources")
        .sheet(isPresented: $adding) { NavigationStack { SearchSourceEditorView(profile: nil) } }
    }
}

private struct SearchSourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SearchSourceStore.shared
    @State private var draft: SearchSourceProfile
    @State private var credential: String
    @State private var tools: [MCPToolDefinition] = []
    @State private var status: String?
    @State private var working = false
    @State private var task: Task<Void, Never>?
    @State private var sampleQuery = "current date"
    @State private var region = "https://api.minimax.io/v1/coding_plan/search"
    private let editing: Bool

    init(profile: SearchSourceProfile?) {
        let value = profile ?? SearchSourceProfile()
        _draft = State(initialValue: value)
        _credential = State(initialValue: profile.flatMap { SearchCredentialStore.get($0) } ?? "")
        _region = State(initialValue: value.kind == .miniMaxPlan ? value.urlString : "https://api.minimax.io/v1/coding_plan/search")
        editing = profile != nil
    }

    var body: some View {
        Form {
            Section("Source") {
                TextField("Name", text: $draft.name)
                Picker("Type", selection: $draft.kind) {
                    ForEach(SearchSourceKind.allCases) { kind in Text(kind.displayName).tag(kind) }
                }
                if draft.kind == .miniMaxPlan {
                    Picker("Key region", selection: $region) {
                        Text("International · minimax.io").tag("https://api.minimax.io/v1/coding_plan/search")
                        Text("China · minimaxi.com").tag("https://api.minimaxi.com/v1/coding_plan/search")
                    }
                    SecureField("MiniMax plan key", text: $credential)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Use a plan key issued for this region with search entitlement. Enter it explicitly; a CPA/gateway key cannot be used here. The selected MiniMax model remains your chat model.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("HTTPS MCP URL", text: $draft.urlString)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Authentication", selection: $draft.authentication) {
                        ForEach(SearchSourceAuthentication.allCases) { method in Text(method.displayName).tag(method) }
                    }
                    if draft.authentication == .apiHeader {
                        TextField("Header name", text: $draft.headerName).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if draft.authentication != .none {
                        SecureField("This source's credential", text: $credential)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button(working ? "Testing…" : "Test Connection & List Tools") { discover() }.disabled(working)
                }
            }
            if draft.kind == .customMCP {
                Section("Selected search tool") {
                    if !tools.isEmpty {
                        Picker("Tool", selection: $draft.toolName) {
                            Text("Choose a tool").tag("")
                            ForEach(tools) { tool in Text(tool.title).tag(tool.name) }
                        }
                        if let tool = selectedTool {
                            Text(tool.description).font(.caption).foregroundStyle(.secondary)
                            if !tool.stringInputFields.isEmpty {
                                Picker("Question field", selection: $draft.queryField) {
                                    ForEach(tool.stringInputFields, id: \.self) { field in Text(field).tag(field) }
                                }
                            } else { TextField("Question field", text: $draft.queryField).autocorrectionDisabled() }
                            if !tool.requiredInputFields.isEmpty {
                                Text("Required fields: " + tool.requiredInputFields.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else if !draft.toolName.isEmpty, draft.inputSchemaJSON != nil {
                        LabeledContent("Tool", value: draft.toolName)
                        Text("Test again to change the selected tool or its input fields.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Test the connection, then choose only the search tool you intend to use.").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Question field", text: $draft.queryField).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Fixed arguments (JSON object)").font(.caption)
                    TextEditor(text: $draft.fixedArgumentsJSON).font(.system(.caption, design: .monospaced)).frame(minHeight: 90)
                    Text("Put required non-query inputs here. The question field always receives the actual question. Store authentication only in the secure field above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Result mapping (optional)") {
                    TextField("Result array path, e.g. data.results", text: $draft.resultArrayPath)
                    TextField("URL field", text: $draft.urlField)
                    TextField("Title field", text: $draft.titleField)
                    TextField("Excerpt field", text: $draft.excerptField)
                    Text("Leave the array path empty for common JSON/JSON-in-text results. Only returned HTTP(S) source URLs become citations; plain text stays uncited reference material.")
                        .font(.caption).foregroundStyle(.secondary)
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("Try this source") {
                TextField("Test search question", text: $sampleQuery)
                Button(working ? "Searching…" : "Run Test Search") { testSearch() }
                    .disabled(working || draft.kind == .customMCP && draft.inputSchemaJSON == nil)
                Text("Sends this test question to the source using its credential. Your provider's normal plan limits apply.")
                    .font(.caption).foregroundStyle(.secondary)
                if let status { Text(status).font(.caption).textSelection(.enabled) }
                if working { Button("Stop", role: .cancel) { task?.cancel(); task = nil; working = false } }
            }
            Section {
                Button("Save and Use for Search") { save(select: true) }.disabled(working)
                Button("Save Source") { save(select: false) }.disabled(working)
            }
        }
        .navigationTitle(editing ? "Search Source" : "Add Search Source")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onChange(of: connectionIdentity) { _, _ in
            task?.cancel(); task = nil; working = false; tools = []
            draft.inputSchemaJSON = nil; draft.toolName = ""; status = nil
        }
        .onChange(of: draft.toolName) { _, _ in
            if let selectedTool {
                draft.inputSchemaJSON = selectedTool.inputSchemaJSON
                if !selectedTool.stringInputFields.contains(draft.queryField) {
                    draft.queryField = selectedTool.stringInputFields.first ?? "query"
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var connectionIdentity: String {
        [draft.kind.rawValue, draft.urlString, draft.authentication.rawValue, draft.headerName, region, credential].joined(separator: "\u{1F}")
    }
    private var selectedTool: MCPToolDefinition? { tools.first { $0.name == draft.toolName } }
    private var configured: SearchSourceProfile {
        var value = draft
        if value.kind == .miniMaxPlan { value.urlString = region; value.authentication = .bearer }
        return value
    }
    private func discover() {
        let source = configured; let secret = credential
        working = true; status = nil
        task = Task { @MainActor in
            defer { if !Task.isCancelled { working = false } }
            do {
                let found = try await MCPRemoteClient.listTools(source: source, credential: secret)
                try Task.checkCancellation()
                tools = found; draft.inputSchemaJSON = nil; draft.toolName = ""
                status = found.isEmpty ? "Connected, but no supported tools were returned." : "Connected. Choose one of \(found.count) available tools."
            } catch is CancellationError { }
            catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    private func testSearch() {
        let source = configured; let secret = credential; let question = sampleQuery
        working = true; status = nil
        task = Task { @MainActor in
            defer { if !Task.isCancelled { working = false } }
            do {
                let result = try await SearchRetriever.retrieve(query: question, source: source, credential: secret)
                try Task.checkCancellation()
                status = result.hasCitableSources ? "Search succeeded with \(result.references.count) returned sources.\n" + result.references.prefix(3).map { $0.title + "\n" + $0.url }.joined(separator: "\n") : "Reference material returned with no reliable source URLs. It will not be labeled verified web search."
            } catch is CancellationError { }
            catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    private func save(select: Bool) {
        do {
            if let tool = selectedTool { try MCPRemoteClient.validateConfiguration(source: configured, tool: tool) }
            try store.upsert(configured, credential: credential)
            if select { store.select(configured.id) }
            dismiss()
        } catch { status = error.localizedDescription }
    }
}
