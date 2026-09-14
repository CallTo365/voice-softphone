# Mistakes log (self-updating)

This file is maintained by whoever works in the repo, human or agent. The **Active rules** section is
injected into every agent turn by the hook in `.claude/settings.json`, so keep it short and current.
The **Log** is append-only.

## Active rules (derived from the log)
- R1. Verify third-party API shapes (linphonesw symbols, CallKit/PushKit signatures, platform endpoints)
  against the pinned version's source or the platform repo before using them; note the version checked.
  Seeded from `voice-platform` R1: the platform's Kamailio 5.8.6 has no RFC 8599 `pn_*` registrar
  parameters (checked 2026-09-14 against the 5.8 registrar README), so push detection is done in cfg.
- R2. A root cause or "it works" that rests on a read or a run that was refused or not performed is a
  hypothesis, not a fact; say so in the report (seeded from the platform's caller-ID lesson).
- R3. CallKit and PushKit behaviour is verified on a real iPhone only (the SDK disables CallKit on the
  simulator: `ios-app-delegate.mm` `callkitEnabled` returns false under `TARGET_IPHONE_SIMULATOR`).
- R4. When a platform change is required, write it into `docs/03-platform-changes.md` here and into the
  platform repo's contract + ADR before building app code against it; never build against an imagined
  endpoint.
- R5. The linphone-sdk Swift package is fetched from the GitHub mirror
  (`BelledonneCommunications/linphone-sdk-swift-ios`); gitlab.linphone.org drops connections. Binaries
  still come from download.linphone.org, so a build needs that host reachable.
- R6. Simulator test runs are signed (ad hoc, no team needed); `CODE_SIGNING_ALLOWED=NO` is only for
  `generic/platform=iOS Simulator` compile checks, because an unsigned app cannot use the Keychain.

## Log

Template (copy, fill, append at the end):
```
### YYYY-MM-DD — short title
- **What happened:** one or two sentences, factual.
- **Root cause:** assumption / missing check / unclear spec.
- **Impact:** what broke or would have broken.
- **Fix:** what was changed.
- **Rule:** new or updated Active rule id, or "none (one-off)".
```

### 2026-09-14 — Repo bootstrapped; rules R1-R4 seeded
- **What happened:** repo created with the design docs and ADRs (proposed, not yet approved). No app
  code yet. Rules seeded from `../voice-platform/.ai/mistakes.md` where they apply to client work.
- **Root cause:** n/a.
- **Impact:** n/a.
- **Fix:** n/a.
- **Rule:** R1-R4.

### 2026-09-14 — gitlab.linphone.org refused connections; SPM dependency moved to the GitHub mirror
- **What happened:** `xcodebuild -resolvePackageDependencies` failed twice with "Couldn't connect to server" for
  `https://gitlab.linphone.org/BC/public/linphone-sdk-swift-ios.git`, minutes after the same host had served
  tags and tutorial files.
- **Root cause:** the Belledonne GitLab host is intermittently unreachable (rate limiting or outage), and
  it was the only source in `Package.swift`.
- **Impact:** no build until the URL was changed.
- **Fix:** `Package.swift` points at `https://github.com/BelledonneCommunications/linphone-sdk-swift-ios.git`
  (same tags, same `download.linphone.org` binaries; `5.5.21-novideo` resolved and built).
- **Rule:** R5.

### 2026-09-14 — Keychain read failed in the unsigned test host
- **What happened:** with `CODE_SIGNING_ALLOWED=NO` the SoftphoneTests host app logged
  `core start failed: keychain(-34018)` (errSecMissingEntitlement) although the Core had started.
- **Root cause:** an unsigned simulator app has no application-identifier entitlement, so the Keychain
  refuses it; and `CallEngine.start()` had the account load inside the Core `do` block.
- **Impact:** misleading error text; a real Keychain problem would have been reported as an SDK failure.
- **Fix:** Keychain load moved to its own `do/catch` with a warning; `make test` signs normally (simulator
  ad-hoc signing needs no team).
- **Rule:** R6.
