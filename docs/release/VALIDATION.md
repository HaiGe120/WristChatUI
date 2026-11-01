# Validation for 1.1.0

The iPhone and Apple Watch development apps were tested on physical devices. The user confirmed that both tested versions work well, including the revised Watch presentation and conversation behavior. Production packaging keeps the tested API-key/search features and removes the unfinished direct ChatGPT account entry from release navigation.

## Local regression checks

- Provider request/stream fixtures: 46 checks passed.
- Search transport/source fixtures: 50 checks passed.
- Recovery, history and sync fixtures: 28 checks passed.
- Markdown/Watch-formatting fixtures: 23 checks passed.
- Endpoint-edit preservation fixtures: 11 checks passed.
- OAuth security primitives: generated-key, callback, claims, refresh and sign-out race fixtures passed; this does not enable or claim live ChatGPT sign-in.
- Simulator lifecycle fixtures: success/error cleanup, one-launch, stalled-command timeout, excessive-memory rejection and denied-inspection checks passed without starting simulators.

The release tooling builds a fresh archive and distribution export, then checks the iPhone, embedded Watch and widget versions, device families, profiles and signatures. Public development-device lists are excluded from distributed artifacts. BUILD-INFO.json and SHA256SUMS.txt accompany release downloads.

Provider-native search and independent search entitlement remain dependent on the selected server, model and account. The release does not promise universal native search support, a particular VPN route, or an always-available iPhone relay. GitHub publication does not imply App Store approval; consult the publication record for the actual Apple state.
