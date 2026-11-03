# Direct sign-in and web search plan

Date: November 1, 2026 (Asia/Shanghai)

Status: implementation started November 1, 2026; provider/search/recovery foundations implemented and locally tested. Direct sign-in, live/device validation, and App Store submission remain pending. See [implementation status](WEB-SEARCH-OAUTH-IMPLEMENTATION.md).

## Agreed scope

- Add direct Codex/ChatGPT OAuth sign-in inside WristChatUI, starting on iPhone and making the account usable from its paired Apple Watch.
- Keep custom endpoints, including CLIProxyAPI (CPA), as ordinary connections configured with a base URL, API format, model, and optional client API key.
- CPA account login, credential refresh, management keys, server administration, and server changes are outside this app update. Users manage CPA upstream accounts themselves.
- Support OpenAI Responses (`/v1/responses`), OpenAI Chat Completions (`/v1/chat/completions`), and Anthropic Messages (`/v1/messages`). “v1 complete” is interpreted as Chat Completions.
- Use provider/server-native web search with no separate search-service key. Search availability depends on the selected endpoint, model, upstream account, and proxy translation.
- Include recovery from Watch connectivity failures: a timed-out or interrupted request must release the conversation so Retry or the next prompt can run when connectivity permits, without restarting the app or creating a new chat.
- Prefer native search; where unavailable, offer an explicitly configured provider search adapter using an existing supported subscription key, such as MiniMax's search tool. An additional third-party search subscription is not required by the default design.
- Add custom remote search MCP as an optional search source, configured on iPhone and usable from Watch. Its credentials and availability are independent of the chat endpoint.
- Validate both apps, then submit the combined iOS + embedded watchOS build for App Store review. Upload, submission, approval, and public availability are separate release states.

## 1. Prove direct OAuth on iPhone first

Use OpenAI's documented Sign in with ChatGPT integration rather than borrowing the Codex CLI client identity or using ChatGPT private backend endpoints. The user-facing button is “Continue with ChatGPT.”

The current public client flow uses PKCE, state and nonce validation, a stable installation host ID, an issued client ID, ID-token signature/issuer/audience validation, and explicit permission for ChatGPT plan usage. Store credentials in a separate Keychain service, with atomic replacement of rotating tokens and serialized refresh. OAuth tokens must never enter endpoint JSON, conversation backup, diagnostic logs, or CPA requests. A signed-in identity without inference permission remains a distinct state.

Before building the full feature, verify the documented HTTP loopback callback on a physical iPhone using system authentication UI. The existing `wristassistant://` deep link must not be substituted for an unregistered redirect. Check cancellation, timeout, app lifecycle, and returning to the app. Resolve any required native-client registration with OpenAI if the documented callback cannot be supported reliably.

Resolve product eligibility at this stage: OpenAI documents this flow for open-source/local apps and selected commercial partners. This repository's PolyForm Noncommercial source license does not itself establish approval for the App Store product. Do not change the license or substitute an undocumented login flow as part of this work.

Discover models for the signed-in account. Use the documented public Responses API contract for this authentication type; its currently required streaming/storage settings and omitted parameters differ from an ordinary API-key request.

References: [registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [eligibility overview](https://developers.openai.com/siwc/token-sharing-open-source), [models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [preview requirements](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).

## 2. Separate account authentication from API format

Extend endpoint configuration with explicit, backward-compatible authentication and API-format selections. Preserve existing endpoint IDs, saved API keys, model choices, full URLs, and reverse-proxy path prefixes. An endpoint rooted at `/v1` must resolve consistently for all three formats.

Show direct ChatGPT accounts separately from custom endpoint profiles. Restrict direct OAuth credentials to official OpenAI inference/authentication destinations and reject redirect-based credential forwarding. CPA and other custom profiles continue to use their own credentials.

For Watch access, keep refresh-token ownership on iPhone initially. Add a dedicated companion session mechanism that supplies the current short-lived access credential when needed; do not reuse the bulk API-key mirroring path for OAuth refresh tokens. The Watch can make native requests with a valid credential. Test expiry while the phone is unreachable and show a reconnect-to-iPhone action when renewal is required. Independent Watch renewal would require its own verified session design and is not assumed in the first release. Sign-out and account changes cancel active requests and invalidate companion credentials.

References: [account/session lifecycle](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions).

## 3. Implement native search per API format

| Connection format | Search behavior |
| --- | --- |
| OpenAI Responses | Use the native `web_search` tool on supported models; consume search progress, text, URL annotations, and returned sources. Preferred initial path for direct OAuth and CPA Codex connections. |
| OpenAI Chat Completions | Retain chat compatibility and returned annotations. Enable search only using a verified endpoint/model contract, such as supported search options. Generic Chat Completions compatibility alone does not imply native search. |
| Anthropic Messages | Use a supported versioned server search tool; consume server-tool activity, search results, citation deltas, search errors, and terminal stop reasons. For CPA, verify its translation against the selected upstream. |

Do not assume a proxy forwards every search field. CPA has had a fixed bug involving dropped Responses source metadata; run the actual endpoint/model validation before claiming complete source support. No CPA upgrade or configuration change is included here.

Start with search Off/Auto. Auto enables the server tool and lets the model decide when to search; existing profiles default to Off to preserve their behavior. Offer “Search this question” only where forced search is supported and tested. Do not claim that a response used the web until the stream reports search activity. Surface unavailable/failed search explicitly, including errors returned inside an HTTP 200 response.

Introduce structured stream events for text, search activity, citations, completion, partial results, and errors. Fix the current Responses parser's duplicate delta/final-text behavior and handle multiple output items. Only terminal success confirms completion; a disconnected stream is partial. Fix cancellation by retaining and cancelling the underlying task and preventing old callbacks from modifying a newer request. Exclude the newly inserted empty assistant placeholder from request history.

Preserve native structured history when required for tool continuation. Anthropic paused server-tool turns require the original blocks rather than reconstructed plain text; continuation must be bounded and cancellable.

References: [OpenAI search contracts and citation requirements](https://developers.openai.com/api/docs/guides/tools-web-search), [Anthropic search contract](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool), [CPA source metadata issue and fix](https://github.com/router-for-me/CLIProxyAPI/issues/6251).

### Search when the chat endpoint cannot search

API format and search capability are separate. In particular, current MiniMax documentation describes beta native `web_search` on its Anthropic Messages interface using `web_search_20250305`, as well as on Responses. Do not label all MiniMax or all Anthropic-compatible endpoints unsupported. Validate the user's actual model, region, subscription entitlement, streaming behavior, and source output first.

For MiniMax Coding Plan / M Plan, use this order:

1. Try its supported native search contract on the configured chat endpoint/model.
2. If that contract is unavailable, offer the provider's separate search capability. MiniMax documents a `web_search` MCP tool authenticated with the plan's existing API key. Evaluate the provider's published implementation for a native Swift adapter so iPhone/Watch do not require a Python subprocess or local MCP server. Confirm this adapter's API contract and entitlement before shipping.
3. Search returns URLs, titles, and excerpts; the selected MiniMax model still writes the answer using those references. Model-side function calling can drive a bounded search loop when supported. For a text-only endpoint, an explicit Search action can retrieve references before the ordinary model request. Preserve source metadata independently of model-generated links and verify displayed citations against retrieved sources. Supply the actual current date/timezone so stale search examples are not interpreted as today.

Reuse a subscription key only for the explicitly selected provider's matching region/host. A CPA/gateway key must not be forwarded to MiniMax's public server. Show the chosen search source in setup, and send only the needed query/context to it. Treat retrieved text as untrusted reference material; bound searches, returned content, and tool iterations. Keep search execution and answer generation under the same cancellation/deadline control.

If the user has another search-capable saved endpoint, it can be selected explicitly for retrieval while keeping the current model for the final answer. This is optional because it changes the destination receiving the query. If no search source is configured or its search fails, show “Live search unavailable” with Retry, choose another source, or answer without search. A request for current facts must not silently become an answer presented as verified live information.

Track native-search support by endpoint + model + API format, with unknown/supported/unsupported states and a way to recheck after configuration changes. Cache explicit unsupported-tool responses to avoid repeating the same failed request. Network timeouts, authentication errors, quota exhaustion, and transient server errors do not establish unsupported capability. Move to a fallback only on a verified capability failure or an explicit user action; do not repeatedly replay an ambiguous generation request.

References checked November 1, 2026: [MiniMax server tools](https://platform.minimax.io/docs/guides/server-tools), [MiniMax plan search tool](https://platform.minimax.io/docs/m-plan/mcp-guide), [provider-maintained search implementation](https://github.com/MiniMax-AI/MiniMax-Coding-Plan-MCP). These establish available approaches, not successful tests of the user's current account or endpoint.

### Custom search MCP

Add a Search Sources screen on iPhone with Native, provider search, and Custom MCP choices. For a custom source, collect a name, HTTPS MCP URL, optional bearer/API-header credential, and a selected search tool. Keep authentication secrets in Keychain separately from the profile and from chat-provider credentials. Test Connection lists available tools with pagination; the user chooses the search tool and configures its query field and required fixed arguments. Do not assume a universal tool name or `query` argument, or automatically enable every tool exposed by a server.

Execute the selected MCP tool in the app's shared search layer, independently of the model API: user question → MCP retrieval → normalized references → current chat model → cited answer. A model that supports function calls can request the selected search tool through the corresponding provider adapter. An explicit Search action can prefetch references for a text-only model. This architecture keeps MiniMax, CPA, and direct OAuth account selection independent of the search source; the user's configured MCP service may require its own key or subscription.

Initial transport scope: remote HTTPS Streamable HTTP with JSON and request-scoped SSE responses. Support version-aware modern requests and the commonly deployed legacy Streamable HTTP lifecycle. The July 28, 2026 revision removed protocol sessions and the GET stream endpoint; older servers can still require initialize/session handling. Negotiate compatibility before tool execution, using protocol errors/metadata rather than blind retries of a search POST. Desktop command configurations (`npx`, `uvx`, stdio) connect through a separately hosted HTTP bridge; installing or administering that bridge is a separate task. A Mac's localhost address is not a remotely reachable endpoint for a phone or Watch.

Initial authentication scope: unauthenticated servers and bearer/custom API-header authentication over HTTPS. Identify OAuth-required servers clearly during setup; general MCP OAuth discovery, client registration, and interactive authorization are a separately scoped extension unless a selected target server makes them necessary for this release. Direct ChatGPT OAuth credentials must never be reused as MCP tokens. Restrict credential forwarding to the configured destination and handle cross-origin redirects without forwarding secrets.

Normalize structured JSON results and text results into actual returned title/URL/excerpt records. Provide result-field mapping for unusual schemas. Text without reliable source URLs can be included as reference material, with no invented citation or verified-web claim. Respect JSON-RPC and tool-level errors even with HTTP 200. Modern `input_required` results or unsupported client callbacks must produce an actionable unsupported-interaction state; do not treat them as search completion or silently enable a general agent runtime.

Perform setup and any interactive authentication on iPhone. Provision the selected source to Watch using a dedicated profile/credential path and store its secrets in the Watch Keychain. Prefer direct Watch access to the configured remote server; test independent reachability. If a future source requires phone-mediated authorization or execution, expose that dependency clearly. Do not assume that an iPhone can stay available as a background relay throughout a Watch search.

Use the same attempt IDs, cancellation, bounds, and overall deadline as chat/search recovery. On timeout or connection loss, cancel the active MCP operation, preserve useful partial output, unlock the composer, and allow Retry or a fresh prompt. Never silently send the query to another MCP/provider or repeatedly re-execute an ambiguous failed tool call. Limit tool iterations and result size; send the selected server only the query/context it needs and treat returned content as untrusted references.

References checked November 1, 2026: [modern MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http), [MCP tool discovery/calls/results](https://modelcontextprotocol.io/specification/2026-07-28/server/tools), [MCP authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization), [legacy Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports). First-release compatibility is the explicitly described transport/authentication/search-tool subset, rather than every optional MCP feature.

## 4. Add the shared iPhone/Watch experience

- iPhone: account connection/status, clear API-format selection, Search Off/Auto, live search status, visible clickable inline citations, and a source list.
- Watch: sign-in guidance on iPhone, account readiness, compact search control/status, and readable citations with a source detail view. Verify source opening on Watch and companion handoff before advertising either behavior.
- Persist compact citation metadata and search outcome with each message. Keep cited sources intact; collapse the initial source display rather than silently discarding references. Avoid syncing raw search documents.
- Extend conversation snapshots, sync upserts, and backups with optional metadata and safe defaults. Read old endpoint JSON and version-1 backups; verify old/new phone-watch combinations retain chats and keys. Treat metadata written by older companions carefully so an old snapshot cannot erase newer citation fields accidentally.
- Update privacy/support text to explain direct OAuth, provider search data flows, credential storage, and the difference between successful search and ordinary answers.

Primary implementation seams: `Shared/Models/EndpointConfig.swift`, `Shared/Providers/`, `Shared/Chat/ChatEngine.swift`, `Shared/Storage/`, `Shared/Sync/`, `App/Views/EndpointEditorView.swift`, and both chat views.

### Failure recovery and the next prompt

Use explicit per-attempt states (connecting, receiving, searching, completed, failed, cancelled, partial) instead of a streaming Boolean as the sole source of truth. Retain and cancel the request task, watchdog, and underlying network operation. Give every attempt an ID; guard all deltas and terminal callbacks with it. Finalize exactly once and immediately restore the composer on every terminal path. An old request's late callback must never clear a newer request's state or append to its reply.

Add bounded connection waiting, inactivity/first-result deadlines, and an overall deadline appropriate to Watch conditions. Search may legitimately wait longer than ordinary chat, so use a search-aware budget and visible progress with an available Stop action. Heartbeats can establish transport liveness but must not keep a stalled request alive forever. Reconcile active state when the app returns from the background. Do not rely solely on URLSession's current 120-second request and 300-second resource settings.

On timeout/offline/connection loss, preserve the user's prompt and any partial reply, label its outcome, cancel outstanding work, and unlock input. Present a compact inline “Connection lost” or “Request timed out” state plus Retry. Retry reuses the original user turn and creates a new attempt; a new prompt is a separate turn in the same conversation. Keep Stop and Submit as distinct actions so a submitted prompt cannot be consumed merely to cancel a stale request. Network availability still determines whether a new request can succeed.

Keep transport errors in metadata/UI rather than assistant answer text. Build outgoing history before inserting the assistant placeholder, or explicitly exclude it. Exclude failed empty responses and transport-error text from future requests; retain real user text and coherent completed context. Keep interrupted partial responses marked as partial and define explicitly whether a retry replaces or resumes them. Normalize adjacent text-only user messages if a compatible provider requires it, while preserving structured tool exchanges and IDs. Do not manufacture an assistant response solely to force alternation.

Handle unexpected EOF, in-stream errors, incomplete Responses, Anthropic search errors, and paused tool turns distinctly. Do not mark an interrupted stream completed. Preserve typed errors for timeout, offline, lost connection, authentication, unsupported tool, quota, and server failure so the UI can offer the right action. Do not automatically resend an ambiguous timed-out generation: the server may already have processed it. If a retry is automatic for a provably safe case, cap it, apply backoff, and keep it within the same overall deadline.

Carry attempt outcome metadata through sync/backup with backward-compatible defaults. Recovery must work entirely on Watch for ordinary API-key endpoints; phone unavailability should affect only operations that actually require the companion, such as direct OAuth renewal.

## 5. Validate and submit

1. Add focused request/parser fixtures for all three formats: fragmented SSE, multiple content blocks, final-text deduplication, citation ordering, native search errors, authentication expiry, cancellation, and interrupted streams. Test legacy decoding and backup/sync metadata preservation.
2. Live-test direct OAuth plus search and each configured CPA format against known-current questions. Confirm actual search execution and source metadata, not just a fluent answer. Test search Off, unsupported models, quota failure, and phone/watch credential isolation.
3. Build both targets and check the UI on iPhone and Watch. Use only `scripts/sim.sh` for simulator work. Its current implementation lacks the EXIT trap described in AGENTS.md; fix that mismatch before running simulator sessions. Use bounded sessions, one install/launch per boot, guaranteed teardown, and the required post-teardown process/memory checks. Keep derived data under `./build/derived`.
4. Verify physical iPhone/Watch sign-in, token renewal, phone-unreachable behavior, source links, sync, and upgrade data retention. These are release requirements that simulator builds alone cannot establish.
5. Verify App Store Connect's existing version/build and signing assets. Assign a new matching version/build to iOS, Watch, and widgets from one source of truth. Reconcile archive/export signing configuration, which currently mixes manual target settings with an automatic export setting.
6. Archive/export the combined build, inspect embedded bundle versions/signatures, and validate the upload. Prepare release notes, privacy answers, and reproducible App Review instructions for both direct sign-in and custom endpoints. Submit after the validation requirements pass; report the exact App Store Connect status.

Additional acceptance checks for recovery and fallback:

- Timeout before response headers, followed by a successful next prompt on the same engine/conversation.
- Partial output followed by a stalled stream; partial text survives, input unlocks, and the next prompt works after reconnection.
- Stop immediately followed by Send; injected late deltas/completion from the first attempt cannot affect the second.
- Offline waiting, repeated heartbeats without useful progress, app background/foreground, and no terminal event all end or recover within the configured bounds.
- Retry creates no duplicate user turn, only one active attempt, and no accumulated stream tasks/sessions. Outgoing history contains no empty assistant placeholders or connection-error prose.
- MiniMax native search succeeds where entitled; an explicit unsupported-tool rejection takes the configured fallback path. A generic HTTP 400, timeout, or quota failure must not permanently disable native search.
- MiniMax search-tool adapter can retrieve references and return them to an Anthropic-format model; missing entitlement, wrong regional host, or unavailable search produces an actionable state while ordinary chat remains usable.
- No CPA/custom key reaches an unrelated search host; no fallback provider receives a query unless configured by the user.
- Search failure never produces a false “searched the web” status or fabricated source citation. Mixed-version sync and old backups preserve readable chats and do not replay UI error messages to the model.
- Custom MCP discovery handles modern/legacy servers, multiple tool-list pages, and tool names/required inputs other than `web_search(query)`.
- MCP results cover JSON and SSE transport, structured/text content, missing source URLs, tool-level errors, malformed output, authentication required, unsupported interactive results, and changed tool schemas.
- A custom MCP timeout followed by a new prompt recovers on the same Watch conversation; Stop then Send cannot leak callbacks or results between attempts. Credentials remain separate from Codex/CPA keys and out of profile JSON/backups/logs.

## Completion criteria

- Direct OAuth works on a physical iPhone under a confirmed supported registration/eligibility path, with refresh, consent denial, revocation, and sign-out handled.
- Watch can use the signed-in account with documented expiry/reconnection behavior.
- All three custom API formats work without corrupting existing endpoint setup; native search is labeled according to verified capability.
- Search-backed replies show real source citations; failed/partial/unavailable search is distinguishable from success.
- After a timeout, dropped connection, or cancellation, the same chat accepts Retry or the next prompt without an app restart, with no stale callback interference.
- MiniMax native search or the verified, explicitly configured provider search adapter can supply current references to the selected chat model; unavailable search remains an explicit outcome.
- A supported custom remote search MCP can be configured on iPhone and used on Watch, with the selected chat model producing the answer from returned references and clear behavior when the MCP is unavailable.
- Chat history, API keys, sync, and backups survive an upgrade.
- Both apps pass the agreed checks, simulator cleanup succeeds, and the validated build is submitted for App Store review.

The original planning phase changed no application code, server configuration, credentials, or release state. Implementation progress is recorded separately in WEB-SEARCH-OAUTH-IMPLEMENTATION.md. Existing untracked campaign files are unrelated and remain untouched.
