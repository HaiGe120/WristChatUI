# Voice conversations and CarPlay

## Current distribution status

The current App Store distribution intentionally ships phone and Apple Watch voice features without CarPlay. Apple has not yet approved the `CARPLAY_VOICE_BASED_CONVERSATION` capability for `com.wristassistant.app`, and the available App Store provisioning profile cannot sign that entitlement. The CarPlay source remains in the repository for a later build after Apple approves the capability and refreshed profiles are installed.

CarPlay support uses Apple's **voice-based conversational app** category on iOS 26.4 or later. The existing iPhone and Apple Watch app remains the place to read complete conversation history. CarPlay shows generic listening/thinking/speaking states and short controls; it never renders recognized speech, AI answers, source text, or prompt-derived conversation titles.

## Voice behavior

- Choose **Speak**, say a question, then choose **Send**, or let recognition finish. The selected existing AI connection receives the resulting text. The successful answer is read aloud and retained in the ordinary chat history.
- **Stop** cancels the local CarPlay turn and releases recording/playback resources. **Replay** reads the last completed answer in the current CarPlay conversation. **New chat** clears the current selection; a row is created only when the next voice turn is started.
- The car screen never asks for microphone or speech permission. Grant these through the iPhone voice setup before using CarPlay. In the car, missing access is reported as a condition rather than an instruction to manipulate iPhone.
- CarPlay owns the iPhone voice service while connected. Scene inactivity and disconnect cancel CarPlay-owned recording, requests and playback. Reconnecting does not restart an interrupted request or activate the microphone automatically.
- Apple speech recognition availability depends on language, device, downloaded resources and network access; it is not a guaranteed offline service. Speech may be processed by Apple. The configured AI endpoint receives the transcript and required conversation context. The app does not save recordings.

## Required Apple capability and signing

The new source files do not by themselves enable CarPlay for distribution. Request Apple's `com.apple.developer.carplay-voice-based-conversation` entitlement for `com.wristassistant.app`, agree to the CarPlay Entitlement Addendum, enable the approved capability for the App ID, and regenerate the provisioning profiles. The repository's manually selected App Store profile must include the new entitlement before an archive can be distributed with CarPlay. Until then, the release configuration omits the CarPlay scene and entitlement.

The scene manifest must include `CPTemplateApplicationSceneSessionRoleApplication` with `CPTemplateApplicationScene` and `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`. Keep this scene separate from the SwiftUI iPhone window. The target must also declare microphone/speech privacy descriptions and the audio background mode needed for active car voice use. The authoritative project configuration is `project.yml`; regenerate the project after changing it.

Apple's October 13, 2026 [CarPlay Developer Guide](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf) requires a voice-first experience, the voice-control template during voice services, and audio sessions only while voice is actively in use. It specifically says not to show text or imagery in response to queries. Recording is permitted for this app category only with the voice-control template. The template contains at most five states and at most two action buttons per state. This implementation stays within those limits.

## Validation before release

1. Verify permission granted/denied/not-yet-requested, unsupported speech language, no speech, recognition timeout and capture cancellation. No prompt should appear on CarPlay.
2. Verify successful answers, offline/slow endpoints, rejected credentials, search failures, Stop followed by another question, Replay and New chat. No partial or failed answer should auto-play as a success.
3. Verify phone and car presentation of the same active conversation, phone/Watch sync, deletion and endpoint edits. Historical or remotely synced answers must never start speaking automatically.
4. Verify screen sizes, touch and rotary controls, light/dark appearance and accessibility. Check every state and error screen for absence of query/answer content.
5. Use a physical iPhone for locked-screen behavior, phone/navigation interruptions, wired and wireless CarPlay, speaker/microphone routing and disconnect/reconnect. Check actual car audio returns promptly after recording or playback ends.
6. Xcode 27's Device Hub includes CarPlay Simulator for an attached physical iPhone. Simulator availability does not establish that the entitlement/profile is approved. All iOS/watchOS simulator work in this repository must go through `scripts/sim.sh`, with one boot/install/launch and teardown. Do not bypass its cleanup rules for CarPlay testing.

Local compilation and fixture tests do not establish real-car audio compatibility or App Store approval. Record physical-device and entitlement validation separately before publishing.

## Local validation — November 2, 2026

- iPhone app with embedded Watch app: simulator build passed with Xcode 27.2.
- Watch app: separate generic watchOS Simulator build passed. The installed Watch simulator runtime is unavailable, so Watch runtime behavior was not verified.
- Native fixtures: 45 recovery/coordinator checks, 15 voice formatting/preferences checks, 46 provider checks, and 23 existing formatting checks passed (129 total).
- Simulator lifecycle fixtures passed, including installation-registration failure, one launch, bounded diagnostic captures, launch timeout, success/error cleanup and memory-regression protection.
- iPhone normal startup and the new Voice settings screen were visually verified on the existing iPhone 17 / iOS 26.5 simulator. The debug-only `WA_TEST_VOICE_SETTINGS=1` launch route opens settings without requesting permissions or sending a chat request. It is excluded from release builds.
- Initial simulator attempts exposed asynchronous app-registration timing and an external-link confirmation dialog. The wrapper now checks registration before its sole launch; the successful settings capture used `SIMCTL_CHILD_WA_TEST_VOICE_SETTINGS=1 SIM_CAPTURE_COUNT=3 scripts/sim.sh boot`.
- Every boot attempt ended with verified shutdown: no remaining WristAssistant process and no SimulatorTrampoline over 200 MiB.

Not verified locally: live microphone recognition, audible synthesis, real Watch routing/lifecycle, locked-iPhone conversation storage, actual CarPlay scene presentation/audio, wired/wireless cars, Apple entitlement approval, refreshed signing profiles, or App Store distribution. The implementation must complete those device and account checks before a CarPlay release.

## Physical-device voice test build — November 2, 2026

Installed version **1.1.0 (3)** on the user's paired iPhone Air over Wi-Fi. The installation succeeded after reconnecting a dropped wireless tunnel, and installed-app readback confirmed the version. No uninstall or app-data reset command was used. Launch was denied because the phone had become locked; the user will open it and test later.

The installed package embeds matching **1.1.0 (3)** Watch and widget apps. The Mac does not expose the physical Watch as a development destination, and the user could not access the phone/Watch to confirm companion transfer during this session. Watch receipt remains unverified; check the new **Voice** item in the Watch app when testing.

Available development profiles do not include CarPlay. This install therefore used `WA_DEVICE_VOICE_ONLY=1 scripts/device-install.sh <device-id>`, which creates an ignored Debug-only entitlement file preserving iCloud and omitting the restricted CarPlay capability. The current distribution configuration also omits CarPlay. This test build supports phone/Watch voice testing and does not enable CarPlay in a vehicle.

Evidence: `build/device-install/build.log`, `codesign-verify.log`, `install-voice.json`, `iphone-voice-after.json`, and `iphone-voice-launch.json`. The staged phone, Watch, and widget bundles all report 1.1.0 (3) and passed deep signature verification.
