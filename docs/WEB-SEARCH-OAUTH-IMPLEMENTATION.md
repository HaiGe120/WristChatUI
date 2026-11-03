# Web search and direct sign-in implementation

Updated November 1, 2026 (Asia/Shanghai).

Status: first implementation milestone, not a release-ready or submitted build.

## Implemented

- Explicit OpenAI Responses, Chat Completions and Anthropic Messages formats, separate authentication selection, legacy endpoint decoding and full-URL/prefix preservation. Custom profiles continue to own their API keys. Extended settings survive older companion snapshots.
- Structured streaming events with real search activity, returned sources and typed errors. Responses final-text deduplication and multiple output items; Anthropic server-search citations/errors and bounded paused-turn continuation with the original structured blocks. Unexpected EOF is a failure/partial result, never inferred success.
- One active attempt per engine with retained cancellation, underlying network cleanup, first-result/inactivity/overall deadlines, foreground deadline reconciliation, immediate Stop, and stale-callback isolation. Retry replaces the interrupted response and reuses its original question. User text and useful partial output remain available; interrupted assistant text, empty placeholders and legacy transport-error prose are excluded from outgoing model context.
- Search Off/Auto controls on both chat screens; actual search status; returned-source lists/details and inline links on supported indexed citations. Retrieved-source Markdown links are checked against returned URLs. Plain reference material without source URLs has a distinct status.
- Optional MiniMax plan search and selected custom remote MCP retrieval, independent of the chat endpoint. Explicit source selection, HTTPS destination restrictions, separately entered credentials, selected tool/schema/query/fixed arguments, modern/legacy HTTP negotiation, paginated discovery, JSON/SSE responses, bounded content/attempts, and explicit tool/auth/interactive errors. There is no automatic replay of ambiguous search calls or unconfigured fallback destination.
- Dedicated, destination-bound search Keychain records and generation/revision-aware companion provisioning. OAuth secrets never enter the endpoint API-key path. Search profile/credential changes cancel active attempts; a partial secure-storage failure cannot send a new key to an old destination.
- Optional response metadata in SwiftData, snapshots and version-2 backups; version-1 snapshots remain readable. Legacy updates cannot detach citation metadata from the newer answer text. Subsecond ordering is preserved through the companion's ISO8601 transport.
- Gated ChatGPT account screen and secure OAuth prerequisites (PKCE/callback broker, ID-token verification, separate atomic token vault and serialized refresh primitives). No working direct account login/inference is claimed.
- Simulator EXIT/signal cleanup, retained build logs, one launch per session, bounded simulator commands, fixed derived-data location, and fail-closed process/memory verification. SIGKILL cannot be trapped. Device names can be selected using SIM_DEVICE_NAME/SIM_WATCH_DEVICE_NAME; `scripts/sim.sh devices` lists installed devices.

## Local validation

| Check | Result |
| --- | --- |
| `scripts/test-provider-fixtures.sh` | 46 checks passed |
| `scripts/test-search-fixtures.sh` | 50 checks passed |
| `scripts/test-recovery-fixtures.sh` | 28 checks passed |
| `scripts/test-oauth.sh` | Local callback, RSA/claims, refresh/sign-out race and persistence fixtures passed using generated test keys |
| `scripts/test-sim-lifecycle.sh` | Mocked success/error/Watch cleanup, one-launch, stalled-launch timeout, high-RSS and denied-process-access fixtures passed |
| Combined iPhone + embedded Watch simulator build | Passed; full log at `build/derived/sim-logs/build.log` |
| Actual iPhone simulator launch | First capture showed a blank startup frame. A repeat launch stalled; it was stopped through the wrapper and the pending capture timed out. UI acceptance remains unverified. Final app/process/memory cleanup passed. |
| Separate Watch simulator SDK build | Passed; `build/derived/sim-logs/watch-build.log` |
| Actual Watch simulator launch | Unavailable: no installed available watchOS runtime/device; the configured watchOS 26.5 runtime is listed unavailable |

The build directory and screenshots are ignored local evidence. Fixtures use synthetic inputs and generated test credentials. No live chat/search account entitlement or device behavior is established by fixture success.

## Physical test installation

A development build was installed and launched on the user's physical iPhone Air on November 1, 2026. New connection/search controls were visible. The signed Watch app was embedded in that install; the user then confirmed the new Search toggle on the physical Watch Ultra, verifying that the update transferred through the phone. Direct Mac development pairing remains unestablished. See [device installation evidence](DEVICE-TEST-INSTALL.md). This does not establish live provider/search behavior or direct OAuth success.

## Remaining release requirements

1. Confirm OpenAI's supported eligibility/registration path for this App Store product. Verify system-authentication HTTP loopback return on a physical iPhone. Implement and live-test actual token exchange/JWKS loading/renewal/revocation/model discovery plus the dedicated Watch access-credential lifecycle before enabling sign-in. See [OAuth status](CHATGPT-OAUTH-STATUS.md).
2. Live-test the user's actual endpoints/models and account entitlements: all three custom formats, MiniMax native search/plan adapter, CPA source metadata, unsupported/quota/auth/connection failures, and selected remote MCP behavior. Generic Chat Completions native search remains gated without a verified model/endpoint search contract; separate retrieval works independently.
3. Complete iPhone/Watch visual checks, source opening/handoff, phone-unreachable networking and renewal, real paired-device provisioning, actual upgrade/data retention, and mixed-version communication. Restore/install an appropriate Watch runtime or use physical hardware for Watch UI checks. No device library reset or runtime installation was performed.
4. Verify App Store Connect version/build and signing, choose matching versions from one source, reconcile release signing/export, archive/export/validate, prepare release/privacy/review material, and submit only after all release requirements pass.

No server configuration, production credentials, license, version/build number or App Store release state was changed. No archive/upload/submission was performed. Unrelated campaign files remain untouched.

## Design limits in this milestone

- Direct OAuth is deliberately disabled; its Watch session provisioning is unimplemented.
- The external-source path performs one explicit retrieval before generation. Model-driven function-call search loops and automatic native-to-provider fallback are not implemented. Source changes and retries are explicit actions.
- MCP supports the documented remote Streamable HTTP/search subset, not general MCP OAuth, desktop stdio, arbitrary client callbacks or a general agent runtime. URLs with query parameters are excluded so credentials cannot be embedded in saved profiles. See [search-source contract and evidence](SEARCH-SOURCES-IMPLEMENTATION.md).
- Partial replies are checkpointed during streaming and saved on scene changes; abrupt termination can still lose the most recent uncheckpointed fragment. No request is automatically replayed after process termination.
