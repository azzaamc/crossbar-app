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
