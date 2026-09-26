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

**Re-checked:** 2026-09-24, same working tree, for the order in which a device is
set up, the two push tokens it files once it is, and the two identity modes. The
claims added then carry today's `file:line` as well.

This document is the input to
[`CROSSBAR_SERVER_REQUIREMENTS.md`](CROSSBAR_SERVER_REQUIREMENTS.md). It does not
propose a design.

---

## 1. Two wires, one transport

Crossbar is a two-protocol client. It speaks to two independent server systems,
and nothing in the client couples them beyond a shared route.

| Wire | Client type | Server today | Auth on the wire |
| --- | --- | --- | --- |
| Control plane | `ServiceClient` — HTTPS JSON + one SSE stream | Family Call service (`127.0.0.1:3001`) behind tailnet Serve on 8443 | none from the client; Tailscale Serve injects `tailscale-user-login`, which the server believes only in private mode (§8) |
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

Base URL, in authority order (`Core/ServiceClient.swift:171-180`):

1. `CROSSBAR_BACKEND_URL` environment variable (`:172`)
2. `AppSettings.serviceAddress` → `UserDefaults` key `crossbar.serviceAddress` (`:175`)
3. compiled default `https://qatar-vpn.tailea67b0.ts.net:8443` (`:163`)

Every request sets two headers beyond `Host`, and a third when it has a body
(`Core/ServiceClient.swift:339-346`):

```swift
request.setValue("application/json", forHTTPHeaderField: "accept")   // :341
request.timeoutInterval = 20                                          // :342
// only when a body exists:
request.setValue("application/json", forHTTPHeaderField: "content-type") // :345
```

A device that has enrolled sets one more, and only while it holds one:
`authorization: Bearer <session>` (`Core/ServiceClient.swift:358-365`; §2.6).
A device that never enrolled — which is every device in private mode — sets
nothing beyond the three above.

**No cookie, and deliberately no `Origin`** — the Family Call backend rejects
only an `Origin` that is present *and* mismatched, so omitting it is what makes
the POST routes reachable (`Core/ServiceClient.swift:193-197`; backend
`src/server.js:97-105`).

Failure handling: non-2xx is parsed as `{error:{code,message}}` and surfaced as
`ServiceError(status:code:message:)` (`Core/ServiceClient.swift:253-266`).
There is **no retry, no backoff, and no idempotency key anywhere in the client**.

### 2.2 Route table

| # | Method and path | Client function | Body | Response | Product? |
| --- | --- | --- | --- | --- | --- |
| 1 | `GET /api/session` | `checkSession()` `:282-294` | — | `{authenticated:Bool, configured:Bool, identity:{name}}` | yes — gate in `load()` |
| 2 | `GET /api/push/config` | `pushConfig()` `:306-313` | — | `{enabled:Bool, publicKey:String}` | **no — DEBUG probe only** |
| 3 | `GET /api/bootstrap` | `bootstrap()` `:320-333` | — | `Bootstrap` `:70-76` | yes |
| 4 | `GET /api/calls/:id` | `call(id:)` `:338-341` | — | `{call:Call}` | **no — never called by the product** |
| 5 | `POST /api/calls` | `createCall(inviteeIds:)` `:347-354` | `{inviteeIds:[String]}` | `{call, joinUrl?}` | yes — always one invitee |
| 6 | `POST /api/calls/:id/respond` | `respond(callId:accepted:)` `:357-364` | `{response:"accepted"\|"declined"}` | `{call, joinUrl?}` | yes |
| 7 | `POST /api/calls/:id/join` | `join(callId:)` `:368-372` | **none** | `{call, joinUrl?}` | yes — resume path |
| 8 | `POST /api/calls/:id/end` | `end(callId:)` `:376-379` | **none** | `{call:Call}` | yes — call-wide |
| 9 | `POST /api/devices/push-token` | `uploadPushToken(deviceId:token:environment:kind:)` `:595-604` | `{deviceId, token, environment, kind}` | `{saved:Bool}` | yes — one call per kind, twice per device (§2.6) |

`GET /api/session` is additionally used as a *carrier liveness probe* by
`TailnetNode.carriesARequest` with a 5 s timeout, where **any** HTTP response
counts as success regardless of status (`Core/TailnetNode.swift:346-357`). A new
server must therefore answer that path cheaply and must not treat a 401/403 as a
transport failure.

### 2.3 Wire models the client decodes

`Call` (`Core/ServiceClient.swift:34-46`):

```swift
struct Call: Decodable {
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
(`Core/ServiceClient.swift:26-33`): `callPublic` includes `participants` but
never `roomId`; `calls[]` from `/api/bootstrap` has `myStatus` and omits
`participants`; `ongoingCalls` is `callPublic`.

**Constraint:** `call.id` must be a UUID string. `CallSession.ring(_:)` maps it
with `UUID(uuidString:)` before telling CallKit, and a non-UUID id means **CallKit
is never told about the call at all** — the call rings on screen but not on the
system UI (`Core/CallSession.swift:727-729`).

### 2.4 The `joinUrl` is the only carrier of media coordinates

`callPublic` omits `roomId` deliberately. The only place a client learns which
room to join, and which host to join it on, is the `joinUrl` string returned by
routes 5, 6 and 7 (`Core/ServiceClient.swift:99-133`):

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
  (`Core/ServiceClient.swift:395-399`).
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

### 2.6 The device: setup, its session, and its two push tokens

**The order a device is set up in.** `DeviceAuth.settle(from:)` reads the
enrolment code into settings — the address and the mode — without dialling
anything (`Core/DeviceAuth.swift:114-135`); `CallSession.attachForSetup()` builds
the network through the one place that chooses a route, `attachTransport()`
(`Core/CallSession.swift:470-503`); and `OnboardingView` enrols only once that
carrier exists (`Features/OnboardingView.swift:236`, `:250`, `:254`). The
enrolment is therefore the first request a new device makes, and its first
request already has a network to leave by. A deployment that answers "could not
reach the service" on the first screen anybody sees is one the client dialled
before its own network was up, which is a client ordering fault and not a server
one.

**Two push tokens per device, filed separately by kind.**
`POST /api/devices/push-token` files one token per kind, and the client calls it
twice: once with `kind: "voip"` — the token a ringing call is delivered to — and
once with `kind: "alert"`, for a call the phone did not answer
(`Core/ServiceClient.swift:576-604`). Each call also carries the
`environment` whose APNs minted the token, because a token offered to the other
environment is refused with nobody told why. The route answers `{saved: true}`
(`Core/ServiceClient.swift:757`). An omitted `kind` is read as `alert`, which
is the right reading of a client written before kinds existed and the wrong one
for this client, so this one never omits it.

**Being enrolled is not being ringable.** They are two facts, recorded
separately: `hasPushToken` says this device can be sent something, and
`hasVoipToken` says this device **can be rung while it is asleep** (the Crossbar
server, `server/src/api.js`, `adminDevice`). A device that is enrolled, is
listed, and holds an alert token and no VoIP token can therefore be told about a
call and still never rung — a state the device list has to be able to show, which
is why `node src/admin.js devices` says it in a `RING` column (`yes`/`NO`).

**A token may be filed in a launch later than the one that minted it.** PushKit
announces the VoIP token once per launch, *before any load runs*, so at that
moment there is either no device to file it against or no transport to file it
over, and a first launch has both problems. The client holds it across both and
files it once a load has settled, clearing it only when the service accepts it
(`Core/CallSession.swift:627`, `:641-706`). The server's side of that is that a
token may arrive minutes — or launches — after it was issued, and it must be
filed against the device the body names rather than against whoever the socket
appears to be.

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
    case outgoing(Call)
    case ringing(Call)
    case inCall(Call)
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
**`CallSession`** owns which `Call` this app is in; the **server** owns call
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
| `DirectoryGroup`/`groups` decoded and unused (log line only) — no group-call path | `Core/ServiceClient.swift:59-76`, `:329-331` |
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

**Control plane.** In private mode the client presents no credential of its own,
and the person is whoever the proxy says: Serve injects `Tailscale-User-Login`
into the request, the server believes it only when the connection came from
loopback, and the listener binds loopback in **both** modes, so "loopback" and
"through the proxy" are the same statement (the Crossbar server,
`server/src/identity.js`, `server/src/config.js`). Measured on device,
2026-09-24: `GET /api/session` over the tailnet answered
`identity: {source: "tailscale"}`, resolving to `abdullah`.

**The header arrives in both modes; it is believed in only one.** In public mode
the header would be supplied by whoever sent it, so `TRUST_TAILSCALE_HEADERS` is
on in private mode, must be off in public, and a public configuration that turns
it on is refused rather than honoured (`server/src/config.js`). A public
deployment therefore decides identity by the device's own key instead: the device
answers a challenge, every later request carries `authorization: Bearer
<session>` (§2.1, §2.6), and that session wins over anything the transport says
(`server/src/api.js`, `currentUser`).

Implication for a server: in private mode **identity is network position** — any
client that can reach the listener through the proxy is that identity — and that
is only defensible where the header is trusted, which is the mode that has a
proxy in front of it. Public mode is where "reachable" and "that person" are
allowed to be different statements, and it is the mode that needs the key.

**Signalling.** Zero authentication from the client: `peer_token: null`,
`channel_password: null`, no header, no cookie, no query token
(`Core/MiroTalkSignalClient.swift:346-347`). The client therefore presents
nothing that could identify it, and a room name cannot be the access control
either: the Crossbar server decides admission from the identity the upgrade
request already carries — the injected header, or the device's own key —
together with the caller's participation in the call the room names
(`server/src/signal.js`; `CROSSBAR_SIGNALING_PROTOCOL.md` §2). A room name is
worth nothing on its own.

**Data the client trusts from the server:** the `joinUrl` origin (used as the
signalling host, no allow-list), and `addPeer.iceServers` (adopted verbatim,
including TURN credentials).

---

## 9. What the client requires the server to guarantee

1. `GET /api/session` answers with `{authenticated, configured, identity:{name}}`, cheaply, and any status counts as "the carrier works" for the node's liveness probe.
2. All routes are reachable with only `accept`/`content-type` — **no `Origin` will ever be sent**.
3. Errors are `{error:{code,message}}`.
4. `call.id` is a UUID string.
5. `Call.myStatus` is present in `/api/bootstrap`'s `calls[]`, because the client filters on `myStatus == "invited"`.
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
16. `POST /api/devices/push-token` files one token per kind against the device the body names — `voip` for a call that rings, `alert` for one that was missed — and a token filed in a launch later than the one that minted it still lands on that device. Enrolment is not ringability: the server must be able to say which of its devices can be rung while asleep (`hasVoipToken`), not only which can be sent something.

---

## 10. Open questions this document does not answer

- Whether the room id may be exposed as a first-class field, or must remain
  derivable only from a `joinUrl`. That is a client-contract change and is
  treated in `CROSSBAR_SERVER_REQUIREMENTS.md`.
- Whether an audio-only call kind is required (the backend hardcodes
  `audio:true, video:true` in `src/mirotalk.js:25-26`).
- Whether a per-participant leave is required for four-person calls, given
  `/end` is call-wide (`src/db.js:385-399`).

---

## 11. `GET /api/health` — the address a client may follow

Added 2026-09-26, after the audit above, and on the same terms: this section is a **guarantee
about the Crossbar server**, not an observation of the stack §1–§10 describe. Where the two
differ, this is the contract the client is being written against.

`GET /api/health` is unauthenticated, and stays unauthenticated. The question it answers has
to be answerable *before* anything has authenticated: a device whose deployment has moved may
not be able to authenticate at all, and this is how it learns that is what happened rather
than guessing at a network fault.

```json
{ "status": "ok", "mode": "private" | "public", "version": "0.1.0", "origin": "https://…" }
```

- `mode` — the trust posture: `private` (reached over a tailnet) or `public` (over the
  internet). The same two words the service uses everywhere (§8).
- `version` — the version of the running process. This is the one question nothing else can
  answer: the CLI can be a shell's checkout and a file can be anything, so the running process
  is the only thing that knows what it is.
- `origin` — the address the server believes it is reached at.

**Additive only, and that is the frozen part.** A device and a server are never upgraded
together, so a phone may be a build behind the service answering it, or ahead of it. Every
field MUST be read as optional, and a missing or unrecognised field is an ordinary peer —
older or newer — never a malformed answer. Nothing may fail, retry, or refuse to proceed
because a field it has never heard of arrived, or because one it expects did not.

`origin` is the one field a client may **act** on: it is how a device dialling a deployment
that has switched learns where the deployment went. A client that follows it adopts the new
address and the `mode` alongside it, and **leaves its device key untouched**: the key is an
identity rather than a token tied to a host, the service holds its public half, and the same
key authenticates at either door. Re-enrolment — an administrator issuing a code and
hand-approving a device that did nothing wrong — is the failure this route exists to prevent.
An `origin` that cannot be dialled (no scheme or no host) MUST leave the device where it is.

The server also opens the new front door before it closes the old one, so the address a client
holds keeps answering for a grace period after a switch — long enough for the next load to be
told where the deployment went. That overlap is in the mode units now
(`CROSSBAR_SWITCH_GRACE_SECONDS`, 900 seconds by default, and a transient `systemd-run` unit
that closes the old door when it fires), but nothing has rehearsed it yet. What a client still
cannot rely on is `origin` itself: the route in the server tree answers `status`, `mode` and
`version`, and the field lands with the mode work. Until both are true, a switch still ends in a
device being set up again. The app's side of it is `Core/CallSession.swift`, `followMovedServer`.
