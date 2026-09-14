# Guardrails (hard rules)

These are not preferences. Breaking one is a defect even if the code "works".

## Telephony behaviour
- S1. **Every VoIP push is reported to CallKit at once.** On `Call.State.PushIncomingReceived` (or any
  VoIP push the SDK hands us) call `reportNewIncomingCall` before any network or UI work. If the call
  turns out to be gone, report it and end it immediately. Swallowing a push loses the app's push
  privilege with Apple, which is the end of the product.
- S2. **The app never decides routing or policy.** Hold, park, transfer, move, pickup, DND and anything
  a switchboard or CDR must see goes through the control-plane API. The SIP stack does REGISTER,
  INVITE, BYE, DTMF and media only. Mute is local.
- S3. **One SIP identity per user, one `+sip.instance` per installed app.** The instance id is generated
  once at enrollment, stored in the Keychain and never changes for the life of the installation.
- S4. **Audio session ownership belongs to CallKit.** Configure the `AVAudioSession` only inside the
  `CXProviderDelegate` actions (`configureAudioSession()` in answer/start, `activateAudioSession` in
  didActivate/didDeactivate). Never touch the session elsewhere; iOS refuses it in the background.
- S5. **Server certificates are always verified.** `verifyServerCertificates(false)` may exist only under
  `#if DEBUG` behind an explicit developer toggle, never in TestFlight or App Store builds.

## Security and compliance
- S6. **Credentials live in the Keychain only**: SIP credentials, API/device tokens, push tokens,
  enrollment codes. Never in `UserDefaults`, files, logs, crash reports or screenshots. Logs are
  user-shareable diagnostics: redact `Authorization`, `password`, `ha1`, tokens, push tokens.
- S7. **No secrets in git**: no `.p8` APNs keys, provisioning profiles, `.env`, `*.xcconfig` with
  secrets, hard-coded test accounts. `.gitignore` covers them; check before every commit.
- S8. **Data minimisation toward Apple.** Push payloads carry what CallKit needs to show a call and the
  ids to correlate it, nothing else; details are fetched over the API. No third-party analytics, crash
  or tracking SDK without an ADR (EU data residency is a platform guardrail, G12).
- S9. **Licensing.** liblinphone is AGPLv3 (GPLv3 terms for a client) unless a commercial licence from
  Belledonne exists. The app stays GPL-3.0 open source until then; no GPL-incompatible dependencies.
- S10. **Destructive operations** (revoking devices, deleting accounts, wiping the Keychain, force-push,
  deleting the App Store record) need an explicit user instruction naming the target.

## Engineering
- S11. **No change ships without its verification.** At minimum `xcodegen generate` + `xcodebuild build`
  for the app and `swift test` for `SoftphoneKit`. Anything touching registration, call setup, audio,
  CallKit or push is verified with a real call on a real device against the platform VM, and the report
  says what was and was not verified.
- S12. **Do not invent SDK APIs.** Verify every `linphonesw` symbol against the pinned SDK version's
  Swift wrapper or C headers in the SPM checkout (see `.ai/instructions.md`). Same for CallKit/PushKit:
  Apple's documentation for the deployment target.
- S13. **The wire contract lives in `../voice-platform/docs/02-contracts.md`.** If the app needs a header,
  endpoint, payload key or table that is not there, the change is made in the platform repo first (doc
  + ADR), then used here. Never guess a platform behaviour from memory; read the platform source.
- S14. **Real-device evidence only for CallKit/PushKit.** The SDK disables CallKit on the simulator and
  PushKit does not exist there; a simulator run never counts as verification of S1 or S4.
