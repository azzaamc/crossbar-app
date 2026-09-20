# Crossbar server requirements

Derived from the shipped Crossbar client and the measured behaviour of both
production services — **designed inward from what Crossbar needs**, not outward
from what MiroTalk happens to do.

Inputs: [`CURRENT_CLIENT_CONTRACT.md`](CURRENT_CLIENT_CONTRACT.md) (client source),
[`QATAR_DEPLOYMENT_AUDIT.md`](QATAR_DEPLOYMENT_AUDIT.md) (production),
[`MIROTALK_SERVER_ARCHITECTURE.md`](MIROTALK_SERVER_ARCHITECTURE.md),
[`MIROTALK_SIGNALING_PROTOCOL.md`](MIROTALK_SIGNALING_PROTOCOL.md),
[`MIROTALK_ROOM_AND_PEER_STATE.md`](MIROTALK_ROOM_AND_PEER_STATE.md),
[`MIROTALK_DEPENDENCY_MAP.md`](MIROTALK_DEPENDENCY_MAP.md),
[`MIROTALK_SECURITY_MODEL.md`](MIROTALK_SECURITY_MODEL.md).

Every requirement below is marked:

- **[EXISTS]** the system does this today and it must not regress
- **[GAP]** the system does not do this and a shippable product needs it
- **[DECISION]** the evidence supports more than one reasonable answer and the
  owner must choose

---

## 1. Identity

**What the server must know about a person.**

| # | Requirement | Status |
| --- | --- | --- |
| I1 | Every request is attributable to exactly one enrolled person. Today that is `tailscale-user-login`, accepted only from loopback, injected by tailnet Serve. | **[EXISTS]** — `family-call/src/identity.js:19-22`, `src/config.js:59-62` |
| I2 | An unenrolled identity is refused, not silently created with full rights. (Today an unknown *login* that is configured is enrolled implicitly on first sight; an unconfigured one is refused.) | **[EXISTS]** partially — enrolment is by configuration plus first-seen (`src/db.js:191-244`) |
| I3 | Identity must survive a change of network path. Today identity *is* network position: any client that can reach the listener on loopback is that identity. | **[GAP]** — see §11 |
| I4 | Display name and avatar come from the server, are stable, and are the only identity a peer sees on the wire. | **[EXISTS]** |
| I5 | A person has a stable opaque id independent of their login string. | **[EXISTS]** — configured users keep a configured id; first-seen users get `ts_<sha256(login)[0:24]>` |
| I6 | The server must not treat a **room id**, a **call id**, or a **device id** as a secret. | **[EXISTS]** by accident: room ids are UUIDs but unguessability is the only protection today |

---

## 2. Devices

**Does one person support multiple devices?** Today: no, and that is a live bug.

| # | Requirement | Status |
| --- | --- | --- |
| D1 | One person may use multiple devices, and the server can tell them apart. | **[GAP]** |
| D2 | Call membership is **per device**, not per person. Measured failure: a call resolved from `/api/bootstrap` is identical for every client authenticating as the same person, so an Xcode preview appeared as a third participant in a real call (2026-09-18). The client had to invent a device-scoped `UserDefaults` key to compensate. | **[GAP]** — client workaround at `Core/CallSession.swift:102-122` |
| D3 | A device has a stable identifier the server issues, used for resume, presence and push. | **[GAP]** |
| D4 | Push credentials are per device and per environment (APNs sandbox vs production). | **[GAP]** |
| D5 | The server must tolerate the same person being signed in on a device that is not in the call: a second device must be able to ring, and must be able to be ignored. | **[GAP]** |

---

## 3. Presence

| # | Requirement | Status |
| --- | --- | --- |
| P1 | Presence means "this person can be reached now", i.e. at least one device holds an open event stream. | **[EXISTS]** — `src/server.js:202-207`, `:216-222` |
| P2 | Presence is a **hint**, not a guarantee of reachability, and the UI must not offer "call this person" as an action that can only fail silently. | **[EXISTS]** — the client marks a contact online/offline and nothing more |
| P3 | Presence must reflect *notification capability*, not just an open SSE stream. A person whose app is closed but who has a registered push token is reachable and should read as reachable. | **[GAP]** |
| P4 | Presence changes are delivered on the same stream as call events. | **[EXISTS]** — `presence{userId, online}` |
| P5 | Presence must not require polling. | **[EXISTS]** |

---

## 4. Call state machine

Today's call states exist in the **control plane** (`calls.status` ∈ `ringing`,
`active`, `declined`, `cancelled`, `ended`, `missed`; `call_participants.status` ∈
`invited`, `accepted`, `declined`, `cancelled`, `left`, `missed`,
`family-call/src/db.js:6-9`) and separately in the **client**
(`CallSession.Phase` ∈ `loading`, `needsLogin`, `ready`, `outgoing`, `ringing`,
`inCall`, `failed`).

The server-side machine that the evidence actually supports:

```text
                    ┌──────────── invite ────────────┐
                    │                                v
  idle ──create──> ringing ──accept(first)──> active ──end──> ended
                    │  │                        │
                    │  └──decline(all)──> declined
                    │                           └──last participant leaves──> ended
                    └──timeout(90s)──> missed
                    └──caller cancels──> cancelled     (ringing only)
```

| # | Requirement | Status |
| --- | --- | --- |
| C1 | `ringing → active` on the **first** accept, regardless of who accepts. | **[EXISTS]** — `src/db.js:341-370` |
| C2 | Ring expiry is bounded and configurable (90 s deployed), applied by a sweep, and announced to participants. | **[EXISTS]** — `CALL_RING_SECONDS`, 10 s sweep, `call-status` |
| C3 | Terminal states are `ended`, `cancelled`, `declined`, `missed`, and are distinguishable by the client. | **[EXISTS]** |
| C4 | A call is **findable after the fact** — a client that missed the event can re-derive outstanding state from one snapshot. | **[EXISTS]** — `/api/bootstrap` |
| C5 | **Per-participant leave.** Today `/end` is call-wide; `'left'` is a declared status that is never written and no leave route exists. In a four-person call, one person hanging up ends it for everyone. | **[GAP]** |
| C6 | `active → active` must be stable under participant churn: adding a person, one person leaving, and one person reconnecting must not end the call. | **[GAP]** |
| C7 | Call state transitions must be **ordered and monotonic** from the client's point of view (see R4). | **[GAP]** |
| C8 | The client's own device-level state (`this device is in this call`) must exist server-side, at least as a membership record. | **[GAP]** — §2 D2 |
| C9 | `failed` must be a first-class server state distinguishable from `missed` (e.g. the room could not be created, or media never established). | **[DECISION]** — today a MiroTalk failure aborts creation entirely |
| C10 | The server must decide whether an **audio-only** call is a product requirement: the call kind is currently hardcoded `audio:true, video:true` (`src/mirotalk.js:25-26`) and no route accepts a media-kind field. | **[DECISION]** |

---

## 5. Participants

| # | Requirement | Status |
| --- | --- | --- |
| N1 | 1:1 calls. | **[EXISTS]** |
| N2 | Calls of 3 and 4 people, in the same room, extending the existing mesh. | **[GAP]** on the client (`inviteeIds` is always length 1) and **[EXISTS]** conceptually on the backend (`POST /api/calls/:id/invite`) |
| N3 | "Add Person" adds to the **same** call and room; it must not create a second call. | **[EXISTS]** backend, unexercised |
| N4 | Only a configured contact may be invited, and only by a participant of that call. | **[EXISTS]** — `allowedContacts`, `addInvitees` requires an accepted participant |
| N5 | An invitation is idempotent: inviting someone already in the call does nothing. | **[EXISTS]** — `INSERT OR IGNORE` |
| N6 | The set of participants must be visible to every participant, including one who joined late. | **[EXISTS]** in the control plane (`participants[]`); the signalling layer has no roster event the native client reads |
| N7 | A participant's departure is announced to the others and does not end the call. | **[GAP]** — see C5 |
| N8 | A participant who is already in the call cannot be invited twice, and a person already in a call cannot be rung into another. | **[DECISION]** — the client ignores a second invitation while busy (`CallSession.swift:713-716`), but the server does not prevent it |

---

## 6. Signalling

The exact message set the shipped client emits and consumes is in
[`CURRENT_CLIENT_CONTRACT.md`](CURRENT_CLIENT_CONTRACT.md) §3 — four emitted and
five consumed events. The requirements that follow from it:

| # | Requirement | Status |
| --- | --- | --- |
| S1 | Admission of a participant to a room, carrying their display name and a stable per-connection peer id. | **[EXISTS]** |
| S2 | **Pairwise negotiation fan-out**: on join, one offer-direction decision per new pair, and the joiner is the offerer. | **[EXISTS]** |
| S3 | SDP relay in both directions, verbatim, with the sender's peer id on the envelope. | **[EXISTS]** |
| S4 | ICE trickle relay in both directions, with `sdpMLineIndex` + `candidate` and **no requirement for `sdpMid`**. | **[EXISTS]** |
| S5 | Departure announced as an explicit `removePeer` generated **by the server**, because the client never sends a goodbye. | **[EXISTS]** |
| S6 | Media status (`video` on/off) relayed so the far end can distinguish "camera off" from "call broken". | **[EXISTS]** |
| S7 | ICE configuration delivered with admission, not hardcoded in the client. | **[EXISTS]** |
| S8 | Ordering guarantee: admission for a peer id **must** precede any SDP/ICE for that id. A client that receives SDP for an unknown peer discards it permanently. | **[EXISTS]** by construction; must be preserved |
| S9 | Mid-call renegotiation must be relayed, not rejected: a browser peer can send a **second offer** on an existing pair. | **[EXISTS]** — relay is opaque |
| S10 | Reconnect must be able to re-establish the same participant and the same pairs (see §8). | **[GAP]** |
| S11 | The signalling endpoint must authenticate the participant and authorize each relay (see §11). | **[GAP]** — the current relays have no membership check at all |

---

## 7. Media

| # | Requirement | Status |
| --- | --- | --- |
| M1 | Audio and video are **peer-to-peer**. The server never carries, inspects, records, or transcodes media. | **[EXISTS]** and structural: the iOS client's userspace tailnet node has no interface for libwebrtc to gather a candidate on, so media always takes the device's own interfaces |
| M2 | The server never sees SDP content beyond relaying it, and never stores it. | **[EXISTS]** |
| M3 | ICE configuration is supplied by the server and used by the client verbatim; the client must never hardcode a third-party STUN/TURN provider. | **[EXISTS]** — one public STUN today, no TURN |
| M4 | The server must be able to supply TURN credentials without baking them into clients, for the case where both peers are behind restrictive NAT. | **[EXISTS]** as a mechanism (TURN fields are relayed), disabled in configuration |
| M5 | There must be an explicit TURN policy decision, including who operates the relay and who sees the traffic. | **[DECISION]** — currently no TURN; the rules forbid an automatic third-party TURN |
| M6 | One capture feeds every sender (one camera/microphone per device, many peer connections). | **[EXISTS]** client-side |
| M7 | Media quality (bitrate, resolution, loss recovery) is unmeasured; the server has no role, but any claim about call quality must be evidence-backed. | **[GAP]** in measurement only |

---

## 8. Reconnection

Requirements below are the ones a replacement must meet; MiroTalk itself provides
almost none of this (see the failure model in
[`CROSSBAR_SERVER_ARCHITECTURE.md`](CROSSBAR_SERVER_ARCHITECTURE.md)).

| # | Requirement | Status |
| --- | --- | --- |
| R1 | The control-plane event stream must be recoverable: a client that reconnects must be able to learn everything it missed. Today the stream has no ids and no replay, so recovery is a full `/api/bootstrap` re-read. | **[EXISTS]** (by re-read) |
| R2 | The signalling socket must be re-establishable without losing the call: reconnect, re-admit, and re-form pairs with the participants still present. | **[GAP]** — the client does not even re-dial a dropped socket today |
| R3 | A participant who reconnects must be recognisable as the same participant (stable participant identity), so the others can replace rather than duplicate them. | **[GAP]** — MiroTalk keys on `socket.id`, which changes; its only continuity mechanism is the presenter `peer_uuid` hack |
| R4 | Events must be **ordered and idempotent** enough that a client cannot act on stale state. Today `/api/bootstrap` and the event stream can interleave: `ongoing-call` is broadcast to non-participants and the client re-checks membership to compensate. | **[GAP]** |
| R5 | A stale participant must be reaped: no ghost tiles, no entries that survive their socket. Today a reconnecting user briefly leaves a stale `peers` entry keyed by the old socket id, counted by `getPeerCount`, until the room empties. | **[GAP]** |
| R6 | Server restart must be survivable at the product level: the call state survives (it is in SQLite today), and the signalling state is rebuilt from it. | **[GAP]** — MiroTalk loses every room on restart with no client notification |
| R7 | Resume must be device-scoped: a device re-joining a call it was in must succeed with no body (`POST /join`), while an unrelated device must not be admitted by that call alone. | **[EXISTS]** for the route shape, **[GAP]** for device identity |

---

## 9. Notifications

| # | Requirement | Status |
| --- | --- | --- |
| X1 | Foreground ringing over the event stream. | **[EXISTS]** |
| X2 | **Background ringing for the native app.** Today it does not exist: iOS suspends the app, the socket dies, and only a push can wake it. The client can only find a waiting invitation by re-reading `/api/bootstrap` at launch, so a locked phone does not ring. | **[GAP]** — needs APNs/VoIP push plus a device-token model |
| X3 | Ringing for the PWA via Web Push/VAPID. | **[EXISTS]** — credentials present, delivery logs show one failure |
| X4 | The server must be able to ring **one person on all their devices** and stop ringing when one of them answers. | **[GAP]** |
| X5 | A call that expired while a device was unreachable must be visible as a missed call rather than vanishing. | **[DECISION]** — `missed` exists as a status; there is no missed-call list UI |

---

## 10. Persistence

Classification of what the server must keep, and where.

| Data | Class | Rationale |
| --- | --- | --- |
| family users, relationships, avatars | **durable** | configured once, read constantly |
| contact allow-list, groups | **durable** | the authorization input for who may call whom |
| device registrations, push tokens | **durable** | a device that reinstalls must be able to re-register; a stale token must be removable |
| call history (who called whom, outcome, timestamps) | **durable, low volume** | needed for missed calls; small |
| active calls and participant statuses | **durable while live** | must survive a server restart mid-call (R6); today this is in SQLite |
| room/participant signalling state (who is connected, which pairs exist) | **ephemeral** | reconstructable from live sockets; must never be the source of truth |
| presence | **ephemeral** | derivable from open connections |
| ICE configuration | **configuration** | boot-time constant |
| SDP / ICE payloads | **never stored** | privacy and size |

Storage shape: the current deployment uses a single SQLite file in WAL mode with
8 tables, which is proportionate to a household. **No requirement in this document
justifies adding a second datastore, a cache, or a message bus.**

---

## 11. Security requirements

The current system is described in
[`MIROTALK_SECURITY_MODEL.md`](MIROTALK_SECURITY_MODEL.md). Requirements, in the
order they matter:

| # | Requirement | Status |
| --- | --- | --- |
| Z1 | Every listener binds loopback; the only ingress is tailnet Serve. | **[EXISTS]** — enforced in code for Family Call (`config.js:59-62`), by a local patch for MiroTalk |
| Z2 | Application-level authentication must exist independently of network position. Today identity is "you reached loopback through Serve", which means anything on the host can be anyone, and the MiroTalk socket is not authenticated at all. | **[GAP]** |
| Z3 | Signalling must be authenticated: only an admitted participant of a call may join its room. | **[GAP]** — MiroTalk accepts any socket into any room |
| Z4 | Every relay must be **participant-scoped**: a socket may send SDP/ICE only to a peer in its own call. Today `relaySDP`/`relayICE` resolve through a global socket registry with no membership check, so any socket can inject into any other socket id. | **[GAP]** |
| Z5 | Payloads must be validated and bounded: shape, size, and allowed value ranges, on every handler. Today `join` and `peerStatus` are sanitised, the two relays are not validated beyond "is an object", and a malformed `join` or `relaySDP` throws inside an async handler. | **[GAP]** |
| Z6 | Rate limits and connection/participant ceilings must be enforced **server-side**. Today: create 6/min, respond 20/min, invite 12/min are enforced; `ROOM_MAX_PARTICIPANTS` is not enforced at all; there is no limit on `join`, sockets, or message rate. | **[GAP]** |
| Z7 | Secrets must never be logged. Production MiroTalk prints its API key and JWT key at `info` level on every start (`server.js:1177`, `:1254`); its `debug`-level auth-failure logs include the full header dump, which contains the API secret. | **[GAP]** |
| Z8 | A locked room's password must not be broadcast to participants. Today it is shipped in plaintext inside every `addPeer.peers`. | **[GAP]** in MiroTalk; irrelevant to Crossbar if room passwords are dropped |
| Z9 | TLS termination and certificate handling must stay with tailnet Serve. | **[EXISTS]** |
| Z10 | Origin checking must stay for the browser-facing service. Today: `checkOrigin` on mutations (present-and-mismatched only), `CORS_ORIGIN` restricted to the tailnet origin, and a full CSP/`permissions-policy` header set on Family Call. | **[EXISTS]** |
| Z11 | Room ids must be treated as identifiers, not secrets; authorization must not depend on guessing them. | **[GAP]** |
| Z12 | Logging must be operationally useful without recording media, SDP, tokens, or identity secrets. Today Family Call logs are good; MiroTalk's positive path is entirely silent because `LOGS_DEBUG=false`, so there is no "who joined what" trail. | **[GAP]** in MiroTalk |

---

## 12. Explicit non-requirements

Not needed by Crossbar, and not to be built: conferencing UI, whiteboard, chat,
file sharing, reactions, polls, recording, transcription, AI features, meeting
administration, public room creation, presentation mode, surveys, analytics,
lobby/waiting room, room passwords, hand-raise, privacy blur, screen annotation,
shared video playback, active-room listings, and MiroTalk's own browser client.

Multi-region deployment, horizontal scaling, multi-process signalling, message
brokers, external caches, Kubernetes, and enterprise tenancy are also
non-requirements: the evidence supports a household of three people with 2–4 way
calls.

---

## 13. Requirements that force a decision

These cannot be settled by evidence; each changes the design materially.

1. **Device identity.** Introduce real per-device identities (D1–D5, C8, R3, R7, X4), or keep the person-scoped model and its known failure mode?
2. **Transport of identity.** Keep "tailnet position is identity" (zero new auth machinery, no protection against anything on the host), or add an application-level credential bound to a device (Z2)?
3. **Wire protocol.** Keep the MiroTalk-compatible Socket.IO shape so the existing client and the PWA's browser peer keep working, or define a clean Crossbar protocol and change the client?
4. **Per-participant leave.** Add it (C5, N7), or keep call-wide end and accept that one person hanging up in a four-way call ends it for all?
5. **TURN.** No relay (calls fail on restrictive NAT pairs), or operate one (requires a decision about who sees relayed media)?
6. **The PWA's media engine.** Keep MiroTalk running for the PWA (no change), or replace/retire the PWA when MiroTalk goes away?
7. **APNs.** Commit to a paid Apple Developer membership and a device-token model (X2), or ship with "the app must be open to ring"?
8. **Audio-only calls** (C10).

Recommendations for each are in
[`CROSSBAR_SERVER_ARCHITECTURE.md`](CROSSBAR_SERVER_ARCHITECTURE.md) §9 and the
review summary.
