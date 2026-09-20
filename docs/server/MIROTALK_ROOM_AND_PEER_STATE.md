# MiroTalk room and peer state (source-derived)

The exact in-memory structures MiroTalk 1.9.64 keeps for a room and its peers,
with every field traced to the code that writes it and the code that reads it, and
each classified by whether Crossbar needs it.

Sources: `app/src/server.js` (**S**, line numbers), `public/js/client.js` (**C**).
Read-only audit, 2026-09-20.

**Nothing here is durable.** There is no database, no serialization, and no room
record on disk anywhere in the tree. Room lifetime equals the interval between the
first and the last socket in it.

---

## 1. The five module-scope maps

```js
const channels   = {}; // S:404  room_id -> { socket_id: socket }
const sockets    = {}; // S:405  socket_id -> socket
const peers      = {}; // S:406  room_id -> { socket_id: peer, lock?, password?, joinLock? }
const presenters = {}; // S:407  room_id -> { socket_id: presenter }
const wbLocks    = {}; // S:408  room_id -> true
const roomMetaKeys = new Set(['lock', 'password', 'joinLock']); // S:410
```

| Map | Purpose | Key | Value |
| --- | --- | --- | --- |
| `channels` | **delivery registry** — who is in the room, for emitting | `room_id` | `{socket_id: Socket}` |
| `sockets` | **global registry** — every connected socket, for `sendToPeer` | `socket_id` | `Socket` |
| `peers` | **identity + presence + room metadata** | `room_id` | `{socket_id: peerRecord}` plus three reserved keys |
| `presenters` | **the only authorization state** | `room_id` | `{socket_id: presenterRecord}` |
| `wbLocks` | whiteboard lock (product feature) | `room_id` | `true` |

The split between `channels` (delivery) and `peers` (identity) is load-bearing:
`sendToRoom` iterates `channels` (S:2527-2542) while every membership and
presenter check reads `peers` or `presenters` (`isPeerInRoom` S:2606-2608,
`isPeerPresenter` S:2620-2650). A peer can therefore exist in `peers` while
absent from `channels` during the join window — see §4.

`getPeerCount(roomId)` (S:412-415) counts keys excluding `roomMetaKeys`.

---

## 2. Room object

The "room" is not one object; it is four parallel entries under the same key plus
one per-socket marker. Every field, with writer and readers:

| Field | Written by | Read by | Notes |
| --- | --- | --- | --- |
| `channels[room][socketId]` | `join` S:1656 | `addPeerTo` S:2434, `sendToRoom` S:2528, `removePeerFrom` S:2499 | deleted per leaver S:2479; whole map deleted when empty S:2483 |
| `peers[room][socketId]` | `join` S:1604-1626 | `addPeerTo` S:2436/2443, `getPeerCount` S:412, `checkPeerName` S:1341, `isPeerInRoom` S:2609, `peerStatus` S:1931, `whiteboardAction` S:2390, `api.js` stats/meetings, `getActiveRooms` S:2740 | the snapshot shipped inside every `addPeer` |
| `peers[room].lock` | `roomAction` S:1747 | `join` S:1545 | deleted on unlock S:1757 |
| `peers[room].password` | `roomAction` S:1748 | `join` S:1545, `checkPassword` S:1784 | **deleted on unlock S:1758; broadcast inside `addPeer.peers` while set** |
| `peers[room].joinLock` | `roomAction` S:1766 | `join` S:1594, `serverInfo` S:1642 | deleted S:1774 |
| `presenters[room][socketId]` | `join` S:1551-1589 | `isPeerPresenter` S:2626, `peerName` S:1813 | see §5 |
| `wbLocks[room]` | `whiteboardAction` S:2394 | `wbCanvasToJson` S:2334 | deleted S:2395 |
| `socket.channels[room]` | init S:1299, add S:1657 | `disconnect` S:1318, `removePeerFrom` S:2458 | the per-socket inverse index |
| `socket.room_id` | **never set** | referenced at S:1726/1729 for logging only | always `undefined`; a dead field |

**Room creation happens before rejection.** `join` creates
`channels[room]`/`peers[room]`/`presenters[room]` at S:1540-1542 and *then* checks
the room lock (S:1545) and join lock (S:1594). A join rejected by either check
leaves **empty containers behind** that nothing ever collects.

---

## 3. Peer record

Created once, in `join` (S:1604-1626), keyed by `socket.id`:

```js
peers[channel][socket.id] = {
    peer_name, peer_avatar, peer_presenter,
    peer_video, peer_audio,
    peer_video_status, peer_audio_status, peer_screen_status,
    peer_hand_status, peer_rec_status, peer_privacy_status,
    os, browser, extras,
};
```

| Field | Source | Written by | Read by | Signaling-critical? |
| --- | --- | --- | --- | --- |
| **key** `socket.id` | server | S:1604 | `isPeerInRoom` S:2609, `isPeerPresenter` S:2626, all guards | **YES** |
| `peer_name` | client `join` | S:1605; `peerName` S:1808 | `isPeerPresenter` S:2640, `checkPeerName` S:1342, `peerStatus` S:1931 | **YES** |
| `peer_uuid` | client `join` | presenters map only, S:1551-1589 | `isPeerPresenter` S:2641 | **YES** (auth) |
| `peer_presenter` | derived server-side | S:1607 | client UI, presenter-gated actions | yes (display) |
| `peer_video`, `peer_audio` | client `join` | S:1608-1609 | initial UI state | product |
| `peer_video_status` | `peerStatus` | S:1940 | client UI badge; also read by the *browser* client from `addPeer.peers` to decide renegotiation (C:2832) | **YES, indirectly** |
| `peer_audio_status` | `peerStatus` | S:1943 | cosmetic only | product |
| `peer_screen_status` | `peerStatus` | S:1946 | screen-share UI; read by the browser client from `addPeer.peers` (C:2833) | product |
| `peer_hand_status` | `peerStatus` | S:1949 | raise-hand UI | product |
| `peer_rec_status` | `peerStatus` | S:1952 | recording indicator | product |
| `peer_privacy_status` | `peerStatus` | S:1955 | privacy/blur UI | product |
| `os`, `browser` | `peer_info` at join | S:1616-1617 | email alert S:1666, participants panel | product |
| `extras` | `join` / `peerStatus` `screen` | S:1618, S:1947 | screen metadata | product |

**The peer record is written once at join and thereafter only through explicit
`peerStatus`/`peerName` updates.** No timestamps, no connection state, no
per-peer ICE or media state — the server never learns whether a peer connection
succeeded.

---

## 4. Timeline of a join (why the window matters)

`join` does these in a fixed order (S:1604-1662):

1. `peers[channel][socket.id] = {…}` — the peer **exists in `peers`**
2. `addPeerTo(channel)` — fan-out; iterates `channels[channel]`, which does **not
   yet contain the joiner**
3. `channels[channel][socket.id] = socket` — the peer **joins the delivery registry**
4. `socket.channels[channel] = channel` — the per-socket index
5. `serverInfo` to the joiner

Consequences:

- Existing peers receive `addPeer` whose embedded `peers` snapshot **already
  includes the joiner** and includes the recipient itself.
- The joiner is **not** an existing member during its own fan-out, so it never
  emits an `addPeer` to itself.
- A `peerStatus`, `message` or whiteboard action arriving in this window would be
  rejected by `isPeerInRoom` (it reads `peers`, which *does* contain the joiner) —
  but `sendToRoom` would not deliver it (it reads `channels`). The two maps
  disagree for the duration of one `await`.

---

## 5. Presenter record — the only authorization state

```js
presenters[channel][socket.id] = { peer_ip, peer_name, peer_uuid, is_presenter };
```
(S:1551-1556)

`isPeerPresenter(room_id, socket_id, peer_name, peer_uuid)` (S:2620-2650) requires
all of:

- an entry exists for `(room_id, socket_id)`;
- stored `peer_name === peer_name`;
- stored `peer_uuid === peer_uuid`;
- `Object.keys(stored).length > 1`.

`peer_uuid` is **never broadcast**, so it acts as the unspoofable link across a
reconnect: `join` migrates a stale presenter entry when name *and* uuid match
(S:1563-1578). `peer_ip` is recorded (`getSocketIP`, S:2816-2826, which honours the
first `X-Forwarded-For` hop under `TRUST_PROXY=true`) but is not used in
authorization.

Presenter authority gates `roomAction` (lock/unlock/joinLock), `whiteboardAction`,
`kickOut`, and the presenter-only branches of `cmd` and `peerAction`. With
`PRESENTERS=[]` (deployed), the first joiner in a room becomes presenter (S:1586).

**Crossbar relevance:** none. Crossbar's product has no presenter, no room lock,
no lobby, and no kick. The presenter mechanism exists to make MiroTalk's meeting
UI work.

---

## 6. Classification

### Required by Crossbar

| State | Why |
| --- | --- |
| room membership keyed by a per-connection peer id | routing SDP/ICE; `addPeer.peer_id` is the client's dial key |
| the peer id the server assigns (Socket.IO `sid`) | the client uses it as `peer_id` in `peerStatus` and expects it back in `relaySDP`/`relayICE` |
| `peer_name` | the tile caption and the only identity the far end sees |
| `iceServers` | delivered per `addPeer`; the client has no built-in fallback |
| one offer/answer relationship per peer pair | the mesh |
| `peer_video_status` (as `peerStatus{ element:"video" }`) | distinguishes "camera off" from "call broken" |

### Potentially required

| State | Depends on |
| --- | --- |
| `peer_uuid` | **only** if a reconnect must be recognised as the same participant. Crossbar currently reconnects by re-`join`ing and relying on `presence`/`bootstrap`; a server that wants stable participant identity across reconnects will need an equivalent. |
| `peer_audio_status` | only if an audio-off indicator is a product requirement |
| `peer_screen_status` + `extras` | only if screen sharing is ever a product requirement |
| any roster/participant list | the product's "Add Person" and N-person UI will need one; today the client derives it from `addPeer` events only |

### MiroTalk-only product state (drop)

`peer_presenter`, `os`, `browser`, `peer_hand_status`, `peer_rec_status`,
`peer_privacy_status`, `wbLocks`, `lock`, `password`, `joinLock`, `extras`
(non-screen), `socket.room_id`.

### Security-related

| State | Issue |
| --- | --- |
| `peers[room].password` | **shipped in plaintext inside every `addPeer.peers`** while the room is locked (S:1748 write, S:2436/2443 emit) |
| `presenters[room][*].peer_uuid` | the only unspoofable authorization token in the system; never broadcast, which is correct |
| `peer_ip` | recorded from a **client-spoofable** `X-Forwarded-For` first hop under `TRUST_PROXY=true`; feeds logging and the presenter record only |

### Unknown — would need a decision

- Whether a replacement should key participants by a **server-issued participant
  id** (stable across socket reconnects) rather than by `socket.id`. MiroTalk does
  not; Crossbar's reconnect story is currently weak precisely because of that
  (`CURRENT_CLIENT_CONTRACT.md` §7).
- Whether the participant list should be an explicit server-maintained roster
  rather than the implicit `peers` map that only MiroTalk's browser client reads.

---

## 7. What the state does *not* contain

- **No call identity.** MiroTalk has no notion of a "call": a room is a set of
  sockets. Crossbar's call ids, ringing, accept/decline, and missed-call expiry
  live entirely in the separate Family Call control plane.
- **No media state.** Not one field records whether a peer connection succeeded,
  what candidates were exchanged, or whether media flows.
- **No timestamps.** Nothing records when a peer joined or left.
- **No persistence.** A restart is total state loss, on every room, with no
  notification to any client beyond the socket closing.
