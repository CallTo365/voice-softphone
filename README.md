# voice-softphone

First-party CallTo softphone for the [voice-platform](../voice-platform) PBX. iOS first, Swift 6 /
SwiftUI, [linphone-sdk](https://gitlab.linphone.org/BC/public/linphone-sdk) over SIP/TLS + SRTP to the
Kamailio edge, CallKit + PushKit, two devices per user, call continuation between devices.

**Status:** decisions approved 2026-09-14, phase 0 (skeleton, register, foreground calls) in progress. See `docs/04-status.md`.

| Read | For |
|---|---|
| `docs/01-mvp.md` | Scope, architecture, phases, prerequisites, open decisions |
| `docs/02-call-flows.md` | Registration, calls, push wake-up, multi-device, move |
| `docs/03-platform-changes.md` | What `voice-platform` must gain (P1-P7) |
| `docs/adr/` | Decisions: SDK, push model, call move, enrollment |
| `CLAUDE.md`, `.ai/` | Agent instructions, guardrails, mistakes log |

Licence: GPL-3.0-or-later (`LICENSE`). liblinphone is AGPLv3/commercial dual-licensed by Belledonne
Communications; a commercial licence is required before a closed-source or App Store release (ADR-0001).
