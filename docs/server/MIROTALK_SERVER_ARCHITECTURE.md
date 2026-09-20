# MiroTalk P2P server architecture (source-derived)

MiroTalk P2P **1.9.64**, upstream commit
`5af51e0cf2fd38bc296574f8d4aff9a19ea318c5`, as deployed at `/home/admin/mirotalk`
on `qatar-vpn` and audited read-only on 2026-09-20.

**Provenance:** AGPLv3 (`package.json` `license`), upstream
`https://github.com/miroslavpejic85/mirotalk`. The deployed tree has **no local
commits**; its only local source change is a one-token bind patch
(`app/src/server.js:1235`). Nothing in Crossbar is derived from this source; this
document is a description, not a copy.

Line references are to `app/src/server.js` unless stated otherwise.

---

## 1. Shape of the thing

MiroTalk P2P is **one Node process, one Socket.IO namespace, one source file**.
`apps/src/server.js` is 2,870 lines and owns:

- the Express app and every HTTP route (landing page, `/join`, `/newcall`,
  `/activeRooms`, `/stats`, `/login`, Swagger, `/api/v1/*`);
- the HTTP **and** HTTPS listener (`httpolyglot`);
- the Socket.IO server and all 18 signalling handlers;
- 100% of room, peer and presenter state, in memory;
- ICE configuration.

There is **no database, no namespace, no adapter, no worker, no message bus, and
no persistence of any kind**. Exhaustive grep for `writeFile|sqlite|redis|createReadStream`
in `server.js` returns no matches. Room lifetime is exactly the interval between
the first and the last socket in it.

```
                 ┌──────────────────────── server.js (2870 lines) ────────────────────────┐
Express routes ──┤ app.get/post  ·  /api/v1/* (API-key gated)  ·  static public/          │
                 │                                                                        │
httpolyglot  ────┤ createServer(options, app)   ← one listener, HTTP + HTTPS                 │
                 │                                                                        │
Socket.IO  ──────┤ new Server({maxHttpBufferSize:1e7, transports:['websocket'], cors})      │
                 │   io.sockets.on('connect')  → 18 handlers + 4 nested helpers            │
                 │                                                                        │
state  ──────────┤ channels{}  sockets{}  peers{}  presenters{}  wbLocks{}   (in memory)    │
                 └────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Startup sequence, in execution order

| # | Step | Line |
| --- | --- | --- |
| 1 | `require('dotenv').config()` — loads `./.env` from the working directory | 54 |
| 2 | Static requires: `express-openid-connect`, `socket.io`, `httpolyglot`, `compression`, `express`, `cors`, `helmet`, `axios`, `jsonwebtoken`, plus local `xss`/`api`/`mattermost`/`validate`/`htmlInjector`/`host`/`logs`/`embedHeaders` | 56-75 |
| 3 | `const app = express()`; `const log = new Logs('server')` | 66, 76 |
| 4 | `const config = require('./config')` — re-runs dotenv; the **only** place `process.env` is read | 79 |
| 5 | Nodemailer transport constructed immediately | 82 |
| 6 | Rate limiter: `maxAttempts`, `minBlockTime`, `loginLimiter` keyed by `getIP(req)` | 87-99 |
| 7 | `port`, `host` from config; `authHost = new Host()` | 101-104 |
| 8 | SSL material read **synchronously** (`app/ssl/key.pem`, `cert.pem`) | 107-114 |
| 9 | `server = httpolyglot.createServer(options, app)` — one listener, both protocols | 117 |
| 10 | `server.on('clientError')` → 400 | 120-127 |
| 11 | `trustProxy`, `corsOptions = {origin, methods}` | 130-136 |
| 12 | **Socket.IO created and attached** | **141-145** |
| 13 | `hostCfg` built; **throws** if host protection is on with invalid `HOST_USERS` passwords | 150-165 |
| 14 | `jwtCfg = {JWT_KEY, JWT_EXP}`; `roomPresenters = config.presenters` | 168-174 |
| 15 | Swagger YAML read synchronously; `swagger-ui-express` mounted | 176-179 |
| 16 | API: `uuidV4`, `apiBasePath='/api/v1'`, `api_key_secret`, `api_disabled` | 181-195 |
| 17 | Ngrok / webhook config objects (both disabled here) | 197-205 |
| 18 | **ICE servers constructed once, at boot** | **201-213** |
| 19 | `testStunTurn` URL; IP lookup / survey / redirect flags | 215-222 |
| 20 | Sentry init + console interception (disabled) | 224-276 |
| 21 | OpenAI client (disabled) | 278-292 |
| 22 | Whisper config + `require('./lib/whisper')` (disabled) | 294-307 |
| 23 | `ipWhitelist`, `OIDC` config objects; `OIDCAuth()` factory | 309-353 |
| 24 | `mattermostCfg`, `statsData`, `dir.public`, `views{10}`, `brandHtmlInjection`, `htmlInjector = new HtmlInjector(...)` — **preloads 7 HTML files and starts a chokidar watcher** | 355-402 |
| 25 | **Room/peer state initialised** | **404-415** |
| 26 | `app.set('trust proxy', trustProxy)` | 417 |
| 27 | Guardrail: `IP_WHITELIST_ENABLED` with `TRUST_PROXY=false` → **`process.exit(1)`** unless `IP_WHITELIST_ALLOW_UNTRUSTED_PROXY=true` | 419-437 |
| 28 | `helmet.noSniff()`; `applyEmbedHeaders` | 439-440 |
| 29 | Static: `express.static(public)` at `/` and `/mattermost` | 443-456 |
| 30 | `cors()`, `compression()`, `express.json()`, `express.urlencoded()`, Swagger UI | 458-462 |
| 31 | IP-whitelist middleware (403 outside list) | 464-475 |
| 32 | Request-logging middleware | 477-487 |
| 33 | `new MattermostController(...)` (returns early when disabled) | 490 |
| 34 | JSON-parse error handler; trailing-slash 301 | 493-508 |
| 35 | OIDC `auth()` mounted (or host-cache variant when `baseUrlDynamic`) | 510-569 |
| 36 | All Express routes | 571-894 |
| 37 | `/api/v1/*` routes | 896-1120 |
| 38 | 404 handler; global error handler | 1122-1146 |
| 39 | `getServerConfig(tunnel)` — builds the object the startup log prints | 1153-1213 |
| 40 | `ngrokStart()` defined; called only if enabled | 1219-1230 |
| 41 | **`server.listen(port, '127.0.0.1', …)`** → banner + `log.info('Server config', …)` + default-secret warnings | **1235-1280** |
| 42 | **Signalling registration**: `io.sockets.on('connect', async (socket) => {…})` | **1293-2550** |
| 43 | Module-scope helpers | 2552-2855 |
| 44 | **Shutdown**: `SIGINT`/`SIGTERM` → `htmlInjector.cleanup()` + `process.exit()` | 2857-2870 |

Three facts from this ordering matter to a redesign:

1. **ICE servers are computed once at boot**, from env, and shipped inside every
   `addPeer`. There is no per-call or per-peer ICE policy.
2. **The listener bind is hardcoded** at line 1235. The `HOST` env var is *not* the
   bind control — changing it only corrupts the `/icetest` and `/api/v1/docs`
   links the startup banner prints.
3. **Shutdown is abrupt**: no `io.close()`, no room teardown, no drain. Every
   client is disconnected by process death.

---

## 3. Socket.IO architecture

```js
const io = new Server({
    maxHttpBufferSize: 1e7,     // 10 MB — 10× the Engine.IO default
    transports: ['websocket'],  // polling effectively disabled
    cors: corsOptions,
}).listen(server);
```
(`:141-145`)

- **One namespace** (`/`). Exhaustive grep for `io.of` → no match.
- **No adapter, no Redis, no sticky sessions.** Single process by construction.
- Because `transports: ['websocket']` is fixed, the polling→websocket upgrade
  logging at `:1308-1311` is vestigial.
- There is **no `SOCKET_*` configuration surface**: buffer size, transports, ping
  timings and the adapter are all hardcoded.
- `maxHttpBufferSize` is the ceiling for in-band whiteboard/caption/file payloads;
  the whiteboard has an additional 2 MB application cap (`:2310-2317`).

### 3.1 The connection chain (`io.sockets.on('connect')`, `:1293`)

1. log accept (`1294-1297`)
2. `socket.channels = {}` (`1299`) — per-socket room membership
3. `sockets[socket.id] = socket` (`1300`) — **global** socket registry
4. `socket.conn.on('upgrade')` logging (`1308-1311`)
5. `socket.on('disconnect')` (`1316-1324`)
6. `socket.on('data')` (`1328-1436`) — ack-style callback API
7. `socket.on('join')` (`1439-1683`)
8. Twelve further signal handlers (`relayICE` … `videoDrawing`)
9. Four **nested helpers** re-declared per connection: `addPeerTo` `2433`,
   `removePeerFrom` `2457`, `toJson` `2519`, `sendToRoom` `2527`, `sendToPeer` `2544`

Point 9 is a real inefficiency: N sockets produce N copies of every helper closure.
A purpose-built server should hoist them.

### 3.2 Handler inventory

| Event | Line | Mutates | On the call path? |
| --- | --- | --- | --- |
| `disconnect` | 1316 | `channels`, `peers`, `presenters`, `wbLocks`, `sockets` | **yes** |
| `data` (ack API) | 1328 | reads `peers` (duplicate-name check), OpenAI proxy | no |
| `join` | 1439 | creates all three per-room maps; writes `peers[ch][socket.id]`; presenter election | **yes** |
| `relayICE` | 1686 | none | **yes** |
| `relaySDP` | 1703 | none | **yes** |
| `roomAction` | 1720 | `peers[room].lock/password/joinLock` | no (lobby/lock product) |
| `peerName` | 1800 | `peers[room][id].peer_name/avatar`, `presenters` | partial |
| `message` | 1843 | none (chat relay) | no |
| `cmd` | 1869 | none (command relay) | no |
| `peerStatus` | 1910 | `peers[room][id].peer_*_status`, `extras` | **yes** (interop) |
| `peerAction` | 1973 | none (mute/hide/eject relay) | no |
| `caption` | 2031 | none | no |
| `getWhisperTranscription` | 2060 | none (server-side Whisper proxy) | no |
| `kickOut` | 2145 | none | no |
| `fileInfo` | 2172 | none | no |
| `fileAbort` / `fileReceiveAbort` | 2219 / 2237 | none | no |
| `videoPlayer` | 2257 | none | no |
| `wbCanvasToJson` | 2300 | reads `wbLocks` | no |
| `whiteboardAction` | 2350 | `wbLocks[room]` | no |
| `videoDrawing` | 2401 | reads `peers[room][screenOwner]` | no |

**Five handlers carry a call; thirteen are product surface.**

### 3.3 The two fan-out primitives

```js
async function sendToRoom(room_id, socket_id, msg, config = {}) {
    for (let peer_id in channels[room_id]) {
        if (peer_id != socket_id) await channels[room_id][peer_id].emit(msg, config);
    }
}

async function sendToPeer(peer_id, sockets, msg, config = {}) {
    if (peer_id in sockets) await sockets[peer_id].emit(msg, config);
}
```
(`:2527-2556`)

- `sendToRoom` iterates **`channels`** (the socket registry), never `peers`.
  `peers` is for identity/presence; `channels` is for delivery.
- `sendToPeer` is keyed on the **global** `sockets` map and therefore performs
  **no room check at all**. An absent id silently no-ops. This is what makes
  `relaySDP`/`relayICE` blind routers — see
  [`MIROTALK_SECURITY_MODEL.md`](MIROTALK_SECURITY_MODEL.md).

---

## 4. Room and peer state

```js
const channels   = {}; // :404  room_id -> { socket_id: socket }        (delivery registry)
const sockets    = {}; // :405  socket_id -> socket                     (global registry)
const peers      = {}; // :406  room_id -> { socket_id: peer, lock?, password?, joinLock? }
const presenters = {}; // :407  room_id -> { socket_id: presenter }
const wbLocks    = {}; // :408  room_id -> true                         (whiteboard lock)
const roomMetaKeys = new Set(['lock', 'password', 'joinLock']); // :410
```

`getPeerCount(roomId)` (`:412-415`) counts keys excluding the three meta keys.
Detailed field-by-field classification is in
[`MIROTALK_ROOM_AND_PEER_STATE.md`](MIROTALK_ROOM_AND_PEER_STATE.md).

Two structural observations:

- **`peers[room]` is a mixed map**: peer records *and* room metadata share one
  object, which is why a locked room's plaintext `password` is shipped inside
  every `addPeer` (see §5).
- **The peer key is `socket.id`**, which the server controls. The client-supplied
  `peer_id`, `peer_uuid` and `peer_name` are metadata; only `peer_uuid` plays an
  authorization role, and only inside `presenters`.

---

## 5. Topology: a full mesh built by one helper

`addPeerTo(channel)` (`:2433-2453`) is the **only** topology driver:

```js
async function addPeerTo(channel) {
    for (let id in channels[channel]) {
        // offer false
        await channels[channel][id].emit('addPeer', {
            peer_id: socket.id, peers: peers[channel],
            should_create_offer: false, iceServers: iceServers,
        });
        // offer true
        socket.emit('addPeer', {
            peer_id: id, peers: peers[channel],
            should_create_offer: true, iceServers: iceServers,
        });
    }
}
```

- Each existing peer gets one `addPeer` per new peer with `should_create_offer: false`;
  the joiner gets one per existing peer with `true`. Exactly one side of each pair
  offers. N peers ⇒ N(N−1) emissions ⇒ **full mesh**.
- Every `addPeer` embeds **the entire raw `peers[channel]` map** — including the
  reserved `lock`/`password`/`joinLock` keys when set, and including both the
  recipient's and the joiner's own entries.
- Because `addPeerTo` runs *before* `channels[channel][socket.id] = socket`
  (`:1629` vs `:1656`), the joiner is not yet visible in `channels` while fan-out
  happens — but *is* already present in the `peers` snapshot each `addPeer` ships.

**Adding a third participant therefore requires no new server concept**: C joins,
the helper emits A↔C and B↔C, A↔B is untouched, and C is the offerer on both new
pairs. The `peers` snapshot already contains all three, so no roster-resync event
exists or is needed.

---

## 6. ICE configuration

Constructed once at boot (`:201-213`):

```js
const iceServers = [];
if (stunServerEnabled && stunServerUrl) iceServers.push({ urls: stunServerUrl });
if (turnServerEnabled && turnServerUrl && turnServerUsername && turnServerCredential) {
    iceServers.push({ urls: turnServerUrl, username: turnServerUsername, credential: turnServerCredential });
}
```

Deployed effective value: **`[{urls:'stun:stun.l.google.com:19302'}]` — one public
STUN server, no TURN**, confirmed in `.env`, in source, and in the running
process's startup log. It is delivered inside every `addPeer` and also echoed in
the `/api/v1/*` config response. Peers are a full mesh; media is pure P2P and never
touches the server.

`/icetest` exists as a manual ICE-check page, but the link is built from
`config.server.host` (the `HOST` env value), so with `HOST=127.0.0.1` the banner
advertises an unreachable URL.

---

## 7. Configuration surface that changes call behaviour

Full key inventory is in [`QATAR_DEPLOYMENT_AUDIT.md`](QATAR_DEPLOYMENT_AUDIT.md) §6.
The keys that actually alter call/signalling semantics:

| Key | Deployed | Effect |
| --- | --- | --- |
| `HOST_PROTECTED` / `HOST_USER_AUTH` | false / false | together with the client's own `peer_token`, they determine `authRequired` in `join` — **false here, so any socket may join or create any room** |
| `peer_token` (client-supplied) | none | the *only* thing that can trigger authentication in this deployment |
| `PRESENTERS` | `[]` | empty ⇒ first joiner becomes presenter |
| `ROOM_MAX_PARTICIPANTS` | 1000 | **never enforced server-side**; only echoed to the client, which enforces it in its own UI |
| `STUN_*` / `TURN_*` | STUN on, TURN off | the `iceServers` above |
| `CORS_ORIGIN` | tailnet origin | applied to Express **and** to Socket.IO (`:458`, `:144`) |
| `ALLOWED_EMBED_ORIGINS` | empty | no `frame-ancestors`/`X-Frame-Options` ⇒ the room page may be iframed from any origin |
| `IP_WHITELIST_*` | disabled | middleware exists and is inert |
| `API_KEY_SECRET` / `API_DISABLED` | set / `["token","meetings"]` | gates `/api/v1/*`, including the `/api/v1/join` route Family Call uses |
| `TRUST_PROXY` | true | `getSocketIP` trusts the first `X-Forwarded-For` hop |

---

## 8. Essential versus droppable

Derived from the module and handler inventory, answering "what breaks if this is
removed?" for each. Full per-file classification is in
[`MIROTALK_DEPENDENCY_MAP.md`](MIROTALK_DEPENDENCY_MAP.md).

**Essential to establishing media (6 things):**

1. An Engine.IO v4 / Socket.IO v5 endpoint over WebSocket on the root namespace.
2. `join`: room validation, socket-id-keyed membership, `peers[channel][socket.id]`,
   `serverInfo`, and `addPeerTo` fan-out.
3. `relaySDP` → `sessionDescription` and `relayICE` → `iceCandidate` relays.
4. `disconnect` → `removePeerFrom` → `removePeer` fan-out and empty-room GC.
5. `iceServers` construction and delivery.
6. `peerStatus` — not needed to establish media, but required for the far end to
   distinguish "camera off" from "call broken"; the native client mirrors it.

**Droppable without touching negotiation** (from `:1328` onward): Express HTML
pages, Swagger, OIDC, Mattermost (217 lines) and its JWT/AES `tokenManager`
(270 lines), Slack, ngrok, Sentry, email alerts, survey/redirect, stats, Whisper,
ChatGPT, the i18n extraction script, whiteboard, chat, file transfer, shared video
player, drawing, captions, hand-raise, privacy blur, kick/eject, room locks and
the lobby.

**One dependency that is *not* obvious:** `validate.js` and `xss.js` are on the
call path as payload gates, and `isPeerInRoom` guards several handlers. Dropping
them is not simplification — it is removing validation. See
[`MIROTALK_SECURITY_MODEL.md`](MIROTALK_SECURITY_MODEL.md) for which parts must be
replaced rather than deleted.

**Two modules that look optional and are not:** nothing in the call path depends
on `htmlInjector.js` or `public/views/*` — those exist to serve MiroTalk's own
browser client. Crossbar does not load them (it is a native WebRTC client), but
the Family Call **PWA does**: `public/app.js:279` sets
`el('call-frame').src = joinUrl`, i.e. the PWA's entire media engine *is*
MiroTalk's web client inside an iframe, and the PWA detects "user left the call"
by observing that iframe navigate to `/newcall` (`public/app.js:311-318`). Any
plan that removes MiroTalk must therefore also replace or retire the PWA's media
path — this is a migration constraint, not a server-design detail.

---

## 9. What the server is not

- **Not an SFU.** It never sees media; it relays SDP/ICE text only.
- **Not stateful across restarts.** No room, peer or call survives a restart, and
  nothing is written to disk.
- **Not multi-process.** No adapter, no sticky sessions, no shared state.
- **Not authenticated.** In this deployment, room membership is the only access
  control, and a room id is not a secret.
- **Not observable.** `LOGS_DEBUG=false` suppresses every connect/join/leave
  trace, so there is no positive-path telemetry at all; only errors and the
  startup banner are emitted.
