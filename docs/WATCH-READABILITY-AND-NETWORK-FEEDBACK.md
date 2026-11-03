# Watch readability, phone navigation and networking feedback

November 1, 2026 (Asia/Shanghai), development build 1.0 (2).

## Changes delivered

- Fixed the actual paragraph-collapse defect: Foundation full Markdown block presentation intents were rendered as one SwiftUI Text. The shared renderer now preserves actual line breaks, blank paragraphs and list markers while retaining inline emphasis/links/code and literal fenced code, including unfinished streamed fences. This also improves existing multiline replies; it does not rewrite saved answer text.
- Added transient Watch-only response-format guidance after the conversation's own system prompt: short paragraphs separated by a blank line, one list item per line, and lists instead of wide tables where appropriate. It preserves requested language, exact code and necessary detail. Saved endpoint/conversation prompts are unchanged.
- The iPhone conversation destination hides Chats/Settings tabs; leaving the destination removes that visibility preference.
- Watch endpoint editing now exposes explicit API format and search mode and preserves endpoint ID, credential ownership, API keys and settings outside the compact editor. Previously saving could reset a Responses profile to Chat Completions.
- Raised the URLSession inactivity ceiling from 45 to 90 seconds so it no longer cuts off a search before the engine's 75-second first-result/inactivity allowance. The engine still owns bounded useful-progress and overall deadlines; cancellation and Retry semantics are unchanged. This does not make an unreachable endpoint reachable.
- Added Watch Connection help beside network failures and in Endpoints.

## Validation and installation

- Formatting fixtures: 23 checks passed, including reproduction of the old flattening behavior.
- Endpoint edit fixtures: 11 checks passed.
- Request recovery/history/sync fixtures: 28 checks passed.
- Physical iPhone + embedded Watch/widget build passed; deep signature verification passed.
- Installed iPhone readback confirms version 1.0, build 2. Staged phone, Watch and widget Info.plists all confirm the same version/build. Version values now come from project.yml build settings through generated Info.plists.
- Build 2's Watch app is embedded for companion update. Receipt of this particular follow-up Watch build remains for user confirmation; the earlier build's Search toggle was already confirmed by the user.
- Physical navigation inspection was interrupted by the user using the phone in another app. No automated questions were sent to a chat provider. The tab modifier compiled but has not been separately visually accepted on the device.

Evidence remains in the ignored build/device-install directory: build.log, codesign-verify.log, install.json, feedback-build2-app.json and feedback-build2-launch.json.

## Networking findings and limits

The installed VPN client is Clash, bundle com.hako.network, version 1.0.13 (152). The user reports the Watch is near the iPhone, is not using cellular, and has not identified whether its current route is Bluetooth or Wi-Fi. One or both of Enforce Routes and Include All Networks is disabled; the exact two states are not yet established. No VPN settings were changed.

The Watch uses its own provider URLSession execution; the app does not implement a foreground iPhone request relay. Apple documents a watchOS-selected network path that may proxy through the paired phone over Bluetooth or use Watch Wi-Fi/cellular. Being nearby and seeing a working iPhone VPN do not establish the route or VPN policy of this Watch request.

An open report in the exact client's maintainer tracker describes a similar Watch problem with both Enforce Routes and Include All Networks enabled. The affected user reported recovery after disabling both; it is not a maintainer-confirmed fix, and their 1.0.12 (128) differs from this phone's build. The user's present answer does not establish the same both-enabled scenario. Do not attribute this failure to that combination or blindly alter routing settings.

Next discriminating check: retry the same endpoint/API format/model once on Watch with Search Off and inspect Clash Connections for the destination hostname, matched rule and outbound. Compare one successful iPhone request. An absent log entry is suggestive only: DNS/TLS failures and logging differences can also hide it. A direct-rule entry versus the expected proxy is stronger routing evidence. Retain the original prompt and use the app's explicit Retry; do not replay ambiguous requests automatically.

No root cause for the physical Watch's VPN/endpoint timeout has yet been proven. No phone relay, VPN configuration change or networking workaround is claimed delivered.

## Primary references

- Apple Watch networking: https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date
- Apple Watch low-level networking limitations: https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos
- Apple includeAllNetworks behavior: https://developer.apple.com/documentation/networkextension/nevpnprotocol/includeallnetworks
- Exact client maintainer repository: https://github.com/ProjectClash/Clash-Client
- Similar Watch report, open when checked November 1, 2026: https://github.com/ProjectClash/Clash-Client/issues/62
