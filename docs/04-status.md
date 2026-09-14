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
- Not yet: Apple team / signing (device builds), P1 cert on the VM, P2 firewall.

## Open threads
- Phase 0 exit criterion (two-way audio 1001 <-> 1002 and PSTN) still to run by the owner with the real
  password once P1 is deployed (or with the trust toggle before that).
- Kamailio dead-branch handling (P3): `remove_branch` vs `event_route[tcp:closed]` + `ul.rm`, to be
  decided in the platform build pass with a SIPp/real-phone test.
- Password field: phase 3 replaces it with enrollment; until then the dev screen is the only way in.
