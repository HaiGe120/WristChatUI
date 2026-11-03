import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    precondition(condition(), description)
    checks += 1
}
let original = EndpointConfig(name: "Gateway", providerType: .openAICompatible,
    baseURLString: "https://gateway.example/proxy/v1", model: "model", systemPrompt: "Use my style",
    temperature: 0.4, maxTokens: 2048, customHeaders: ["X-Deployment": "test"], apiFormat: .responses,
    searchMode: .auto, chatSearchVerified: true)
var draft = EndpointProfileEdit(original)
draft.name = " Renamed "
draft.systemPrompt = "Keep this custom prompt"
let renamed = draft.applying(to: original)!
check(renamed.id == original.id && renamed.authentication == original.authentication, "Editing keeps credential identity and auth type")
check(renamed.apiFormat == .responses && renamed.searchMode == .auto, "Unchanged explicit format and search survive a rename")
check(renamed.maxTokens == original.maxTokens && renamed.customHeaders == original.customHeaders, "Hidden settings survive an edit")
check(renamed.chatSearchVerified, "Unchanged model/URL keeps verified capability")
check(renamed.name == "Renamed" && renamed.systemPrompt == draft.systemPrompt, "Editable values apply and names trim")
var latest = original; latest.maxTokens = 4096; latest.customHeaders["X-New"] = "new"
let concurrent = draft.applying(to: latest)!
check(concurrent.maxTokens == 4096 && concurrent.customHeaders["X-New"] == "new", "Latest synced hidden fields win")
draft.apiFormat = .anthropicMessages
let changed = draft.applying(to: original)!
check(changed.providerType == .anthropicCompatible && changed.chatCompletionsURL()?.path == "/proxy/v1/messages", "Format chooses matching family and correct URL")
check(!changed.chatSearchVerified, "Changing the format requires new capability verification")
var account = original; account.authentication = .chatGPT
check(draft.applying(to: account) == nil, "An API-key edit cannot downgrade a direct account")
let old: [String: Any] = ["id": UUID().uuidString, "name": "Legacy", "providerType": "openAICompatible", "baseURLString": "https://gateway.example/proxy", "model": "legacy"]
let legacy = try JSONDecoder().decode(EndpointConfig.self, from: JSONSerialization.data(withJSONObject: old))
let editedLegacy = EndpointProfileEdit(legacy).applying(to: legacy)!
check(editedLegacy.chatCompletionsURL() == legacy.chatCompletionsURL(), "Editing keeps the legacy custom-root path policy")
var invalid = EndpointProfileEdit(original); invalid.model = " \n "
check(!invalid.hasRequiredFields, "Whitespace model cannot enable Save")
let emptyLimit = OutputTokenLimitEdit("")
check(emptyLimit.isValid && emptyLimit.value == nil, "Empty output limit keeps the API's default behavior")
let whitespaceLimit = OutputTokenLimitEdit(" \n ")
check(whitespaceLimit.isValid && whitespaceLimit.value == nil, "Whitespace output limit remains optional")
let preservedLimit = OutputTokenLimitEdit(original.maxTokens.map(String.init) ?? "")
check(preservedLimit.isValid && preservedLimit.value == original.maxTokens, "An untouched explicit output limit survives the editor")
let expandedLimit = OutputTokenLimitEdit(" 4096 ")
check(expandedLimit.isValid && expandedLimit.value == 4096, "Positive whole-number limits are accepted with surrounding whitespace")
check(OutputTokenLimitEdit("0008").value == 8, "Leading zeroes retain the positive whole-number value")
check(OutputTokenLimitEdit(String(Int.max)).value == Int.max, "Validation accepts representable positive integers without a silent cap")
for value in ["0", "-1", "+1", "1.5", "1e3", "1 024", "abc", String(Int.max) + "0"] {
    check(!OutputTokenLimitEdit(value).isValid, "Invalid or overflowing output limit must disable Save and connection testing: \(value)")
}
print("Endpoint edit fixtures passed: \(checks)")
