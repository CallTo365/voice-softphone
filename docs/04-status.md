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

## Open threads
- Phase 0 exit criterion (two-way audio 1001 <-> 1002 and PSTN) still to run by the owner with the real
  password once P1 is deployed (or with the trust toggle before that).
- Kamailio dead-branch handling (P3): `remove_branch` vs `event_route[tcp:closed]` + `ul.rm`, to be
  decided in the platform build pass with a SIPp/real-phone test.
- Password field: phase 3 replaces it with enrollment; until then the dev screen is the only way in.
