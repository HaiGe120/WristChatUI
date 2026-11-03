# Search recovery and conversation ordering — November 2, 2026

The supplied iPhone screenshot showed a timed-out attempt, a partial answer with a generic provider error, concatenated research commentary, and concurrent phone/Watch questions displayed out of time order. Returned references did not establish that a final answer had completed. The exact on-device terminal error was not inspected: automatic approval review rejected reading app records because they could contain private conversations. No phone database or credentials were copied, and no live AI requests were replayed.

## Reproduced defects and corrections

- Anthropic-compatible paused responses previously received a fresh three-search allowance on every continuation, followed by a three-response cap reported as a generic server error. A single three-search budget now spans the logical turn, and response continuations have a separate eight-segment ceiling. Budget exhaustion has an explicit error. Calls are counted by server tool identifiers, not by source count; a fixture returns 90 references from one call.
- A `max_uses_exceeded` server-tool control result previously aborted decoding before the model could give its final answer. It now remains in the preserved continuation blocks, notes the limit in metadata, and allows an actual terminal answer in the same response.
- MiniMax documents only automatic tool choice for its Anthropic-compatible API. The implementation does not send unsupported `tool_choice:none` or `max_uses:0` finalization requests.
- Text from successive Anthropic blocks/rounds and Responses output parts is separated into paragraphs. Responses citation offsets include inserted UTF-16 separators; opaque server tool blocks and signatures are preserved unchanged.
- Phone and Watch can allocate matching order indices before sync. Canonical display/history ordering now groups metadata-linked answers with their questions and resolves colliding turn slots by timestamp and stable UUID. Unambiguous sequential indices remain authoritative across clock skew. Legacy and orphan rows remain visible, and persisted indices/schema are unchanged.
- Partial answers are explicitly labeled, and their links are labeled **References returned** with an incomplete-answer explanation. Search, continuation, context and output limits have separate safe messages. Empty successful responses are rejected as missing answers.
- The existing 75-second search progress and 240-second overall deadlines remain bounded. Duplicate citations and repeated identical search states do not prolong inactivity. First-response, inactivity and overall timeouts explain the difference.
- Nonempty reasoning deltas count as processing progress without displaying or saving their text as an answer. This avoids first-response timeouts while a model is actively generating; processing activity still cannot extend the overall deadline, and pings/empty events do not count.
- **Retry without search** replaces the failed reply using its original question, disables search for that one attempt, and preserves the saved search preference. There is no automatic replay of a failed request.
- The iPhone endpoint editor exposes its optional maximum-output-token limit. Existing values/defaults remain unchanged unless edited; invalid, nonpositive or overflowing input cannot be saved. Messages retains its existing default of 2,048 tokens, and the settings explain potential usage/cost changes.

## Validation

Synthetic cases cover the screenshot's ordering collision, stale callbacks, explicit retry, limit-control finalization, duplicate-progress deadlines, paragraph boundaries, citation offsets, preserved tool state, settings validation and legacy metadata. Live backend behavior and Watch receipt of an updated build must be verified separately.

Build 4 contains the ordering, continuation and recovery corrections. Build 5 also includes processing-progress timeout handling. Physical-device installation uses the same Debug-only voice signing override as build 3; canonical CarPlay/Release entitlements remain intact.

Final validation: 97 provider, 73 recovery/ordering/deadline, 25 endpoint-edit, 50 search, 23 formatting and 15 voice checks passed (283 total). The signed iPhone app and embedded Watch/widget build passed compilation and deep signature verification.

Version **1.1.0 (5)** was installed on the paired iPhone Air over Wi-Fi after reconnecting a dropped tunnel. Installed-app readback confirmed build 5. The package includes matching Watch/widget build 5 for companion transfer; Watch receipt is not confirmed. No conversation records were exported, app uninstalled, or library reset. Evidence is in `build/device-install/search-build5-install.json`, `search-build5-after.json`, `build.log`, and `codesign-verify.log`.

## Build 6: finish the answer after acquisition

The next user screenshot confirmed that build 5's cumulative three-search cap stopped a real request after returning 30 references, leaving only research narration. This was an app-side workflow error: collecting references must be followed by an answer, rather than treating the acquisition budget as the end of the entire task.

Build 6 transitions into at most one ordinary text-generation request on the same connection when native search acquisition reaches its limit and readable evidence exists. The final request omits tools and server-tool blocks, preserves the original question/history and explicit output limit, and supplies bounded returned page text as untrusted references. Source titles/URLs alone or opaque encrypted content are not evidence. It neither fetches extra pages nor changes providers. This is a bounded answer-generation phase within the original attempt/deadline, not a replay of a failed user request.

Only evidence selected for that answer remains in its source metadata. Starting synthesis clears acquisition narration and obsolete citation offsets from the live buffer and stored answer, while preserving the attempt and original question identifiers. A genuine nonempty terminal answer is required for success, and unselected citation URLs cannot expand the approved link set. The final answer streams normally. Official MiniMax M3.1 endpoints use their documented low reasoning effort for this final phase only; explicit token limits and the existing 2,048-token default remain unchanged.

Sources and References now open a separate, left-aligned list on iPhone and Watch. Duplicate exact valid URLs are grouped while retaining all original reference numbers. Complete URLs and excerpts appear only in the source detail screen, keeping the conversation compact.

Acquisition has an independent monotonic 120-second ceiling and a 45-second stalled-progress limit once readable evidence exists, leaving time inside the original overall deadline for the answer. The timer cancels only the collection session; the provider task alone starts synthesis. Explicit Stop wins over timer expiry, and synthesis has its own cancellation handler. Native output exhaustion can enter this same final phase only when readable evidence already exists; it preserves the original output-limit error otherwise.

Build 6 validation passed: 149 provider transport/protocol, 82 engine/recovery/ordering, 50 search, 25 endpoint-edit, 23 formatting and 15 voice checks (344 total). End-to-end intercepted HTTP tests cover three paused searches followed by exactly one ordinary answer request, selected-source metadata/reset ordering, actual final text, empty/failed/paused finalization, stalled acquisition, synthesis cancellation, rejected foreign citations, and evidence bounds. No live AI requests or private phone records were used. Physical iPhone, Watch and widget builds report 1.1.0 (6) and passed compilation and deep signature verification.

The initial physical-device transfer could not acquire the wireless device services (CoreDevice error 4016). The signed build was held at `/tmp/WristAssistantDeviceInstall/WristAssistant.app` while awaiting an available paired iPhone connection. The user was asked to wake/unlock the phone on the same Wi-Fi. The installer now refreshes the device connection before transfer because wireless tunnels can expire during compilation.

After the user confirmed the iPhone was unlocked on Wi-Fi, **1.1.0 (6) installed successfully** and installed-app readback confirmed build 6. Evidence: `build/device-install/search-build6-install.json` and `search-build6-after.json`. The package includes matching Watch/widget build 6 for companion transfer; physical Watch receipt remains unconfirmed. The user can test the normal **Retry** action with Web search still enabled.
