# iPhone Duo, voice, and better conversations

WristChatUI adapts from the iPhone Duo outer display to its larger inner display, with a native conversation sidebar, comfortable reading widths, and controls that reflow with the available space. Unsent drafts and the search choice stay with each conversation while its layout changes.

This update also includes optional web search for compatible iPhone and Apple Watch connections, clearer source details, and recovery when a request is interrupted.

The current App Store submission includes phone and Apple Watch voice features. CarPlay remains disabled in this distribution until Apple approves the CarPlay Voice Based Conversation capability and refreshed App Store provisioning profiles are installed.

- Select OpenAI Responses, OpenAI Chat Completions or Anthropic Messages format without rebuilding existing connection profiles.
- Use a conversation sidebar on wider windows, then continue the selected chat in the compact layout.
- Dictate questions on iPhone, read completed replies aloud, and choose voice playback preferences separately on iPhone and Apple Watch.
- Turn Web search on for a supported native endpoint/model, or explicitly select independent MiniMax plan search or a search tool on a remote HTTPS MCP server.
- See search activity and returned source details. Citation links stay with search-backed replies and conversation backups.
- Read paragraphs, blank lines, lists and code on Watch. Watch requests include small-display formatting guidance while preserving custom prompts and requested formats.
- Keep compact iPhone chats clear of the tab bar while preserving access to tabs in wider layouts.
- Stop an active request, retain a marked partial reply, or Retry the original question after a failure without adding a duplicate user turn.
- Preserve API format, credential ownership and advanced settings when editing a connection on Watch.

Search depends on the endpoint, model, account entitlement, region and server implementation. Separate search sources must be explicitly configured and may require their own credentials. Generic Chat Completions compatibility does not imply native search support. Direct ChatGPT subscription sign-in is not included.

## Release files

The release publishes source and compiled artifacts with the version/build, signing method and checksums recorded alongside them. The iPhone package embeds the matching Watch app and widget. A separate Watch artifact contains only the Watch component.

An **App Store distribution IPA is an upload artifact**, not a file that can be installed on arbitrary devices by downloading it. Development/ad hoc builds require the appropriate signing and registered devices. Use the App Store for ordinary installation once Apple has approved and released that version. A GitHub release, App Store upload, review submission and public App Store availability are separate states.
