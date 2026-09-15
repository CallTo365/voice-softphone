# Softphone MVP: scope, architecture, plan

Status: **decisions D1-D10 approved by the owner on 2026-09-14** (section 9). Phase 0 in progress.

## 1. Goal

A first-party CallTo softphone that behaves like the phone app: calls ring on the lock screen and from
the background, audio routes and CallKit work as users expect, two devices of one user ring together,
and a call can be continued on another device. iOS first, Swift, open source. It uses the same edge as
desk phones (Kamailio SIP/TLS on 5061, SRTP through rtpengine) and the same control plane as the admin
UI, so it needs **no change on FreeSWITCH** and no new media path.

## 2. Relation to the platform design

`../voice-platform/docs/07-clients.md` and ADR-0002 chose *WebRTC over WSS* as the primary client core
for a multi-platform (Flutter) app and explicitly kept native SIP/TLS + SRTP (liblinphone / PJSIP) as a
supported alternative on the same edge. This repo takes that alternative for the iOS MVP because:

- the SIP/TLS + SRTP path exists today and is proven (Bria on iOS registers and takes queue calls on the
  VM); WSS needs Kamailio `websocket`, DTLS on rtpengine and TURN, none of which exist yet;
- liblinphone gives PushKit token handling, RFC 8599 contact parameters, CallKit-aware audio and a
  generated Swift API out of the box (ADR-0001); the WebRTC route would need a SIP stack in Swift;
- media is anchored on rtpengine's public address, so mobile NAT works without ICE/TURN.

The push wake-up design of `07-clients.md` section 2 (park in Kamailio with `tsilo`, control plane
sends the push, deliver on re-REGISTER) is kept as written, with the concrete Kamailio mechanism in
`docs/03-platform-changes.md`. Contract section 7 (`devices`, `push_deliveries`, `/v1/auth/device`,
`/internal/push`) is the API this app targets; the deltas the app needs are listed in `03`.

## 3. Stack

| Layer | Choice | Notes |
|---|---|---|
| Language / UI | Swift 6, SwiftUI, iOS 17+ | Xcode 26.6 on the owner's Mac; iOS 17 covers iPhone XS and later |
| Project | `xcodegen` (`project.yml` in git, `.xcodeproj` generated) | Reviewable diffs, no merge conflicts in pbxproj |
| SIP / media | **linphone-sdk 5.5.21** via SPM, product `linphonesw`, `-novideo` variant | `https://gitlab.linphone.org/BC/public/linphone-sdk-swift-ios.git` (GitHub mirror `BelledonneCommunications/linphone-sdk-swift-ios`), iOS 13+. Pin the exact tag |
| Telephony UI | CallKit (`CXProvider` owned by the app), PushKit (`PKPushRegistry` owned by the SDK) | See ADR-0001 for the split |
| Platform API | control plane `/v1` REST + `live-state` WebSocket | `../voice-platform/docs/02-contracts.md` sections 7, 10 |
| Storage | Keychain (credentials, instance id), SwiftData or files for recents cache | No SIP password ever typed by the user in production builds |
| Licence | GPL-3.0 (app) on top of AGPLv3 liblinphone; commercial Belledonne licence before App Store release | ADR-0001 |

## 4. App architecture

```
apps/ios/Softphone (SwiftUI)                 packages/SoftphoneKit (no UI)
┌─────────────────────────────┐              ┌──────────────────────────────────────────┐
│ Screens: Enroll, Dialer,    │  observes    │ CallEngine (@MainActor)                   │
│ Call, Recents, Contacts,    │◄────────────►│   wraps linphone Core, Account, Call      │
│ Devices/Settings            │              │   state machine: Idle→Ringing→Active→...  │
├─────────────────────────────┤              ├──────────────────────────────────────────┤
│ CallKitProvider             │◄────────────►│ PlatformAPI: /v1/auth/device, /v1/me,     │
│   CXProvider + CXCallController            │   /v1/calls/{id}/hold|park|transfer|move, │
│   audio session ownership   │              │   /v1/me/devices, live-state WS           │
├─────────────────────────────┤              ├──────────────────────────────────────────┤
│ AppLifecycle (scene phases, │              │ AccountStore (Keychain), Diagnostics      │
│ background/foreground)      │              │ (os.Logger + redaction, log bundle export) │
└─────────────────────────────┘              └──────────────────────────────────────────┘
          │ CallKit / PushKit                              │ SIP/TLS 5061, SRTP
          ▼                                                ▼
        iOS                                     Kamailio edge  ──  control plane /v1
```

- **CallEngine** owns the single liblinphone `Core` (auto-iterate, main thread). It exposes an
  observable model (`registration`, `calls[]`, `audioRoute`, `pushState`) and intents (`call(to:)`,
  `accept`, `decline`, `hangup`, `mute`, `dtmf`, `hold` -> API, `move(to:)` -> API).
- **CallKitProvider** maps CallKit actions to engine intents and engine events to CallKit reports. It is
  the only place that touches `AVAudioSession` (S4). Every `PushIncomingReceived` becomes
  `reportNewIncomingCall` first (S1).
- **PlatformAPI** is a thin, typed client. Auth = device token from enrollment (ADR-0004). The live-state
  socket is used for: own calls (for the move/pull banner), DND, and later presence.
- **AccountStore** keeps SIP identity, credentials, device id, `+sip.instance`, device token, push token
  in the Keychain (S6). The liblinphone config file (`linphonerc`) is written from these values at start;
  it must not become the source of truth.

Threading rule: everything that touches `Core` is `@MainActor`; API calls are `async` and hop back.

## 5. Feature scope

**In the MVP**
- Enrollment with a code/QR from the admin UI (no SIP password typed), Keychain storage, re-enrollment.
- REGISTER over TLS with `+sip.instance` and push parameters; registration state in the UI.
- Outgoing calls (dialer, recents, contacts) through CallKit (`CXStartCallAction`), caller id as set on
  the platform (identity numbers / departments already handle this server-side).
- Incoming calls in foreground (INVITE first) and background/locked/killed (PushKit first, INVITE after
  re-REGISTER), CallKit native UI, answered-elsewhere handling.
- In-call: mute, speaker/Bluetooth via CallKit routes, DTMF, hold (API), blind transfer (API), move to /
  pull from another device (API, ADR-0003).
- Two devices per user ringing together (Kamailio parallel forking, already the platform behaviour).
- Recents from the CDR API scoped to the user; tenant directory as contacts (read-only).
- DND toggle (live-state `set_dnd`).
- Diagnostics: registration/call log export with redaction; SIP Call-ID shown for support.

**Out of the MVP** (later phases or never): video, chat/SMS, conference, call recording control,
presence display of colleagues, Android, macOS (the package is written so a macOS target can be added:
liblinphone ships a macOS package and CallKit exists on macOS 13+), Entra sign-in (phase 5),
call quality telemetry upload (contract roadmap), CarPlay, watch.

## 6. Phases and exit criteria

Every phase ends with a real call on a real iPhone against the VM and a line in `docs/04-status.md`.

| Phase | Deliverable | Exit criterion (verified on the VM) | Needs from platform |
|---|---|---|---|
| **0 Skeleton** | `project.yml`, `SoftphoneKit` with `linphonesw`, dev-only account screen, register over TLS, audio call foreground only (no CallKit) | 1001 (app) <-> 1002 (Bria) and app <-> PSTN via MOR with two-way audio, SRTP shown in Homer | P1 (trusted TLS cert), P2 (firewall for mobile networks) |
| **1 CallKit** | `CallKitProvider`, in-call screen, lock-screen answer, audio routes, mute/DTMF, hold via API | Inbound and outbound calls through CallKit, answer from lock screen with the app in foreground/recently backgrounded; hold visible in the admin UI timeline | none |
| **2 Push** | SDK push enabled, `pn-*` params on REGISTER, `PushIncomingReceived` -> CallKit, cancel handling, killed-app wake-up | Phone locked for 30 min, app killed: inbound call rings via push within 3 s, answered with audio; caller hangs up before answer -> CallKit UI dismissed | P3 (tsilo + push trigger in Kamailio), P4 (APNs sender, `/internal/push`, cancel) |
| **3 Enrollment + devices** | Enrollment code/QR, `/v1/auth/device`, device token for the API, Devices screen, re-enroll/revoke | Fresh install enrolled from the user sheet in the admin UI without typing a SIP password; revoke from the UI unregisters the phone | P5 (`/v1/auth/device`, device endpoints, user-sheet Devices tab) |
| **4 Multi-device + move** | Second device, answered-elsewhere, "Move to ..." and "Continue here" | iPhone + iPad ring together; answer on one dismisses the other; active call moved iPhone -> iPad and pulled back, far end hears at most a short gap, CDR shows one call | P6 (GRUU + `/v1/calls/{id}/move`) |
| **5 Rounding** | Recents, directory contacts, DND, diagnostics export, TestFlight build, Entra sign-in (optional) | TestFlight build used by the owner as daily phone for a week | P7 (user-scoped CDR list if missing) |

Phase 0-1 can start immediately; phases 2-4 wait for the platform items, which can be built in parallel
in `voice-platform` (see `docs/03-platform-changes.md`).

## 7. Apple prerequisites (owner)

1. Apple Developer Program membership for the company (Team ID). Individual accounts cannot ship a
   business VoIP app under the company name.
2. App ID (bundle id, decision D2) with capabilities **Push Notifications** and **Background Modes:
   Voice over IP, Audio**. CallKit needs no capability. Note: CallKit apps are not available on the China
   App Store (irrelevant for now).
3. **APNs Auth Key (.p8)** from the developer portal: Key ID + Team ID + the key file go into the
   platform VM `.env` (`APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_KEY_P8_BASE64`). One key serves sandbox
   (`api.sandbox.push.apple.com`, debug builds, `pn-provider=apns.dev`) and production
   (`api.push.apple.com`, `pn-provider=apns`). Topic is `<bundle id>.voip`, header `apns-push-type: voip`.
4. Two test devices (iPhone + iPad or second iPhone) registered in the portal; automatic signing in Xcode.
5. For TestFlight (phase 5): App Store Connect record, privacy manifest (`PrivacyInfo.xcprivacy`),
   export compliance answer (TLS/SRTP are standard-protocol exempt; confirm at submission).
6. Before public App Store release: a commercial liblinphone licence from Belledonne, or an explicit
   decision to ship under GPL-3.0 and accept the App Store/GPL ambiguity (ADR-0001).

## 8. Platform prerequisites (summary; details in `docs/03-platform-changes.md`)

| Id | Item | Phase |
|---|---|---|
| P1 | Kamailio 5061 serves a certificate iOS trusts (mount Caddy's Let's Encrypt cert for `91-99-163-145.sslip.io`; later a real `sip.` hostname) | 0 |
| P2 | Firewall: 5061/tcp and the RTP range reachable from mobile networks, not only the office IP; pike + fail2ban stay | 0 |
| P3 | Kamailio: `tsilo` park, dead-connection detection (`tcpops` / `$ulc(conid)`), async push trigger with the SIP Call-ID, `ts_append` on REGISTER | 2 |
| P4 | Control plane: APNs sender (token auth, HTTP/2, stdlib), `/internal/push` + `/internal/push/cancel`, `push_deliveries`, rate limit | 2 |
| P5 | Control plane + admin UI: `/v1/auth/device` with enrollment codes, device endpoints, device-token auth (control plane + live-state), user sheet "Devices" tab with QR | 3 |
| P6 | Kamailio `gruu_enabled=1`; control plane `POST /v1/calls/{id}/move {device_id}` (park + originate to GRUU + bridge), `X-CallTo-Move` header, cancel push on move | 4 |
| P7 | User-scoped CDR list for recents (`GET /v1/me/calls` or a filter on the tenant list) if not already covered by the OIDC `user` role | 5 |

## 9. Decisions (all recommendations approved by the owner, 2026-09-14)

| Id | Question | Decision |
|---|---|---|
| D1 | SIP stack | **liblinphone 5.5.21** (ADR-0001). PJSIP only if we want to avoid AGPL and accept building CallKit/PushKit/audio glue ourselves |
| D2 | Names | Repo `voice-softphone` (this), app name "CallTo", bundle id `com.callto365.softphone`, GitHub `CallTo365/voice-softphone` **public** (open source at first). Licence file GPL-3.0 |
| D3 | Platform floor | iOS 17+, iPhone and iPad (same layout), no macOS target in the MVP |
| D4 | Credential model (ADR-0004) | MVP: one SIP identity per user, the enrolled device receives the user's `ha1` + realm (the platform stores no plaintext); revocation = rotate the user's SIP secret and re-provision remaining devices. v1: per-device subscriber rows as `07-clients.md` section 4 already plans |
| D5 | Enrollment (ADR-0004) | Enrollment code / QR generated in the admin UI user sheet (10-minute validity, single use) for the MVP; Entra sign-in in phase 5 once a public-client app registration exists |
| D6 | Call continuation (ADR-0003) | `POST /v1/calls/{id}/move {device_id}` built on park/retrieve with GRUU targeting; both "Move to ..." (from the active device) and "Continue here" (from the other device, same endpoint, target = self) |
| D7 | What "two softphones" means | **Two devices, one user** (owner, 2026-09-14): two installed apps (or app + Bria/desk phone) on one user, all ringing together, first answer wins |
| D8 | Push payload (S8) | Minimal: `aps.call-id` (SIP Call-ID), platform `call_id`, `callee`, `tenant`; caller number/name **not** in the push, taken from the INVITE (arrives < 2 s later) and shown via `CXCallUpdate`. Faster first paint if we include the caller number; that sends PII to Apple |
| D9 | Codecs | Opus (preferred) + PCMA, 20 ms, DTX on; FreeSWITCH transcodes toward PSTN as today. Confirm opus is enabled on the worker profile |
| D10 | Test VM exposure | Open 5061/tcp + RTP to the internet on `voice-mvp-fw` for mobile-network tests (P2) |

Added 2026-09-15 (docs/05, caller-ID selection) — **open**:

| Id | Question | Recommendation |
|---|---|---|
| D11 | How the chosen caller ID reaches the call | Per call: `P-Preferred-Identity` on the INVITE, validated by the router (platform P8); not the user-wide active selection |
| D12 | API access for the app | Build P5 (enrollment code -> device token) now; no throwaway API-key path |
| D13 | Choice not allowed | Fall back to the normal resolution + timeline entry `caller_id_override_rejected`; the app clears its stored choice |

## 10. Risks and how the plan handles them

- **Push privilege loss** (Apple kills apps that receive a VoIP push and do not report a call): S1, the
  SDK's `PushIncomingReceived` state, and the platform never pushing without a parked INVITE (`07-clients`
  guardrail). Late pushes are bounded with `apns-expiration` = now + 30 s.
- **Dead TLS sockets after backgrounding**: usrloc is DB-only on the platform, so `handle_lost_tcp` is
  unavailable; P3 detects dead connections with `tcpops` and pushes instead of relaying (03 section 2).
- **Licensing**: AGPLv3 today; a commercial licence is a line item before App Store release.
- **Two codebases later** (Android/desktop): accepted for the MVP; `SoftphoneKit` isolates what would be
  rewritten. The WebRTC/Flutter path of ADR-0002 remains open for the browser softphone.
- **Certificate on the test VM**: sslip.io hostnames get Let's Encrypt certificates (Caddy already has
  one), so P1 is a volume mount, not new infrastructure.
- **Mobile networks blocked by the VM firewall** (D10): decide before phase 0 testing on 4G/5G.
