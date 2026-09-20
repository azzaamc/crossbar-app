# Current Crossbar client contract

What the shipped Crossbar client actually requires from server-side systems, read
from source, not from documentation.

**Audit date:** 2026-09-20
**Client revision audited:** branch `tailscale-kit`, working tree
`/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar/Crossbar/` (7,034 lines
of Swift across `Core/`, `Features/`, `Prototype/`).
**Method:** direct source reading plus a read-only repo-wide sweep. Every claim
below carries `file:line`. Where a prior document disagrees with source, source
wins and the disagreement is stated.

This document is the input to
[`CROSSBAR_SERVER_REQUIREMENTS.md`](CROSSBAR_SERVER_REQUIREMENTS.md). It does not
propose a design.

---

## 1. Two wires, one transport

Crossbar is a two-protocol client. It speaks to two independent server systems,
and nothing in the client couples them beyond a shared route.

| Wire | Client type | Server today | Auth on the wire |
| --- | --- | --- | --- |
| Control plane | `FamilyCallClient` — HTTPS JSON + one SSE stream | Family Call service (`127.0.0.1:3001`) behind tailnet Serve on 8443 | none from the client; Tailscale Serve injects `tailscale-user-login` |
| Signalling | `MiroTalkSignalClient` — raw WebSocket, Engine.IO v4 / Socket.IO v5 | MiroTalk P2P (`127.0.0.1:3000`) behind tailnet Serve on 443 | **none at all** (`peer_token: null`, `channel_password: null`) |

Both dial through the same `CallTransport` (`Core/CallTransport.swift:17-33`),
which is either the embedded userspace Tailscale node's SOCKS loopback or
`.direct`. `CallSession.hand(_:)` sets it on both clients before either is used
(`Core/CallSession.swift:283-287`).

Media never rides that transport. An embedded userspace node has no TUN
interface, so libwebrtc cannot gather a candidate on the overlay: during a
node-carried call the node's own address never appeared among the 55 candidates
gathered, while the system Tailscale tunnel's address did
(`Core/TailnetNode.swift:33-39`, `docs/NATIVE_PROGRESS.md`). **A server that
assumes a tailnet-reachable media address will not work.**

---

## 2. HTTP contract

### 2.1 Shared request shape

Base URL, in authority order (`Core/FamilyCallClient.swift:171-180`):

1. `CROSSBAR_BACKEND_URL` environment variable (`:172`)
2. `AppSettings.serviceAddress` → `UserDefaults` key `crossbar.serviceAddress` (`:175`)
3. compiled default `https://qatar-vpn.tailea67b0.ts.net:8443` (`:163`)

Every request sets exactly two headers beyond `Host`
(`Core/FamilyCallClient.swift:233-242`):

```swift
request.setValue("application/json", forHTTPHeaderField: "accept")   // :236
request.timeoutInterval = 20                                          // :237
// only when a body exists:
request.setValue("application/json", forHTTPHeaderField: "content-type") // :239
```

**No `Authorization`, no cookie, no client identity header, and deliberately no
`Origin`** — the Family Call backend rejects only an `Origin` that is present
*and* mismatched, so omitting it is what makes the POST routes reachable
(`Core/FamilyCallClient.swift:193-197`; backend `src/server.js:97-105`).

Failure handling: non-2xx is parsed as `{error:{code,message}}` and surfaced as
`FamilyAPIError(status:code:message:)` (`Core/FamilyCallClient.swift:253-266`).
There is **no retry, no backoff, and no idempotency key anywhere in the client**.

### 2.2 Route table

| # | Method and path | Client function | Body | Response | Product? |
| --- | --- | --- | --- | --- | --- |
| 1 | `GET /api/session` | `checkSession()` `:282-294` | — | `{authenticated:Bool, configured:Bool, identity:{name}}` | yes — gate in `load()` |
| 2 | `GET /api/push/config` | `pushConfig()` `:306-313` | — | `{enabled:Bool, publicKey:String}` | **no — DEBUG probe only** |
| 3 | `GET /api/bootstrap` | `bootstrap()` `:320-333` | — | `FamilyBootstrap` `:70-76` | yes |
| 4 | `GET /api/calls/:id` | `call(id:)` `:338-341` | — | `{call:FamilyCall}` | **no — never called by the product** |
| 5 | `POST /api/calls` | `createCall(inviteeIds:)` `:347-354` | `{inviteeIds:[String]}` | `{call, joinUrl?}` | yes — always one invitee |
| 6 | `POST /api/calls/:id/respond` | `respond(callId:accepted:)` `:357-364` | `{response:"accepted"\|"declined"}` | `{call, joinUrl?}` | yes |
| 7 | `POST /api/calls/:id/join` | `join(callId:)` `:368-372` | **none** | `{call, joinUrl?}` | yes — resume path |
| 8 | `POST /api/calls/:id/end` | `end(callId:)` `:376-379` | **none** | `{call:FamilyCall}` | yes — call-wide |

`GET /api/session` is additionally used as a *carrier liveness probe* by
`TailnetNode.carriesARequest` with a 5 s timeout, where **any** HTTP response
counts as success regardless of status (`Core/TailnetNode.swift:346-357`). A new
server must therefore answer that path cheaply and must not treat a 401/403 as a
transport failure.

### 2.3 Wire models the client decodes

`FamilyCall` (`Core/FamilyCallClient.swift:34-46`):

```swift
struct FamilyCall: Decodable {
    let id: String
    let callerId: String
    let callerName: String?
    let status: String
    let myStatus: String?          // present only in calls[] from /api/bootstrap
    let createdAt: String
    let answeredAt: String?
    let participants: [Participant]?
}
```

Three shapes exist for the same idea and the client tolerates all three
(`Core/FamilyCallClient.swift:26-33`): `callPublic` includes `participants` but
never `roomId`; `calls[]` from `/api/bootstrap` has `myStatus` and omits
`participants`; `ongoingCalls` is `callPublic`.

**Constraint:** `call.id` must be a UUID string. `CallSession.ring(_:)` maps it
with `UUID(uuidString:)` before telling CallKit, and a non-UUID id means **CallKit
is never told about the call at all** — the call rings on screen but not on the
system UI (`Core/CallSession.swift:727-729`).

### 2.4 The `joinUrl` is the only carrier of media coordinates

`callPublic` omits `roomId` deliberately. The only place a client learns which
room to join, and which host to join it on, is the `joinUrl` string returned by
routes 5, 6 and 7 (`Core/FamilyCallClient.swift:99-133`):

```swift
init?(joinUrl: String)            // :115
    // takes scheme + host + port as `origin` (:126-129)
    // takes `?room=` as the room   (:120)
```

`CallSession.connect(using:)` then dials `wss://<origin>/socket.io/` and joins
`<room>` (`Core/CallSession.swift:580-596`). The origin is **trusted wholesale** —
there is no allow-list and no comparison against the configured service host. The
backend validates that the URL it mints carries `room === roomId` before
rewriting the origin (`src/mirotalk.js:34-42`), which is the only check that
exists.

This is a design smell the new server should remove: a native client should
receive a room and a signalling endpoint as *fields*, not be handed a web page
URL to reverse-engineer. Today's coupling also means the client depends on
MiroTalk's `/join` web-route shape.

### 2.5 SSE stream

- `GET /api/events`, `accept: text/event-stream`, `timeoutInterval = 120`
  (`Core/FamilyCallClient.swift:395-399`).
- Parsed byte-by-byte, not with `bytes.lines`, because the **empty line
  dispatches** (`:411-425`); `:` lines are heartbeats (`:427`); `id:` and `retry:`
  are unsupported and unused (`:434-436`).
- The client's idle timeout is 120 s and the server's heartbeat is 20 s
  (`src/server.js:250-253`). A new server must keep a heartbeat comment well
  inside 120 s.

| Event | Payload | Client behavior | Site |
| --- | --- | --- | --- |
| `ready` | `{userId}` | clears `eventsDown` | `:483-487`, `CallSession.swift:735` |
| `incoming-call` | `callPublic` **unwrapped** | membership-checked, then rings | `:489-496`, `:737-743` |
| `call-status` | `callPublic` unwrapped | terminal → tear down; `active` → in call | `:745-762` |
| `ongoing-call` | `callPublic` unwrapped | broadcast to non-participants; client re-checks membership | `:763-766` |
| `presence` | `{userId, online}` | updates one contact row | `:497-502`, `:768-770` |

**No event ids, no replay.** Recovery is entirely the client's job: on stream end
it sleeps `min(30, 2^failures)`, sets `eventsDown`, and re-reads
`GET /api/bootstrap` (`Core/CallSession.swift:637-661`, `:700-709`). The server's
contractual obligation is therefore that **`/api/bootstrap` is a complete,
authoritative answer to "what is waiting for me"** after any drop.

---

## 3. Signalling contract

### 3.1 Dial and framing

```
wss://<joinUrl origin>/socket.io/?EIO=4&transport=websocket
```

(`Core/MiroTalkSignalClient.swift:143-150`.) Direct WebSocket only — no polling
probe, no `sid` parameter, no `t=` cache-buster.

Engine.IO v4 framing consumed (`:243-266`): `0` open → client sends `40`;
`1` close; `2` ping → `3` pong; `4` message → Socket.IO layer; multi-packet
frames split on `U+001E` (`:235-240`).

Socket.IO v5 framing consumed (`:269-293`): `0` connect → the payload's `sid`
becomes `myPeerId` and `emitJoin()` fires (`:277-283`); `2` event; `3` ack —
logged only, the client never requests or matches an ack id (`:289-290`);
`4` connect_error → state `"rejected"`, no retry (`:286-288`).

### 3.2 Events emitted

| Event | Payload | Site |
| --- | --- | --- |
| `join` | 18 keys, §3.3 | `emitJoin()` `:330-359` |
| `peerStatus` | `{room_id, peer_name, peer_id, element:"video", status:Bool, extras:{}}` | `setVideoEnabled(_:)` `:375-392` |
| `relaySDP` | `{peer_id, session_description:{type:"offer"\|"answer", sdp}}` | `:479-482`, `:507-510` |
| `relayICE` | `{peer_id, ice_candidate:{sdpMLineIndex:Int, candidate:String}}` | `:796-808` |

`relayICE` carries **no `sdpMid`, no `usernameFragment`, and no
end-of-candidates marker** (`:562-563` reconstructs `sdpMid: nil`).

### 3.3 `join` payload

`Core/MiroTalkSignalClient.swift:330-359`, verbatim key set:

| Key | Value |
| --- | --- |
| `join_data_time` | ISO8601 timestamp |
| `channel` | room id |
| `channel_password` | `null` |
| `peer_info` | `{osName:"iOS", osVersion, browserName, browserVersion, extras:{}}` |
| `peer_uuid` | client-generated stable UUID |
| `peer_name` | enrolled family display name in the product path |
| `peer_avatar` | `""` |
| `peer_token` | `null` |
| `peer_video`, `peer_audio`, `peer_video_status`, `peer_audio_status` | `true` |
| `peer_screen_status`, `peer_hand_status`, `peer_rec_status`, `peer_privacy_status` | `false` |
| `userAgent` | `"Crossbar/1.0 (iOS)"` |

### 3.4 Events consumed

| Event | Fields read | Required | Site |
| --- | --- | --- | --- |
| `addPeer` | `peer_id`, `should_create_offer` (default false), `peer_name`, `iceServers[].urls/username/credential` | `peer_id` only | `:416-470` |
| `sessionDescription` | `peer_id`, `session_description.type` (anything that is not `"offer"`/`"answer"` becomes `.prAnswer`), `.sdp` | all three | `:515-547` |
| `iceCandidate` | `peer_id`, `ice_candidate.candidate`, `.sdpMLineIndex` (default 0) | `peer_id`, `candidate` | `:550-570` |
| `peerStatus` | `peer_id`, `element` (**only `"video"` acts**), `status` | the three | `:394-410` |
| `removePeer` | `peer_id` | yes | `:316`, `:587-598` |

Anything else is silently dropped (`default: break` `:311-318`) — including
`serverInfo`, despite the state string the client writes after joining reading
`"join sent — awaiting addPeer/serverInfo"` (`:359`).

### 3.5 Server-generated fields the client depends on

- **socket `sid`** becomes `myPeerId` and is used as `peer_id` in every outgoing
  `peerStatus` (`:93`, `:280`, `:386`).
- **`addPeer.peer_id`** keys `peers`, `pendingCandidates`, `remoteVideo`,
  `remoteNames`, and is echoed on `relaySDP`/`relayICE`. The client sends to
  exactly the peer id the server gave it; the server must accept that id as the
  destination.
- **`addPeer.should_create_offer`** is the *only* offer trigger. libwebrtc has no
  `negotiationneeded` event, so the native client synthesises the policy: append
  tracks, then offer iff the server said so (`:428`, `:463-468`).
- **`addPeer.iceServers`** is adopted verbatim into `RTCConfiguration`
  (`:436-437`, `iceServers(from:)` `:733-747`). The product has no way to ignore
  them; only the DEBUG probe sets `ignoreServerIceServers`
  (`Prototype/SignalProbe.swift:238`).
- **Ordering:** `addPeer` must precede the first `sessionDescription`/`iceCandidate`
  for that `peer_id`. ICE arriving early is queued (`:550-570`) and flushed only
  immediately after a successful `setRemoteDescription` (`:572-579`); **SDP from
  an unknown peer is discarded outright** (`:521-524`), so an out-of-order SDP
  is a permanent dead end for that pair.

---

## 4. Client call state machine

Authoritative source: `CallSession.Phase` (`Core/CallSession.swift:20-40`).

```swift
enum Phase: Equatable {
    case loading
    case needsLogin
    case ready
    case outgoing(FamilyCall)
    case ringing(FamilyCall)
    case inCall(FamilyCall)
    case failed(String)
}
```

| Transition | Trigger | Site |
| --- | --- | --- |
| `*` → `.loading` | `load()` | `:372` |
| `.loading` → `.needsLogin` | node published a login URL and is not running | `:222-230`, `:395-397` |
| `.loading` → `.ready` | bootstrap succeeded | `:404` |
| `.ready` → `.outgoing` | CallKit accepted, `POST /api/calls` returned | `:302-308`, `:471-479` |
| `.ready` → `.ringing` | SSE `incoming-call`, or bootstrap shows `myStatus == "invited"` | `:737-743`, `:682-685` |
| `.ringing` → `.inCall` | user answers in the system UI → `POST /respond` accepted | `:309-312`, `:496-510` |
| `.outgoing` → `.inCall` | SSE `call-status` with `status == "active"` | `:758-762` |
| `.ready` → `.inCall` | `resume()` after `POST /join` | `:576-589` |
| `.outgoing/.ringing/.inCall` → `.ready` | `tearDown()` | `:560-573` |
| any → `.failed` | `load()` catch | `:433-436` |

Two guards the server must design around:

- `ring(_:)` **drops** an invitation unless the client is idle in `.ready`
  (`:713-716`). A second concurrent invitation is silently lost client-side.
- `adopt`/`refreshState` bail unless `phase.call == nil` (`:681`, `:701`).

Split of authority: **CallKit** owns the system call UI and answered/ended/muted;
**`CallSession`** owns which `FamilyCall` this app is in; the **server** owns call
status; and the **device** owns whether *this device* is in the call, via
`UserDefaults` key `crossbar.currentCallID` (`:102-122`). That last split exists
because Family Call identity is a person, not a device — a second instance
authenticating as the same person sees the same `ongoingCalls[]`, and an Xcode
preview joined a real call that way on 2026-09-18 (`ContentView.swift:100-104`).

The signalling client has **no state machine**: `state` is prose written for a
human (`Core/MiroTalkSignalClient.swift:27`), and the only branchable fact is
`isSocketOpen` (`:35`).

---

## 5. Worked flows

### 5.1 Outgoing 1:1

1. `ContactsView` row button → `session.placeCall(to:)` (`Features/ContactsView.swift:186-190`).
2. `CallKitController.startOutgoing(handle:)` with the **contact id as the handle** (`Core/CallKitController.swift:52-58`).
3. CallKit callbacks `onStart` → `createCall(toContactID:)` (`Core/CallSession.swift:302-308`).
4. `POST /api/calls {inviteeIds:[contactID]}` → `{call, joinUrl}` (`:471-477`).
5. `phase = .outgoing`; `deviceCallID = call.id`; `connect(using: joinUrl)` (`:475-477`).
6. `JoinTarget(joinUrl:)` yields room + origin; `media.startCapture()`; `signal.connect(room:)` (`:580-596`).
7. Engine.IO open → `40` → `sid` captured → `join`.
8. Server sends `addPeer{peer_id:<remote>, should_create_offer:true, peers, iceServers}`.
9. Client appends both tracks to a new `RTCPeerConnection`, then offers → `relaySDP`.
10. ICE trickles via `relayICE` throughout.
11. Remote answers → `sessionDescription` → `setRemoteDescription` → flush queued ICE.
12. Remote tracks → `remoteVideo[peerId]` → `CallVideoGrid` → `CallStage` → `RTCVideoSurface`.

### 5.2 Incoming 1:1

1. SSE `incoming-call` → membership check against `participants[].userId` (`:737-743`).
2. `ring(_:)` → `phase = .ringing` → `callKit.reportIncoming(callID: UUID(call.id), …)` (`:712-731`).
3. User answers on the **system** banner → `accept()` → `POST /respond {response:"accepted"}` (`:496-510`).
4. `connect(using: envelope.joinUrl)`; the server sends this peer
   `addPeer{should_create_offer:false}`, so it appends tracks and waits for the offer.

**The callee never dials the room before answering.** Ringing is a control-plane
event; the signalling socket opens only after `/respond` returns a `joinUrl`.

### 5.3 Decline, cancel, end

- **Decline** is `end()` (`:533-535`); because phase is `.ringing`, CallKit's end
  callback routes to `POST /respond {response:"declined"}` (`:541-553`). The
  response's missing `joinUrl` is tolerated (`JoinEnvelope.joinUrl` is optional).
- **Cancel** of an outgoing call that never connected: `abandonCall(reason:)` ends
  the CallKit transaction and tears down — **no HTTP cancel is issued**, because
  the failure was the create itself (`:486-492`).
- **End** of an established call: `POST /api/calls/:id/end`, which the backend
  applies **call-wide**, not per participant (`:541-553`; backend `src/db.js:385-399`).
  There is no per-participant leave anywhere in the client.
- **Server-driven end:** SSE `call-status` in `{ended,cancelled,declined,missed}`
  → tear down, then tell CallKit (`:745-757`).

### 5.4 Teardown on the signalling wire

`MiroTalkSignalClient.disconnect()` closes every `RTCPeerConnection`, cancels the
WebSocket with `.goingAway`, and invalidates the `URLSession`
(`:177-193`). **It emits no `leave`, no `disconnect`, and no final `peerStatus`.**
Every departure is inferred server-side from socket close, and the server must
generate the `removePeer` that other peers receive. Any new protocol that
requires a client goodbye message will not be honoured by this client as written.

---

## 6. Multiparty: what exists and what does not

**Exists**

- The signalling client is structurally a mesh: `peers` is keyed by remote socket
  id and `handleAddPeer` creates one `RTCPeerConnection` per `addPeer`, adding the
  same two shared tracks to each (`Core/MiroTalkSignalClient.swift:62`, `:416-470`).
- A single capture feeds every sender (`Core/CallMediaSource.swift`), which is what
  the product requires.
- The UI renders N participants: `CallStage.arrangement` has explicit 0/1/2/3+
  layouts (`Features/CallStage.swift:103-124`) and `InCallView` renders
  `"Connected · N people"` (`Features/InCallView.swift:108-113`).
- CallKit is provisioned for four: `maximumCallsPerCallGroup = 4`
  (`Core/CallKitController.swift:32`).
- A three-peer mesh has been measured on device (three native peers, three links,
  all `pc state 2`, media both ways — `docs/NATIVE_PROGRESS.md`).

**Does not exist**

| Gap | Evidence |
| --- | --- |
| Cannot invite a second participant — `inviteeIds` is always length 1 | `Core/CallSession.swift:474`; `Features/ContactsView.swift:186-190` |
| Never reads the `addPeer.peers` roster; learns peers only from individual `addPeer` events | `:416-429` |
| `FamilyGroup`/`groups` decoded and unused (log line only) — no group-call path | `Core/FamilyCallClient.swift:59-76`, `:329-331` |
| No `serverInfo`, `unauthorized`, `roomIsLocked`, `peerName` handling | `:311-318` |

The **Add Person** flow the product needs is missing on both wires: the client
never calls a per-call invite route, and although the backend implements
`POST /api/calls/:id/invite` (`src/server.js:290-311`) nothing invokes it. The
mesh itself, however, needs no new server concept: a third participant is another
`addPeer` pair.

---

## 7. Reconnect and failure behavior

| Situation | Current behavior | Site |
| --- | --- | --- |
| SSE stream drops | exponential backoff `min(30, 2^failures)`, `eventsDown = true`, then `GET /api/bootstrap` | `Core/CallSession.swift:637-661`, `:700-709` |
| Signalling socket drops | **nothing** — state becomes `"closed"`, no re-dial, no watchdog, no backoff | `Core/MiroTalkSignalClient.swift:207-209`, `:251-253` |
| App returns to foreground | `reverifyCarrier()`: verify or rebuild the node, re-dial the control plane, restart SSE, and re-`join` the signalling socket **only if it is already closed** | `Core/CallSession.swift:238-259` |
| Node loopback went stale after suspension | intermittent; the app verifies rather than assumes, and a rebuild creates a *new* address everything must be re-pointed at | `Core/TailnetNode.swift:322-345` |
| Cold launch while a call is live | resumes only a call **this device** previously joined (`deviceCallID`); otherwise it only rings an outstanding invitation found via `myStatus == "invited"` | `Core/CallSession.swift:102-122`, `:680-691` |
| Call invitation arrived while suspended | found by re-reading `/api/bootstrap` at launch | `:682-685` |

The client therefore needs from a server: (a) `addPeer`/`sessionDescription`/
`iceCandidate` delivered in the order described in §3.5, (b) a fresh `joinUrl`
from `POST /join` when resuming, and (c) an authoritative `/api/bootstrap`.

There is **no server-side reconnection support**: the backend has no session
concept, and MiroTalk has no room persistence — a MiroTalk restart destroys every
room (`app/src/server.js:404-408`; verified no persistence anywhere).

---

## 8. Identity and trust

**Control plane.** The client presents no credential. The backend accepts
`tailscale-user-login` **only when the TCP peer is loopback**
(`src/identity.js:19-22`) and refuses to bind a non-loopback host at all
(`src/config.js:59-62`), so the client must traverse tailnet Serve, which injects
the header. Verified on device: `GET /api/session` returned
`HTTP 200 authenticated=true identity.source=tailscale` with the enrolled display
name and **no `Origin` header** (`docs/CROSSBAR_ARCHITECTURE.md`, "Native client
contract"; probe `Prototype/BackendReachabilityProbe.swift`).

Implication for a new server: **identity is network position today.** Any client
that can reach the listener is that identity. Application-level identity does not
exist yet.

**Signalling.** Zero authentication: `peer_token: null`, `channel_password: null`,
no header, no cookie, no query token (`Core/MiroTalkSignalClient.swift:346-347`).
The client therefore assumes room names are the only access control and are not
themselves secret. The deployed MiroTalk confirms this: with
`HOST_PROTECTED=false` and `HOST_USER_AUTH=false`, any room name is joinable by
anyone who can reach the socket.

**Data the client trusts from the server:** the `joinUrl` origin (used as the
signalling host, no allow-list), and `addPeer.iceServers` (adopted verbatim,
including TURN credentials).

---

## 9. What the client requires the server to guarantee

1. `GET /api/session` answers with `{authenticated, configured, identity:{name}}`, cheaply, and any status counts as "the carrier works" for the node's liveness probe.
2. All routes are reachable with only `accept`/`content-type` — **no `Origin` will ever be sent**.
3. Errors are `{error:{code,message}}`.
4. `call.id` is a UUID string.
5. `FamilyCall.myStatus` is present in `/api/bootstrap`'s `calls[]`, because the client filters on `myStatus == "invited"`.
6. `/api/bootstrap` is a complete snapshot of outstanding state — the SSE stream has no replay, so it is the only recovery mechanism.
7. SSE keeps a heartbeat comment inside 120 s and emits `ready`, `incoming-call`, `call-status`, `ongoing-call`, `presence`, with the three call events carrying `callPublic` **unwrapped**.
8. `POST /api/calls/:id/join` works with an **empty body** for a device re-joining a call it was already in.
9. The signalling endpoint completes an Engine.IO v4 handshake on a raw WebSocket and returns a Socket.IO `sid`.
10. `join` is accepted with `channel` + `peer_uuid` + `peer_name` and no token.
11. One `addPeer` per required pair, `should_create_offer` true only for the joiner, `iceServers` always present (possibly empty), and **`addPeer` strictly before any SDP/ICE for that peer**.
12. `sessionDescription` uses `type` exactly `"offer"` or `"answer"`; `iceCandidate` may omit `sdpMid`.
13. The server itself emits `removePeer` on socket close — the client never says goodbye.
14. `peerStatus` is rebroadcast with the **sender's** `peer_id` and `element == "video"`.
15. Media coordinates arrive as a room plus a signalling endpoint; today that is smuggled through a web `joinUrl`, and the origin is trusted without validation.

---

## 10. Open questions this document does not answer

- Whether the room id may be exposed as a first-class field, or must remain
  derivable only from a `joinUrl`. That is a client-contract change and is
  treated in `CROSSBAR_SERVER_REQUIREMENTS.md`.
- Whether an audio-only call kind is required (the backend hardcodes
  `audio:true, video:true` in `src/mirotalk.js:25-26`).
- Whether a per-participant leave is required for four-person calls, given
  `/end` is call-wide (`src/db.js:385-399`).
