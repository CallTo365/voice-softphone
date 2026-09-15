# Outbound caller-ID selection in the app

Status: **proposed 2026-09-15**, decisions D11-D13 open (docs/01 section 9).

## 1. What the user gets

A compact control on the dialer, under the number: **From: +31 85 666 2750 ▾** (or "Default caller ID"
until the user ever chose one). Tapping it opens a sheet listing what this user may present, the
platform's default marked, "Anonymous" when allowed, one checkmark for the current choice. The choice
is remembered on the device (per user); every outbound call carries it. Selecting an entry never calls
the API and never changes what other devices of the user present (D11).

Nothing is fetched when the dialer appears (the owner's requirement). The list is loaded when the
sheet opens: a spinner on the first open, then the items; the next opens show the cached list at once
and refresh it in the background when it is older than 5 minutes. Pull-to-refresh forces a reload.
If the platform later rejects a choice (number no longer presentable), the app clears the stored choice
and says so once.

## 2. Where the data comes from (existing platform API, contract §15 / docs/22)

`GET /v1/tenants/{t}/users/{u}/caller-ids` ->
`{items:[{number, label, source: department|inherited|tenant|own|anonymous, department_id}],
  active_caller_id, active_caller_id_until, default:{number, layer, anonymous}}`

Cache: in memory in `CallerIDStore` (SoftphoneKit), keyed by `user_id`, with `fetched_at`; the chosen
number in `UserDefaults` (`callerId.<user_id>`; it is not a secret). Invalidation: TTL 5 min,
pull-to-refresh, a `422 caller_id_not_allowed`/timeline rejection, and later (phase 5) the live-state
event `user.caller_id.changed`.

## 3. How the choice reaches the call (D11)

**Recommended — per call, on the INVITE:** the app adds `P-Preferred-Identity:
<sip:+31856662750@acme.sip.local>` (RFC 3325; `sip:anonymous@anonymous.invalid` for anonymous) with
`CallParams.addCustomHeader` (verified in the 5.5.21 wrapper). Kamailio already forwards user headers
to FreeSWITCH; the control plane reads `sip_h_P-Preferred-Identity` on **user ingress only** and feeds
it into the existing `RouteInput.CallerIDPerCall`, which the router already validates against the
allowed set. This is platform item **P8** (below): ~20 lines of Go, a contract line, an ADR.

Alternative with zero platform work: the sheet writes the user-wide *active selection*
(`PUT .../caller-id {number}`), which the admin UI already shows and which every device of the user
follows. Simpler, but choosing on the iPhone silently changes the desk phone, and each change is an
API round-trip.

Both can coexist later (long-press "Make my default" -> `PUT`), but the MVP ships one.

## 4. Not allowed (D13)

When the per-call choice is not in the allowed set (stale list, revoked number): the router falls back
to the normal resolution (active selection -> default) and writes a timeline entry
`caller_id_override_rejected {requested, presented}`; the call proceeds. Alternative: reject with
`403 caller_id_not_allowed` and let the app show it — stricter, but a stale list then blocks calls.

## 5. Authentication (D12)

The app has no API access yet. The designed path is phase 3 / platform P5: enrollment code from the
user sheet -> `POST /v1/auth/device` -> device token accepted by the control plane as principal
`{kind: device, user_id, tenant_id}`; `GET /v1/me` then gives the tenant and user ids the caller-ID
endpoint needs. Recommendation: build P5 now (it is the first API-backed feature; recents, contacts
and call move all need it). Interim alternative: a DEBUG-only tenant API key field on the dev screen
plus a user lookup by extension — throwaway code, not recommended.

## 6. Work

| Where | Item |
|---|---|
| voice-platform (P8) | `readChannel`: on user ingress set `CallerIDOverride` from `sip_h_P-Preferred-Identity` (user part; `anonymous`); router fallback + timeline entry per D13; contract §15 line; ADR. Kamailio: strip `P-Preferred-Identity`/`P-Asserted-Identity` on *non-user* ingress paths that do not already (check) |
| voice-platform (P5) | enrollment codes, `/v1/auth/device`, device-token principal (control plane + live-state), `/v1/me`, `/v1/me/devices`, user sheet "Devices" tab with QR |
| app | `PlatformAPI` (device token, `/v1/me`, caller-ids), `CallerIDStore` (lazy fetch, TTL, choice persistence), dialer control + sheet, `P-Preferred-Identity` on `placeCall`, enrollment screen replacing the dev screen in release builds |

Verification: call with a chosen department number -> the far end (Hugo's mobile via MOR) shows it and
`calls.presented_caller_id` matches; choose a number, revoke it in the admin UI, call again -> fallback
+ timeline entry, app clears the choice; open the sheet twice -> one request in the API log.
