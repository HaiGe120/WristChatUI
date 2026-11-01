# Direct ChatGPT sign-in implementation status

Verified November 1, 2026 (Asia/Shanghai).

## Current release gate

Direct sign-in is disabled. `ChatGPTAccountView` reports the remaining requirements; it does not show an enabled sign-in button. Existing custom endpoint connections remain usable.

The official OpenAI pages were retrieved directly on November 1, 2026. Their documented public-client flow starts first registration with `dynamic_agent_client`, then uses the issued account/workspace-bound `oaiapp_…` client ID returned to the callback for code exchange and later sign-ins. A global borrowed Codex CLI client ID is unnecessary and must not be substituted.

OpenAI describes this plan-usage flow for open-source/local apps and directs paid or remotely hosted products to its interest form. WristChatUI's existing PolyForm Noncommercial license and App Store distribution do not establish eligibility for this product. Confirm the supported product/registration path before enabling sign-in. No license changes, interest-form submission, credentials, or server changes were performed here.

The required callback uses `http://127.0.0.1:<port>/auth/callback`. Only the port may vary between attempts. Physical iPhone system-authentication UI, listener lifecycle, cancellation, app return, and background behavior still need a device proof. The existing `wristassistant://` URL scheme cannot substitute for the documented callback.

## Implemented prerequisites

- Secure independent PKCE verifier, state, and nonce for each attempt, S256 challenge, exact callback URI/state matching, callback deadline, duplicate-parameter rejection, denial handling, and account-bound issued-client validation.
- A one-shot authorization broker rejects callback replay. Authorization URL generation alone does not open a browser or enable sign-in.
- An RS256 ID-token verifier validates the signature against supplied trusted JWKS, key strength, issuer, audience/authorized party, expiry/issued-at/not-before, nonce, and returning account subject. It never resolves a key URL from the JWT header. The eventual network layer must fetch discovery/JWKS from the official destination and enforce redirect restrictions.
- A separate non-synchronizing, device-only Keychain credential service, stable installation host ID, atomic whole-record replacement, one refresh operation per registration, and a generation check that prevents sign-out/account replacement from being undone by a late refresh. Identity-only grants remain distinct from inference permission.
- Exact official credential destination checks for token exchange, revocation, model discovery, and Responses inference. A later OAuth transport must apply these checks together with a no-redirect session delegate; these checks alone do not create an authenticated connection.

The prerequisites are independent of endpoint JSON, conversation backups, and the API-key mirroring path. OAuth tokens have not been added to any of those models. Live token exchange, discovery/JWKS loading, renewal/revocation HTTP operations, authentication UI/listener, account switching UI, model discovery, and dedicated Watch access-credential provisioning are still unimplemented. No physical login or account inference success is claimed.

## Verification

`scripts/test-oauth.sh` compiles and runs local fixtures for PKCE/callback/issued-ID/replay behavior, credential destinations, real generated RSA signatures and invalid claims, refresh coalescing, sign-out races, and atomic-write retention. The fixtures use generated test keys and in-memory credential storage; they do not read or modify user credentials. This Mac requires access to its crypto service for generated RSA keys, so the runtime was executed with that access. All fixtures passed.

`scripts/test-sim-lifecycle.sh` uses fake Xcode and simulator commands. It passed success, one-launch, Watch, build/install/launch failure cleanup, high-RSS boot rejection, and denied process-inspection cases. `scripts/sim.sh` now installs EXIT/signal traps and performs teardown checks; it cannot trap SIGKILL. Physical simulator process/memory checks remain the responsibility of the actual validation session.

## Official sources

- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Eligibility and host/client identity](https://developers.openai.com/siwc/token-sharing-open-source)
- [Accounts, refresh, sign-out, and credential handling](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [ID-token verification](https://developers.openai.com/siwc/website)
- [Public OIDC discovery](https://auth.openai.com/.well-known/openid-configuration): issuer `https://auth.openai.com`; RS256 ID tokens; JWKS `https://auth.openai.com/.well-known/jwks.json`; token and revocation paths match the documented official account endpoints.
