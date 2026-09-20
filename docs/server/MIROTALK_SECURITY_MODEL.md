# MiroTalk security model (source-derived)

Trust boundaries, every control that exists, every gap that does not, and what
each control is worth. Derived from the deployed MiroTalk 1.9.64 source on
`qatar-vpn` (read-only, 2026-09-20) plus the measured runtime state.

Companion: [`CROSSBAR_SECURITY_MODEL.md`](CROSSBAR_SECURITY_MODEL.md) (what a
replacement must enforce), [`QATAR_DEPLOYMENT_AUDIT.md`](QATAR_DEPLOYMENT_AUDIT.md)
(network topology).

> **Nothing in this document is a vulnerability report against a public service.**
> MiroTalk is loopback-bound behind a private tailnet, reachable only by tailnet
> members. The gaps below matter because a Crossbar server must not reproduce
> them, and because "it is on the tailnet" is not the same as "it is authorized".

---

## 1. Trust boundaries

```
   tailnet members (family devices)          anyone with a shell on the Pi
                 |                                     |
                 |  tailnet ACLs decide reachability    |  no control at all
                 v                                     v
   ┌─────────────────── tailscaled (root, TLS terminator) ───────────────────┐
   │  Serve 443 → http://127.0.0.1:3000        Serve 8443 → http://127.0.0.1:3001 │
   │  injects Tailscale-User-Login/-Name/-Profile-Pic; strips spoofed copies   │
   └────────────────────────────────────────────────────────────────────────┘
                 |                                     |
                 v                                     v
        127.0.0.1:3000 MiroTalk                127.0.0.1:3001 Family Call
        reads NO Tailscale header               reads ONLY Tailscale headers,
        → tailnet identity is invisible         and only from loopback peers
```

Three facts define the boundary:

1. **Both apps bind loopback only** (`mirotalk/app/src/server.js:1235` is a local
   patch; `family-call/src/config.js:59-62` refuses to start otherwise). Nothing
   on the LAN or the internet can reach either.
2. **`tailscaled` is the only ingress.** It terminates TLS with a real tailnet
   certificate and speaks plaintext HTTP to the loopback app. There is no nginx,
   no caddy, no host firewall.
3. **`httpolyglot` also accepts plain HTTP on the same loopback port**, with a
   shipped self-signed upstream certificate that is never used on the live path.

### Network position is not application authorization

MiroTalk reads **no** Tailscale header at all — exhaustive grep for
`tailscale`/`Tailscale-User` across `app/src/**` and `public/js/client.js` returns
zero matches. Its request path is byte-identical whether a request arrives through
Serve or from a local process. **Anything running on the Pi can therefore speak
to MiroTalk as a fully-privileged anonymous client**, and every tailnet member is
an equally trusted, fully unauthenticated signalling client. "Only tailnet members
can join a Crossbar call" is exactly as strong as the tailnet ACLs on port 443,
and no stronger.

Family Call is the opposite: it derives identity from the injected headers, but
**accepts them only when `req.socket.remoteAddress` is loopback**
(`src/identity.js:9-22`), which is why its bind restriction is load-bearing rather
than decorative.

---

## 2. What an unauthenticated socket can do

Host and user authentication are both off (`HOST_PROTECTED=false`,
`HOST_USER_AUTH=false`), and the only auth expression on the socket path is:

```js
const authRequired = hostCfg.user_auth || peer_token || (hostCfg.protected && isRoomNew);
```
(`server.js:1495`)

which reduces to **`!!peer_token`** — authentication happens only if the client
*volunteers* a token. A socket that sends none skips the entire auth block.

The remaining gate is the room-name check (`server.js:1474-1477`) plus the room
password check. Therefore an unauthenticated socket can:

- connect (no gate in the connect handler at all);
- join **any** room whose name passes `isValidRoomName` — which accepts any
  non-empty string that survives `checkXSS` and has no path-traversal pattern;
  **no charset, length, or UUID requirement**;
- **create** rooms simply by naming them;
- become **presenter** of any room it is first to name (with `PRESENTERS=[]`),
  which grants lock/join-lock, kick, mute-all/hide-all/eject-all, and whiteboard
  control.

**Room name is the only application-level access control**, and the system treats
it as an identifier, not a secret: it is a plain object key, logged at debug
level (`server.js:1455`), and would be listed in bulk by `/api/v1/activeRooms` if
`SHOW_ACTIVE_ROOMS` were enabled. Crossbar/Family Call happen to use UUIDv4 names,
which makes guessing infeasible — but that is a *deployment* property, not an
enforced one.

---

## 3. Controls that exist, and what they are worth

| Control | Location | What it actually protects |
| --- | --- | --- |
| Loopback bind | `server.js:1235` (local patch) | reachability: no LAN/internet exposure. **Must preserve.** |
| Tailnet Serve TLS | `tailscaled.service` | transport confidentiality/integrity, coarse reachability by tailnet ACL. **Must preserve.** |
| `isPeerInRoom` guard | `server.js:2608-2610`, call sites for `message`, `cmd`, `peerStatus`, `peerAction`, `caption`, `fileInfo`, `videoPlayer`, `videoDrawing`, whiteboard, whisper | cross-room injection of *broadcast* events. Keyed on the server-controlled `socket.id`. **Must preserve the invariant.** |
| Presenter model (`isPeerPresenter`) | `server.js:2620-2650` | privileged actions (lock/kick/whiteboard/mute-all). Requires a server-issued entry **and** `peer_name` + `peer_uuid` match, with `peer_uuid` never broadcast. **The only real anti-spoofing primitive in the system.** |
| `checkXSS` (DOMPurify + jsdom) | `xss.js:66-112`, applied to `join`, `peerStatus`, `data`, `roomAction`, `peerName`, `message`, `cmd`, `peerAction`, `caption`, `kickOut`, `fileInfo`, `videoPlayer`, whiteboard, `videoDrawing` | HTML/JS injection into *other browsers*. Decode-then-sanitize, recursive. **Note: it fails open** — on any exception it returns the original unsanitized object (`xss.js:74-79`). |
| `Validate.isValidRoomName` / `hasPathTraversal` | `validate.js:11-53` | path traversal in room names. Double-decoded. **No length or charset limit.** |
| `isPrivateOrLoopbackHost`, `isSafeImageSrc`, `sanitizeWbCanvasJson`, `isValidHttpURL` | `validate.js:66-215`, `server.js:2565-2579` | browser-side SSRF/tracking beacons via whiteboard images and shared video URLs. Product-surface only. |
| `maxHttpBufferSize: 1e7` | `server.js:142` | a per-message ceiling — 10 MB, i.e. **10× the Engine.IO default**, which is what makes the flood primitive in §4 expensive. |
| `transports: ['websocket']` | `server.js:143` | removes the polling handshake; not a security control. |
| API-key gate on `/api/v1/*` | `api.js` `isAuthorized()`, call sites `server.js:911,947,976,1004,1030` | who may mint rooms and read stats/meetings listings. Plain `!==` string compare (not constant-time). The secret is printed at startup (§6). |
| `loginLimiter` | `server.js:87-99`, applied only at `server.js:824` | `POST /login` brute force. Key is `req.ip`, derived from a spoofable `X-Forwarded-For`. Protects an endpoint that gates nothing in this configuration. |
| IP whitelist + its guardrail | `server.js:419-437, 464-475` | nothing today (`IP_WHITELIST_ENABLED=false`). Note the guardrail *mandates* `TRUST_PROXY=true`, i.e. it requires the configuration in which `X-Forwarded-For` is trusted leftmost — so enabling the whitelist behind this proxy would create a spoofable allow-list. |
| `helmet.noSniff()` | `server.js:439` | MIME sniffing only. There is **no** HSTS, no frameguard, no CSP, no referrer policy. |
| CORS (`CORS_ORIGIN`, applied to Express **and** Socket.IO) | `server.js:132-145, 458` | **Nothing but browser read policy.** The `cors` package only sets response headers; Engine.IO installs it as HTTP middleware and its `verify()` rejects only malformed Origin values (`allowRequest` is unset, so all requests pass). A native WebSocket client sends no `Origin` and is entirely unaffected. **CORS is not admission control.** |

---

## 4. Authorization gaps, with evidence

### 4.1 `relaySDP` / `relayICE` are blind routers through a global registry

```js
socket.on('relayICE', async (config) => {
    if (!Validate.isValidData(config)) return;      // "is a non-empty object"
    const { peer_id, ice_candidate } = config;
    await sendToPeer(peer_id, sockets, 'iceCandidate', { peer_id: socket.id, ice_candidate });
});
```
(`server.js:1686-1698`; `relaySDP` at `:1703-1715` is identical in shape)

- **No `checkXSS`.**
- **No `isPeerInRoom`, no room check, no participant check of any kind.**
- `peer_id` is resolved through `sockets` — the **global** socket registry
  (`server.js:405`, populated at `:1300`) — so a socket that never joined a room
  can address any other socket id in the process.

Practical impact is bounded by the client, not by the server: the stock browser
client **drops** `sessionDescription` for an unknown peer (no `RTCPeerConnection`),
but it **queues** `iceCandidate` for an unknown peer with no key allow-list and no
length cap — so a known socket id is a cross-room memory-exhaustion primitive,
one 10 MB message at a time. The emitted `peer_id` is overwritten with the
sender's own `socket.id`, so relay cannot impersonate a third party.

**Socket ids are unguessable** (Engine.IO `base64id`, ~120 bits) but **not secret**:
every `addPeer` ships `peers[channel]`, whose keys *are* the socket ids of everyone
in the room, and every broadcast carries `peer_id: socket.id`.

### 4.2 Two unauthenticated oracles

- **`checkPassword`** (`server.js:1779-1787`) answers `OK`/`KO` against
  `peers[room_id].password` for any caller with no membership check, no presenter
  role, and **no rate limit** — an unlimited online guessing oracle that also
  confirms room existence.
- **`checkPeerName`** inside the `data` handler (`server.js:1336-1346`) iterates
  `peers[room_id]` for any `room_id` with no membership check and no limiter —
  a cross-room peer-name oracle.

### 4.3 A locked room's plaintext password is broadcast to every participant

```js
case 'lock':
    if (!isPresenter) return;
    peers[room_id]['lock'] = true;
    peers[room_id]['password'] = password;
```
(`server.js:1753-1756`), and every `addPeer` ships the **whole raw room map**:

```js
await channels[channel][id].emit('addPeer', { peer_id: socket.id, peers: peers[channel], … });
```
(`server.js:2436`, `:2443`)

Nothing strips the reserved `lock`/`password`/`joinLock` keys at send time; the
only filtering anywhere is `getPeerCount`'s, for counting. The stock client caches
the object (`allPeers = peers`), so the plaintext password persists in every peer's
heap for the session. It is also written to the log at debug level
(`server.js:1794`).

### 4.4 Remote crash / restart loop

```js
if (peer_id in sockets) { await sockets[peer_id].emit(msg, config); }
```
(`server.js:2545` — `in`, not `Object.hasOwn`)

`'constructor' in sockets` is `true` because of the prototype chain, and
`Object.emit` is `undefined`, so `relayICE {peer_id: "constructor"}` throws a
`TypeError` inside an async handler that has no `try`/`catch`. There is **no
`unhandledRejection` handler** anywhere (only `SIGINT`/`SIGTERM` at `:2860-2870`),
so under Node's default the process exits, and `mirotalk.service` has
`Restart=on-failure` / `RestartSec=5` — a crash–restart loop that drops every live
call. The same shape exists in `relaySDP`, `cmd`, `peerAction`, `kickOut`,
`fileInfo`, `videoPlayer`. `roomAction` is the exception: its relay calls sit
inside a `try`/`catch`. *[INFERENCE on the process exit — not executed, read-only.]*

### 4.5 Divergence that silently strands state

`removePeerFrom`'s `try` block deletes `channels[channel][socket.id]` **before**
`peers[channel][socket.id]` (`server.js:2477-2480`). If `channels[channel]` were
ever `undefined` (a concurrent disconnect GC'd the room), the `TypeError` is
swallowed by a `catch` that only logs, and the peer deletion never runs — a
permanent ghost that no later disconnect can reap, because the socket's own
`channels` entry was already deleted.

### 4.6 A token-minting login endpoint with default credentials

`POST /login` (`server.js:824-866`) mints a `JWT_KEY`-signed token for any user in
`HOST_USERS`, which ships in `.env` as `admin/admin` and `guest/guest`. The
deployment disables host protection, so the token grants nothing beyond the
already-unauthenticated default path — but the endpoint is live and its
credentials are defaults.

---

## 5. Input validation and size limits

| Control | Value | Where |
| --- | --- | --- |
| Socket message ceiling | **10 MB** (`1e7`, 10× the Engine.IO default) | `server.js:142` |
| HTTP body ceiling | 100 kB default (no options passed) | `server.js:460-461` |
| `relayICE` / `relaySDP` / `peerStatus` | **no per-handler cap** | `server.js:1686-1715`, `:1910` |
| Whiteboard canvas | 2 MB | `server.js:2305-2312` |
| `videoDrawing` points | 1–128, each coordinate finite in `[0,1]` | `server.js:2407-2420` |
| `fileInfo` filename | rejects `[\\/?*|:"<>]` | `server.js:2558-2561` |
| Rate limits | **only** `POST /login`; no limit on connections, joins, rooms, message rate, or payload volume | `server.js:87-99, 824` |
| `ROOM_MAX_PARTICIPANTS` | **never enforced server-side**; echoed to the client, which enforces it in its own UI | `server.js:155, 1651` |

`checkXSS` provides **no length limit and no type coercion** — it returns
arbitrary-length sanitized strings. So `peer_name`, `peer_avatar` and `extras`
reach every room member as arbitrary-length strings, and the two relay events
cross the server **completely unfiltered**.

---

## 6. Secrets and logging

`log.info('Server config', getServerConfig())` runs **on every start**
(`server.js:1254`) and the object it prints includes, by name:

- **`jwtCfg`** — which contains `JWT_KEY`, the key that signs *and* decrypts every
  token and doubles as the Mattermost encryption key;
- **`api_key_secret`** — the full `API_KEY_SECRET` that authorizes `/api/v1/join`,
  i.e. the room-minting capability;
- conditionally, if ever enabled: `oidc` (would include `clientSecret`),
  `iceServers` (would include TURN credentials), `chatGPT_enabled` (API key),
  `email` (password), `mattermost_enabled` (password/token), `ngrok.token`.

**Values are deliberately not reproduced in this document.** They are nonetheless
written to the journal on the production host — which is exactly the leak that
`engine-patches/0002-redact-startup-config.patch` fixes **for the inactive 3002
copy only**.

Also suppressed-but-present hazards: the request logger at debug level records
full URLs (including `/join?room=…&name=…`) and parsed bodies including login
credentials (`server.js:477-489`), and the auth-failure logs include
`header: req.headers`, i.e. the `authorization` secret. All of these are currently
silenced only because `LOGS_DEBUG=false` — a single environment change away.

**Observability is the mirror image of this:** with `LOGS_DEBUG=false` there is
**no positive-path telemetry at all** — no "peer joined room X", no peer-leave
line, no auth-failure line. Only errors and the startup banner are emitted.

---

## 7. Classification

Each control classified as required by the brief: **must preserve** / **Crossbar
can replace with a simpler equivalent** / **not relevant to Crossbar** /
**requires design decision**.

### Must preserve

| Control | Why |
| --- | --- |
| Loopback bind + tailnet Serve as sole ingress | the entire reachability model; removing it exposes an unauthenticated signalling surface to the LAN |
| Tailnet TLS termination | only transport confidentiality/integrity in effect |
| Room-scoped membership check on every broadcast (`isPeerInRoom`) | prevents cross-room event injection; must be extended to the **relays**, which lack it |
| Cleanup on last leave (room GC) | without it, in-memory state leaks per room forever |
| `disconnect`-driven departure handling | multiparty correctness; the client never says goodbye |
| A per-message size cap | 10 MB is too generous, but *a* cap is required |
| The invariant behind `isPeerPresenter`: authorize on a server-controlled id, never on client-supplied identity | the only anti-spoofing primitive in the codebase |

### Crossbar can replace with a simpler equivalent

| Control | Simpler equivalent |
| --- | --- |
| `checkXSS`/DOMPurify/jsdom | per-field type checks, length caps and value allow-lists. Crossbar's native client has no HTML context; a jsdom runtime and its fail-open path should not be carried over. |
| JWT + AES token subsystem (`tokenManager`, `isValidToken`, `decodeToken`, `isAuthPeer`) | dead code in this configuration; replace with a minimal credential if Crossbar needs one at all |
| `isAllowedRoomAccess` | one admission check at join, applied uniformly to HTTP and socket paths |
| `helmet.noSniff()` | set the two or three headers a Crossbar HTTP surface actually needs |
| `httpolyglot` + shipped self-signed cert | bind loopback and let Serve terminate TLS; ship no certificate |
| Per-feature caps (`wbCanvasToJson`, `videoDrawing`, whisper) | apply the *idea* — validate shape and size at every handler edge — to `join`/`relaySDP`/`relayICE`/`peerStatus` |
| `checkPeerName` | if name-collision checking is needed, scope it to the caller's own room and rate-limit it |

### Not relevant to Crossbar

Tailscale-header consumption (MiroTalk reads none); `POST /login` and its limiter;
OIDC; the API-key surface (`/api/v1/*`) except as the room-minting hop Family Call
needs; `isPrivateOrLoopbackHost`/`isSafeImageSrc`/`sanitizeWbCanvasJson` and
`isValidHttpURL` (whiteboard/video-player features); embed headers and the whole
web-UI surface; Mattermost, Slack, ChatGPT, Whisper, Sentry, ngrok, webhook,
email alerts, survey/redirect, stats. CORS, for a native WebSocket client, is
**not** a control.

### Requires a design decision

| Decision | Options |
| --- | --- |
| `X-Forwarded-For` trust | ignore it and use the socket address; keep it for logs with the spoofability documented; or drop `TRUST_PROXY` entirely. Nothing security-relevant consumes it today. |
| Room-name generation | minted opaque token (bearer-secret-like) vs human-chosen name. First-joiner-becomes-presenter makes guessable names squattable. |
| `relaySDP`/`relayICE` semantics | Crossbar needs both events; it must decide to require caller-and-target in the same call, and to keep the property that the emitted `peer_id` is the server's, not the client's. |
| Room passwords / locks | drop them entirely (Crossbar has no such product concept) or reimplement without the plaintext broadcast and the `checkPassword` oracle. |
| `addPeer`'s roster payload | keep `peers` for browser interoperability (the browser reads media status from it) while **never** including room meta-keys. |
| Process error model | an async handler rejection must not be able to kill the signalling process. |
| Startup logging | log a redacted configuration; never secrets. |
| `sendToPeer` map semantics | use a `Map` / `Object.hasOwn` / id-shape validation — never `in` on a plain object. |

---

## 8. Bottom line

**Protected today, verifiably:** network reachability (loopback + tailnet only);
cross-room injection of *broadcast* events; privileged action spoofing (presenter
model); HTML injection into browsers for the handlers wrapped by `checkXSS`;
path traversal in room names; SSRF via whiteboard/video URLs; unauthorized use of
the room-minting API.

**Not protected:** participant identity (no accounts, no per-room membership, first
joiner becomes presenter); room confidentiality (the room name is the only
application-level control, and it is treated as an identifier); signalling
integrity (blind cross-room SDP/ICE relay, unsanitized, uncapped); signalling
availability (a malformed `peer_id` can crash the process into a restart loop);
locked-room password secrecy (broadcast in plaintext inside `addPeer`);
any linkage to tailnet identity (MiroTalk reads no Tailscale header, so every
tailnet member — and anything local — is an equally trusted anonymous client);
and any form of abuse throttling beyond one dead login limiter.
