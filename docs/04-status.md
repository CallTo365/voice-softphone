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
  mobile, 12:00 to `*98`). First real call presented the default: the control plane read the wrong FreeSWITCH
  variable (`sip_h_…` instead of `sip_P-Preferred-Identity`, platform branch `softphone/ppi-variable-fix` 099d506,
  merged + deployed by the owner). **Verified by the owner afterwards: the outbound leg's P-Asserted-Identity shows
  +32473981616.** docs/05 is complete.

## 2026-09-16 — hold and on-demand recording in the call screen (docs/06)
- App: `platformCallID` captured from `X-Call-ID-Platform` (INVITE / 18x / 200), Hold and Record buttons calling
  `/v1/calls/{id}/hold|unhold|record` with the device bearer, status line marks, readable errors; 25 tests.
- Platform branch `softphone/call-id-header-and-user-recording` (1f03484): `multiset sip_ph_/sip_rh_X-Call-ID-Platform`
  on user A-legs, recording control for the user on the call. Not yet deployed.

- 2026-09-16 afternoon: owner's tests found (1) Hold/Record disabled once the platform's hold re-INVITE put the
  phone in `.held` — fixed d71ca3f; (2) no hold music — platform gap (`uuid_hold` with no `hold_music` on the
  source-built workers), fixed on branch `softphone/hold-music` (9a8e7ed, merged + deployed 14:2xZ: the queue
  fallback tone; tenant hold-music media is the follow-up in the platform's docs/23); (3) internal extension →
  extension calls to the app drop with BYE cause 16 right after answer — platform log for call
  189e0018-9170-475b-981e-2f164e581c75 requested, cause unknown yet.

## 2026-09-18 — dialing context on the platform (P9)
- Owner's finding: `0634443999` on the softphone was refused ("forbidden"): the platform read every 8+ digit
  string as E.164 without `+`. Proposal docs/40 + ADR-0059 in the platform repo approved ("go with the
  recommendations"), built on `softphone/dialing-context` (e27e8f4, rebased on main f892ab4, pushed): per-country
  table in code, effective country user → tenant → none, Entra `usageLocation` sync rule, user sheet picker,
  `unparseable_destination` rejection. Merged as platform main 3a99f5b and on the VM 2026-09-18 09:41Z (migration
  0060, control-plane ×3, admin-ui; `directory` 09:45Z). **Owner-verified ~10:00Z:** the acme tenant is `country = BE`,
  1001 dialed `0473981616` from the app and the outbound leg shows `+32473981616`.
- App side of the same request: long-press 0 → `+` was already in (dae569e). Nothing else changes in the app.

## Open threads
- 1001 <-> 1002 with Bria on a real phone and the owner's ear test remain as human checks.
- Next block: phase 1 (CallKit; needs the Team ID for a device build) or P3/P4 push (needs the APNs `.p8`).
- Kamailio dead-branch handling (P3): `remove_branch` vs `event_route[tcp:closed]` + `ul.rm`, to be
  decided in the platform build pass with a SIPp/real-phone test.
- Password field: phase 3 replaces it with enrollment; until then the dev screen is the only way in.
