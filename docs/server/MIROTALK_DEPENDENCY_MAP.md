# MiroTalk dependency map — essential vs optional

For every subsystem MiroTalk 1.9.64 contains, what it does, what depends on it,
and whether Crossbar needs it. The question asked of each row is the one that
matters: **what breaks if this is removed?**

Sources: `app/src/**` inventory and handler inventory from the read-only audit of
`/home/admin/mirotalk` (2026-09-20); see
[`MIROTALK_SERVER_ARCHITECTURE.md`](MIROTALK_SERVER_ARCHITECTURE.md).

---

## 1. Server modules

| File | Lines | What it does | Call path? | If removed |
| --- | --- | --- | --- | --- |
| `app/src/server.js` | 2870 | HTTP/HTTPS host **and** Socket.IO signalling, all routes, all room/peer state | **essential** | nothing works |
| `app/src/config.js` | 606 | the only `process.env` reader; env → typed config | **essential** (config) | no configuration at all |
| `app/src/config.template.js` | 606 | upstream template, copied to `config.js` by `prestart` if missing | not loaded | nothing |
| `app/src/api.js` | 130 | `ServerApi`: API-key check, stats/activeRooms/meetings, `getJoinURL()`/`getToken()` | **call-adjacent** | Family Call can no longer mint join URLs; signalling unaffected |
| `app/src/validate.js` | 200 | room-name validation, path traversal, private/loopback host detection, payload shape checks, fabric canvas sanitizer | **essential** (validation) | **removes input validation** — see §4 |
| `app/src/xss.js` | 109 | `checkXSS` = `he.decode` + DOMPurify over every string in a payload, recursive | **essential** (validation) | **removes payload sanitisation** |
| `app/src/host.js` | 54 | `Host` = in-memory `Map` of login/OIDC-authorized IPs | auth only | nothing in this deployment (`HOST_PROTECTED=false`) |
| `app/src/logs.js` | 132 | logger with levels, JSON mode, TZ | infra | loses logging |
| `app/src/htmlInjector.js` | 113 | caches and OG-injects 7 `public/views/*.html`, chokidar watcher | **no** | MiroTalk's own web pages lose OG tags; signalling unaffected. *But the browser client is how the PWA gets media — see §3* |
| `app/src/mattermost.js` | 217 | Mattermost slash-command controller | no | nothing (disabled) |
| `app/src/tokenManager.js` | 270 | JWT/AES helper imported **only** by `mattermost.js` | no | nothing (disabled) |
| `app/src/lib/nodemailer.js` | 172 | "user joined" email alert | no | nothing (`EMAIL_ALERT=false`) |
| `app/src/lib/whisper.js` | 112 | Whisper audio-payload validation + hallucination filter | no | nothing (`WHISPER_ENABLED=false`) |
| `app/src/middleware/embedHeaders.js` | 66 | CSP `frame-ancestors` / `X-Frame-Options` from `ALLOWED_EMBED_ORIGINS` | no | loss of an **unset** control |
| `app/src/scripts/extract-ui-lang.js` | 325 | dev-only i18n extractor | never loaded | nothing |
| `app/src/server.js.before-local-bind` | 2870 | pre-edit backup of the bind patch | not loaded | nothing (must be preserved as rollback) |

**Concentration:** one file is ~13× the next largest and owns the entire protocol.
Only 6 of 16 files are on the call path at all.

---

## 2. Signalling handlers

| Handler | Call path? | If removed |
| --- | --- | --- |
| `join` (1439) | **essential** | no admission, no room |
| `relaySDP` (1703) → `sessionDescription` | **essential** | no offer/answer ever arrives |
| `relayICE` (1686) → `iceCandidate` | **essential** | no connectivity |
| `disconnect` (1316) + `removePeerFrom` (2457) + `addPeerTo` (2433) | **essential** | no mesh, no cleanup |
| `peerStatus` (1910) | **required for interop** | far end cannot tell "camera off" from "call broken"; MiroTalk UI badges go stale |
| `peerName` (1800) | optional | a rename/avatar change never propagates |
| `roomAction` (1720) — lock/unlock/joinLock/checkPassword | no | loses room locks and the lobby |
| `message` (1843) — chat | no | loses text chat |
| `cmd` (1869) | no | loses generic command relay |
| `peerAction` (1973) — mute/hide/eject/stop-screen/rec | no | loses remote moderation |
| `caption` (2031) | no | loses live captions |
| `getWhisperTranscription` (2060) | no | loses server-side transcription |
| `kickOut` (2145) | no | loses eject |
| `fileInfo` / `fileAbort` / `fileReceiveAbort` (2172/2219/2237) | no | loses P2P file transfer signalling |
| `videoPlayer` (2257) | no | loses shared video playback |
| `wbCanvasToJson` (2300) / `whiteboardAction` (2350) / `videoDrawing` (2401) | no | loses whiteboard and screen annotation |
| `data` (1328) — ack API | no | loses duplicate-name check and the ChatGPT proxy |

**Five of eighteen handlers carry a call. Thirteen are product surface.**

---

## 3. Hidden dependencies — the part that matters

These are the cases where the user-facing feature is unnecessary but something
else depends on it.

### 3.1 The Family Call PWA's media engine *is* MiroTalk's browser client

`family-call/public/app.js:279` does:

```js
el('call-frame').src = joinUrl;      // joinUrl = https://<mirotalk-host>/join?room=<uuid>&…
```

and detects that the user hung up by observing that iframe navigate to
`/newcall` (`public/app.js:311-318`). The PWA therefore cannot be pointed at a
signalling-only server: **its media engine is the MiroTalk web client**, served by
the very Express/static/`htmlInjector` layer that the call path does not need.

Consequences for any plan to remove MiroTalk:

- Keeping the PWA working during development **requires MiroTalk to stay running**
  exactly as it is.
- Retiring MiroTalk later requires either a web call engine for the PWA (i.e.
  reusing MiroTalk's browser core under AGPL, or writing one) or retiring the PWA
  in favour of the native client.
- The **iframe origin allow-list** (`ALLOWED_EMBED_ORIGINS`, empty today) is
  exactly the control that would normally be tightened here; it is unset, so any
  origin may iframe a MiroTalk room.

### 3.2 `validate.js` and `xss.js` are not "features"

They look like plumbing; they are the only payload validation in the system.
Deleting them is not simplification — it is removing input validation. What must
be **replaced** rather than dropped is listed in §4.

### 3.3 `peerStatus` is product-looking but load-bearing for interop

The native client's tiles would draw a frozen last frame forever without it. It is
the only way a peer signals "my camera is off" versus "my call is broken" — the
project has already shipped a bug of exactly that shape.

### 3.4 `api.js` + `POST /api/v1/join` keep the secret off clients

Family Call mints rooms by calling MiroTalk's loopback API with
`authorization: <API_KEY_SECRET>`, then rewrites only the origin to the embed
origin and validates `pathname === '/join'` and `room === roomId`
(`family-call/src/mirotalk.js:12-44`). A replacement must provide an equivalent
server-to-server room-minting step, or the API secret moves onto clients — which
the project's rules forbid.

### 3.5 `peer_video_status` / `peer_screen_status` inside `addPeer.peers`

Not a feature: the **browser client reads them from the `addPeer` roster** to
decide whether to schedule a renegotiating offer (`public/js/client.js:2882-2884`).
Dropping the `peers` map breaks *negotiation* against MiroTalk's own client, not
just its UI.

### 3.6 `htmlInjector.js`'s chokidar watcher

A file watcher in a production service with no relation to signalling; its only
effect is cache invalidation for 7 HTML templates. It is also the only thing
`SIGINT`/`SIGTERM` cleanup does (S:2857-2870) — there is no `io.close()` and no
room teardown on shutdown.

---

## 4. What must be replaced rather than deleted

| Current mechanism | Why it cannot simply go |
| --- | --- |
| `checkXSS` on `join` and `peerStatus` | it is the only sanitisation of client-supplied strings that other participants render |
| `Validate.isValidRoomName` / `isValidData` | the only shape checks; a replacement should be **stricter** (see the security model) |
| `isPeerInRoom` guard on `peerStatus` | the only membership check on the call path |
| `sendToPeer` via the global `sockets` map | needed for routing — but it must gain a **participant-scoped** authorization check that MiroTalk lacks |
| presenter/`peer_uuid` model | not needed by Crossbar, but it is MiroTalk's only unspoofable identity binding; a replacement needs its own equivalent for participant identity across reconnects |
| `ROOM_MAX_PARTICIPANTS` | currently a client-side-only limit that the server never enforces; a replacement should enforce it server-side |
| startup config logging | production currently prints its API key and JWT key at `info` level on every start; a replacement must not |

---

## 5. Removal budget, honestly stated

A Crossbar-only signalling server needs, from the list above:

**Kept conceptually:** Socket.IO/Engine.IO admission, `join`, pairwise `addPeer`
fan-out, SDP/ICE relays, disconnect/`removePeer` cleanup, ICE configuration
delivery, `peerStatus{video}`, and the validation/sanitisation *behaviour* (written
fresh, stricter).

**Dropped entirely:** all Express HTML pages and static assets for MiroTalk's own
client, Swagger, OIDC, Mattermost, `tokenManager`, Slack, ngrok, Sentry, email,
survey/redirect, stats, Whisper, ChatGPT, whiteboard, chat, file transfer, shared
video, drawing, captions, hand-raise, privacy blur, kick/eject, room locks/lobby,
the presenter model, the `data` ack API, and `htmlInjector`'s watcher.

**Not a server concern at all:** the AGPLv3 browser client's UI, which is where the
overwhelming majority of MiroTalk's ~18k-line `public/js/client.js` lives.

**Licensing note:** MiroTalk P2P is AGPLv3, and the Crossbar repository currently
contains **no MiroTalk-derived code** — the native client was written against the
audit, not copied from upstream. Any decision to reuse MiroTalk source (including
its browser core for the PWA) is a distribution/licensing decision that precedes
the code, and must preserve upstream URL, exact commit, original
paths/functions, notices, and corresponding-source obligations.
