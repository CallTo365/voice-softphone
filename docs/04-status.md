# Status and hand-off

## 2026-09-14
- Repo created with the agent instruction layout (`CLAUDE.md`, `.ai/*`, hooks), design docs 01-03 and
  ADR-0001..0004 (all **proposed**). No app code, no Xcode project yet.
- Decisions D1-D10 in `docs/01-mvp.md` section 9 are waiting for the owner.
- Platform work P1-P7 is listed in `docs/03-platform-changes.md`; nothing started in `voice-platform`.
- Local toolchain checked: Xcode 26.6, Swift 6.3, xcodegen present. linphone-sdk stable 5.5.21
  (5.6.0-alpha exists; do not use).
- Not yet: GitHub remote, LICENSE file (D2), Apple developer prerequisites (01 section 7).

## Open threads
- D7: confirm what "two softphones" means for the owner.
- D10: VM firewall exposure for mobile-network tests.
- Kamailio dead-branch handling (P3): `remove_branch` vs `event_route[tcp:closed]` + `ul.rm`, to be
  decided in the platform build pass with a SIPp/real-phone test.
