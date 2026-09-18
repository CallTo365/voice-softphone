# CallKit (phase 1)

Status: **built 2026-09-18**, verified on the owner's iPhone the same day in both directions (incoming: platform
originate to 1001 rang the native screen, answered, two-way audio; outgoing from the dialer through the start
action; the diagnostics export shows the audio-session hand-over for both — docs/04). ADR-0001 fixed the model (the app owns
`CXProvider`, the SDK owns `PKPushRegistry`); this page is how the app implements it and the decisions taken
while doing so (ADR-0005). Push (phase 2) plugs into the same bridge.

## 1. Pieces

| Piece | File | Role |
|---|---|---|
| `CallKitBridge` | `packages/SoftphoneKit/…/CallKitBridge.swift` | The `CXProvider` + `CXCallController`. Requests (start, answer, end, mute) from the UI, actions from CallKit to the engine, reports from the engine to CallKit. The only code that touches the audio session, through the SDK (S4). |
| `CallEngine.callKit` | `CallEngine.swift` | Set by `AppSession` before `start()`, so the Core is created with `callkitEnabled = true`; the engine reports every call state to the bridge and takes `configureAudioSession()` / `audioSessionActivated()` from it. |
| `AppSession` intents | `AppSession.swift` | `placeCall`, `answer`, `endCall`, `toggleMute`: through the bridge on a device, straight to the engine on the simulator. `holdForCallKit` maps CallKit's hold to the platform hold. |
| `ActiveCall.uuid` | `CallModels.swift` | CallKit's id: generated for inbound calls, given by the `CXStartCallAction` for outbound ones. |
| Recents callback | `RootView.swift`, `Info.plist NSUserActivityTypes` | `includesCallsInRecents` puts our calls in the Phone app; a tap comes back as `INStartCallIntent` and dials through the same path. |

## 2. Flows as built

**Outgoing** (docs/02 §2): dialer → `AppSession.placeCall` → `CallKitBridge.startCall` keeps the P-Preferred-Identity
per uuid and requests `CXStartCallAction(handle)` → CallKit performs it → `engine.configureAudioSession()` →
`engine.placeCall(to:preferredIdentity:callKitUUID:)` → `action.fulfill()`. `OutgoingProgress` →
`reportOutgoingCall(startedConnectingAt:)`, `Connected/StreamsRunning` → `reportOutgoingCall(connectedAt:)`,
`didActivate` → `activateAudioSession(true)`. A refused invite (not registered, bad number, busy) fails the
action and the engine's `lastError` says why.

**Incoming** (docs/02 §3): `IncomingReceived` → the engine builds the `ActiveCall` and calls
`reportNewIncomingCall` at once (the same rule S1 applies to pushes in phase 2). CallKit's Answer (lock screen,
banner or our button, which requests `CXAnswerCallAction`) → `configureAudioSession()` → `accept()` → fulfill →
`didActivate` → audio. CallKit's decline / our Decline → `CXEndCallAction` → `decline()` (ringing) or
`terminate()` (live). If CallKit refuses the report (a Focus filter) the engine declines **busy** so the platform's
busy handling (forwarding, voicemail) runs instead of ringing a phone that shows nothing.

**End reasons**: a call ended by our own `CXEndCallAction` is not reported again; everything else is
`reportCall(endedAt:reason:)` from the SDK's call log: `AcceptedElsewhere` → `.answeredElsewhere` (the user's other
device took it: parallel forking), `DeclinedElsewhere` → `.declinedElsewhere`, `Missed` → `.unanswered`, an
outgoing 4xx/5xx other than busy/decline → `.failed`, the rest `.remoteEnded`.

**Mute / DTMF / speaker**: mute goes through `CXSetMutedCallAction` so the native screen and ours agree; DTMF from
our keypad goes straight to the SDK (the `CXPlayDTMFCallAction` path serves Siri and the system); speaker stays
the SDK's `outputAudioDevice` switch, not an audio-session call.

**Hold**: CallKit asks for a hold when the user answers a cellular call on top of ours (`CXSetHeldCallAction`).
The bridge asks `AppSession.holdForCallKit`, which is the **platform hold** (`/v1/calls/{id}/hold`), so the far end
hears music and the switchboard sees `call.held` (S2); a plain SDK pause would leave the platform blind. No
platform call id yet, or a failed request → the action fails and CallKit ends the call. `didDeactivate` stops the
streams either way.

## 3. Threading (R12)

`setDelegate(self, queue: nil)` delivers every provider callback on the main queue; the conformance is
`@preconcurrency CXProviderDelegate` with `@MainActor` methods (SE-0423: a runtime isolation check at entry instead
of `assumeIsolated` boilerplate). Request and report completions are `@Sendable` and hop to the main actor
through a static, like the engine's SDK closures.

## 4. Simulator

`CallKitBridge.isSupported` is false on the simulator: the SDK disables CallKit there (ADR-0001, S14) and the
audio session callbacks never come. The session then drives the engine directly, exactly as phase 0, so the
simulator remains the place for registration and media checks; CallKit evidence is real-device only.

## 5. Decisions (ADR-0005)

| Id | Question | Decision |
|---|---|---|
| D1 | CallKit hold = SDK pause or platform hold? | **Platform hold** (S2): the switchboard and the far end see the same thing as the Hold button. |
| D2 | CallKit refuses an incoming report (Focus) | Decline **busy**, never let it ring unseen; the platform's busy handling takes over. |
| D3 | Our own in-call buttons | Always through `CXTransaction`s on a device; the engine acts only on CallKit's `perform`. |
| D4 | Recents | `includesCallsInRecents = true` with the `INStartCallIntent` callback wired; numbers are `.phoneNumber` handles (Contacts matching), extensions with `*`/`#` or letters `.generic`. |
| D5 | Simulator | Direct engine path, no provider (S14). |

## 6. Not in this phase

- Bluetooth / route picker in our own screen (the native CallKit screen has it; an `AVRoutePickerView` in ours is
  a small follow-up).
- A provider icon (`iconTemplateImageData`) for the native screen.
- Push (phase 2): `PushIncomingReceived` → the same `reportIncoming`, cancel handling, killed-app wake-up.
- Call waiting: a second incoming call is still busy-declined by the engine.
