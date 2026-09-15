# Status and hand-off

## 2026-09-14 (evening) — decisions approved, phase 0 built
- All D1-D10 approved by the owner; D7 = two devices, one user. ADR-0001..0004 accepted. LICENSE
  GPL-3.0. Public repo `https://github.com/CallTo365/voice-softphone`.
- Phase 0 code: `project.yml` (xcodegen), `packages/SoftphoneKit` (CallEngine on linphone-sdk
  5.5.21-novideo via the GitHub mirror, AccountStore/Keychain, DialString, Redactor, Diagnostics),
  SwiftUI app (dev account screen, dialer, call screen), 17 unit tests.
- Verified: `make build` (Swift 6 strict concurrency) and `make test` (17/17 on iPhone 15 simulator,
  Core starts, instance id persisted). In the simulator against the VM: with certificate verification on
  the TLS handshake fails on the self-signed 5061 cert (expected, P1); with the development trust toggle
  the REGISTER reaches Kamailio and a wrong password is answered "Unauthorized". A real registration and
  the phase 0 exit call need the seeded `SIP_USER_PASSWORD` (VM `.env`) typed into the dev screen.
- P1 built in `voice-platform` on branch `softphone/p1-sip-tls-cert` (a828104) and **deployed to the VM
  by the owner from the branch on 2026-09-14 ~20:05Z** (main was dirty with another session's edits, so
  `git archive softphone/p1-sip-tls-cert docker-compose.yml edge/kamailio` was exported; branch still to
  merge). Kamailio logged the certificate install (expires 2026-12-11), `openssl s_client` shows issuer
  Let's Encrypt, and the app on the simulator completed a TLS 1.3 handshake with certificate verification
  on (no bypass) before Kamailio answered the wrong test password with Unauthorized.
- Fixed the same evening: the Core is created with `configPath: nil` (liblinphone had persisted the
  account, auth info and the trust flag in `linphonerc`; R7), and simulator builds are signed so the
  Keychain works (R6).
- P2 applied live on `voice-mvp-fw` (5061/tcp and 30000-30100/udp from anywhere); the same two
  `hcloud firewall add-rule` lines still need to go into `scripts/hetzner-up.sh` (the auto-mode
  classifier refused that edit).
- Not yet: Apple team / signing (device builds), P3-P7.

- **22:34 CEST: first calls from the app.** 1001 registered with the real password over verified TLS
  (after a 5-minute `ipban` I had caused with wrong-password tests, R8). Outbound to the echo agent
  (+31856662751 via MOR): 407 -> authenticated INVITE -> 200 OK in 300 ms, SRTP (AES_CM_128_HMAC_SHA1_80),
  opus offered, RTCP SRs from the far end for 27 s until the app's BYE. An inbound INVITE to 1001 reached
  the app and rang (180). Two crashes at call start before that: the wrapper's unretained `LoggingService`
  pointer (R9), fixed in the commit after 76cb8a6.

- **22:53 CEST, phase 0 exit met on the simulator:** call to `*98` (voicemail menu, TTS prompts): 200 OK
  in 140 ms, `opus/48000 · SRTP · ↓ 67 ↑ 60 kbit/s · loss 1%/0% · jitter 56 ms` shown live on the call
  screen (new media-stats line from `onCallStatsUpdated`), i.e. real audio content in both directions
  without relying on ears. Ended by the app's BYE.

## 2026-09-15 — P5 + P8 built in voice-platform
- Branch `softphone/p5-p8-enrollment-callerid` (7a45f2d, rebased on main): enrollment codes from the user sheet's new
  Devices tab, `POST /v1/auth/device` -> `dvt_` bearer + SIP identity with `ha1` and `SIP_TLS_HOST`, device bearer =
  user principal in control plane, live-state and presence; `P-Preferred-Identity` honoured on user ingress with the
  `call.caller_id.override_rejected` timeline entry. Platform ADR-0042/0043, migration 0045. Verified with Go and UI
  test suites and an integration test against the local Postgres; not yet deployed to the VM.
- Next in this repo: `PlatformAPI` + enrollment screen (code entry, `callto://enroll` link), `CallerIDStore` + dialer
  sheet (fetch on open, 5-minute cache), `P-Preferred-Identity` on `placeCall`.

## 2026-09-15 12:00 — enrollment + caller-ID selection live end to end
- Platform P5/P8 deployed by the owner (main, cluster recipe; my first deploy command used the previous day's
  recipe and half-recreated the stack, R10). QR code in the Devices tab (branch `softphone/qr-enrollment`, f381c70)
  deployed too.
- Simulator: enrolled with a code (twice, same device id re-used), one `GET …/caller-ids` per sheet open, chose
  "Hugo Mobiel", outbound calls carried `P-Preferred-Identity: <sip:+32473981616@acme.sip.local>` (11:51 to a
  mobile, 12:00 to `*98`). Owner to confirm the displayed number and the timeline's `caller_id_layer: per_call`.

## Open threads
- 1001 <-> 1002 with Bria on a real phone (the 22:31 attempt got only `100 Trying`: 1002 was not
  ringing anywhere) and the owner's ear test are the remaining human checks; then phase 1 (CallKit).
- Kamailio dead-branch handling (P3): `remove_branch` vs `event_route[tcp:closed]` + `ul.rm`, to be
  decided in the platform build pass with a SIPp/real-phone test.
- Password field: phase 3 replaces it with enrollment; until then the dev screen is the only way in.
