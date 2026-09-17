# MiroTalk P2P core audit for Crossbar

## Scope and confidence

This is the durable Crossbar copy of the source audit completed against the
installed production MiroTalk source on 2026-09-16. The production tree was
inspected read-only. It was not re-fetched or modified during the 2026-09-17 OMP
handoff.

The audit traces the essential call path sufficiently to define a minimal
runtime and signaling contract. It does not claim that an extraction has been
implemented or tested from Crossbar.

## Audited provenance

| Item | Audited value |
| --- | --- |
| Upstream | `https://github.com/miroslavpejic85/mirotalk.git` |
| Product/version | MiroTalk P2P 1.9.64 |
| Upstream commit | `5af51e0cf2fd38bc296574f8d4aff9a19ea318c5` |
| Production path | `/home/admin/mirotalk` on `qatar-vpn` |
| License | GNU Affero General Public License v3 (AGPLv3) |
| Production source difference | deliberate server bind change to `127.0.0.1` |
| Code copied/adapted into Crossbar | None |
| Crossbar MiroTalk modifications | None |

Production also contained untracked backup/configuration files that may hold
secrets. They were not copied or documented. Never clean/reset/stage that tree
casually.

## Executive findings

1. The required signaling protocol is small: Socket.IO connect/disconnect plus
   `join`, `addPeer`, SDP relay, ICE relay, and `removePeer`.
2. Multiparty is a pairwise mesh. When C joins A and B, the server creates A-C
   and B-C relationships without replacing A-B.
3. The browser media implementation is not a reusable module. Essential logic
   is embedded in a roughly 18,297-line `public/js/client.js` and calls meeting
   UI, chat/file, settings, sounds, whiteboard, and accessibility helpers.
4. Architecture A therefore requires a deliberate extraction/refactor, not
   loading the existing meeting page or hiding it with CSS.
5. A native Swift WebRTC client would reproduce nearly all behavior under
   **Core media engine**. It would reuse the signaling server, not MiroTalk's
   proven browser engine.
6. Production delivered `iceServers: []` at audit time because STUN and TURN
   were disabled. Calls rely on direct candidates/private topology.

   **Corrected 2026-09-17 from live evidence.** A native client's `addPeer`
   payloads carried `"iceServers":[{"urls":"stun:stun.l.google.com:19302"}]`, so
   the deployed server does hand out Google's public STUN and the statement above
   is not current. See `CROSSBAR_ARCHITECTURE.md`, "Native signalling executed".
7. Direct copying/adaptation into a distributed app raises AGPLv3 obligations.
   Licensing approval precedes extraction.

## Source inventory

Line numbers refer to the audited installed 1.9.64 commit.

### Server

| Source | Responsibility | Classification |
| --- | --- | --- |
| `app/src/server.js:101-145` | HTTP/TLS and Socket.IO initialization; WebSocket transport | Core/signaling |
| `app/src/server.js:199-213` | Effective STUN/TURN `iceServers` construction | Core media configuration |
| `app/src/server.js:404-415` | `channels`, `sockets`, `peers`, `presenters`, counts | Room/peer state |
| `app/src/server.js:1021-1040` | authenticated REST join URL creation | Family Call adapter dependency |
| `app/src/server.js:1293-1323` | socket connect/disconnect and room cleanup | Signaling/lifecycle |
| `app/src/server.js:1439-1659` | `join` validation, room/peer insertion, `addPeerTo`, `serverInfo` | State/signaling |
| `app/src/server.js:1686-1715` | `relayICE` and `relaySDP` forwarding | Signaling |
| `app/src/server.js:1910-1968` | `peerStatus` update/broadcast | PWA interoperability metadata |
| `app/src/server.js:2433-2451` | `addPeerTo`; mesh-pair creation and offerer selection | Core mesh |
| `app/src/server.js:2457-2509` | `removePeerFrom`; state deletion and notification | Core lifecycle |
| `app/src/server.js:2527-2549` | `sendToRoom` and `sendToPeer` helpers | Signaling transport |

Other socket handlers cover optional meeting features such as chat, files,
whiteboard, captions, transcription, media-player synchronization, drawing,
moderation, and commands.

### Browser client

| Source/function | Responsibility | Classification |
| --- | --- | --- |
| `public/js/client.js:1470-1548`, `initClientPeer` | Socket.IO client creation and event registration | Core connection; registrations mostly optional |
| `public/js/client.js:1576-1608`, `handleConnect` | initial media setup and reconnect/rejoin | Core lifecycle |
| `public/js/client.js:2797-2820`, `joinToChannel` | emits join payload | Signaling contract |
| `public/js/client.js:2827-2907`, `handleAddPeer` | constructs/stores `RTCPeerConnection`, hooks callbacks, adds tracks | Core media, UI-coupled |
| `public/js/client.js:2927-2939` | connection-state observation | Core lifecycle |
| `public/js/client.js:2947-3002`, `handleOnIceCandidate` | local ICE emission | Core ICE |
| `public/js/client.js:3009-3080` | remote track reception and media loading | Core media, UI-coupled |
| `public/js/client.js:3087-3120` | camera/screen/microphone `addTrack` | Camera/mic core; screen optional |
| `public/js/client.js:3130-3186` | chat/file data channels | Optional |
| `public/js/client.js:3212-3239`, `handleRtcOffer` | `onnegotiationneeded`, offer, local description, relay | Core SDP |
| `public/js/client.js:3246-3305`, `handleSessionDescription` | remote description, ICE flush, answer/local description/relay | Core SDP |
| `public/js/client.js:3312-3366`, `handleIceCandidate` | construct, queue, and apply remote ICE | Core ICE |
| `public/js/client.js:3373-3435` | disconnect cleanup/reconnect flag | Core lifecycle plus UI cleanup |
| `public/js/client.js:3444-3515`, `handleRemovePeer` | one-peer close/delete/UI cleanup | Core lifecycle plus UI cleanup |
| `public/js/client.js:4104-4194` | camera and microphone `getUserMedia` setup | Core local media |
| `public/js/client.js:8744-8810` | production audio/video constraints | Core local media |
| `public/js/client.js:9266-9377` | mute and camera controls/status | Core track state plus UI |
| `public/js/client.js:9402-9433` | front/rear camera switching | Core local media |
| `public/js/client.js:9837-9928` | `replaceTrack`, add/remove sender, late negotiation | Core renegotiation |
| `public/js/client.js:16946-16992` | meeting leave via navigation | UI behavior to replace with explicit teardown |
| `public/views/client.html:2114-2170` | meeting dependencies/scripts | Mostly optional/UI-only |

## Core media engine

### Local camera and microphone

The audited client acquires camera and microphone separately:

- `setupLocalVideoMedia()` calls
  `navigator.mediaDevices.getUserMedia({video: getVideoConstraints('default')})`
  and falls back to `{video:true}`;
- `setupLocalAudioMedia()` calls `getUserMedia(getAudioConstraints())`, checks
  the initial track, and can retry with `{audio:true}`;
- default video constraints are ideal 1280x720 at 30 fps;
- audio requests echo cancellation and automatic gain control and, when custom
  RNNoise is disabled, browser noise suppression.

A minimal runtime should retain separate audio/video acquisition so an
audio-only call does not request camera permission. It should surface errors to
Swift rather than calling MiroTalk modal/UI helpers.

### Peer connections and mesh

`handleAddPeer(config)` creates:

```javascript
new RTCPeerConnection({ iceServers })
```

The object is stored by remote Socket.IO ID. The function installs connection,
candidate, remote-track, and negotiation handlers, chooses whether this peer is
the offerer, and adds local camera/microphone tracks.

The following coupled calls are not core and must not be dragged into the
runtime merely because they occur nearby:

- profile/UI emission helpers;
- chat/file data-channel setup;
- meeting-tile construction;
- whiteboard updates;
- sounds and screen-reader announcements;
- conference settings/buttons.

Remote `MediaStream` objects should remain rendered by minimal `<video
playsinline autoplay>` and `<audio autoplay>` elements within the media-only
WebKit surface. Passing browser streams directly to native SwiftUI renderers is
not a standard bridge and would undermine Architecture A.

### Offer/answer behavior

For each new pair, the server makes the newly joining client the offerer:

- existing peer receives `addPeer` with `should_create_offer:false`;
- joining peer receives `addPeer` with `should_create_offer:true`.

The offerer uses `createOffer()`, `setLocalDescription()`, and `relaySDP`. The
answerer applies the offer with `setRemoteDescription()`, flushes queued ICE,
uses `createAnswer()`, sets its local description, and relays it. The offerer
applies the returned answer through the same session-description handler.

The implementation is not the WebRTC perfect-negotiation pattern. It relies on
server-selected offer direction and a late-track flag. Preserve compatibility
before attempting negotiation redesign.

### ICE

The browser sends:

```json
{
  "peer_id": "target Socket.IO id",
  "ice_candidate": {
    "sdpMLineIndex": 0,
    "candidate": "candidate:..."
  }
}
```

The receiver constructs `RTCIceCandidate`. Candidates arriving before the peer
connection/remote description are queued per peer and flushed after
`setRemoteDescription()` succeeds. The runtime must consume server-delivered
`iceServers`; it must never hard-code a public STUN/TURN provider.

### Tracks and controls

- Initial microphone/camera tracks are added with `addTrack`.
- Mute changes the audio track's `enabled` state and emits `peerStatus` so
  existing MiroTalk clients update correctly.
- Camera-off in MiroTalk stops the camera track and later reacquires it; this is
  not identical to the simple probe's current `enabled` toggle.
- Camera/device switching reacquires media and calls
  `RTCRtpSender.replaceTrack` for every peer.
- When a required sender does not exist, MiroTalk adds the track and triggers
  negotiation.

### Remote tracks

The installed client handles remote audio/video track events in
`public/js/client.js:3009-3080`, then routes streams into meeting DOM helpers.
Crossbar needs the track handling and minimal media elements, not tile controls,
avatars, chat affordances, pin/full-screen buttons, or meeting layout code.

### Connection state and reconnection

Socket.IO owns transport reconnection. On disconnect, MiroTalk closes peer
connections, clears connection/candidate/media maps, and marks the client for
rejoin. A subsequent Socket.IO `connect` gets a new socket ID and sends `join`
again using retained local media.

The server removes the old socket from rooms and emits `removePeer`. The
durable `peer_uuid` helps presenter recovery but is not the transient peer
connection key.

Crossbar must report reconnecting/rejoined/failed separately from the Family
Call application's call lifecycle. A transient media reconnect must not
silently end the backend call.

### Teardown

The meeting UI currently leaves by navigating away. A minimal runtime needs an
explicit, idempotent teardown that:

1. stops every local track;
2. closes every peer connection;
3. disconnects Socket.IO;
4. clears peer, candidate, stream, and media-element maps;
5. emits one `left` event to Swift.

## Signaling contract

Socket.IO uses the MiroTalk origin, default namespace, and WebSocket transport.

| Event | Sender -> receiver | Payload | Purpose/timing | Requirement | Source |
| --- | --- | --- | --- | --- | --- |
| `connect` | Socket.IO -> client | socket lifecycle; new `socket.id` | initial connection/reconnect | Mandatory | client `initClientPeer`/`handleConnect`; server socket connection handler |
| `join` | client -> server | join schema below | after identity/media readiness; again after reconnect | Mandatory | client `joinToChannel`; server `socket.on('join')` |
| `addPeer` | server -> client | `{peer_id, peers, should_create_offer, iceServers}` | one event per required peer pair | Mandatory | server `addPeerTo`; client `handleAddPeer` |
| `relaySDP` | client -> server | `{peer_id, session_description:{type,sdp}}` | send local offer/answer to target | Mandatory | client offer/description handlers; server relay handler |
| `sessionDescription` | server -> target client | `{peer_id:<sender>, session_description:{type,sdp}}` | deliver offer/answer | Mandatory | server relay handler; client `handleSessionDescription` |
| `relayICE` | client -> server | `{peer_id, ice_candidate:{sdpMLineIndex,candidate}}` | send each local candidate | Mandatory | client `handleOnIceCandidate`; server relay handler |
| `iceCandidate` | server -> target client | `{peer_id:<sender>, ice_candidate:{sdpMLineIndex,candidate}}` | deliver remote candidate | Mandatory | server relay handler; client `handleIceCandidate` |
| `removePeer` | server -> client | `{peer_id}` | remote socket leaves/disconnects | Mandatory | server `removePeerFrom`; client `handleRemovePeer` |
| `disconnect` | Socket.IO -> client/server lifecycle | reason | transport loss, server close, or client leave | Mandatory | both disconnect handlers |
| `serverInfo` | server -> joined client | capability/state object | after successful join | Conditional; minimal runtime needs errors/capabilities actually used | server join; client `handleServerInfo` |
| `peerStatus` | client -> server -> room | client `{room_id,peer_name,peer_id,element,status,extras}`; rebroadcast omits room | audio/video status interoperability | RTP-optional; required for correct existing PWA UI | server status handler; client emit/handle functions |
| `peerName` | client -> server -> room | name/avatar update schemas | profile update/late broadcast | Optional if identity immutable | server/client profile handlers |
| `unauthorized` | server -> client | no payload | invalid authentication/token | Mandatory error path when enabled | server join; client handler |
| `roomIsLocked` / `roomIsJoinLocked` | server -> client | no payload | policy rejects join | Conditional error path | server join; client registration |

### `join` payload

Minimum compatible shape inferred from the installed client/server:

```json
{
  "join_data_time": "display/debug timestamp",
  "channel": "private MiroTalk room UUID",
  "channel_password": null,
  "peer_info": {
    "osName": "iOS",
    "osVersion": "...",
    "browserName": "Crossbar WebKit Runtime",
    "browserVersion": "...",
    "extras": {}
  },
  "peer_uuid": "stable runtime/device-session UUID",
  "peer_name": "trusted Family Call display name",
  "peer_avatar": "trusted HTTPS URL or empty",
  "peer_token": null,
  "peer_video": true,
  "peer_audio": true,
  "peer_video_status": true,
  "peer_audio_status": true,
  "peer_screen_status": false,
  "peer_hand_status": false,
  "peer_rec_status": false,
  "peer_privacy_status": false,
  "userAgent": "runtime user agent"
}
```

`peer_info` must be an object because the audited server destructures it. Peer
identity must come from the authenticated Family Call backend, never arbitrary
product UI entry.

### `addPeer` payload and metadata

`peers` is the room's current peer map keyed by socket ID. A peer entry includes
name/avatar, presenter flag, audio/video capability/status, screen/hand/
recording/privacy status, OS/browser strings, and `extras`. The map can also
contain room metadata keys such as `lock`, `password`, or `joinLock`; the client
must not treat those as peer IDs.

## Minimum room/peer state

### Server

- `sockets[socketId]` for connected sockets;
- `channels[roomId][socketId]` for successful room membership;
- `peers[roomId][socketId]` for peer metadata/status;
- `presenters[roomId][socketId]` for MiroTalk authorization state;
- `socket.channels` for disconnect cleanup;
- effective `iceServers` sent in every `addPeer`.

The REST `POST /api/v1/join` does not create a durable room; it constructs a
direct-join URL. In-memory room state begins when the first socket sends `join`
and disappears after the last leaves. Family Call durably owns application call
ID -> private room UUID.

### Client

- room ID and trusted display identity;
- stable `peer_uuid` and current transient socket ID;
- local camera/microphone streams and current status;
- `peerConnections[remoteSocketId]`;
- peer identity/status map;
- pending ICE candidates per remote peer;
- minimal remote audio/video element registry;
- reconnect and bridge-visible engine state.

## Multiparty sequence

For A and B already connected, adding C uses the same Family Call room UUID.
The MiroTalk server sends `addPeer(C,false)` to A and B and sends one
`addPeer(existing,true)` event to C for each of A and B. C negotiates separate
C-A and C-B connections while A-B remains. Three people form three links; four
people form six links. There is no C2C switch or SFU in this design.

## Optional MiroTalk functionality

Exclude from the initial Crossbar runtime unless source coupling proves a tiny
piece unavoidable:

- chat, reactions, and chat/file data channels;
- file transfer;
- whiteboard/drawing/locks;
- captions, speech recognition, and transcription;
- audio/video URL player;
- screen sharing;
- recording;
- polls, reactions, hand raise, privacy/blur effects;
- room creation UI, lobby, passwords, manual locks, join locks;
- presenter/moderation/kick UI;
- surveys, redirects, invitation/QR/email UI;
- AI integrations;
- themes, settings panels, analytics, and network-stat UI;
- custom RNNoise for the first implementation.

Do not remove any of these from production MiroTalk as part of Crossbar work.

## UI-only code

The audited `public/views/client.html` is a roughly 2,179-line meeting page and
loads many UI/collaboration dependencies. The global client dynamically creates
meeting tiles and controls. Crossbar must not load that application and hide or
fake-click it.

A valid Architecture A runtime contains only a media canvas, local/remote media
elements, the required Socket.IO client, extracted peer/SDP/ICE/track state,
explicit teardown, and the typed native bridge. SwiftUI owns contacts, names,
navigation, ringing, controls, accessibility, Add Person, and End.

## Security observations

These are audit observations, not authorization to patch production:

1. The random room UUID acts as a bearer capability at the MiroTalk layer.
2. The audited SDP/ICE relay handlers target global socket IDs without an
   explicit same-room membership check; future hardening should verify sender
   and target membership.
3. MiroTalk peer names/status are client-supplied; Crossbar must use trusted
   backend identity.
4. Future TURN credentials require an explicit short-lived credential design;
   never bundle static secrets or add third-party TURN automatically.

## Licensing/provenance gate

MiroTalk P2P is AGPLv3. Family Call's MIT license and original Crossbar code do
not relicense it. Before creating `ThirdParty/MiroTalkCore/`:

1. obtain a specific review for iOS/App Store distribution and network use;
2. decide whether covered source will be offered under AGPL-compatible terms or
   obtain a separately approved upstream license;
3. preserve upstream URL, exact commit, original paths/functions, copyright,
   AGPL license, and notices;
4. add `UPSTREAM.md`, `NOTICE.md`, `LICENSE`, and `CHANGES.md` beside the copied
   subset;
5. document every local modification and corresponding-source delivery;
6. copy only the approved minimal subset, never the full repository.

No commercial/rebranding license is assumed. As of this handoff, files already
copied/adapted: **none**.

## Audit conclusion

The essential call path and signaling contract are identified. The remaining
Architecture A question is not whether the protocol can represent two-to-four
peers; it can. The gating questions are physical iOS CallKit/audio/background
reliability, a maintainable extraction boundary from the monolithic client, and
the AGPL distribution decision. Crossbar has not yet executed this signaling
contract.

## Mesh and negotiation specification (reimplementation reference)

Extracted from the pinned upstream commit `5af51e0c…` to support Architecture B,
where the client is reimplemented in Swift rather than reused. Citations:
`client.js:NNNN` = `public/js/client.js`, `server.js:NNNN` =
`app/src/server.js`, both at that commit.

**Verdict: tractable with care.** The wire protocol is fully determined — what is
sent, and in what shape — and can be implemented from this section without
reference to the original. What is *not* determined is **when the local side
decides to offer**, because MiroTalk delegates that to the browser's
`negotiationneeded` event, which Objective-C libwebrtc does not expose. The port
must re-derive the trigger as explicit policy and validate it against a real
1.9.64 peer. Budget for interop testing, not for porting effort.

### Offer, answer and mesh shape

1. On `join`, the server creates `channels`/`peers`/`presenters` for the room and
   writes the joiner's metadata into the room peer map, then calls
   `addPeerTo(channel)` **before** adding the joiner to `channels`
   (`server.js:1629` vs `server.js:1631`). The `for (let id in channels[channel])`
   loop therefore iterates only pre-existing members, so the joiner is never
   asked to peer with itself.
2. For each existing member the server emits two `addPeer` events
   (`server.js:2433-2451`): to the existing member
   `{peer_id, peers, should_create_offer: false, iceServers}` and to the joiner
   `{peer_id, peers, should_create_offer: true, iceServers}`. `peers` is the
   **entire** room peer map, including the recipient itself and the room-metadata
   keys (`lock`, `password`, `joinLock`). The offerer role is decided once at join
   time and never re-elected.
3. Topology is a pairwise full mesh: N(N−1)/2 independent peer connections.
4. `handleAddPeer` (`client.js:2827-2907`) dedupes against `peerConnections`,
   constructs the connection with **only** `iceServers` set — no
   `iceTransportPolicy`, `bundlePolicy` or `rtcpMuxPolicy`, verified absent — and
   caches `allPeers = peers`, installs handlers, then adds local tracks in the
   order **video → screen → audio** (`client.js:3087-3120`).
5. **Ordering invariant:** handlers are installed and the offer path armed
   *before* tracks are added, so the offerer's single `negotiationneeded` fires
   after its tracks exist.
6. Offer path (`handleRtcOffer`, `client.js:3212-3239`) does nothing but assign
   `pc.onnegotiationneeded = () => createOffer().then(setLocalDescription)
   .then(relaySDP)`. `createOffer(` occurs exactly once in the file, with **no
   arguments**. There is no code path that creates an offer at an
   application-chosen moment.
7. Answer path (`handleSessionDescription`, `client.js:3246-3305`):
   `setRemoteDescription` is applied **unconditionally, with no `signalingState`
   check**, failures logged only. On success it flushes queued ICE **before**
   creating an answer; only for `type == 'offer'` does it `createAnswer` →
   `setLocalDescription` → `relaySDP`, then consume the late-track latch. An
   `answer` does nothing but apply.
8. ICE (`client.js:2947-3002`, `3312-3367`): candidates relay as
   `{sdpMLineIndex, candidate}` only — **`sdpMid` and `usernameFragment` are never
   sent**. The null end-of-candidates event is deliberately dropped. Incoming
   candidates are queued per `peer_id` when the connection is missing or
   `remoteDescription` is unset, and the queue is flushed in exactly one place:
   immediately after a successful `setRemoteDescription`. SDP and ICE are
   unordered on the wire; that queue is the only protection.
9. Remote tracks (`client.js:3009-3080`): one inbound audio stream per peer keyed
   by socket id; video and screen share share one branch discriminated by a
   four-way heuristic. The DOM/tile construction around it is meeting UI and is
   droppable.
10. Teardown (`client.js:3444-3515`, `server.js:2457-2509`): per peer, close the
    connection and delete `peerConnections`, `pendingIceCandidates`, the
    media-element maps and `allPeers[peer_id]`. Remote tracks are never explicitly
    stopped; `close()` is relied on. The leaver also receives `removePeer` for each
    remaining peer.
11. Reconnect: a new transport yields a new socket id; `handleDisconnect`
    (`client.js:3373-3435`) closes all connections and clears the maps but
    **retains local media**, and `handleConnect` re-sends `join` when local streams
    already exist (`client.js:1586-1587`). Every `peer_id` is new, so the mesh is
    rebuilt from scratch.

### `replaceTrack` and the negotiation trigger

- `replaceTrack` never renegotiates and never touches SDP; MiroTalk relies on this
  for camera switch, mic switch and noise-suppression pipeline changes
  (`client.js:9876, 9897, 9919`).
- Adding or removing a track does require renegotiation, and those branches re-arm
  the offer handler via `handleRtcOffer` rather than creating an offer directly
  (`client.js:9879-9880, 9900-9901, 9907-9908, 9922-9923`).
- **Mute is not renegotiation**: `track.enabled` flips and a `peerStatus` message
  goes out for UI interop only (`client.js:9266-9321`).
- **Camera off has two different paths**: `handleVideo` stops the track
  (`track.stop()`, no SDP), while `refreshMyStreamToPeers` uses
  `replaceTrack(null)` when no camera track is present in the local stream
  (`client.js:9886`). The remote peer's observable result differs per path.
- **Sender roles are positional**: `videoSenders[0]` is treated as the camera
  sender and `videoSenders[1]` as the screen sender (`client.js:9869-9871`), with
  no explicit role tag. A reimplementation should keep the `RTCRtpSender` returned
  by `add(_:streamIds:)` as the role tag instead.
- The **late-track latch** (`needToCreateOfferByPeer`, declared `client.js:824`,
  set `client.js:2882-2884`, consumed `client.js:3284-3286`) only *arms* the offer
  handler after an answer when the remote joined with video or screen off. It sends
  nothing itself and is never cleared on disconnect. It references upstream issue
  #110 and is a behavioural patch, not a rule.

### Divergence risks for a Swift port

| # | Risk | Likelihood of silent divergence |
| --- | --- | --- |
| A1 | Objective-C libwebrtc exposes **no `onnegotiationneeded`**, so MiroTalk's offer trigger has no native equivalent | likely |
| A2 | An offerer with no tracks never offers — the event fires only because `addTrack` created a transceiver | likely |
| A3 | The late-track latch has no deterministic effect; the repair offer depends on a browser event | likely |
| A4 | No `signalingState` guards and no glare handling; concurrent offers fail silently | possible |
| A5 | Local transceivers exist before `setRemoteDescription(offer)`; answer m-line association relies on libwebrtc transceiver recycling | likely |
| A6 | Candidates carry only `sdpMLineIndex` — no `sdpMid` or `usernameFragment` | possible |
| A7 | End-of-candidates is never signalled | unlikely |
| A8 | Camera-off takes two paths with different remote-visible results | likely |
| A9 | Positional sender bookkeeping can silently swap camera and screen | likely |
| A10 | Mute is invisible at the signalling layer; a track-stopping port looks different to peers | possible |
| A11 | The offerer role is server-assigned while renegotiation is opportunistic and bidirectional | likely |
| A12 | Audio silently switches to screen-share audio while screen sharing | possible |
| A13 | The `peers` map embeds room-metadata keys alongside peer entries | possible |
| A14 | `needToCreateOfferByPeer` is never cleared across reconnect | possible |
| A15 | SDP and ICE are unordered on the wire, with a single flush trigger | possible |
| A16 | No SDP munging, transceiver API or codec preferences anywhere — a positive finding that removes most porting risk | unlikely (as a risk) |

### Native API mapping

| MiroTalk JS | Native iOS WebRTC |
| --- | --- |
| `new RTCPeerConnection({iceServers})` | `RTCPeerConnection(configuration:)`; `iceServers` from the `addPeer` payload, never hard-coded |
| `pc.addTrack(track, stream)` | `pc.add(_:streamIds:)` — keep the returned sender as the role tag |
| `pc.getSenders()` filtered by kind | `pc.senders` filtered by `track?.kind`; do not rely on index order |
| `sender.replaceTrack(t)` / `(null)` | `RTCRtpSender.track = t` / `= nil` |
| `pc.removeTrack(sender)` | `pc.removeTrack(sender)`, then renegotiate |
| `pc.onnegotiationneeded` | **no equivalent** — synthesise the trigger |
| `pc.createOffer()` / `createAnswer()` | `offer(for:)` / `answer(for:)` with default options |
| `pc.setLocalDescription` / `setRemoteDescription` | same names; add the `signalingState` guard the JS lacks |
| `new RTCIceCandidate({sdpMLineIndex, candidate})` | `RTCIceCandidate(sdp:sdpMid:sdpMLineIndex:)` with `sdpMid` `nil` |
| `pendingIceCandidates[peer_id]` + `flushIceCandidates` | application-level `[String: [RTCIceCandidate]]`; libwebrtc does not queue for you |
| `pc.ontrack` | `peerConnection(_:didAdd:streams:)` keyed by remote socket id |
| `<audio>`/`<video>` + `srcObject` | `RTCAudioTrack` auto-played via `RTCAudioSession`; `RTCVideoTrack` + an `RTCVideoRenderer` |
| `pc.onconnectionstatechange` (logging only in JS) | `peerConnection(_:didChange:)`; drive reconnect and UI from it |
| `io({transports:['websocket']})` | `SocketIO` client forced to websocket transport |

### Open questions requiring an experiment, not more reading

- Does the offerer-with-zero-tracks deadlock actually occur in 1.9.64? Requires
  observing a live pair where both sides joined with camera, mic and screen off.
- Does libwebrtc on iOS associate a pre-existing local transceiver with an
  incoming offer's m-line identically to Chrome?
- Is an offer in practice ever produced by the latch path?
- Does libwebrtc accept `replaceTrack` with a track whose `readyState` is `ended`?
