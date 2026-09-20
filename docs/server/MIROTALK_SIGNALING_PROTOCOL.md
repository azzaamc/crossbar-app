# MiroTalk signalling protocol (source-derived)

The complete call-path message map for MiroTalk P2P **1.9.64** as deployed, plus
the negotiation sequences a replacement server must reproduce. Derived from
`app/src/server.js` (**S**), `public/js/client.js` (**C**),
`app/src/validate.js` (**V**) and `app/src/xss.js` (**X**) on `/home/admin/mirotalk`,
read-only, 2026-09-20.

Companion documents: [`MIROTALK_SERVER_ARCHITECTURE.md`](MIROTALK_SERVER_ARCHITECTURE.md),
[`MIROTALK_ROOM_AND_PEER_STATE.md`](MIROTALK_ROOM_AND_PEER_STATE.md),
[`MIROTALK_SECURITY_MODEL.md`](MIROTALK_SECURITY_MODEL.md).

---

## 1. Transport and framing

| Layer | Fact |
| --- | --- |
| Library | `socket.io@^4.8.3` (`package.json`) → Engine.IO v4 + Socket.IO protocol v5 |
| Server | `new Server({maxHttpBufferSize: 1e7, transports: ['websocket'], cors}).listen(server)` (S:141-145) |
| Client | `io({ transports: ['websocket'] })` (C:1489) |
| Namespace | root `/` only; no `io.of` anywhere |
| Path | `/socket.io/` |

Wire frames: `0{handshake}` → `40{sid,…}` → `42["event", payload]`. The `sid` from
the namespace connect frame **is the peer identity** used everywhere as `peer_id`,
and **it changes on every (re)connect**.

The ack-style `data` call (`socket.on('data', async (dataObj, cb)`, S:1328) is not
on the call path.

---

## 2. Message reference

### 2.1 `join` — C→S

The only admission message. Room key is **`channel`**, not `room_id`.

| Key | Type | Server handling |
| --- | --- | --- |
| `channel` | string | the room id; validated (see §4.1) |
| `channel_password` | string \| null | compared against `peers[channel].password` when locked |
| `peer_uuid` | string | stored in `presenters` only |
| `peer_name` | string | stored; used in `isPeerPresenter`, duplicate-name check, `peerStatus` |
| `peer_avatar` | string | stored |
| `peer_token` | string \| null | **the only thing that can trigger auth in this deployment** |
| `peer_video`, `peer_audio` | bool | stored |
| `peer_video_status`, `peer_audio_status`, `peer_screen_status`, `peer_hand_status`, `peer_rec_status`, `peer_privacy_status` | bool | stored |
| `peer_info` | object `{osName,osVersion,browserName,browserVersion,extras}` | destructured **without a guard** at S:1601 |
| `join_data_time`, `userAgent` | any | destructured nowhere — ignored |

Server response: `unauthorized` \| `roomIsLocked` \| `roomIsJoinLocked` to the
sender, else `serverInfo` to the sender plus the `addPeer` fan-out.

### 2.2 `serverInfo` — S→C (sender only, S:1629-1659)

```
peers_count        int      host_protected   bool     user_auth     bool
is_presenter       bool     join_locked      bool     maxRoomParticipants int
survey   {active, url}      redirect {active, url}     whisper {enabled, segmentSeconds}
```

**The native Crossbar client never handles `serverInfo`** — it falls into the
client's `default: break`. It is safe for a replacement server to omit it, or to
keep it only for MiroTalk-browser interoperability.

### 2.3 `addPeer` — S→C (the topology driver)

```
peer_id            string          the *other* peer's socket id
peers              object          the raw `peers[channel]` map — see below
should_create_offer bool           true only for the joiner
iceServers         array           e.g. [{urls:'stun:stun.l.google.com:19302'}]
```

Emitted by `addPeerTo` (S:2433-2453), one per pair, in both directions with
opposite offer flags:

```js
for (let id in channels[channel]) {
    channels[channel][id].emit('addPeer', { peer_id: socket.id, peers: peers[channel],
                                             should_create_offer: false, iceServers });
    socket.emit('addPeer',              { peer_id: id,        peers: peers[channel],
                                             should_create_offer: true,  iceServers });
}
```

The embedded `peers` value is the **raw room map**: every peer record keyed by
socket id, *plus* the reserved keys `lock` / `password` / `joinLock` when the room
is locked or join-locked (S:410, 1747-1748, 1766). It contains both the
recipient's own entry and the joiner's.

The MiroTalk browser client reads `peers[peer_id]` for the remote's
`peer_name`, `peer_video`, `peer_video_status` and `peer_screen_status`
(C:2830-2834). **The native Crossbar client ignores `peers` entirely** and reads
only `peer_id`, `should_create_offer`, `peer_name` and `iceServers`.

### 2.4 `relaySDP` — C→S → `sessionDescription` — S→target

```js
socket.on('relaySDP', async (config) => {
    if (!Validate.isValidData(config)) return;
    const { peer_id, session_description } = config;
    await sendToPeer(peer_id, sockets, 'sessionDescription', {
        peer_id: socket.id,
        session_description: session_description,
    });
});
```
(S:1703-1714)

- **Validation: `isValidData` only** — non-empty object. No `checkXSS`, no room
  membership check, no authorization of any kind.
- Forwarded verbatim, with `peer_id` replaced by the **sender's** socket id.
- `peer_id` is resolved against the **global** `sockets` map (S:2544-2556), so any
  connected socket can address any other socket id on the server.
- S:1710 dereferences `session_description.type` unconditionally, so a payload
  without it throws inside the async handler.

`session_description` is `{type: 'offer'|'answer', sdp: string}`.

### 2.5 `relayICE` — C→S → `iceCandidate` — S→target

```js
socket.on('relayICE', async (config) => {
    if (!Validate.isValidData(config)) return;
    const { peer_id, ice_candidate } = config;
    await sendToPeer(peer_id, sockets, 'iceCandidate', {
        peer_id: socket.id,
        ice_candidate: ice_candidate,
    });
});
```
(S:1686-1697) — same properties as `relaySDP`.

`ice_candidate` is `{sdpMLineIndex: int, candidate: string}`. **Neither MiroTalk
client sends or expects `sdpMid`.** Candidates are trickled; there is no
end-of-candidates marker.

### 2.6 `peerStatus` — C→S → room broadcast

```js
const { room_id, peer_name, peer_id, element, status, extras } = config;
if (!isPeerInRoom(room_id, socket.id)) return;                 // S:1921 — the only membership guard on the call path
// ... update peers[room_id][peer_id] where peer_id == socket.id && peer_name matches
await sendToRoom(room_id, socket.id, 'peerStatus', { peer_id, peer_name, element, status, extras });
```
(S:1910-1968)

- Wrapped by `checkXSS` (unlike the relays).
- `element` ∈ `video | audio | screen | hand | rec | privacy`; `screen` also writes
  `extras`.
- State is written only when the entry's key equals `socket.id` **and** its stored
  `peer_name` matches — but the broadcast happens regardless, and `peer_id` in the
  broadcast is the **client-supplied** value.
- Outbound payload **strips `room_id`** and targets every room member except the
  sender.

UI effect that matters for interop (C:13745-13776): `video:false` hides the remote
`<video>` and shows the avatar; `video:true` restores it. `audio` status is
**purely cosmetic** — it never changes remote playback. The native Crossbar client
mirrors exactly the `video` semantics (`remoteVideoOff`).

### 2.7 `peerName` — C→S → room broadcast

Payload `{room_id, peer_name_old, peer_name_new, peer_avatar}` (C:2913-2918);
updates peer records and the presenter entry, then rebroadcasts to the room.
**Note for interop:** the browser client re-emits its profile (`emitMyPeerProfile`,
C:2912-2919) on **every** `addPeer` it handles (C:2838), so a native peer receives
a `peerName` from the browser shortly after each `addPeer`. The native client does
not handle `peerName` and ignores it.

### 2.8 `removePeer` — S→remaining, and S→leaver

`{peer_id}` only. Fan-out from `removePeerFrom` (S:2497-2503): each **remaining**
member receives `{peer_id: <leaver>}`; the leaver receives `{peer_id: <each
remaining id>}`. If the room became empty, the maps are deleted first and the loop
iterates nothing — **the last leaver receives no `removePeer`**.

### 2.9 `disconnect` — transport→S

```js
socket.on('disconnect', async (reason) => {
    removeIP(socket);                                        // no-op unless HOST_PROTECTED
    for (let channel in socket.channels) await removePeerFrom(channel, socket, reason);
    delete sockets[socket.id];
});
```
(S:1316-1324) — no grace period, no timer; the peer is gone immediately.

### 2.10 Rejection events

| Event | Condition | Line |
| --- | --- | --- |
| `unauthorized` | invalid room name; token invalid/unverifiable/absent while `authRequired` | 1475, 1505-1536 |
| `roomIsLocked` | `peers[channel].lock === true` and password mismatch | 1547 |
| `roomIsJoinLocked` | `peers[channel].joinLock === true` and sender is not presenter | 1597 |

---

## 3. Negotiation sequences

### 3.1 Two peers — A joins first, B second

1. **A `join`** → room containers created; `peers[ch][A]` written; `presenters[ch][A]`
   set (A is the first joiner and `PRESENTERS=[]`); `addPeerTo(ch)` iterates an empty
   `channels[ch]` ⇒ **no `addPeer`**; A gets `serverInfo {peers_count:1, is_presenter:true}`.
2. **B `join`** → `peers[ch][B]` written (so A's `addPeer` snapshot already contains B
   *and* the recipient); `addPeerTo(ch)`:
   - A ← `addPeer{peer_id:B, should_create_offer:false, peers, iceServers}`
   - B ← `addPeer{peer_id:A, should_create_offer:true,  peers, iceServers}`
   - then `channels[ch][B] = socket`, `serverInfo(B) {peers_count:2, is_presenter:false}`.
3. Both sides create `RTCPeerConnection({iceServers})`, then **two data channels**
   (`mirotalk_chat_channel`, `mirotalk_file_sharing_channel`, C:10560/16087-16089),
   then add tracks (C:2827-2895).
4. **B offers** (it holds `should_create_offer: true`). B's client installs
   `pc.onnegotiationneeded` inside `handleRtcOffer` (C:3212-3236) and lets the
   **browser's own negotiation-needed event** produce the offer; it then sends
   `relaySDP{peer_id:A, session_description:{type:'offer', sdp}}`.
5. Server relays as `sessionDescription{peer_id:B, …}` to A.
6. A: `setRemoteDescription(offer)` → `flushIceCandidates` → `createAnswer()` →
   `setLocalDescription` → `relaySDP{peer_id:B, {type:'answer'}}` → B sets remote.
7. **ICE trickles both ways** the whole time. Candidates arriving before
   `remoteDescription` are queued per peer and flushed **only** in the
   `setRemoteDescription().then()` (C:3339-3366).
8. Media flows P2P. The server sees nothing further except `peerStatus` and
   teardown.

**m-lines in the initial offer** are `application` (SCTP, from the two data
channels) + `video` + `audio` (screen only if already sharing) — order is
browser-dependent `[INFERENCE, from createDataChannel/addTrack ordering]`.

### 3.2 A third peer joins the A↔B pair

`join` → `peers[ch][C]` written → `addPeerTo` loops `channels[ch] = {A, B}`:

| Emitted to | payload |
| --- | --- |
| A | `addPeer{peer_id:C, should_create_offer:false}` |
| C | `addPeer{peer_id:A, should_create_offer:true}` |
| B | `addPeer{peer_id:C, should_create_offer:false}` |
| C | `addPeer{peer_id:B, should_create_offer:true}` |

Then `channels[ch][C] = socket`, `serverInfo(C) {peers_count:3}`.

**A↔B is untouched, and C is the offerer on both new pairs.** The `peers` snapshot
inside each `addPeer` already contains all three peers, so there is no roster
resync and no separate "participant joined" event. Four peer connections exist for
three people — a full mesh, with no server-side coordination of the A↔C / B↔C / A↔B
matrix beyond the pairwise loop.

### 3.3 Renegotiation — what actually triggers a second offer

This matters because a native client must answer mid-call offers correctly.

1. **The answerer's round-2 offer.** `handleAddPeer` sets
   `needToCreateOfferByPeer[peer_id] = true` whenever the *remote* peer's
   `peer_video_status` or `peer_screen_status` is false (C:2882-2884) — i.e. for
   almost every peer at join time. After that peer's own answer is set, the client
   calls `handleRtcOffer(peer_id)` again (C:3284-3286), installing
   `onnegotiationneeded`. Any still-unnegotiated local change (classically a
   `video` track with no matching m-line in the remote offer, because the remote
   joined camera-off) then fires and produces **a second offer carrying the
   existing `application` data-channel m-line plus the missing media m-lines.**
   *This is the mechanism behind the native client's observed "browser renegotiated
   a data channel" during a real call.*
2. **Explicit track add/remove** in `refreshMyStreamToPeers` (C:9837-9928) calls
   `handleRtcOffer` when a track cannot be `replaceTrack`ed — `addTrack` for a first
   camera or screen track, `removeTrack` when screen sharing stops, `addTrack` for
   a missing audio sender.
3. **What does *not* renegotiate:** camera on/off, mute/unmute, and ordinary
   screen-share start/stop with an existing sender. Those use
   `RTCRtpSender.replaceTrack` (or `replaceTrack(null)`) plus `peerStatus`.
   Data channels are created exactly once and never recreated.

A replacement server needs **no renegotiation logic**: it relays whatever SDP
appears, exactly as `relaySDP` does. But it must not assume one offer per pair.

---

## 4. Server-side validation actually performed

### 4.1 `join`

```js
const config = checkXSS(cfg);                       // S:1447 — tree-wide sanitize
if (!Validate.isValidData(config)) return;          // S:1448 — non-empty object only
...
if (!Validate.isValidRoomName(channel)) { socket.emit('unauthorized'); return; }   // S:1474-1477
if (channel in socket.channels) return;             // S:1479-1481 — re-join short-circuit
const isRoomNew = !(channel in presenters) || Object.keys(presenters[channel]).length === 0;
const authRequired = hostCfg.user_auth || peer_token || (hostCfg.protected && isRoomNew);
```

- `checkXSS` (X:66-112) `he.decode`s and `DOMPurify.sanitize`s every string
  (recursing through objects/arrays) with a small tag/attribute allow-list.
- `Validate.isValidRoomName` (V:11-50) is only: non-empty string, survives
  `checkXSS`, and contains no double-decoded path-traversal pattern. **There is no
  charset whitelist, no length cap, and no UUID requirement** — any string passes,
  including one that no `/api/v1/join` ever minted.
- `Validate.isValidData` (V:56-61) is `typeof data === 'object' && Object.keys(data).length > 0`.

**With the deployed environment (`HOST_PROTECTED=false`, `HOST_USER_AUTH=false`),
`authRequired` reduces to `peer_token`** — i.e. authentication happens *only if the
client volunteers a token*. No token ⇒ any socket may create or join any room and,
being first, become its presenter.

### 4.2 The relays

`relaySDP` and `relayICE` perform **only** `isValidData`. They are not wrapped in
`checkXSS`, and they contain **no membership, room or authorization check**. Because
`peer_id` resolves through the global `sockets` map, a socket that never joined any
room can inject an SDP or ICE payload into any other socket id on the server.

`peerStatus` is the only call-path handler with a membership guard
(`isPeerInRoom(room_id, socket.id)`, S:1921).

---

## 5. Interoperability requirements for a replacement server

If the same **MiroTalk browser client** must keep working (the Family Call PWA
embeds it — see [`MIROTALK_DEPENDENCY_MAP.md`](MIROTALK_DEPENDENCY_MAP.md)), a
replacement must keep:

- the `/socket.io/` path, Engine.IO v4 handshake, `sid` as `peer_id`;
- `join` with `channel` + the 18-field payload, and `serverInfo`;
- `addPeer` **including the `peers` map**, since the browser reads
  `peers[peer_id].peer_name` / `peer_video_status` / `peer_screen_status` from it
  (C:2830-2834);
- `sessionDescription` / `iceCandidate` relay semantics and names;
- `peerStatus` with `element` values `video|audio|screen|hand|rec|privacy`;
- `removePeer` as the only departure signal.

If only **native Crossbar** must work, the required set is smaller and exact — see
[`CURRENT_CLIENT_CONTRACT.md`](CURRENT_CLIENT_CONTRACT.md) §9, which lists the 15
guarantees the shipped client actually depends on (`serverInfo`, `peers`, and the
whole `peerStatus` element set are not among them except `video`).

---

## 6. Deliberate deviations found (not upstream hardening)

None. Every guard described above — `checkXSS`, `isValidRoomName`, the
`unauthorized` branches, `isPeerInRoom`, the presenter model, the IP-whitelist
guardrail — is upstream 1.9.64 code present in the shipped `config.template.js`
and `xss.js`/`validate.js`. The only local change in the deployed tree is the
loopback bind at S:1235. **The security gaps in §4.2 are upstream behaviour, not
the result of local edits**, which matters when deciding what a replacement must
improve rather than merely preserve.
