# Call flows

Normative for the app. Names of platform pieces follow `../voice-platform/docs/02-contracts.md`;
liblinphone names follow the 5.5 Swift wrapper (`linphonesw`). `Edge` = Kamailio + rtpengine,
`CP` = control plane, `FS` = a FreeSWITCH worker driven by the CP over ESL.

## 1. Start-up and registration

```
App start (cold, or woken by push)
  AccountStore.load()                      -- Keychain: identity, ha1/realm, device_id, instance, tokens
  CallEngine.start():
    core = Factory.createCore(configPath, factoryConfigPath, systemContext)
    core.callkitEnabled = true             -- SDK behaves for CallKit (audio session, ringing)
    core.pushNotificationEnabled = true    -- SDK owns PKPushRegistry, fills pushNotificationConfig.voipToken
    core.userAgent = "CallTo/<version>"
    core.config misc/uuid = device instance id (urn:uuid:<device_id>)   -- fixed per install (S3), verify key at build
    account.params:
      identity  sip:1001@acme.sip.local
      server    sip:<edge host>;transport=tls            (host = certificate name, e.g. 91-99-163-145.sslip.io)
      registerEnabled = true, expires = 600
      pushNotificationAllowed = true
      pushNotificationConfig.provider = "apns.dev" (DEBUG) | "apns" (release)
      pushNotificationConfig.teamId = <Team ID>, bundleIdentifier = <bundle id>   -- SDK builds pn-param
    core.addAuthInfo(AuthInfo(username, ha1, realm, domain))
    core.start()

App ──REGISTER (TLS)──────────────────────────────────────────────────────► Edge
    Contact: <sip:1001@10.0.0.5:5061;transport=tls;pn-provider=apns.dev;
              pn-prid=<voip token>;pn-param=<TeamID>.<bundle>.voip>
             ;+sip.instance="<urn:uuid:device_id>";expires=600
App ◄─401 / 200 OK──────────────────────────────────────────────────────── Edge
                                                       Edge ──POST /internal/registrations──► CP (async, existing)
```
The push token is not known at first start (PushKit delivers it asynchronously); the SDK re-REGISTERs
with the `pn-*` parameters once it has one. The CP learns the token through the registration event
*and* through `PATCH /v1/me/devices/{id} {push_token}` from the app (belt and braces: the `devices`
row is what P4 pushes to when the contact is gone).

## 2. Outgoing call

```
User taps a number
  CallKitProvider: CXStartCallAction(handle) via CXCallController
  provider(perform: CXStartCallAction):
    core.configureAudioSession()
    call = core.invite(address)            -- INVITE over TLS, SRTP offered (SAVP)
    action.fulfill(); provider.reportOutgoingCall(startedConnectingAt:)
  didActivate(audioSession): core.activateAudioSession(true)
Edge classifies ingress = user, relays to FS; CP routes (caller id, outbound policy) as for any phone
Call.State .OutgoingRinging -> reportOutgoingCall(connectedAt:) on .StreamsRunning
```

## 3. Incoming call, app in foreground (or connected in background within iOS' grace period)

```
FS ──INVITE──► Edge: lookup("location") finds the live TLS contact ──INVITE──► App
App: Call.State.IncomingReceived -> CallKitProvider.reportNewIncomingCall(uuid, CXCallUpdate(handle))
User answers: provider(perform: CXAnswerCallAction): core.configureAudioSession(); call.accept()
didActivate -> core.activateAudioSession(true) -> 200 OK, SRTP
```
The Edge also triggers a push for this call if the user has other push devices that are not live
(section 5); the same app never receives both an INVITE and a push for the same Call-ID unless its own
socket was dead (then only the push path applies).

## 4. Incoming call, app backgrounded, suspended or killed (PushKit)

```
FS ──INVITE (Call-ID X)──► Edge
Edge: lookup(); contact of this device present but TCP connection dead (or no contact at all)
      ts_store()                                    -- park the transaction (tsilo)
      180 Ringing toward FS                         -- caller hears ringback at once
      POST /internal/push {tenant_domain, user, sip_call_id: X, call_id, instances_live: [...]} (async)
CP:   selects devices of the user with a push token whose instance is not live
      APNs voip push, topic <bundle>.voip, priority 10, expiration now+30 s,
        payload {"aps":{"call-id":"X"}, "callto":{"call_id":"<uuid>","callee":"1001","tenant":"acme"}}
      push_deliveries row per device
iOS wakes the app (or launches it)
SDK:  PKPushRegistry delegate -> linphone_call_new_incoming_with_callid(X) -> Call.State.PushIncomingReceived
App:  CallKitProvider.reportNewIncomingCall(uuid, update: handle "CallTo call")   -- FIRST, S1
      (D8: caller number arrives with the INVITE; then provider.reportCall(with:updated:))
SDK:  refreshes REGISTER over a new TLS connection
Edge: save() ok -> ts_append("location", "$tu") -> the parked INVITE X is relayed to the new contact
App:  Call.State.IncomingReceived for Call-ID X matches the CallKit call; user answers as in section 3
```
Failure branches:
- No REGISTER within the caller's ring time: FS CANCELs (originate timeout from the CP), the Edge
  cancels the stored transaction; the CP posts `/internal/push/cancel {call_id}` -> cancel push
  `{"aps":{"call-id":"X"},"callto":{"type":"cancel"}}`; the app reports the CallKit call ended with
  `.unanswered` (or `.answeredElsewhere` when another device took it).
- Push arrives after the INVITE was already handled (foreground race): the SDK finds the call log for
  X and terminates the ghost call; the app ends the CallKit call it reported. Never skip the report.
- Push arrives, the SDK cannot register (network): report, wait up to 25 s, end with `.failed`.

## 5. Two devices of one user

```
FS ──INVITE X──► Edge: lookup() -> contacts A (iPhone, live TLS) and B (iPad, dead TCP)
Edge: relays branch A; removes/does not create branch B; ts_store(); /internal/push for B only
A rings (INVITE), B rings (push, then INVITE after re-REGISTER via ts_append)
User answers on B: 200 OK from B -> Edge CANCELs branch A -> A gets CANCEL
A: Call.State.End with reason .AnsweredElsewhere (SIP 200 elsewhere) -> reportCall(ended, .answeredElsewhere)
```
Both devices are enrolled separately (own `device_id`, own instance, same SIP identity, D4).
Kamailio `max_contacts` (5) bounds the fan-out; the CP rate-limits pushes per device.

## 6. Move a call to another device / continue here (ADR-0003, P6)

```
Active call C between far end F and device A (leg La). Device B is enrolled and registered (or pushable).

From A: "Move to iPad"  ──POST /v1/calls/C/move {device_id: B}──► CP
From B: "Continue here" ──POST /v1/calls/C/move {device_id: B}──► CP   (same endpoint; B learns about C
                                                                        from live-state: call with to/from.user_id = me, state active on another device)
CP:  authorises (call belongs to the principal's user; device belongs to the same user)
     holds F (uuid_hold, existing park machinery, silent or MOH)
     originates a new leg Lb to sip:1001@acme.sip.local;gr=urn:uuid:<instance of B>   -- GRUU, only B rings
       with X-CallTo-Move: C  and caller id = F's number/name
Edge: lookup() honours ;gr= -> only contact B (push path of section 4 if B is not live)
B:   INVITE with X-CallTo-Move -> reportNewIncomingCall + immediately CXAnswerCallAction (user asked
     for it on B) or, when initiated from A and B is foreground, the same auto-answer; when B is locked
     the user taps Answer on the CallKit screen ("CallTo · continue call")
CP:  on Lb answered: uuid_bridge F <-> Lb; hangs up La with cause NORMAL_CLEARING and header
     X-CallTo-Moved: <device_id B>; emits call.leg.ended (La) / call.leg.started (Lb); one call C in CDR
A:   BYE with X-CallTo-Moved -> shows "Moved to iPad", no missed-call entry
```
Gap for F: hold -> bridge, typically 1-3 s (B foreground) or a CallKit answer on B (locked).
Fallback without P6 (phase 1-3): user taps Hold, walks to the other device, the admin UI/switchboard
shows the parked call; "Continue here" = `retrieve` — but that rings *all* devices of the user, so it
is a demo path only.

## 7. Hold, transfer, DND

- Hold: `CXSetHeldCallAction` -> `POST /v1/calls/{id}/hold|unhold` (S2). Local `call.pause()` is not
  used, so the switchboard sees `call.held` and MOH plays. If the API is unreachable, the action fails
  and the UI says so.
- Blind transfer: `POST /v1/calls/{id}/transfer {to, mode:"blind"}`; attended transfer waits for phase 5+.
- DND: live-state `{"type":"set_dnd","dnd":true}`; the platform's routing skips the user.

## 8. States the UI shows (from CallEngine)

`registration`: `.unregistered | .registering | .registered | .failed(reason)`; with push enabled the
app shows "reachable via push" instead of "offline" when the socket is closed in the background.
`call`: `.idle | .incomingPush | .incoming | .outgoing(.ringing) | .active(muted, held, route) | .ending`.
`device`: `enrolled(tenant, user, device_id)`, `notEnrolled`.
