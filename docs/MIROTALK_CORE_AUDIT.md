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
