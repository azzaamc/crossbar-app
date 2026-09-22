# Crossbar server architecture (proposed)

The target server, derived from the four investigations rather than from
MiroTalk's shape. **Nothing here is implemented.** This is the document the
architecture review is about.

Inputs: [`CURRENT_CLIENT_CONTRACT.md`](CURRENT_CLIENT_CONTRACT.md),
[`QATAR_DEPLOYMENT_AUDIT.md`](QATAR_DEPLOYMENT_AUDIT.md),
[`MIROTALK_SERVER_ARCHITECTURE.md`](MIROTALK_SERVER_ARCHITECTURE.md),
[`MIROTALK_SIGNALING_PROTOCOL.md`](MIROTALK_SIGNALING_PROTOCOL.md),
[`MIROTALK_ROOM_AND_PEER_STATE.md`](MIROTALK_ROOM_AND_PEER_STATE.md),
[`MIROTALK_SECURITY_MODEL.md`](MIROTALK_SECURITY_MODEL.md),
[`MIROTALK_DEPENDENCY_MAP.md`](MIROTALK_DEPENDENCY_MAP.md),
[`CROSSBAR_SERVER_REQUIREMENTS.md`](CROSSBAR_SERVER_REQUIREMENTS.md).

---

## 1. The finding that shapes the design

The control plane is **already** a small purpose-built server. Family Call is six
modules of plain Node (`config`, `db`, `identity`, `mirotalk`, `push`,
`rate-limit`) totalling ~1,300 lines, one SQLite file, one runtime dependency
(`web-push`), and it already owns identity, contacts, groups, presence, call
lifecycle, ringing, missed-call expiry, SSE, and Web Push — with a hardening
systemd unit and a coherent security posture.

MiroTalk, by contrast, is 2,870 lines in one file owning the whole protocol plus
a web application, of which **five handlers carry a call**.

Therefore the minimal Crossbar server is **not** "MiroTalk made smaller". It is:

> the existing control plane, extended to own signalling, with an authorization
> model MiroTalk never had.

That single decision removes ~13,000 lines of product surface, a jsdom/DOMPurify
sanitiser, a JWT/AES subsystem, the web client, all of the whiteboard/chat/file
feature handlers, and the entire class of gaps catalogued in
[`MIROTALK_SECURITY_MODEL.md`](MIROTALK_SECURITY_MODEL.md) — while keeping the
proven parts: the same transports, the same call semantics, and the same wire
vocabulary the shipped client already speaks.

---

## 2. Component decomposition

```
                        tailscaled (TLS, tailnet-only)
                                   |
                     ┌─────────────┴─────────────┐
                     |   127.0.0.1:<port>        |     ONE Node process, loopback-bound
                     |   Crossbar server         |
                     └─────────────┬─────────────┘
                                   |
   ┌───────────────┬───────────────┼───────────────┬────────────────┐
   |               |               |               |                |
 HTTP API      SSE stream     WebSocket       call state      authorization
 identity      one per user   signalling      machine         participant-
 calls         call/status/   (Engine.IO v4   (explicit,      scoped, per
 devices       presence       subset)         durable while   call, bound by
 push                          \              live)          identity
                                \
                                 └── validates, limits, logs, relays
                                            |
                                     SQLite (one file)
```

| Component | Responsibility | Persistence |
| --- | --- | --- |
| HTTP API | identity, bootstrap, call create/respond/join/end/invite/leave, device + push registration | SQLite |
| SSE stream | `ready`, `incoming-call`, `call-status`, `ongoing-call`, `presence`, `directory-updated` | none |
| Signalling endpoint | admission, pairwise fan-out, SDP/ICE relay, departure | none (ephemeral) |
| Call state machine | explicit states, transitions, timeouts, per-participant leave | SQLite while live |
| Room/participant state | who is connected, which pairs exist | in-memory, rebuildable |
| Authorization | identity-bound admission, participant-scoped relay | in-memory + SQLite |
| Validation/limits | per-event schema, size caps, rate limits | none |
| Observability | structured, redacted logs | none |

**One process.** Not because two would be wrong, but because the state they share
(call ↔ room ↔ participant ↔ device) is exactly the state that must not be split
across a network boundary in a three-person system.

---

## 3. Technology selection

Requirements first: a handful of low-rate message types; one durable relational
dataset of a few hundred rows; long-lived sockets for three to five devices;
loopback-only; one operator; must be debuggable by hand years from now.

| Option | Assessment |
| --- | --- |
| **Node.js (recommended)** | Matches the existing control plane exactly — same language, same `node:sqlite`, same unit, same deployment practice, same `fetch`, no new runtime on the Pi (v22.23.2 already installed). `ws` is the only plausible new dependency; the Ice/Engine.IO framing subset is small enough to own. |
| Go | Excellent fit technically (single static binary, first-class WebSocket, easy concurrency). Rejected for now on one ground: it introduces a second language and a second deployment path while the control plane stays Node, doubling the operations surface for a three-user system. |
| Swift server | The client is Swift; the server gains nothing from sharing the language, and the server-side ecosystem path (`swift-nio` + WebSocket + SQLite) is heavier to operate here. |
| Rust | Overkill on every axis. |
| Python | Feasible, but no existing code to reuse and no advantage over Node. |

**Decision: Node.js, one process, one SQLite file, `ws` for WebSocket.** Reuse the
existing `config`/`db`/`identity`/`push` modules and their tests rather than
rewriting them.

**Socket.IO library vs a minimal framing subset?** The client hand-rolls
Engine.IO v4 / Socket.IO v5 over a raw WebSocket
(`CURRENT_CLIENT_CONTRACT.md` §3.1). The server needs: send the Engine.IO open
frame, accept `40`, answer `40{"sid":…}`, exchange `42["event",payload]`, and run
a 25 s ping / 20 s pong heartbeat. Recommendation: **own that subset** (~150 lines
and one test file), because it is smaller than the dependency it replaces, it is
symmetric with the client's existing implementation, and the client never uses
polling, acks, namespaces or binary frames. Use the `socket.io` package instead
only if browser (PWA) interop against this endpoint becomes a requirement —
that path also needs `GET /buttons` and an `addPeer.peers` roster, so it is a
larger commitment than it looks.

---

## 4. Wire protocol strategy

Two options were considered.

| | Keep the MiroTalk wire vocabulary | Design a clean Crossbar protocol |
| --- | --- | --- |
| Client change | **none** | rewrite `MiroTalkSignalClient.swift` (870 lines) |
| Risk | low — the protocol is already verified on device against a real peer | medium — new protocol, new bugs, no reference peer |
| Security | fully fixable server-side; every gap in MiroTalk is an *authorization* gap, not a vocabulary gap | equivalent |
| Browser interop | possible later | lost |
| Legacy ballast | event names like `relaySDP`/`addPeer` and a `peers` roster | none |

**Recommendation: keep the vocabulary, replace the implementation.** The evidence
is that the wire shape is *not* where MiroTalk's problems live — its auth bypass,
blind relays, plaintext password broadcast and crash-on-malformed-id are all
server behaviour. Keeping the vocabulary means the already-device-verified client
needs no change, the migration becomes a configuration change (the client already
accepts a signalling-origin override), and the PWA keeps working meanwhile.

The full protocol is in
[`CROSSBAR_SIGNALING_PROTOCOL.md`](CROSSBAR_SIGNALING_PROTOCOL.md); the three
deliberate behavioural changes are:

1. **Admission requires being a participant of the call** (below), not just
   knowing the room name.
2. **Relay is participant-scoped** — a socket may address only peers in the same
   call, and only ids the server issued for that call.
3. **Validation is per-field and bounded** on every event, including the relays.

---

## 5. Signalling admission — the one new mechanism

> **Revised during implementation.** This section originally proposed single-use
> signalling tickets. Building it showed a better mechanism was already available,
> so tickets were dropped. The reasoning is kept here because the mistake is
> instructive: the design had assumed the socket could not identify its caller, and
> it can.

A signalling connection is an HTTP request too — `GET /socket.io/…` with an
`Upgrade` header — so when it arrives through tailnet Serve it carries the same
injected identity headers the API uses. The upgrade is therefore authenticated by
exactly the mechanism the rest of the server already relies on, and admission
becomes an authorization decision rather than a shared room name:

```text
POST /api/calls/:id/join          (authenticated as a person)
        │
        ├── verifies: the caller is a participant of call :id
        ├── verifies: the call admits that participant right now
        └── returns { call, signalling: { url, room, eio, transport }, joinUrl }

client opens wss://<host>/socket.io/?EIO=4&transport=websocket&device=<id>
        │   (identity is injected by the proxy on this request, as on any other)
        │
client emits join { channel: room, peer_uuid, peer_name, … }
        │
        ├── server resolves the caller from the upgrade request's identity
        ├── finds the call whose room is `channel`
        ├── refuses unless that person is a participant of it
        └── admits, then pairs it with everyone already in the room
```

Properties this buys, each of which MiroTalk lacks:

- knowing a room id is **not** enough to join — the caller must be a participant;
- the room id stops being a credential, so it can be logged and put in a URL;
- no new secret, no new storage, and no expiry window to get wrong;
- one identity mechanism for the whole server, not two;
- **zero client changes**: neither the native client nor the browser client has to
  be taught a new field, because both already send `join` with a `channel`.

What was given up: a ticket could be scoped to a single call and a single device
and could expire. Identity-based admission has no expiry — a socket lives as long
as the connection, and the call's own state (`ended`, `missed`) is what ends its
authority. That is checked on every join, which is the only moment authority is
needed.

Device identity still matters, for a different reason: it is what lets the server
recognise "this is the same install reconnecting" and evict the previous
connection rather than leaving a ghost in the room. It is optional — a client that
does not send `?device=` is admitted by identity alone, and one that does gets
clean re-attach.

---

## 6. State model

### 6.1 Durable (SQLite, the existing file)

| Table | Change |
| --- | --- |
| `users`, `contacts`, `family_groups`, `group_members` | unchanged |
| `calls`, `call_participants` | unchanged schema; **`left` status now actually written**; add `kind` (`audio`/`video`) if §13.8 is approved |
| `presence` | unchanged (a last-seen hint) |
| `push_subscriptions` | unchanged (PWA/Web Push) |
| **`devices`** (new) | `id`, `user_id`, `platform`, `push_token`, `environment`, `created_at`, `last_seen_at`, `label` — the missing half of the APNs story |
| **`call_devices`** (new) | `call_id`, `device_id`, `joined_at`, `left_at` — what makes "this device is in this call" a server fact instead of a `UserDefaults` key |

### 6.2 Ephemeral (in memory, rebuilt from connects)

| State | Content | Rebuild rule |
| --- | --- | --- |
| `calls[callId].participants[peerId]` | `peerId`, `deviceId`, `userId`, `peerName`, socket, joined-at | rebuilt as sockets connect; the authoritative membership is `call_participants` |
| pairs | implied by membership, not stored | derived |
| presence | open event-stream count per user | derived |

No SDP, no ICE payload, no media, and no room password is ever stored — the last
of these by omission, because Crossbar has no room passwords.

### 6.3 Why room state is ephemeral and call state is durable

A room is a *view* of who is connected; a call is a *fact* about people. If the
server restarts mid-call, the call must still exist (the client re-reads it), while
the room is legitimately empty until clients reconnect. This is the property
MiroTalk cannot offer — it has no call concept and loses every room on restart.

---

## 7. Call state machine

Explicit, server-owned, and **not** implicit in socket handlers.

```text
idle ──create(invitees)──> ringing
                            │
        ┌───────────────────┼────────────────────────┬──────────────────┐
        │ first accept      │ all invitees declined  │ 90 s expiry      │ caller ends
        v                   v                        v                  v
      active            declined                  missed           cancelled
        │
        ├── participant joins/leaves (leaves ≠ end) ──> active
        ├── last participant leaves ─────────────────> ended
        └── any participant ends ────────────────────> ended
```

Server-enforced rules:

| Rule | Value |
| --- | --- |
| Only `invited` participants may `accept`/`decline`, once each | existing |
| `ringing → active` on the **first** accept | existing |
| `ringing → missed` after `CALL_RING_SECONDS` (90 s) | existing |
| `ringing → cancelled` when the caller ends | existing |
| `ringing → declined` when no invitee can still accept | existing |
| **`active → ended` only when the last participant leaves or someone ends the call** | **new** (C5/N7) |
| A participant may leave an `active` call without ending it | **new** |
| A device may re-attach to an `active` call it is a member of | **new**, device-scoped (R7) |
| Concurrent state changes are serialized per call | **new** |

Timeout and terminal transitions emit `call-status` to every participant, and
`ongoing-call` on entry to `active` (the client already handles both).

---

## 8. Authorization model

Three layers, each independently meaningful.

1. **Network** — loopback bind; tailnet Serve is the only ingress; TLS terminated
   by `tailscaled`. Unchanged from today, and *not* relied on for authorization.
2. **Application identity** — Tailscale Serve's injected identity, accepted only
   from loopback, exactly as the control plane does today (`src/identity.js:9-22`).
   This stays: it is the one thing that already works on device with no credential
   on the client.
3. **Session/participant authorization** — the new part:
   - **Device identity**: a device registers once per install and gets a
     server-issued `device_id`; call membership is per device.
   - **Identity-bound admission**: a socket is authenticated by the same injected
     identity the API uses, and may only join a call its person is a participant
     of.
   - **Participant-scoped relay**: `relaySDP`/`relayICE` are accepted only from a
     socket that is admitted to that room, and only when `peer_id` names another
     admitted participant of the *same* call. The emitted `peer_id` is always the
     server's record of the sender.

This is what makes "anyone who can reach the server can do anything" false, which
is the requirement the current system does not meet (`Z2`, `Z3`, `Z4`).

---

## 9. Storage, sizing, and what is deliberately absent

| Item | Choice | Why |
| --- | --- | --- |
| Database | the existing single SQLite file, WAL mode | a household's data; `node:sqlite` is built in; no server to operate |
| Cache / broker | **none** | one process; nothing to coordinate |
| Queue | **none** | push delivery is fire-and-forget with a logged failure, as today |
| Files | **none** | no media, no recordings, no uploads |
| Migrations | the existing idempotent `migrate()` plus `ensureUserColumn`-style column adds | already proven in place |

Sizing estimate [INFERENCE]: the durable dataset is O(10) users, O(10²) calls per
year, O(10) devices. The whole database will remain far below the journal's 8 MB.

---

## 10. Failure model

| Situation | Current behaviour (measured) | Proposed behaviour |
| --- | --- | --- |
| Server restart mid-call | MiroTalk: instant FIN, all rooms gone, no notification; control plane: call survives in SQLite; client does not re-dial the socket | call survives; on restart the room is empty; a client that notices its socket closed re-joins via `POST /join` and re-attaches; other participants see `removePeer` then `addPeer` rather than duplicates |
| Signalling socket loss (unclean) | server notices at ≤45 s (Engine.IO defaults); re-joining client can be paired against its own ghost for the rest of that window | same heartbeat bound, **plus** identity-aware eviction: admitting a device that already has a live participant row evicts the old row atomically before fan-out |
| Clean close / app kill | immediate `removePeer`, room GC | unchanged |
| App backgrounding (iOS suspend) | socket dies; nothing re-dials until foreground; media keeps flowing if audio is running | unchanged on the client; the server reaps the dead participant on heartbeat timeout and accepts a re-attach with the same identity |
| Network change (Wi-Fi↔cellular) | dead-but-unclosed socket on both sides for ≤45 s; no ICE restart | server: identity-aware eviction removes the ghost window; media: **plainly documented as unhandled** unless ICE restart is adopted (§13.9) |
| Tailscale path change | signalling may die; media is independent (no TUN) | unchanged; signalling recovery is the socket-loss path |
| ICE failure | **nothing at all** anywhere — no restart, no teardown, no user-visible error | at minimum: a per-peer failure state surfaced to the UI and a bounded teardown; ICE restart is a separate, explicit decision |
| Notification delayed | Web Push only; a native app that is closed never rings | unchanged until APNs exists; the server must not claim a call was delivered |
| Third participant cannot join | `invite` exists but the client cannot call it; `ROOM_MAX_PARTICIPANTS` unenforced | invite is exercised; capacity is enforced **server-side**; a refused join emits a reason the client can show |
| Malformed message | MiroTalk can be crashed into a restart loop (`peer_id: "constructor"`) | every handler is wrapped; a malformed message is rejected and counted, never fatal; a supervisor restart policy is not a substitute for this |

---

## 11. Observability

Keep the control plane's model and fix MiroTalk's omission. Structured, single
line, no secrets, no SDP, no tokens:

```
call_created {callId, callerId, inviteeIds}
call_accepted {callId, userId, deviceId}
call_left {callId, userId, deviceId}
call_ended {callId, userId, status}
call_missed {callId}
signal_admitted {callId, peerId, deviceId, room}
signal_rejected {reason, callId?, peerId?}        ← the line MiroTalk does not have
relay_denied {reason, from, to}                    ← ditto
peer_left {callId, peerId, reason}                 ← ditto
push_dispatched {callId, deviceCount, failures}
request_error {message}                            (5xx only)
```

Never logged: identity headers, API secrets, SDP bodies, ICE candidates,
push endpoints, or full request headers. The startup banner prints a **redacted**
config — the current production MiroTalk prints its API key and JWT key on every
start, and that must not be reproduced.

Runtime logs go to journald, which is **volatile on the Pi** (lost on reboot).
A Crossbar server should either enable persistent journald storage or write a
bounded rotating file — an operations decision recorded in
[`MIGRATION_PLAN.md`](MIGRATION_PLAN.md).

---

## 12. What breaks if a component is removed

Answering the minimalism criterion directly.

| Component | What breaks without it |
| --- | --- |
| HTTP API | nothing can create or find a call |
| SSE stream | no foreground ringing; the client would have to poll, and its whole reconnect design assumes a stream |
| Signalling endpoint | no media negotiation at all |
| Call state machine | ringing, accept, decline, expiry and "who is in this call" have no owner (this is precisely MiroTalk's condition) |
| Room/participant state | no fan-out, no `removePeer`, no mesh |
| Authorization (admission + scoped relay) | every gap in `MIROTALK_SECURITY_MODEL.md` returns |
| Validation/limits | a single malformed message becomes a crash or an unbounded allocation |
| SQLite | calls, contacts, devices and push tokens vanish on restart |
| Push | a closed app never rings (already true today) |
| Observability | the next failure is undiagnosable — the state the project is in today for anything that happens on the MiroTalk side |
| **Media path** | *not a component* — there is nothing to remove; media is P2P and the server never touches it |

---

## 13. Design decisions

Settled during implementation, and the answer that was chosen:

| # | Decision | Settled as |
| --- | --- | --- |
| 1 | Device identity | **Server-recognised `?device=` on the socket, optional, bound to the authenticated person.** A reconnect from the same device evicts its previous connection; a client that sends none is admitted by identity alone. |
| 2 | Identity transport | **Tailnet identity as enrollment, device id on top.** Proven on device, no new credential to distribute. |
| 3 | Wire protocol | **MiroTalk's vocabulary kept.** Every weakness found was server behaviour, not wire shape; keeping it means no client changes. |
| 4 | Framing | **Own Engine.IO v4 subset**, ~40 lines against `ws`; the client already hand-rolls the mirror image. |
| 5 | Per-participant leave | **Implemented.** `POST /calls/:id/leave`; the call ends only when nobody is left in it. |
| 6 | TURN | **None**, with the symmetric-NAT failure documented rather than hidden. |
| 7 | The PWA's media engine | **Migrated.** The server now serves its own browser call client, and the PWA drives it through the same `joinUrl`-in-a-frame contract it used for MiroTalk — so the PWA source needed no change at all. |
| 8 | Audio-only calls | **A stored `kind` column exists**; no client requests it yet. |
| 9 | ICE restart | **Out of scope**, documented as a media-plane gap. |
| 10 | APNs | **`devices` table built** (with push token and environment columns); delivery deferred to the Apple Developer decision. |

Still open, and requiring the owner rather than evidence:

- **Where the PWA's files live.** It is currently served from its existing
  repository through `WEB_ROOT`; moving those files into this project is a
  one-step copy but forks the PWA's source, so it is a deliberate choice.
- **Whether the native client adopts `?device=`**, which it needs for clean
  re-attach on the same phone. Until then it relies on its existing
  `UserDefaults` guard.
- **TURN**, if a real pair is ever measured failing without it.
- **APNs**, which needs a paid membership before any of it can be built.

---

## 14. Summary

- **One** Node process owning identity, contacts, call state, presence, push,
  signalling, and the browser call client.
- **One** SQLite file, extended with `devices` and `call_devices`.
- **Two** transports: HTTPS + SSE, and one WebSocket signalling endpoint speaking
  the vocabulary both clients already speak.
- **Three** security layers: tailnet (network), Tailscale identity (person),
  identity-bound admission + participant-scoped relay (call).
- **No** media path, no database server, no cache, no queue, no framework beyond
  the platform's own HTTP and one WebSocket library.
- **Zero** client changes: the shipped native client and the existing PWA both
  work against it as written.

What was built, how it is run, and what was verified are in
[`CROSSBAR_SERVER_IMPLEMENTATION.md`](CROSSBAR_SERVER_IMPLEMENTATION.md).

---

## 15. Network modes and Crossbar device identity (2026-09-21)

Everything above assumes the tailnet is the only way in. That assumption is now
explicit and configurable rather than implicit, because the same server also has to
work on a hostname on the open internet.

```
                         CROSSBAR CLIENT
                               │
                    Crossbar Device Identity
                               │
             ┌─────────────────┴─────────────────┐
      PRIVATE NETWORK                       PUBLIC INTERNET
         Tailscale                            HTTPS/WSS
             │                                   │
    optional additional                         Caddy
   network identity/auth                          │
             │                                   │
             └─────────────────┬─────────────────┘
                               │
                       Crossbar Backend
                               │
                         Signaling/API
                               │
                         WebRTC / ICE
                          /         \
                     Direct         TURN
                                     │
                                   coturn
```

**`CROSSBAR_NETWORK_MODE` selects a trust posture, not a code path.** One process, one
database, one signalling implementation, both modes.

| | private | public |
| --- | --- | --- |
| Transport | Tailscale Serve → loopback | Caddy → loopback |
| `CROSSBAR_PUBLIC_HOSTNAME` | unused | required, and `PUBLIC_ORIGIN` must name it |
| `trustTailscaleHeaders` | default on | **default off, and refuses to be turned on** |
| `allowDevIdentity` | allowed on loopback only | refused at startup |
| `requireDeviceAuth` | default off | **default on** |
| Relay | not needed on a tailnet | coturn, credentials issued per device |

**Where the identity layer sits.** `src/auth.js` is transport-independent: the same
enrolment, challenge-response and session code serves both modes, and the socket in
`src/signal.js` authenticates with the same session the API does — including the rule
that a transport identity is not enough where a key is required. `src/identity.js` is
now only about the transport.

**Media.** ICE configuration is built per device by `src/ice.js` and delivered two
ways: inside `addPeer` on the signalling socket, and from `GET /api/webrtc/ice` for a
client that wants it before a peer exists. Each side is told what *it* may use, with
credentials that expire. Direct paths are still preferred and nothing here arranges
them; TURN is the fallback.

The flows, the deployment requirements and the configuration reference are in
[`CROSSBAR_SERVER_IMPLEMENTATION.md`](CROSSBAR_SERVER_IMPLEMENTATION.md) and
[`CROSSBAR_SECURITY_MODEL.md`](CROSSBAR_SECURITY_MODEL.md).
