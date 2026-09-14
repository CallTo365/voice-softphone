# ADR-0003: Continue a call on another device = control-plane "move" to a specific device via GRUU

- **Status:** accepted (owner, 2026-09-14)
- **Date:** 2026-09-14
- **Deciders:** Hugo (owner)

## Context
The owner wants a user to continue an active call on another of their devices. The platform already
has hold, park and retrieve, but retrieve rings every device of the user, and SIP-level tricks (REFER
from the phone) would route around the control plane (platform guardrail G1/G4).

## Decision
One endpoint, `POST /v1/calls/{id}/move {device_id}`, usable from the active device ("Move to
iPad") and from the other device ("Continue here", target = self). The control plane holds the far
end, originates a new leg to the target device's GRUU (`sip:<ext>@<domain>;gr=urn:uuid:<instance>`,
Kamailio `gruu_enabled=1`) with `X-CallTo-Move: <call_id>`, bridges on answer and hangs up the old leg
with `X-CallTo-Moved: <device_id>`. The target app auto-answers when it is in the foreground (the user
asked for it), otherwise the CallKit screen shows "continue call". The CDR keeps one call; the timeline
shows the move. Live-state tells the other device that a call of its user is active elsewhere, which
is what enables the "Continue here" banner.

## Consequences
- Platform: GRUU on, a new call-control endpoint reusing park/retrieve internals, two private
  headers, timeline entries, cancel-push on move timeout. App: a device list with online state, a
  banner, auto-answer keyed on the header (never on caller id).
- Push path (ADR-0002) applies unchanged when the target is backgrounded.
- Until the endpoint exists, hold + walk + park/retrieve is a demo-only fallback (rings all devices).

## Alternatives considered
- Phone-initiated REFER to the other device's GRUU: bypasses control-plane routing and CDR semantics.
- Shared line appearance (SIP dialog event package): far more signalling, no benefit for two devices.
- Apple Handoff: not applicable to VoIP media sessions.
- Per-device SIP identities and a transfer to the other identity: needs the per-device credential
  model first (ADR-0004 v1); the GRUU form works with shared credentials today.
