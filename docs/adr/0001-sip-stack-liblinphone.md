# ADR-0001: SIP stack is liblinphone (linphone-sdk 5.5.x) over SIP/TLS + SRTP; CallKit owned by the app, PushKit by the SDK

- **Status:** proposed
- **Date:** 2026-09-14
- **Deciders:** Hugo (owner)

## Context
The MVP needs a native iOS softphone in Swift with CallKit, background calling via PushKit, SRTP, and
two devices per user, against the existing Kamailio edge (5061/TLS live, WebSocket not enabled). The
owner prefers liblinphone and asked whether anything is better. Open source at first.

Options looked at on 2026-09-14:

| Option | Licence | Push/CallKit | Swift | Fit with our edge | Verdict |
|---|---|---|---|---|---|
| **liblinphone / linphone-sdk 5.5.21** (SPM `linphonesw`, iOS 13+) | AGPLv3 (GPLv3 terms for a client) or commercial | SDK owns `PKPushRegistry`, adds RFC 8599 `pn-*` params, raises `Call.State.PushIncomingReceived`; CallKit glue is the app's `CXProvider` + `core.configureAudioSession()/activateAudioSession()` | generated wrapper | SIP/TLS + SRTP works today | **chosen** |
| PJSIP 2.16 (pjsua2) | GPLv2+ or commercial | none built in: PushKit, CallKit, audio session, pn params are app code; the Swift sample has no push | C++ via ObjC++ bridge, build from source for iOS | same edge | solid stack, more glue to write and own; no advantage here |
| WebRTC over WSS (07-clients / ADR-0002 primary) | BSD (libwebrtc) | app code; needs a SIP stack in Swift (none mature) | no SIP UA | needs Kamailio `websocket`, DTLS, TURN | right for the browser softphone, wrong for a native MVP |
| baresip / libre | BSD-3 | none; iOS community-level | C | same edge | permissive licence, immature on iOS |
| Commercial SDKs (Acrobits, Siprix, Mizu) | proprietary, per seat | included | yes | same edge | contradicts "open source at first"; can be revisited if licensing liblinphone is unattractive |
| CPaaS SDKs (Twilio, Telnyx, LiveKit) | proprietary | included | yes | replace our edge | no |

## Decision
Use linphone-sdk 5.5.21 (`-novideo`), pinned, via Swift Package Manager. Transport SIP/TLS to
Kamailio 5061, SRTP (SAVP) through rtpengine, opus + PCMA. The SDK is configured with
`callkitEnabled = true` and `pushNotificationEnabled = true`; the app owns the `CXProvider` and the
audio session hand-over exactly as in Belledonne's CallKit tutorial. Licence: the app is GPL-3.0 open
source; a commercial licence from Belledonne is a prerequisite for a closed-source or App Store release
(the FSF and Belledonne both treat GPL on the App Store as problematic; TestFlight/internal use is fine).

## Consequences
- Two native codebases later (Android with the same SDK in Kotlin); the WebRTC path of ADR-0002 stays
  for the browser client. `SoftphoneKit` isolates the SDK behind `CallEngine`.
- The platform must trigger pushes with the SIP Call-ID in `aps.call-id` (docs/03 P3/P4); liblinphone's
  contact parameter format (`pn-prid=<voip token>`, `pn-param=<TeamID>.<bundle>.voip`) is what
  Kamailio will store.
- No ICE/TURN needed: rtpengine anchors media on a public address.
- CallKit is disabled by the SDK on the simulator: real devices for phases 1+.

## Alternatives considered
See the table: PJSIP (more glue, same licence class), WebRTC (needs edge work and a Swift SIP stack),
baresip (iOS immaturity), commercial SDKs (not open source), CPaaS (replaces the platform).
