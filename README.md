# WristChatUI

Bring your own AI connection to iPhone and Apple Watch, with optional web search and source links alongside your conversations.

- **App Store:** Search for **WristChatUI**.
- **GitHub builds and source:** [Releases](https://github.com/HaiGe120/WristChatUI/releases).
- **Website / Support:** <https://HaiGe120.github.io/WristChatUI/support.html>
- **Privacy Policy:** <https://HaiGe120.github.io/WristChatUI/privacy.html>

## Features

- Native iPhone and Apple Watch chat, with dictation and conversation history on Watch
- Explicit **OpenAI Responses**, **OpenAI Chat Completions**, and **Anthropic Messages** API formats for compatible providers and custom gateways
- **Web search Off/Auto** using a supported endpoint/model's native search, with search activity, returned source details and citation links
- Optional independent search sources: **MiniMax plan search** or a selected search tool on a **remote HTTPS MCP server**
- Clear interrupted/partial reply states, Stop and Retry without duplicating the original question, and recovery after connection failures
- Readable paragraphs, lists and code on Watch; the iPhone chat screen hides the bottom tabs while a conversation is open
- Paired-device sync of connection profiles, securely stored keys and conversations
- Watch complications, Smart Stack widget and Siri Shortcuts for starting a chat
- Optional iCloud Drive conversation backup and restore, including compact source metadata

Search support depends on the endpoint, model, account entitlement and server implementation. Generic Chat Completions compatibility does not itself provide native search. Independent search requires explicitly selecting and configuring that service; its own credentials or subscription may be needed. ChatGPT subscription sign-in is not part of the current release.

## Requirements and setup

- iOS 26.0 or later on iPhone
- watchOS 11.0 or later on the paired Apple Watch
- A compatible chat endpoint, model and any authentication it requires
- For web search: a supported native search contract, an entitled MiniMax plan key for its matching region, or a configured remote search MCP service

On iPhone, add a connection in **Settings → Endpoints**, choose its API format and enter its base URL and model. Use **Test connection & load models** where the server supports model discovery. Keys are entered in the dedicated secure key field.

Search defaults to Off. Select a source in **Settings → Search sources**, then enable **Web search** in a chat. Native search lets the model decide when a supported server tool is needed. An independent source retrieves references before the selected chat model answers. Search status and source details distinguish a search-backed reply from an ordinary answer or a failure.

A custom MCP source must be remotely reachable over HTTPS and support the app's Streamable HTTP search subset. Setup supports unauthenticated servers, bearer tokens and custom API-header credentials. Choose one search tool and map its question field and required fixed arguments. Desktop `npx`/`uvx`/stdio configurations need a separately hosted HTTP bridge. Interactive MCP OAuth, arbitrary client callbacks and general agent execution are not included. MCP URLs containing query parameters are excluded so credentials belong in the secure field.

The Watch makes its own app requests using watchOS networking. Sync with a nearby phone is not an app-level request relay, and a working phone VPN does not establish the route or VPN rules of a Watch request. **Connection help** on Watch explains a comparison check without automatically resending a timed-out request.

## GitHub release downloads

Release assets identify their signing and intended use. An App Store distribution IPA is an upload artifact; downloading it does not make it directly installable on arbitrary devices. A development or ad hoc build requires appropriate device registration/signing. The iPhone package embeds its matching Watch app; a separate Watch archive is not an independent iPhone installer. Follow the instructions included with the particular release.

## Building

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen); the `.xcodeproj` is generated from `project.yml`.

```bash
brew install xcodegen
xcodegen generate
```

Use the repository wrapper for simulator work:

```bash
scripts/sim.sh build
scripts/sim.sh boot        # one build/install/launch/capture, then automatic cleanup
scripts/sim.sh teardown    # explicit cleanup and process/memory verification
```

See [AGENTS.md](AGENTS.md) before simulator work. All `xcodebuild` work uses `./build/derived`.

For a connected physical iPhone, sign with your own development team and use `scripts/device-install.sh <device-id>`. The iPhone build includes the Watch app. Archive the `WristAssistant` scheme for distribution; a successful local build is distinct from App Store upload, review and availability.

## Privacy

WristChatUI has no developer-operated chat/search backend or analytics service. API keys entered in the secure fields use Keychain; conversations and settings are stored on your devices. Your configured chat connection receives the context needed to answer. An independently selected search source receives the question, and its retrieved references are sent to your chat model. Opening a source link contacts its website. Paired-device sync and optional iCloud backups use Apple's services.

Search credentials are stored separately from chat keys and provisioned separately to the paired Watch. Credentials from those secure fields are not included in conversation backups. Source links and compact citation information are included with backed-up conversations. See the [Privacy Policy](https://HaiGe120.github.io/WristChatUI/privacy.html) for details and deletion controls.

## License

Source-available for noncommercial use. Commercial use requires prior written permission. See [LICENSE](LICENSE).
