# Crossbar server implementation

What was built, where it lives, how it is run, and what has actually been
verified. Written after the fact, so every claim here corresponds to something
that exists or something that was run.

Companions: [`CROSSBAR_SERVER_ARCHITECTURE.md`](CROSSBAR_SERVER_ARCHITECTURE.md)
(the design), [`CROSSBAR_SIGNALING_PROTOCOL.md`](CROSSBAR_SIGNALING_PROTOCOL.md)
(the wire contract), [`CROSSBAR_SECURITY_MODEL.md`](CROSSBAR_SECURITY_MODEL.md)
(what it defends), [`MIGRATION_PLAN.md`](MIGRATION_PLAN.md) (what happens next).

---

## 1. Where it is

```text
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/server
├── src/
│   ├── server.js      composition root: one process, one listener, one store
│   ├── config.js      every process.env read; refuses a non-loopback bind
│   ├── log.js         structured lines; redaction by construction
│   ├── identity.js    who is asking — proxy header, loopback only, dev stand-in
│   ├── db.js          SQLite: people, contacts, devices, calls, participants
│   ├── calls.js       the call state machine, as pure functions
│   ├── lifecycle.js   the rules — create, respond, join, invite, leave, end
│   ├── events.js      the SSE stream and presence
│   ├── signal.js      Engine.IO v4 / Socket.IO v5 subset, rooms, relay, limits
│   ├── validate.js    per-event schemas
│   ├── api.js         HTTP routes, SSE, static, security headers
│   └── push.js        Web Push for browser clients
├── public/
│   ├── call/          the browser call client (index.html, call.js, call.css)
│   └── newcall.html   where the client lands after a call, which is how the PWA
│                      knows the user hung up
├── test/              38 tests over the state machine, HTTP, and the protocol
├── data/              family.example.json (the shape), family.json (yours, untracked),
│                      crossbar.sqlite (created on run)
└── .env               local development only
```

Two runtime dependencies: `ws` (WebSocket) and `web-push` (notifications). No
framework, no ORM, no build step. Node ≥ 22.5 for `node:sqlite`.

**Under version control** since 2026-09-20: its own Git repository on `main`,
initialised on explicit instruction, with `node_modules/`, `data/*.sqlite` and
`.env` ignored and a committed `.env.example` in their place.

---

## 2. How it is run

```bash
cd /Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/server
node src/server.js          # or: npm start
npm test                    # node --test
```

Listens on `127.0.0.1:3010` with `.env` as shipped. It refuses to start if `HOST`
is not loopback, and refuses to start with development identity enabled on a
non-loopback listener.

On a laptop, with no Tailscale proxy present, an identity has to come from
somewhere, so:

```bash
open "http://127.0.0.1:3010/dev/identity?login=dad@dev"   # sets the dev cookie
```

That route exists **only** when `ALLOW_DEV_IDENTITY` is set, only on a loopback
listener, and only for a login that is already allowed. Production sets none of
it; identity then comes from the proxy's injected headers, as it does today.

---

## 3. What is different from what it replaces

| | MiroTalk + Family Call | This server |
| --- | --- | --- |
| Processes | two | one |
| Files that matter | 2,870-line `server.js` plus a 6-module control plane | 12 small modules |
| Room/peer state | in memory, lost on restart, no call concept | in memory for presence, in SQLite for calls |
| Joining a room | the room name is the credential | identity + participation in the call |
| Relay | blind: any socket to any socket id, unsanitised, uncapped | participant-scoped, schema-validated, size-capped |
| Leaving | ends the call for everyone | one participant leaves; the call ends when nobody is left |
| A device | not modelled; a second instance could enter a live call | `call_devices`; a reconnect replaces its own connection |
| A bad message | can crash the process into a restart loop | rejected, counted, connection closed at ten |
| Logging | no positive-path telemetry; the startup line prints secrets | redacted startup, per-call lifecycle events, no secrets |
| Browser client | MiroTalk's AGPL web app, embedded by the PWA | an original client in this project, ~500 lines |

---

## 4. Verified

### Automated — 39 tests, all passing

```text
node --test --test-timeout=15000
# tests 39   pass 39   fail 0
```

Covering, with the ones that found real bugs called out:

- **state machine** — accept, decline, cancel, expire, and the rule that one
  person leaving does not end a call others are in;
- **HTTP** — identity required, enrolment both ways (a pinned member keeps their
  id; an unknown login joins under a derived one, or is refused when
  auto-enrolment is off), directory and groups,
  ringing over SSE, answering, double-answer refused, decline, **per-participant
  leave**, inviting into a live call, **device-scoped ongoing calls**, origin
  rejection, ring expiry, static serving and path-traversal refusal, and
  **self-calls refused by default and working when enabled**;
- **protocol** — no-identity refusal, non-participant refusal, unknown room,
  offerer selection and the ICE configuration, an offer and its answer relayed
  with the server's name attached, **a relay to another call refused**, **a peer
  that cannot announce itself as another peer**, **a malformed relay cannot take
  the server down** (`peer_id: "constructor"`, the exact message that crashed the
  old server), heartbeat pings, the participant ceiling, **a reconnecting device
  replacing its own connection**, and departure announced to those left behind.

### End-to-end — the first real call, phone to browser (2026-09-20)

A native app and a browser in one room, on the deployed development server, with
the owner seeing and hearing both ends. The server's own log of it, in order:

```text
call_created    callId 37d15042…  callerId abdullah  inviteeIds ["dad"]
signal_admitted peerId NG8KnWqN…  userId abdullah  deviceId null              peers 1
call_joined     userId abdullah   deviceId null
call_joined     userId abdullah   deviceId web-d5f6f358-…
signal_admitted peerId xkqD2f6cW… userId abdullah  deviceId web-d5f6f358-…    peers 2
call_ended      status ended
peer_left / call_left   ×2, reason socket_closed
```

The `deviceId` column is what makes this worth reading: `null` is the native
client, which does not send one yet, and `web-…` is the browser. One room, two
peers, one identified device, and a clean teardown where each departure was logged
with its reason.

This is the last piece of the native path to be proven end to end: identity through
Serve, bootstrap and the directory, call creation, `joinUrl` parsing, the socket
upgrade and admission, offer/answer, ICE, and media in both directions.

The same log also carried the one malformed message the server has ever seen, which
was a bug worth having: see 10 below.

### End-to-end — a real call between two browsers

Two Chrome instances, synthetic camera and microphone, both admitted to one call
through the real server:

| Measurement | Abdullah | Dad |
| --- | --- | --- |
| Connection state | `connected` / ICE `connected` | `connected` / ICE `connected` |
| Audio | 22,005 in / 26,444 out | 26,444 in / 22,005 out |
| Video | 538,820 in / 199,657 out | 199,657 in / 538,820 out |
| Remote video decoded | 640×360 | 320×180 |

Then, in the same call:

- **camera off on one peer** → the other peer's tile marked that peer's video off
  over `peerStatus`, with no renegotiation;
- **one peer hung up** → it landed on `/newcall` (the PWA's leave contract), the
  other peer's peer list went to zero, and the call **stayed active** with
  `abdullah:accepted, dad:left`.

### Not yet verified

- **A call between two native devices**, and three- or four-way calls. The mesh is
  proven between native peers in the earlier Architecture B spike and between
  native and browser here, but not with two phones.
- **Backgrounding and locking the phone mid-call**, and what the far end sees.
- **Reconnection**, including a network change: nothing in this system restarts ICE,
  and that is a media-plane gap rather than a server one.
- **Web Push delivery.** The code path exists and reports itself disabled without
  VAPID keys; no notification has been delivered.
- **APNs**, which the developer programme unlocks and which is what makes a locked
  phone ring at all.

---

## 5. Bugs found by building it

Recorded because each one is a thing the design had wrong:

1. **`serverInfo` was framed as `4["serverInfo",…]`.** Socket.IO events are `42`.
   The tests caught it immediately; it would have been a silent "the client never
   hears anything" mystery.
2. **`callById` selected an ambiguous `id`** across a join, so every call creation
   returned 500. Found by running the server, not by reading it.
3. **The heartbeat only covered admitted sockets**, so a connection that never
   joined was never pinged and never reaped — exactly the "unlimited idle
   sockets" gap the design set out to close.
4. **SSE heartbeat timers outlived the store**, producing "database is not open"
   errors after every test run.
5. **Shutdown hung** on upgraded sockets: `http.Server.close()` waits for them, and
   a polite `ws.close()` waits for a peer that may never answer. Now every socket
   is tracked and terminated, and live devices are marked left before the store
   closes.
6. **A participant who left could never rejoin an active call** — the admission
   rule required `accepted`, and leaving sets `left`. This broke the ordinary
   "backgrounded the app and came back" path.
7. **Declining could leave a 1:1 call ringing forever**, because the caller's own
   acceptance counted as somebody being in the call.

8. **The PWA could not frame the call client.** The call page was served with
   `frame-ancestors 'none'` and `X-Frame-Options: DENY` — headers inherited from
   the standalone PWA, where they are right, and exactly wrong for a page whose
   entire purpose is to be that PWA's call frame. Firefox refused with an explicit
   message; Safari rendered a blank frame and explained nothing, which is the worse
   failure of the two. Both now say `'self'` / `SAMEORIGIN`, verified by running a
   call through the frame with media crossing both ways.
9. **Two deployment-hygiene faults**, found by deploying rather than by testing:
   the committed lockfile named the package by its pre-rename name, so every
   `npm install` on the Pi rewrote it; and the household file was tracked, so the
   deployment's real copy — the one naming actual people — showed up as a
   modification. The lock is regenerated, `npm ci` is used, and the household file
   is now untracked with a committed example beside it.

10. **Safari's end-of-candidates looked malformed.** WebKit marks the end of its ICE
    candidates with an `RTCIceCandidate` whose `candidate` string is empty, where
    Chrome sends a null candidate. The relay rejected it as a malformed message and
    counted it — and ten malformed messages close the connection. So a working
    Safari call could have been dropped by a message that means nothing, and the
    web client had the same blind spot when sending. Found by reading the first
    real call's log, which is what the positive-path telemetry exists for.

Of these, 6 and 7 were product bugs rather than code bugs: they were decided in
the state machine and would have shipped as behaviour. 8, 9 and 10 were found by
running the deployment rather than the tests — a frame bug only appears when one
served page embeds another, hygiene faults only when a real host installs the
thing, and this one only when a browser other than the one used for development
joins a call.

---

## 6. What is deliberately not built

No TURN (a symmetric-NAT pair will fail, and says so), no ICE restart, no APNs
delivery (the `devices` table holds the token and environment; the Apple
membership does not exist), no media path of any kind, no cache, no queue, no
second datastore, and none of MiroTalk's product surface — no chat, whiteboard,
file transfer, recording, transcription, polls, lobby, room passwords, presenter
role, or room listing.

Audio-only calls have a `kind` column and no way to ask for it.

---

## 7. The browser client

`public/call/` is an original ~500-line WebRTC client: one capture, one
`RTCPeerConnection` per peer, tracks appended before offering, explicit
offer/answer rather than `negotiationneeded`, ICE queued until a remote
description exists, and `window.crossbarStatus()` for inspecting a live call from
a console.

It is both the interop peer — which is how this server can be tested without a
second phone — and the PWA's media engine, loaded into the PWA's existing call
frame. On hang-up it navigates to `/newcall`, which is the signal the PWA already
watched for when MiroTalk's client was in that frame.

That the PWA needed **no source change** is worth stating plainly, because it was
not the plan: the plan was to keep MiroTalk for the PWA. What made it unnecessary
is that the PWA's contract was always "a page URL goes in the frame, a navigation
to `/newcall` comes out" — and this server can satisfy that with its own client on
its own origin.

---

## 8. Device identity, network modes and relay (added 2026-09-21)

### 8.1 The two flows, as implemented

Private mode — today's deployment, with a device key added as clients acquire one:

```
client → tailnet → Tailscale Serve → 127.0.0.1:3003 → Crossbar
       → challenge-response (device key) → session
       → signalling admission (participant of that call) → WebRTC (host candidates on the tailnet)
```

Public mode:

```
client → Internet → TCP 443 → Caddy (TLS, WSS, header hygiene) → 127.0.0.1:3003 → Crossbar
       → challenge-response (device key) → session
       → signalling admission → WebRTC: direct, or TURN on the same host when ICE cannot pair
```

### 8.2 What an operator does

```bash
node src/admin.js status                     # mode, origin, counts
node src/admin.js users                      # people, and who administers
node src/admin.js enroll --user mum          # one-time invitation: JSON payload and token
node src/admin.js enrollments                # every invitation and its state
node src/admin.js devices                    # every device, with state and last seen
node src/admin.js revoke-device dev_xxx      # that device stops working; the person does not
node src/admin.js doctor                     # DNS, TLS, HTTPS, WSS, STUN, TURN
```

The same operations exist over HTTP under `/api/admin/*` for an administrator — which
is what the authorization tests exercise — and there is deliberately no admin web UI.

### 8.3 Configuration reference

New settings. Existing ones (`HOST`, `PORT`, `PUBLIC_ORIGIN`, `ICE_STUN_URL`,
`DATA_DIR`, `FAMILY_CONFIG_PATH`, `WEB_ROOT`, `MAX_PARTICIPANTS`, `CALL_RING_SECONDS`,
`ALLOW_SELF_CALLS`, `ALLOW_DEV_IDENTITY`, `DEV_IDENTITIES`, `AUTO_ENROL_IDENTITIES`)
are unchanged, so an existing `.env` keeps working.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CROSSBAR_NETWORK_MODE` | `private` | `private` or `public`; the trust posture |
| `CROSSBAR_PUBLIC_HOSTNAME` | — | required in public mode; `PUBLIC_ORIGIN` must name it |
| `CROSSBAR_REQUIRE_DEVICE_AUTH` | `true` public, `false` private | whether a device key is required, not merely available |
| `CROSSBAR_SESSION_SECRET` | — | signs session tokens; required whenever device auth is on |
| `CROSSBAR_SESSION_TTL_SECONDS` | `43200` | how long a session lasts |
| `CROSSBAR_CHALLENGE_TTL_SECONDS` | `120` | how long a challenge may be answered |
| `CROSSBAR_ENROLLMENT_TTL_SECONDS` | `900` | how long an invitation lasts |
| `CROSSBAR_TURN_HOST` | — | relay host; empty means STUN only |
| `CROSSBAR_TURN_PORT` | `3478` | relay port for both STUN and TURN |
| `CROSSBAR_TURN_MIN_PORT` / `_MAX_PORT` | `49160` / `49200` | relay range to forward |
| `CROSSBAR_TURN_SHARED_SECRET` | — | coturn's `static-auth-secret`; required with a TURN host |
| `CROSSBAR_TURN_TTL_SECONDS` | `600` | lifetime of a relay credential |

Unsafe combinations are **refused at startup** rather than warned about: public mode
without a hostname or a session secret, `PUBLIC_ORIGIN` that does not name the public
hostname, `TRUST_TAILSCALE_HEADERS` on in public mode, `ALLOW_DEV_IDENTITY` on in
public mode, and a TURN host with no shared secret.

### 8.4 Data model additions

`devices` gains `public_key`, `key_algorithm`, `status` and `revoked_at`; `users`
gains `admin`; three tables are added — `enrollment_tokens` (hashes only),
`authenticators` (one row per additional mechanism per device) and `auth_challenges`
(single-use). Changes land through `MIGRATIONS` in `src/db.js`, keyed on `PRAGMA
user_version`, applied on every start and idempotent, so a database created before
this change picks them up with no rebuild and no manual step.

### 8.5 Verified

- `npm test` — **66 tests, all passing**. `test/auth.test.js` adds 23: enrolment
  (valid, invalid, expired, reused, revoked, wrong curve), challenge-response (valid,
  wrong signature, replay, another device's challenge, expiry), sessions (valid,
  expired, tampered, revoked mid-session), revocation (one device fails, the person's
  other device keeps working), authorization (a non-admin is refused; an administrator
  is not; a member cannot revoke somebody else's device), relay credentials (expiry,
  the HMAC shape coturn expects, refused with no session, refused for a revoked
  device), and health. `test/family.test.js` adds three for the household file being
  able to move a login between people.
- The 40 pre-existing tests are unchanged and still pass — that is the private-mode
  regression, and it is the evidence that nothing about the current deployment moved.
- The operator CLI was run against the development database (`status`, `users`,
  `enroll` with and without a session secret, `enrollments`, `devices`, `revoke-device`,
  `revoke-enrollment`, `doctor`).
- Each unsafe public-mode combination was confirmed to refuse to start.
- **A real iPhone enrolled and called, 2026-09-21.** The app generated a key, spent
  an invitation, and from then on authenticated with it: the server logged
  `device_enrolled deviceId=dev_CpPdyPcugPw3Do8V userId=abdullah platform=ios`, and
  the phone's signalling socket was admitted as that device
  (`signal_admitted … userId=abdullah deviceId=dev_CpPdyPcugPw3Do8V`). That line can
  only come from the session token — the app has never sent a `device=` parameter, and
  every app connection before this logged `deviceId: null`.
- **A two-participant call with media, 2026-09-21**: two peers admitted to one room —
  the phone as an enrolled device, a browser client as the other end — carrying video
  both ways for 34 seconds (590 decoded remote frames at 20 fps, none dropped, camera
  flips included) and ending cleanly.
- The ring window works: an unanswered call went `ringing` → `call_missed` at 93
  seconds, and the app cleared itself without help.
- **A three-way call with media, 2026-09-21**: the phone (an enrolled device), Dad and
  Mum as browser clients, all three in the room at once. The phone reported two separate
  remote tiles with live video and each browser rendered the other two. The call was
  created by a client *other* than the one that answered, so this covers the invitation
  path as well: the phone rang for a call it had not placed.
- **The room limit holds and the mesh scales, 2026-09-21**: four peers in one room — the
  configured maximum — among them the same person on two devices, which the server allows
  because the limit counts sockets rather than people; every peer carried three remote
  streams. A fifth peer was refused with `reason=room_full` and the client said so plainly
  ("Not admitted") rather than failing silently.
- **A native-to-native call with media, 2026-09-21** — the first, and the case all the
  earlier ones missed by pairing a phone with a browser. Both ends iPhones; the callee
  admitted by her own device key (`signal_admitted … userId=mum
  deviceId=dev_hHH6Gxo_QbDHdEaT`) and the caller on the tailnet identity her household
  file names. Video ran both ways at 30 fps for about fifty seconds with no dropped
  frames. Both phones reached the server through the app's own embedded node, on their
  own tailnets — the arrangement the product intends, exercised end to end from a second
  person's device for the first time.
- **A lapsed device session is invisible in private mode, 2026-09-21.** After the rig was
  restarted with a new session secret, the caller's phone went on working, but
  `signal_admitted` logged `deviceId=null` for it while the callee's key was named
  normally. Nothing returned 401 for the app to react to, because the transport identity
  answered every request, so it never re-authenticated and its device key quietly stopped
  being used. Harmless where the tailnet identity is enough — but not where relay
  credentials are wanted, since those require a session.
- **A three-way call with two real phones in the mesh, 2026-09-21.** A browser client
  joined first, then both phones answered into the same room: three peers, every pair
  negotiated, the browser rendering both phones' video and each phone carrying a remote
  stream. One phone was admitted by its device key
  (`signal_admitted … userId=mum deviceId=dev_hHH6Gxo_QbDHdEaT`), the other on the
  tailnet identity its household file names — the two ways in, in one room.

### 8.6 Not verified

- **No public deployment exists.** The deployment files are written and were exercised
  separately — the Caddyfile passes `caddy validate`, and its header stripping was proven
  end to end against a throwaway upstream that received none of the spoofed identity
  headers; HTTPS/2, HSTS, the WSS upgrade and rate limiting through a real Caddy in front
  of the real server were all measured. What has never happened is a deployment at a real
  hostname: no ACME certificate, no coturn process, no public IP, and therefore no call in
  public mode.
- **Allocation through coturn is not exercised.** `doctor` checks that the relay answers,
  not that it will relay for a given device, and says so.
- **The two modes have not been timed against each other** — a call in public mode
  through TURN has never been made.

### 8.7 A browser cannot enrol yet, and that is a protocol detail

Where `CROSSBAR_REQUIRE_DEVICE_AUTH` is on, the only clients that can connect are ones
holding a device key — which today means the iOS app. A browser is not excluded by
policy, but it cannot sign what the server verifies: `crypto.verify('sha256', …)` and
`P256.Signing` both take **DER-encoded** ECDSA signatures, and WebCrypto's
`crypto.subtle.sign` produces IEEE P1363 (`r‖s`) instead. A browser client therefore
needs either a conversion at the client (40 lines, no new cryptography) or a server that
accepts both encodings — a decision for whoever writes the browser enrolment, and
recorded here so it is not discovered twice.

That matters for the shape of a public deployment: until then, enrolling a phone needs
the app, and the browser client is a private-mode participant only.
