# ADR-0005: CallKit phase 1 — every device intent is a CXTransaction, CallKit's hold is the platform hold, refused reports decline busy

- **Status:** accepted (owner, 2026-09-18: incoming verified on the owner's iPhone the same day)
- **Date:** 2026-09-18
- **Deciders:** Hugo (owner)

## Context
ADR-0001 fixed the model (the app owns `CXProvider`, the SDK owns `PKPushRegistry`, audio session hand-over
through `configureAudioSession()` / `activateAudioSession()`). Building it raised three choices the model did
not settle: what a CallKit-initiated hold means for a platform that owns hold (S2), what to do when CallKit
refuses to show an incoming call, and whether the app's own in-call buttons may bypass CallKit.

## Decision
1. On a device every user intent (start, answer, end, mute) is a `CXTransaction`; the engine acts only when
   CallKit performs the action, so the native screen, the lock screen and the app never disagree. DTMF from
   our keypad and the speaker switch stay SDK calls (no audio-session access, S4).
2. `CXSetHeldCallAction` (a cellular call answered on top of ours) is the **platform hold**
   (`/v1/calls/{id}/hold`), not an SDK pause: the far end hears music and switchboards see `call.held`, as with
   the Hold button. Without a platform call id or on a failed request the action fails and CallKit ends the call.
3. A refused `reportNewIncomingCall` (Focus / Do Not Disturb, unsupported handle) declines the INVITE **busy**:
   the platform's busy handling (forwarding, voicemail) runs instead of a phone ringing with nothing on screen.
4. End reasons come from the SDK's call log (`AcceptedElsewhere` → answered elsewhere for the user's other
   device, `Missed` → unanswered, outgoing 4xx/5xx → failed), and a call ended by our own end action is not
   reported a second time.
5. `includesCallsInRecents` is on and the `INStartCallIntent` callback dials through the same path; the
   simulator keeps the direct engine path because the SDK disables CallKit there (S14).

## Consequences
- `CallEngine` reports every state to the bridge and exposes `configureAudioSession` / `audioSessionActivated`
  for it; `ActiveCall` carries CallKit's uuid.
- Phase 2 (push) plugs `PushIncomingReceived` into the same `reportIncoming`; nothing else changes.
- A hold forced by iOS depends on the platform call id having arrived (the INVITE for inbound, the 18x/200 for
  outbound); a hold in the first second of an outbound call can fail. Accepted for the MVP.

## Alternatives considered
- SDK `pause()` for CallKit holds: simpler and always available, but invisible to the platform (breaks S2).
- Bypassing CallKit for the in-app buttons: fewer round trips, but the native UI drifts (mute state, ended calls
  lingering on the lock screen).
- Declining refused reports with `Declined`: ends parallel forking for the user's other devices too early;
  busy lets the platform decide.
