# In-call controls: hold and on-demand recording

Built 2026-09-16 (app `main`, platform branch `softphone/call-id-header-and-user-recording`).

Both actions change platform state, so they go through the control plane (guardrail S2), never through SIP
from the phone: hold = `POST /v1/calls/{id}/hold|unhold` (the far end hears music, switchboards see
`call.held`), recording = `POST /v1/calls/{id}/record {action}` (the platform's recorder; the seat must carry
the recording feature). Mute stays local.

## The call id

The app needs the platform's `call_id`, not the SIP Call-ID. The platform stamps `X-Call-ID-Platform`:
- inbound: as a header on the INVITE it originates toward the phone (already the case, contract §3);
- outbound: since 2026-09-16 the control plane runs `multiset sip_ph_X-Call-ID-Platform=<id>
  sip_rh_X-Call-ID-Platform=<id>` on every user A-leg before routing continues, so the 18x and the 200 OK
  toward the phone carry it (mod_sofia 1.10.12 emits `sip_ph_*` on 180/183 and `sip_rh_*` on the 200 OK).

`CallEngine` reads it from `Call.remoteParams.getCustomHeader("X-Call-ID-Platform")` at
`IncomingReceived`, `OutgoingRinging/EarlyMedia` and `Connected/StreamsRunning`, into
`ActiveCall.platformCallID`. Until it is known the two buttons are disabled.

## Behaviour

- **Hold** toggles `heldByMe`; the status line shows "on hold". Platform hold does not pause the SDK call
  (the phone keeps its media session; the far end is parked on music), so CallKit's hold action (phase 1)
  maps onto the same API call.
- **Record** toggles `recording` (red when on); the status line shows "● recording". A `402/403`
  (`feature_not_licensed`) is shown as "Recording is not included in your seat."
- Failures (network, `not_found` when the platform has not registered the call yet) are shown under the
  buttons and cleared on the next success or tap.

## Platform changes (contract §3, §12.8)

- `esl.Session.run`: the `multiset` stamp for `IngressUser` legs (not for hangup decisions).
- `POST /v1/calls/{id}/record`: accepted from the `user` on the call (loadCall's party check), not only
  operators and API keys; the recording-feature check is unchanged.
