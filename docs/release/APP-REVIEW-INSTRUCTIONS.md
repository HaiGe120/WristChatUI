# App Review instructions

This file contains no provider credentials. Put any review connection details in App Store Connect's private App Review Information, never in this public file or the release notes.

## Product and access

WristChatUI is a bring-your-own-connection iPhone app with a companion Watch app. It does not have a WristChatUI account system or provide an AI subscription. The production UI has no unfinished ChatGPT sign-in entry. A real compatible endpoint/model and its required credentials are necessary for generation and search; do not claim an untested service is available.

Use the review connection supplied privately in App Store Connect, or a compatible service the reviewer controls. Keep the API format, model and search contract consistent with that connection. For native search review, a Responses or Messages endpoint/model that has actually been verified to execute search and return source metadata is the clearest path. Search entitlements are independent of ordinary chat access.

## iPhone walkthrough

1. Open Settings → Endpoints and add the review connection's name, base URL, API format and model. Enter its own API key if required. Test connection & load models can retrieve the model list when the server exposes one. Save and set it active.
2. Return to Chats and create a conversation. Compact layouts hide the tab bar while the conversation is open. Wider layouts show the conversation list beside the selected chat and preserve access to the tabs. On iPhone Duo, fold, unfold and rotate while composing; the selected conversation, unsent draft and search choice remain available.
3. Send an ordinary question with Web search off. Observe incremental reply text.
4. Enable Web search and ask a question requiring current information. With Native selected, a supported model decides whether to use its server tool. “Web search used” is shown only after reported search activity/retrieval; a supported native model can also choose not to search. Source details and links appear when returned by the service.
5. In Settings → Search sources, optionally test a separately supplied MiniMax plan source or remote HTTPS MCP service. For MCP, list tools, select the search tool, choose its question field and supply required fixed arguments. The selected source receives the question; the selected chat model receives the references. This is optional setup, not required for ordinary chat.
6. Start a reply, select Stop, and verify the composer is released. If a connection genuinely fails, the response is marked failed/partial and Retry reuses the original user turn; requests are not silently replayed.
7. Back Up to iCloud and Restore from iCloud are optional controls for conversation JSON, including compact source metadata but no credentials from secure key fields.
8. Open Settings → Voice to grant microphone/speech access, dictate a question and use Read reply on a completed answer. Automatic playback is off by default. CarPlay is not enabled in this distribution.

## Apple Watch walkthrough

1. Use a Watch paired with the configured iPhone. Open WristChatUI on both devices and use Sync now on iPhone if needed.
2. On Watch, open a synced conversation or choose New chat. Use native text input/dictation. Replies retain line breaks, paragraphs and lists.
3. Verify the Search control and returned source details in a supported search-backed reply. A source's actual reachability and account entitlement still apply on Watch.
4. Stop or Retry as on iPhone. Watch requests use watchOS networking; the app does not promise to inherit a particular iPhone VPN route. Connection help is available in Endpoints and beside network failures.
5. The complication/Smart Stack widget opens a new chat using the active connection.

## Information to complete privately before submission

- Confirm the supplied endpoint/model works in the review environment and whether native search/source output is available.
- Supply any required review credentials in the private review fields, with appropriate provider-side limits.
- State the exact version/build attached to the submission and include relevant test steps for that build.
- Keep all public descriptions limited to the implemented API-key/search-source features. Direct ChatGPT subscription sign-in remains unavailable.
