# ADR-0004: Devices enroll with a single-use code from the admin UI; MVP shares the user's SIP secret (ha1) across devices, per-device credentials in v1

- **Status:** accepted (owner, 2026-09-14)
- **Date:** 2026-09-14
- **Deciders:** Hugo (owner)

## Context
`07-clients.md` section 5 says the app never asks for a SIP password and exchanges an OIDC token for
device credentials (`POST /v1/auth/device {id_token}`). The platform stores only `ha1`/`ha1b` for
subscribers (no plaintext), the Entra public-client app registration for a mobile app does not exist
yet, and the MVP needs something an admin can do from the user sheet today.

## Decision
- MVP: the admin generates an enrollment code (QR + text, 10 minutes, single use) in the user sheet;
  the app posts it with its platform, app id, device name and `+sip.instance` to `/v1/auth/device`
  and receives a device-scoped API token plus the SIP identity, `ha1`, realm and server. liblinphone
  authenticates with `ha1` directly (`AuthInfo(ha1:realm:)`), so no password exists on the device.
  Everything lands in the Keychain (S6).
- All devices of a user share the user's SIP identity and `ha1`, distinguished by `+sip.instance`
  (contract §7.4 "MVP" model). Revoking a device deletes its API token and contact; if the secret must
  be considered compromised the admin rotates the user's SIP secret, which re-enrolls all devices.
- v1 (not now): per-device subscriber rows (`1001.<device_id>`) with Kamailio AoR rewrite, as
  `07-clients.md` section 4 plans, giving per-device revocation without rotation.
- Phase 5: Entra sign-in in the app (ASWebAuthenticationSession, PKCE) as a second way to obtain an
  enrollment, when the public-client app registration exists.

## Consequences
- Platform: `device_enrollments` and `device_tokens` tables, `/v1/auth/device` (code variant),
  `/v1/me/devices*`, device principal in the control plane and `live-state`, user sheet "Devices" tab
  (platform ADR + migration 0042+).
- `ha1` on the device is as sensitive as a password: Keychain with `kSecAttrAccessibleAfterFirstUnlock`
  (the app must register after reboot before unlock, for push), no iCloud Keychain sync.
- One rotation logs out every device of the user; acceptable for the MVP and documented in the UI.

## Alternatives considered
- Typing SIP credentials (Bria style): contradicts the platform design and puts a shareable secret in
  users' hands.
- Returning a plaintext password: impossible, the platform stores `ha1` only.
- Per-device credentials now: touches the Kamailio auth path (REGISTER and INVITE) before the app
  exists; deferred to v1.
- OIDC only: blocks the MVP on an app registration and MSAL/ASWebAuthenticationSession work.
