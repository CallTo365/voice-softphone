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
