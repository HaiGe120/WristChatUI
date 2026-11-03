# iPhone Duo validation — November 3, 2026

Release candidate: **1.1.0 (7)**, built with Xcode **27.2 (27B52)**.

## Layout and state

- Native `NavigationSplitView` shows the conversation list beside the selected chat when space permits and uses compact navigation at narrower widths.
- Chat text and the composer are centered with an 800-point maximum width. Search details wrap, streaming status has its own row, and microphone/send controls have a minimum 44-point layout size.
- Drafts and search choices belong to the conversation session, surviving view recreation and sidebar switching. Removing a conversation removes that session.
- Simulator checks covered Duo closed, partially open, fully open and rotated. The selected conversation remained available. A seeded unsent draft and enabled search survived closed-to-open transitions.
- iPhone 17 / iOS 26.5 rendered the compact chat successfully. Its cold launch required a longer bounded launch allowance; the first frame preceded scene readiness. Three bounded frames produced the verified capture. The launch timeout is now 90 seconds.

## Screenshots

The DEBUG-only screenshot route uses an in-memory SwiftData container with CloudKit disabled. It seeds local sample text, makes no provider requests, and does not replace the normal conversation database. Screenshot presentation is excluded from Release builds.

Native-size RGB assets, without alpha:

- [Duo outer display — 1398 × 2034](screenshots/1.1.0-build7/duo-outer-final.png)
- [Duo inner display — 2853 × 2007](screenshots/1.1.0-build7/duo-inner-final.png)
- [iPhone 17 — 1206 × 2622](screenshots/1.1.0-build7/iphone17-chat.png)

Additional draft, partial-pose and rotation captures are retained locally under `build/duo-screenshots/`.

## Verification

- iPhone simulator build, including embedded Watch components: passed.
- Provider fixtures: 149 checks; search: 50; endpoint editing: 25; formatting: 23; voice: 15; recovery/coordinator: 85. **347 checks passed.**
- Recovery checks include draft/search retention, independent conversation state and state removal on deletion.
- Simulator lifecycle fixtures cover a single launch, success/error cleanup, stalled launch, memory protection, display selection, bounded review polling, failure to inspect processes, and invalid review options rejected before boot.
- Each real simulator session ended with verified shutdown, no remaining WristAssistant app process and no SimulatorTrampoline above 200 MiB. No app uninstall or simulator data reset was used.

Physical Duo hardware, live microphone recognition, audible playback, broad accessibility coverage and physical Watch behavior have not been verified in this task. CarPlay scene registration and its restricted entitlement remain disabled in this distribution.

Publication, Apple upload, review submission and App Store approval are separate steps. This validation record does not assert Apple approval.
