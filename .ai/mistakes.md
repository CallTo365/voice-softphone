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
- R6. Every simulator build is signed (ad hoc, no team needed): an unsigned app cannot use the Keychain,
  and the app then silently behaves differently (fresh instance id, no stored account). Never pass
  `CODE_SIGNING_ALLOWED=NO`.
- R8. Never test wrong credentials against the VM more than once: liblinphone retries a rejected digest
  every few seconds, Kamailio bans the source IP after 10 failures for 5 minutes and drops everything
  silently (the client sees 408), and the office IP is shared with the owner's own tests. Unban early with
  `kamcmd htable.delete ipban <ip>` on the VM. The app now stops registering after the first
  Unauthorized/Forbidden.
- R9. Any linphonesw object whose C counterpart calls back into Swift (Core, LoggingService, Account,
  Call with delegates) must be held in a stored property for as long as callbacks can arrive: the
  wrapper stores unretained Swift pointers in the C objects and callbacks may come from any thread.
- R10. Before handing the owner a platform deploy command, read the deploy recipe in
  `../voice-platform/docs/23-status.md` on *current* `origin/main` — it changed within a day (cluster compose file
  pair, `rsync --delete` export, `--scale control-plane=3` on every `up` that includes control-plane, never `tar -x`
  over the tree). A recipe that worked yesterday is not evidence it works today.
- R7. The liblinphone Core is created with `configPath: nil`. A config file persists accounts, auth info
  (password/ha1) and `verify_server_certs` in plain text and restores them at the next launch; the
  Keychain is the only credential store and `start()` re-applies everything.

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

### 2026-09-14 — liblinphone restored credentials and the trust flag from linphonerc
- **What happened:** after "Sign out" and a relaunch, the app registered by itself before the new account
  was entered, with `verify_server_certs=0` still in effect although the toggle was off; the container's
  `linphonerc` held the account, the auth info and both verify flags.
- **Root cause:** `createCore(configPath: "<dir>/linphonerc")` copied from Belledonne's tutorial; the SDK
  persists everything it is told into that file. Not caught earlier because the first runs were on a
  fresh container.
- **Impact:** credentials in a plain file (S6), and a development-only TLS bypass surviving sign-out (S5).
- **Fix:** `configPath: nil` (documented as "Core will not store any settings"), legacy file deleted at
  start, `make build` signs so the Keychain is the store that actually works.
- **Rule:** R6 amended, R7 new.

### 2026-09-14 — wrong-password tests banned the office IP on the edge; the owner's real registration got 408
- **What happened:** three "wrong password" registration tests from the simulator (to prove the TLS path)
  were enough for Kamailio's `route[AUTH_FAIL]` (10 failed authentications in 5 minutes -> `ipban` 5 min,
  requests dropped without reply). The owner's first attempt with the real password fell in that window
  and timed out (408).
- **Root cause:** I treated one wrong-password attempt as one failure; liblinphone retries the same
  credentials repeatedly ("Authentication is failing constantly, will retry later"), so one attempt is
  several failures, and I did not read the edge's ban rules before testing.
- **Impact:** ~5 minutes of no service for every phone behind the office IP; a misleading first impression
  of the app.
- **Fix:** `CallEngine` disables registration after the first Unauthorized/Forbidden; rule R8.
- **Rule:** R8.

### 2026-09-14 — app crashed at call start: freed LoggingService wrapper dereferenced from the media thread
- **What happened:** two SIGABRTs seconds after placing a call (`LoggingService.__deallocating_deinit`
  via `LoggingServiceDelegateManager` closure #2, called from mediastreamer2 `ms_ticker_run`).
- **Root cause:** `LinphoneWrapper.swift` keeps only an *unretained* pointer to the Swift
  `LoggingService` object in the C object's `swiftRef` user data; `installSDKLogging()` held
  `LoggingService.Instance` in a local, so the Swift object was freed after setup and the next log line
  from a non-main thread (the ticker starting at call time) used a dangling pointer.
- **Impact:** every call crashed the app; registration alone worked, which hid it.
- **Fix:** `CallEngine.sdkLogging` keeps the wrapper alive for the engine's lifetime (as the Linphone
  app does). Rule R9.
- **Rule:** R9.

### 2026-09-15 — P5/P8 deploy command used yesterday's recipe; the VM stack was half-recreated
- **What happened:** the deploy command I gave (`git archive | ssh tar -x`, then `docker compose up -d --build
  --force-recreate <five services>` with the single compose file) made compose recreate postgres/nats and collapse the
  three control-plane replicas; a daemon race on `control-plane-2` aborted it half-way.
- **Root cause:** the platform moved to the cluster compose pair with scaled replicas and an rsync export during the
  night (docs/23 "Deploy ="), and I reused the P1 recipe from the evening before without re-reading that page.
- **Impact:** the test VM stack was partly down until the recovery command; the tree on the VM is a tar superset until
  the rsync export runs.
- **Fix:** recovery = cluster `up -d` with both scale flags; then the documented rsync export + `--no-deps` rebuild.
- **Rule:** R10.
