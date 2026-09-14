# ADR-0002: Push wake-up parks the INVITE in Kamailio; push tokens live in `platform.devices`; dead TCP contacts are never relayed to

- **Status:** proposed (implementation belongs to `voice-platform`; this ADR records what the app relies on)
- **Date:** 2026-09-14
- **Deciders:** Hugo (owner)

## Context
iOS drops the app's TLS socket seconds after backgrounding and only VoIP pushes wake it (and Apple
requires the app to report a CallKit call for every VoIP push). The platform's `07-clients.md` section
2 designs the park-push-deliver flow with `tsilo`. Two details were open: how Kamailio knows a contact
is unreachable, and where the push token comes from when the contact has expired. Kamailio 5.8 has no
RFC 8599 registrar parameters (checked), and usrloc runs DB-only, so `handle_lost_tcp` is unavailable.

## Decision
1. Kamailio always `ts_store()`s an INVITE toward a user, relays only to contacts whose TCP/TLS
   connection is alive (`tcpops` `tcp_conid_alive` on `$ulc(conid)`), replies `180 Ringing` when no
   live contact exists, and asynchronously posts `/internal/push` with the SIP Call-ID and the list of
   dead instances. After a successful REGISTER it calls `ts_append("location","$tu")`.
2. The control plane pushes to the user's `platform.devices` rows (not to `pn-*` parameters from
   `location`), skipping live instances; the app keeps its `devices` row current with `PATCH
   /v1/me/devices/{id} {push_token}`. Payload: `aps.call-id` = SIP Call-ID plus a `callto` object with
   the platform call id; no caller PII in the push (D8).
3. Two devices of one user = two enrolled apps with the same SIP identity and distinct `+sip.instance`;
   Kamailio's parallel forking rings all live ones, pushed ones join via `ts_append`; the first answer
   cancels the others, which report `.answeredElsewhere` to CallKit.

## Consequences
- Registration expiry of a backgrounded phone no longer matters for reachability: the token is in the
  database. `location` stays honest for presence.
- New platform pieces: `tsilo`, `tcpops`, an APNs sender in Go (stdlib HTTP/2 + ES256 JWT),
  `/internal/push` and `/internal/push/cancel`, `push_deliveries`, rate limits, metrics.
- App rule S1: every `PushIncomingReceived` is reported to CallKit before anything else.

## Alternatives considered
- Trust `pn-*` params in `location` with long expiry (Flexisip model): needs long-lived contacts and a
  Kamailio-side token parser; tokens would also live in the location table.
- Change usrloc to `db_mode 1` to get `handle_lost_tcp`: a platform-wide change to registration
  storage for one feature; rejected for the MVP.
- Speculative push on every call to a user: burns battery and violates the "never push without a
  parked call" guardrail.
