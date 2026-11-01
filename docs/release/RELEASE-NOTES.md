# Web search and better Watch conversations

WristChatUI adds optional web search to compatible iPhone and Apple Watch chat connections, with clearer source details and recovery when a request is interrupted.

- Select OpenAI Responses, OpenAI Chat Completions or Anthropic Messages format without rebuilding existing connection profiles.
- Turn Web search on for a supported native endpoint/model, or explicitly select independent MiniMax plan search or a search tool on a remote HTTPS MCP server.
- See search activity and returned source details. Citation links stay with search-backed replies and conversation backups.
- Read paragraphs, blank lines, lists and code on Watch. Watch requests include small-display formatting guidance while preserving custom prompts and requested formats.
- Open an iPhone chat without the bottom Chats/Settings tabs covering the conversation; return to the list to restore them.
- Stop an active request, retain a marked partial reply, or Retry the original question after a failure without adding a duplicate user turn.
- Preserve API format, credential ownership and advanced settings when editing a connection on Watch.

Search depends on the endpoint, model, account entitlement, region and server implementation. Separate search sources must be explicitly configured and may require their own credentials. Generic Chat Completions compatibility does not imply native search support. Direct ChatGPT subscription sign-in is not included.

## Release files

The release publishes source and compiled artifacts with the version/build, signing method and checksums recorded alongside them. The iPhone package embeds the matching Watch app and widget. A separate Watch artifact contains only the Watch component.

An **App Store distribution IPA is an upload artifact**, not a file that can be installed on arbitrary devices by downloading it. Development/ad hoc builds require the appropriate signing and registered devices. Use the App Store for ordinary installation once Apple has approved and released that version. A GitHub release, App Store upload, review submission and public App Store availability are separate states.
