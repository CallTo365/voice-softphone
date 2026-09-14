# Changes needed in `voice-platform`

Everything on the wire is owned by `../voice-platform` (its `docs/02-contracts.md` is normative). This
page is the app's shopping list against that repo: what exists, what is missing, and the proposed
shape. Each item becomes a contract edit + ADR + migration there (numbering in that repo as of
2026-09-14: next ADR `0031`, next migration `0042`). Status of the platform pieces was checked in the
working tree on 2026-09-14.

## 0. What already exists (verified in the platform source)

| Piece | Where | State |
|---|---|---|
| SIP/TLS listener 5061, TLS profile, self-signed fallback cert | `edge/kamailio/kamailio.cfg`, `tls.cfg`, `entrypoint.sh` | live on the VM |
| SRTP toward TLS phones (`RTPE_SRTP`), plain RTP toward FS | `kamailio.cfg` route `FROM_WORKER` | live |
| Parallel forking to all contacts (`lookup` + `t_relay`), `max_contacts=5`, `+sip.instance` captured and posted with registration events | `kamailio.cfg` ~L694-760, `/internal/registrations` | live |
| `platform.devices`, `platform.push_deliveries` | `db/migrations/0003_devices.sql` | tables only, no code |
| Call control: hold/unhold/park/pickup/transfer/complete/cancel, `/v1/me` with OIDC | `services/control-plane/internal/api/callcontrol.go`, `server.go` | live |
| Registrations table + events, presence, live-state WS | contract §10 | live |
| `http_async_client`, `jansson`, `pike`, `htable` loaded | `kamailio.cfg` | live |
| `websocket` module | commented out (`WITH_WEBSOCKET`) | not needed for this app |
| `gruu_enabled` | `modparam("registrar","gruu_enabled",0)` | must become 1 for P6 |
| usrloc `db_mode` | 3 (DB-only) | `handle_lost_tcp` is documented as not working in DB-only mode, hence the `tcpops` approach below |

## P1. Trusted certificate on 5061 (phase 0) — built 2026-09-14, branch `softphone/p1-sip-tls-cert` (a828104), not yet merged/deployed

iOS/liblinphone verify the server certificate (S5). Caddy on the VM already holds a Let's Encrypt
certificate for `91-99-163-145.sslip.io`. Mount it into Kamailio:
- compose: `kamailio` gets a read-only volume of Caddy's data dir; `entrypoint.sh` copies
  `certificates/acme-v02.api.letsencrypt.org-directory/<host>/<host>.crt|.key` to `/etc/kamailio/tls/`
  when present (falls back to self-signed as today); a small cron/compose sidecar runs
  `kamcmd tls.reload` after Caddy renews (or restart kamailio weekly outside business hours).
- The app's *server address* is the certificate host (`sip:91-99-163-145.sslip.io;transport=tls`); the
  SIP domain in From/To stays `acme.sip.local`, which is what `is_domain_local()` and `auth_check()`
  key on, so no cfg change. Production: `sip.<base-domain>` with the same mechanism (cert-manager in K8s).

## P2. Firewall for mobile networks (phase 0, decision D10) — applied to `voice-mvp-fw` 2026-09-14 (5061/tcp + 30000-30100/udp from 0.0.0.0/0, ::/0); `scripts/hetzner-up.sh` still to gain the same two rules

`voice-mvp-fw` allows SIP/RTP only from the office IP and the trunk. A phone on 4G/5G cannot reach
5061. Options: open `5061/tcp` and `30000-30100/udp` to `0.0.0.0/0` (Kamailio auth + `pike` + fail2ban
already protect the edge; that is the production posture anyway), or test on office Wi-Fi only.

## P3. Kamailio: park, dead-connection detection, push trigger (phase 2)

Contract §7.3 says "Kamailio parks INVITEs for push-capable contacts with `tsilo`, calls
`/internal/push`, and delivers on re-registration with `ts_append`". The concrete mechanism, using
modules verified against the 5.8 READMEs on 2026-09-14 (`tsilo`: `ts_store`, `ts_append`,
`ts_append_by_contact`; `tcpops`: `tcp_conid_alive(conid)`, `event_route[tcp:closed]`; `registrar`:
`reg_fetch_contacts` and `$ulc(p=>addr|instance|conid|socket|received)`):

```
# route[FROM_WORKER], toward a registered user
if (!lookup("location")) { $var(rc) = $rc; }
reg_fetch_contacts("location", "$ru", "callee");
$var(live) = 0; $var(dead) = "";
$var(i) = 0;
while ($var(i) < $ulc(callee=>count)) {
    if ($ulc(callee=>conid[$var(i)]) > 0 && !tcp_conid_alive("$ulc(callee=>conid[$var(i)])")) {
        # contact registered over TCP/TLS whose connection is gone: never relay to it
        $var(dead) = $var(dead) + $ulc(callee=>instance[$var(i)]) + ",";
        # drop the matching branch created by lookup(): remove_branch(<index>) / or rebuild the dset
    } else {
        $var(live) = $var(live) + 1;
    }
    $var(i) = $var(i) + 1;
}
ts_store();                                    # always cheap; needed whenever a push may follow
if ($var(dead) != "" || $var(rc) < 0) {
    # push devices exist or nothing is registered: let the control plane decide
    $var(body) = '{"tenant_domain":"' + $rd + '","user":"' + $rU + '","sip_call_id":"' + $ci +
                 '","from":"' + $fU + '","from_name":"' + $fn + '","dead_instances":"' + $var(dead) + '"}';
    http_async_query(CP_URL + "/internal/push", "PUSH_DONE");   # fire-and-forget, X-Internal-Token header
    if ($var(live) == 0) { t_newtran(); send_reply("180", "Ringing"); exit; }   # parked, no branch yet
}
route(RELAY_INITIAL);                          # live contacts ring now; pushed ones join via ts_append

# route[REGISTER], after save("location") succeeded
ts_append("location", "$tu");                  # delivers any parked INVITE for this AoR to the new contact
```
Notes for the build pass (rule R1 there: verify each function on 5.8.6 before use):
- `lookup()` sets `$du`, socket and NAT branch flags per contact; when a branch must be dropped, prefer
  `remove_branch()` by index over rebuilding the dset by hand. If matching indices proves fragile, the
  alternative is `event_route[tcp:closed]` (tcpops) removing the contact through the usrloc RPC
  (`jsonrpc_exec` `ul.rm`) so `lookup()` never sees dead contacts and registration events stay correct.
- The parked transaction with no branches lives until the caller CANCELs (FS `originate_timeout`
  from the CP's ring policy) or `ts_append` adds a branch. No Kamailio timer is needed for the MVP;
  the contract's "max park 25 s" is enforced by the CP's ring timeout.
- `+sip.instance` must be stored: it is today (`$var(pn) = "+sip.instance"` block around L754).
- `tsilo` is in the stock 5.8.6 image (`kamailio` package); `tcpops` too. R6 in the platform repo:
  assert at image build.
- Keep G5: nothing here calls the CP on the REGISTER path; the push call is on the INVITE path.

## P4. Control plane: APNs sender and push endpoints (phase 2)

- `POST /internal/push` (X-Internal-Token): body from P3. Resolve tenant + user, load
  `platform.devices` rows with `push_provider='apns_voip'`, not revoked, whose `sip_instance` is in
  `dead_instances` or (when nothing is registered) all of them. Idempotent per `(sip_call_id, device_id)`.
- APNs: token-based auth (ES256 JWT from the `.p8`, cached 50 min), HTTP/2 via `net/http` (stdlib,
  no dependency), host from the device's provider (`apns.dev` -> sandbox), headers
  `apns-push-type: voip`, `apns-topic: <bundle>.voip`, `apns-priority: 10`, `apns-expiration: now+30s`.
  Payload (D8): `{"aps":{"call-id":"<sip_call_id>"},"callto":{"type":"incoming","call_id":"<uuid>",
  "callee":"1001","tenant":"acme","expires_at":"..."}}`. `410`/`BadDeviceToken` -> mark the device
  `push_token=NULL` and emit an event; every attempt -> `push_deliveries`.
- `POST /internal/push/cancel {call_id}` and an internal hook when the call/leg ends before answer
  (already known to the CP from the ESL session): same payload with `"type":"cancel"`.
- Rate limit: 30 pushes / 5 min / device (contract §5); metrics `voice_push_sent_total{provider,kind,status}`,
  `voice_push_latency_seconds`.
- Contract §7.2/§7.4 edits: add `sip_call_id`, `dead_instances` to `/internal/push`; specify the
  `aps.call-id` key (liblinphone reads exactly `aps["call-id"]`, verified in
  `src/core/app/ios-app-delegate.mm`); keep `caller_*` optional (D8).
- Config: `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_KEY_P8_BASE64`, `APNS_BUNDLE_ID` in `.env` (G8).

## P5. Enrollment, device auth, devices UI (phase 3, ADR-0004)

- Table `platform.device_enrollments(id, tenant_id, user_id, code_hash, expires_at, used_at,
  created_by)` (migration `0042`). Codes: 8 characters, 10-minute validity, single use, shown as text
  and QR (`callto://enroll?code=...&api=https://...`) in the admin UI user sheet, new tab "Devices".
- `POST /v1/auth/device {enrollment_code, platform:"ios", app_id, device_name, sip_instance}` ->
  `{device_id, api_token, sip:{domain, username, ha1, realm, server:"91-99-163-145.sslip.io", port:5061,
  transport:"tls"}, tenant, user}`. Replaces the OIDC `id_token` variant of §7.2 for the MVP; the
  OIDC variant stays for phase 5. `api_token` is a device-scoped bearer (`platform.device_tokens`,
  hashed) accepted by the control plane and `live-state` as principal `{kind:"device", user_id,
  roles:["user"]}`.
- `GET /v1/me/devices`, `PATCH /v1/me/devices/{id} {push_token, device_name}`,
  `DELETE /v1/me/devices/{id}` (self) and the admin variants under `/v1/tenants/{t}/users/{u}/devices`
  (contract §7.2 already lists them). Revoke = delete token + rotate the user's SIP secret when the
  last device is revoked (D4), + `ul.rm` of its contact via Kamailio RPC.
- Rotation of the user's SIP secret invalidates all devices: the app re-enrolls via a new code; the
  admin UI explains this on the user sheet.
- Audit log rows for every mutation (G9).

## P6. GRUU and call move (phase 4, ADR-0003)

- `modparam("registrar", "gruu_enabled", 1)`: 200 OK to REGISTER carries `pub-gruu`; `lookup()`
  routes an R-URI with `;gr=urn:uuid:<instance>` to that contact only. Verify liblinphone keeps using
  the plain AoR for its own contact (it supports GRUU; no app change expected).
- `POST /v1/calls/{id}/move {device_id}`: principal must be the user on the call (or operator);
  device must belong to the same user. Implementation reuses park/retrieve internals: hold the far
  end, originate to `sip:<ext>@<domain>;gr=<instance>` with header `X-CallTo-Move: <call_id>` and the
  far end's caller id, on answer `uuid_bridge`, then hang up the old leg with `X-CallTo-Moved:
  <device_id>`. Timeout 30 s -> unhold and 409 `move_timeout`. Emits `call.leg.started/ended`; the
  timeline shows "moved from iPhone to iPad".
- Push for the move INVITE follows P3/P4 unchanged (the target may be backgrounded).

## P7. Recents for the user (phase 5)

If the tenant CDR list already accepts the OIDC/device `user` role and filters to the caller's own
calls, nothing to do; otherwise add `GET /v1/me/calls` (paginated per §16).

## Contract deltas summary (for the platform ADR)

| Section | Change |
|---|---|
| §7.2 | `/v1/auth/device` accepts `enrollment_code`; returns `ha1`+`realm`+`server` instead of `password`+`wss_url` for MVP; `/internal/push` body gains `sip_call_id`, `dead_instances`; new `GET/PATCH/DELETE /v1/me/devices` |
| §7.3 | contacts arrive over TLS (not WSS) with liblinphone's `pn-provider=apns|apns.dev`, `pn-prid=<voip token>`, `pn-param=<TeamID>.<bundle>.voip`; dead-connection rule; GRUU enabled |
| §7.4 | payload shape with `aps.call-id`; `caller_*` optional |
| §10.6 | new `POST /v1/calls/{id}/move {device_id}` + `X-CallTo-Move` / `X-CallTo-Moved` headers |
| §10.7 | principal kind `device` |
