# Device test installation

November 1, 2026 (Asia/Shanghai).

The development build was installed over the existing WristChatUI on the user's iPhone Air at approximately 21:57. No app uninstall or data reset was performed. The app launched successfully, and its new API-format/search controls were visible on the physical phone.

The initial installation identified as version 1.0 (build 1); this was a development installation of the current working tree, not an App Store release. Direct ChatGPT sign-in remains gated as described in CHATGPT-OAUTH-STATUS.md.

The combined physical-device build passed, the staged bundle passed deep signature verification, and iPhone/embedded Watch/widget bundle identities and device families were checked. The signed Watch app is embedded in the installed phone app. The user subsequently confirmed that the physical Watch Ultra shows the new “Search · Native” control inside a chat, establishing that the updated embedded Watch app transferred through the iPhone. The Mac still does not list the physical Watch as a development destination; direct Mac-to-Watch installation was not performed.

Local evidence (ignored build directory):

- `build/device-install/build.log`
- `build/device-install/codesign-verify.log`
- `build/device-install/install.json` (successful installation)
- `build/device-install/iphone-after.json` (installed bundle readback)
- `build/device-install/iphone-launch.json` (successful launch)
- `build/device-install/watch-discovery.json` (physical Watch not discovered)

Verification: the user confirmed WristChatUI under Installed on Apple Watch, then opened a Watch chat and confirmed the new Search toggle. Both devices are ready for user testing. No app removal or library reset was needed.

Development pairing was initially blocked by automatic approval review, then explicitly authorized by the user. The approved Device Hub pairing command did not expose a new pairing window or physical Watch. No completed pairing change is claimed. Further pairing attempts stopped once the user confirmed the updated Watch UI.


## Follow-up build 2

At approximately 22:31 on November 1, 2026, the phone was updated to 1.0 (2) with the paragraph rendering, Watch formatting guidance, hidden phone chat tabs, preserved Watch endpoint formats and search-timeout ceiling fixes. Phone installation/version readback and staged Watch/widget versions were verified. The build-2 Watch app is included for companion transfer; receipt of this follow-up build on Watch is not yet confirmed. See WATCH-READABILITY-AND-NETWORK-FEEDBACK.md for validation and the unresolved VPN diagnosis.

## Voice test build — November 2, 2026

Installed **1.1.0 (3)** on the same iPhone Air over the paired wireless connection. An initial transfer lost its tunnel; reconnecting and retrying the already signed package succeeded. Installed-app readback confirmed 1.1.0 (3). No uninstall or data-reset command was used. The app could not be opened remotely afterward because iOS reported the phone locked; the user said they will test later. Conversation contents and on-device voice behavior were not inspected.

The package includes matching 1.1.0 (3) Watch and widget apps for companion transfer. The physical Watch remains unavailable as a Mac development destination, and the user could not confirm its update during this session. Watch delivery is pending verification, rather than claimed complete.

Existing development profiles lack Apple's CarPlay capability. The installed Debug test signature omits that restricted entitlement and preserves iCloud. The current App Store release configuration also omits CarPlay until Apple approves the capability and refreshed profiles are installed. This installation enables phone/Watch voice testing; it does not enable CarPlay in the car. See CARPLAY-VOICE.md for the build flag and validation limits.

Evidence: `build/device-install/install-voice.json` (success), `iphone-voice-after.json` (version readback), `iphone-voice-launch.json` (locked-device denial), `build.log`, and `codesign-verify.log`.

## Search recovery follow-up — November 2, 2026

Following the user's search-failure screenshot, version **1.1.0 (5)** was installed over Wi-Fi and confirmed by installed-app readback. It includes deterministic phone/Watch turn ordering, bounded search continuations, accurate limit/partial-answer messages, explicit Retry without search, optional output-token controls, and processing-progress timeout handling. The signed package contains matching Watch/widget build 5; companion receipt remains unverified. No uninstall, library reset, or conversation-record export occurred. See SEARCH-RECOVERY-FIXES.md for 283 synthetic checks and the limits of the diagnosis. Evidence: `search-build5-install.json` and `search-build5-after.json` under `build/device-install`.

## Search answer finalization — November 2, 2026

The next screenshot showed build 5 stopping after search acquisition instead of producing its answer. Build **1.1.0 (6)** adds one bounded source-based answer step, proper cancellation/deadline handling, and a compact Sources link opening a dedicated list. All 344 local checks passed. Initial installation attempts hit an unavailable wireless developer connection; after the user confirmed the phone was unlocked on Wi-Fi, installation succeeded and app-version readback confirmed 1.1.0 (6). The package includes matching Watch/widget build 6, but physical Watch receipt remains unverified. No app uninstall, library reset, private-record export, or live AI replay occurred. Evidence: `search-build6-install.json` and `search-build6-after.json` under `build/device-install`.
