# voice-softphone: agent instructions

You are working in the first-party CallTo softphone: iOS first, Swift, liblinphone, talking SIP/TLS +
SRTP to the `voice-platform` edge (Kamailio + rtpengine) and REST/WebSocket to its control plane.
A softphone defect means a customer misses or drops calls, or loses push privileges with Apple, so this
repo carries explicit instructions and guardrails, in the same layout as `../voice-platform`.

**Read, in this order, before doing anything:**
1. `.ai/guardrails.md` — hard rules. Never violate them; if a task requires it, stop and ask.
2. `.ai/instructions.md` — how to work here: layout, commands, verification, review checklist.
3. `.ai/mistakes.md` — the "Active rules" section lists lessons already paid for. Apply them.
4. `docs/01-mvp.md` and `docs/02-call-flows.md` — the normative design of the app.
5. `../voice-platform/docs/02-contracts.md` sections 7 and 10 — the wire contract the app speaks. The
   platform repo is normative for anything on the wire; `docs/03-platform-changes.md` here lists the
   deltas this app needs from it.
6. `docs/04-status.md` — what works where today and the open threads; update it when a milestone lands.

**Mistakes protocol (mandatory):** whenever (a) the user corrects you, (b) a verification step fails
because of something you did or assumed, or (c) you discover that an earlier assumption in this repo was
wrong, append an entry to `.ai/mistakes.md` *in the same turn*, following its template, and if the
lesson generalises, add or update a bullet in its "Active rules" section. Do not wait to be asked.
Keep entries factual and short. Never delete entries; mark superseded rules as such. If you are a subagent
or working in parallel with others, write `**Rule:** proposed: <one line>` and let the integrating session
assign the number.

**Decisions protocol:** any change to the SIP stack, a dependency, the CallKit/PushKit model, the
credential model, or the API surface the app relies on gets an ADR in `docs/adr/` (template there).
Changes to the wire contract are made in `../voice-platform` (its `docs/02-contracts.md` + an ADR there)
and referenced from here; never fork the contract in this repo.
