# Crossbar signalling protocol

The protocol: MiroTalk's event vocabulary, with an admission model and validation
that MiroTalk does not have. **Implemented** — see
[`CROSSBAR_SERVER_IMPLEMENTATION.md`](CROSSBAR_SERVER_IMPLEMENTATION.md) for what
was built and how it is verified.

Every message below is stated in the required form: name, direction,
authentication, payload, validation, state precondition, state transition,
response/ack, error behaviour, authorization.

Design note: the vocabulary is deliberately **unchanged** from what the shipped
client already speaks and has verified on device
([`CURRENT_CLIENT_CONTRACT.md`](CURRENT_CLIENT_CONTRACT.md) §3). The three
behavioural changes are identity-bound admission, participant-scoped relay, and
strict per-field validation.

---

## 1. Transport

| Item | Value |
| --- | --- |
| URL | `wss://<service-host>/signal/?EIO=4&transport=websocket` |
| Framing | Engine.IO v4 over a raw WebSocket, Socket.IO v5 message layer |
| Namespace | default only |
| Polling | **not supported** — WebSocket only, matching both existing clients |
| Server → client heartbeat | Engine.IO `2` (ping) every 25 s; a pong (`3`) must arrive within 20 s |
| Client → server heartbeat | pong only; the client never initiates |
| Max message | **128 KiB**, enforced before parse; per-event caps below |

Frames used, and only these:

| Frame | Meaning |
| --- | --- |
| `0{…}` | Engine.IO open (server → client, sent on connect) |
| `2` / `3` | ping / pong |
| `40` | client requests the default namespace |
| `40{"sid":"…"}` | server confirms; **`sid` is this connection's `peer_id`** |
| `42["event",{…}]` | an event |

Deviations from MiroTalk, all deliberate:

- `maxHttpBufferSize` drops from 10 MB to 128 KiB.
- No ack (`43`) support: the client never requests acks, so the server never sends
  one.
- Unknown events are **rejected and counted**, never silently ignored.
- Every handler is wrapped; a malformed message can never terminate the process
  (MiroTalk can be crashed by a single `peer_id: "constructor"`).

---

## 2. Authentication and admission

```text
POST /api/calls/:id/join            (HTTPS, authenticated as a person)
  → 200 { call, signalling: { url, room, eio, transport }, joinUrl }
```

The client then opens the socket and sends `join`. The server decides, in this
order:

1. **the connection's identity** — resolved from the upgrade request exactly as
   the API resolves it (an injected header, accepted only from loopback);
2. the person is enrolled in this household;
3. `channel` names a call this person is a participant of;
4. the call's state admits that participant — any participant of an `active`
   call, or a participant who already accepted while it is still `ringing`;
5. the room is below its participant ceiling;
6. any earlier connection of the **same device** in that room is evicted first,
   so the room is not full of this very device and the other participants see one
   departure before one arrival.

Only then does the socket become a participant.

**Why not the room name, and why not a ticket.** In MiroTalk the room name *is*
the credential, so anyone who learns it joins and the first joiner becomes
presenter. The obvious fix is a short-lived ticket minted by the API — but that
turns out to be unnecessary, because a WebSocket upgrade is an HTTP request and
carries the same injected identity. Admission can therefore be decided from who
the caller is plus what the call says about them, with no new secret, no storage,
and no expiry window to get wrong.

What that gives up: a ticket could be scoped to one call and expire. Here, a
socket's authority lasts as long as its connection, and the call's own state is
what ends it — re-checked at every join, which is the only moment it is needed.

---

## 3. Messages

### 3.1 `join` — client → server

| Field | Required | Type | Validation |
| --- | --- | --- | --- |
| `channel` | yes | string | names a call the caller is a participant of; ≤64 chars |
| `peer_uuid` | yes | string | ≤64 chars; stable per install |
| `peer_name` | yes | string | ≤80 chars; display only, never an authorization input |
| `peer_avatar` | no | string | ≤500 chars |
| `peer_video`, `peer_audio` | no | bool | default true |
| `peer_video_status`, `peer_audio_status` | no | bool | default true |
| `peer_screen_status`, `peer_hand_status`, `peer_rec_status`, `peer_privacy_status` | no | bool | default false; accepted and stored for interop, not used by Crossbar product logic |
| `peer_info` | no | object | `{osName, osVersion, browserName, browserVersion}` each ≤64 chars; read field by field, never destructured unguarded |
| `channel_password` | no | — | ignored; Crossbar has no room passwords |
| `peer_token` | no | — | ignored; a token is not what admits |

- **Authentication:** the identity injected on the upgrade request.
- **State precondition:** the call admits this participant (§2).
- **State transition:** none in the call machine (joining does not change call
  status); the participant gains a live room membership, and a ringing call
  becomes active if it had not already.
- **Response:** `serverInfo` to the sender, then one `addPeer` per existing pair.
- **Errors:** `unauthorized {reason}` before any state change, with a reason from
  `no_identity`, `not_enrolled`, `room_not_found`, `NOT_A_PARTICIPANT`,
  `CALL_NOT_JOINABLE`, `room_full`, `invalid_join`, `already_joined`.
- **Authorization:** identity plus participant status.

### 3.2 `serverInfo` — server → client

```
peers_count int, is_presenter bool, join_locked bool, maxRoomParticipants int
```
Kept for vocabulary compatibility and for browser interop. Crossbar's native
client does not read it; `is_presenter` is always `false` because there is no
presenter role. **Safe to omit if the client is ever extended**, since MiroTalk's
`serverInfo` fields it does not read are pure noise.

### 3.3 `addPeer` — server → client

| Field | Type | Notes |
| --- | --- | --- |
| `peer_id` | string | the **other** participant's `sid` |
| `should_create_offer` | bool | `true` to the joiner, `false` to the incumbent, per pair |
| `iceServers` | array | from config; see §4 |
| `peer_name` | string | included directly (the client reads it from the top level as well as from `peers`) |
| `peers` | object | **only for browser interop**; a native-only deployment may omit it. When present it must contain **no** room metadata keys — MiroTalk leaks a locked room's plaintext password here. |

- **Authentication:** implicit — the server only sends it to admitted sockets.
- **Precondition/transition:** none.
- **Ordering guarantee (must hold):** `addPeer` for a given `peer_id` reaches a
  client **before** any `sessionDescription`/`iceCandidate` for that id. The client
  discards SDP from an unknown peer permanently.

### 3.4 `relaySDP` — client → server

| Field | Type | Validation |
| --- | --- | --- |
| `peer_id` | string | must name a **currently admitted participant of the sender's call** |
| `session_description.type` | string | exactly `"offer"` or `"answer"` |
| `session_description.sdp` | string | non-empty, ≤64 KiB, must start with `v=` |

**Authorization:** sender admitted to the room; target in the same call; target
admitted. On failure the relay is dropped and `relay_denied` is logged — the
sender is not told, because a probe should not learn whether an id exists.

Forwarded as `sessionDescription {peer_id: <server's record of the sender>, session_description}`.

### 3.5 `relayICE` — client → server

| Field | Type | Validation |
| --- | --- | --- |
| `peer_id` | string | as above |
| `ice_candidate.candidate` | string | non-empty, ≤4 KiB, must begin with `candidate:` |
| `ice_candidate.sdpMLineIndex` | int | 0 ≤ n ≤ 32 |

Same authorization as `relaySDP`. Forwarded as
`iceCandidate {peer_id: <sender>, ice_candidate}`.

### 3.6 `peerStatus` — client → server → room

| Field | Type | Validation |
| --- | --- | --- |
| `room_id` | string | must equal the sender's own room |
| `peer_id` | string | must equal the **server's** record of the sender's id |
| `peer_name` | string | must equal the sender's admitted name |
| `element` | enum | `video` (Crossbar uses only this); `audio`/`screen`/`hand`/`rec`/`privacy` accepted for browser interop |
| `status` | bool | — |
| `extras` | object | ≤1 KiB when present |

Broadcast to the room except the sender, **with `room_id` stripped** and with the
**server's** `peer_id` — MiroTalk rebroadcasts the client-supplied id, which makes
the id a spoofing and DOM-indexing input.

### 3.7 `removePeer` — server → clients

`{peer_id}` emitted to every remaining participant when a peer leaves, on:

- socket close (immediate for a clean close, or on heartbeat timeout at ≤45 s);
- identity-aware eviction when the same device re-attaches;
- call end.

The client never sends a goodbye, so this is the only departure signal it will
ever receive.

### 3.8 `call.*` events — server → client, on the existing SSE stream

Unchanged from today's control plane, because the client already understands them:

| Event | Payload |
| --- | --- |
| `ready` | `{userId}` |
| `incoming-call` | call object, unwrapped |
| `call-status` | call object, unwrapped (including the new `left` transitions) |
| `ongoing-call` | call object, unwrapped |
| `presence` | `{userId, online}` |

**Change required by C5/N7:** `call-status` must now be emitted when a participant
leaves an `active` call, and not only when the whole call ends.

---

## 4. ICE configuration

- Server config: `ICE_STUN_URL` (default: one public STUN), `ICE_TURN_URL` /
  `ICE_TURN_USERNAME` / `ICE_TURN_CREDENTIAL` (absent by default).
- Delivered inside every `addPeer`; the client adopts it verbatim and has no
  built-in fallback.
- The server never hardcodes a provider in a client, never uses a third-party
  TURN without an explicit decision, and reports the effective configuration in
  the startup log (URLs only — **never** TURN credentials).
- No TURN means a symmetric-NAT pair cannot connect. That is a documented,
  decision-level limitation, not a silent one.

---

## 5. Rate limits and ceilings

| Limit | Value | On breach |
| --- | --- | --- |
| Message size | 128 KiB, enforced by the WebSocket layer before parse | connection closed |
| SDP | 64 KiB, must begin `v=` | message rejected and counted |
| ICE candidate | 4 KiB, must begin `candidate:` | message rejected and counted |
| `relaySDP` + `relayICE` per socket | 60 per second | excess dropped silently |
| `peerStatus` per socket | 10 per second | excess dropped silently |
| Malformed messages per socket | 10 | connection closed (1008) |
| Participants per call | 4, **enforced server-side** | `join` refused with `room_full` |
| Sockets per device | the newest wins | the previous connection is evicted |
| Calls created per person | 6 per minute | refusal, counted |
| Invitations per person | 12 per minute | refusal, counted |
| Responses per person | 20 per minute | refusal, counted |

Every limit is per server process, in memory, and resets on restart — adequate for
a household, and a deliberate choice against adding a shared store.

---

## 6. Explicitly not in the protocol

No chat, whiteboard, file transfer, captions, reactions, screen-share signalling
beyond the interop `peerStatus` element, presenter/lock/kick, lobby, room
passwords, `checkPassword`, `checkPeerName`, room listings, `data` ack API,
video-player sync, drawing, whisper, OIDC, or Mattermost. Each was traced in
[`MIROTALK_DEPENDENCY_MAP.md`](MIROTALK_DEPENDENCY_MAP.md); none is required for a
call, and each carried either product surface or a security gap.
