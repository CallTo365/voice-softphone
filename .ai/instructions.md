# Working instructions

## Where things are (planned layout; created in phase 0)
| Path | What |
|---|---|
| `docs/` | Normative design: `01-mvp.md` (scope, architecture, phases, decisions), `02-call-flows.md`, `03-platform-changes.md` (what `voice-platform` must gain), `04-status.md` (hand-off) |
| `docs/adr/` | Architecture decision records, one file per decision |
| `.ai/` | This folder: instructions, guardrails, mistakes log |
| `project.yml` | xcodegen spec; the `.xcodeproj` is generated and git-ignored |
| `apps/ios/Softphone/` | The iOS app (SwiftUI): screens, CallKit provider delegate, app lifecycle |
| `packages/SoftphoneKit/` | Swift package, no UI: `CallEngine` (liblinphone wrapper), `PlatformAPI` (control plane REST + live-state WS), `AccountStore` (Keychain), `Diagnostics` |
| `scripts/` | Bootstrap, device run, log collection |
| `../voice-platform` | The PBX. Contracts in `docs/02-contracts.md`; Kamailio in `edge/kamailio`; control plane in `services/control-plane` |

## Commands (once phase 0 exists)
```bash
make bootstrap   # xcodegen generate; resolves SPM (linphone-sdk-swift-ios)
make build       # xcodebuild -scheme Softphone -destination 'generic/platform=iOS Simulator' build
make test        # swift test --package-path packages/SoftphoneKit + xcodebuild test for the app target
make device      # build + install on the connected iPhone (xcrun devicectl), stream os_log
```
Toolchain on the owner's Mac (2026-09-14): Xcode 26.6, Swift 6.3, xcodegen installed.

## Conventions
- Swift 6 language mode, strict concurrency. `CallEngine` is a `@MainActor final class`; the liblinphone
  `Core` runs with auto-iterate on the main thread and is never touched from another actor.
  `@preconcurrency import linphonesw` where the wrapper is not `Sendable`.
- SwiftUI views are dumb: state comes from observable models in `SoftphoneKit`; no SDK calls in views.
- Logging with `os.Logger`, one subsystem (`com.callto365.softphone`), categories `sip`, `callkit`,
  `push`, `api`, `ui`. Redaction is the logger's job (S6), not the caller's.
- Errors are typed (`enum SoftphoneError: Error`) and surfaced to the UI as short user sentences; the
  technical cause goes to the log with a correlation id (SIP Call-ID or platform call id).
- Naming: platform ids as in the contract (`call_id`, `device_id`, `tenant`), SIP identities as
  `sip:<ext>@<tenant>.sip.<base-domain>`.
- Time: UTC, RFC 3339 in API bodies and logs.
- Dependencies: `linphonesw` (SPM, pinned exact version) and Apple frameworks only, until an ADR adds more.

## Where to look things up (S12)
- liblinphone Swift wrapper: after `xcodegen generate` + first build, the checkout is under
  `~/Library/Developer/Xcode/DerivedData/<app>/SourcePackages/checkouts/linphone-sdk-swift-ios/`; the
  generated Swift API is in `linphone.xcframework/*/linphone.framework/Modules` (or the `linphonesw`
  sources shipped with the package), C headers in `include/linphone/api/*.h` and `include/linphone/core.h`.
- Reference implementations: Belledonne's tutorials (`gitlab.linphone.org/BC/public/tutorials`,
  `ios/swift/4-CallKitTutorial`) and the Linphone iOS app (`linphone-iphone`). Copy behaviour, not code
  (their code is GPL too, but ours must stay readable and small).
- Apple: CallKit, PushKit, AVAudioSession documentation for iOS 17+.

## How to make a change
1. Find the flow in `docs/02-call-flows.md` and the contract section in the platform repo. If the change
   needs something new on the wire, do the platform change first (contract + ADR there).
2. Implement in `SoftphoneKit` when it has no UI, in the app when it does.
3. Add or update tests (state machines and API clients are testable without a SIP server; use the
   liblinphone tester only when unavoidable).
4. Run the verification for everything you touched (S11). Paste real output in your report.
5. If something went wrong along the way, record it in `.ai/mistakes.md` (see `CLAUDE.md`).

## Review checklist (use before reporting done)
- [ ] S1/S4: every push path reports to CallKit; audio session only in provider actions
- [ ] S2: no platform state changed without the API; every API mutation has a user-visible failure
- [ ] S6/S7: nothing secret outside the Keychain; nothing secret in git or logs
- [ ] Contract used as written in `../voice-platform/docs/02-contracts.md`; deltas recorded in `docs/03-platform-changes.md`
- [ ] Verification commands run and results stated honestly (S11, S14)
- [ ] `docs/04-status.md` updated if a milestone landed; mistakes log updated if applicable
