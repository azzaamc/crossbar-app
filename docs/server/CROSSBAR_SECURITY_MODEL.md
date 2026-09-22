# Crossbar security model

Security as a first-class component of the server. First written before the
implementation; **updated 2026-09-21** for the two deployment modes and for Crossbar's
own device identity, both of which are implemented and tested (`test/auth.test.js`).

It is written as an explicit answer to each gap measured in
[`MIROTALK_SECURITY_MODEL.md`](MIROTALK_SECURITY_MODEL.md), and it must be **at
least as resistant** as the current private system — not simpler at the cost of
protection.

---

## 1. Trust boundary

```
   family device (iOS app)                family device (browser, PWA)
            |                                       |
            |  tailnet membership + ACLs            |
            v                                       v
   ┌─────────────────────── tailscaled (root) ───────────────────────┐
   │  TLS termination · tailnet-only listeners · injects and sanitises │
   │  Tailscale-User-Login / -Name / -Profile-Pic                      │
   └───────────────────────────────┬──────────────────────────────────┘
                                   |  plaintext HTTP to loopback
                                   v
                       127.0.0.1:<port>  Crossbar server
                       - refuses to bind anywhere else
                       - accepts identity headers only from loopback
                       - authorizes every call/room/signalling action itself
```

| Boundary | Who can cross it | What is enforced |
| --- | --- | --- |
| Internet → host | nobody | no public listener; no Funnel; nothing on the LAN NIC |
| Tailnet → service | tailnet members, per ACL | Serve proxies 443/8443 only |
| Host → service | anything local | **application authorization** — this is the boundary MiroTalk does not have |
| Service → data | the server process only | SQLite file `0600` in a hardened unit |

**Network position is treated as an enrollment signal, not as authorization.**
Explicit statement of the property that must hold: *a process running on the
server host, with no tailnet identity, must not be able to act as a family member
or join a call.* Today that is false for MiroTalk (it reads no identity header at
all) and true for the control plane.

**Reachability and identity are separate questions (added 2026-09-21).** The model
above treats the tailnet as the perimeter, which holds only while the tailnet is the
only way in. Crossbar now runs in two modes — `CROSSBAR_NETWORK_MODE=private` (the
tailnet, as drawn above) and `CROSSBAR_NETWORK_MODE=public` (a hostname on the open
internet, terminated by a reverse proxy on the same host) — and in **both** of them the
canonical application identity is a key held by the device, not the network it arrived
over:

```
NETWORK REACHABILITY  →  APPLICATION AUTHENTICATION  →  SIGNALLING AUTHORIZATION  →  WEBRTC
tailnet, or internet     Crossbar device key            call participation           direct, or TURN
```

The tailnet keeps its value as an *additional* signal about a device — recorded in the
`authenticators` table beside the key — and as the transport for a private deployment.
It stops being the thing that decides who somebody is. In public mode the transport
says nothing at all: a header a local proxy injects cannot be told apart from one the
caller typed, so `trustTailscaleHeaders` defaults to false there and the process
**refuses to start** if it is asked for. The same reasoning makes
`ALLOW_DEV_IDENTITY` a startup error in public mode.

---

## 2. Authentication

| Subject | Mechanism | Notes |
| --- | --- | --- |
| **Person, canonical** | **Crossbar device key** — a P-256 ECDSA key generated on the device, enrolled once, proved by signing a challenge | `src/auth.js`. The private half never leaves the device; the server keeps the public half as SPKI DER and nothing else. Required in public mode, available in private mode |
| Device enrolment | a single-use, high-entropy, expiring invitation token, stored server-side **only as a SHA-256 hash**, and always naming the person it is for | `POST /api/auth/enroll`. The plaintext token is shown to the operator exactly once and never logged |
| Session | an HMAC-SHA256 token binding device id, person id and expiry, verified against the **live** device row | stateless, so there is no session table to grow or to leak; revocation works because the row is read on every use |
| Device (legacy, private mode) | a `?device=` id on the socket, bound to the authenticated person and stored in `devices` | optional; closes the "Xcode preview joined a live call" defect and makes re-attach clean |
| Person (legacy, private mode) | Tailscale Serve identity headers, accepted **only** when `remoteAddress` is loopback | retained so devices with no key keep working; no longer sufficient where device authentication is required |
| Additional authenticator | the tailnet login a device arrived with, recorded per device in `authenticators` | evidence about a device, withdrawable on its own, never the identity itself |
| Call participation | the person must be a participant of the call whose room they name | replaces "the room name is the password" |
| Signalling connection | the same session, presented as a header or as `?token=` on the upgrade | an upgrade is an HTTP request, so it obeys the same rule as the API — and where a key is required, the socket refuses a transport identity too |
| Push delivery | provider credentials held server-side only; never sent to clients | unchanged |

There is **no password, no shared secret in a client, and no API key on a device.**
A client holds a private key and, briefly, a session token.

**What a device proves, and how.** `POST /api/auth/challenge` issues 32 random bytes
with an expiry. The device signs the exact bytes
`crossbar-device-auth-v1\n<deviceId>\n<challengeId>\n<nonce>` with ECDSA over SHA-256
and posts the signature to `/api/auth/session`. The challenge is spent **before** the
signature is examined, so a wrong signature costs the attempt rather than leaving the
challenge standing for the next guess, and expiry is decided before the verdict. A
challenge belongs to the device it was issued to: presenting it with another device id
fails. Each of those properties is asserted in `test/auth.test.js`.

**Who becomes a member.** In private mode the household file pins id/name/avatar
before first sign-in, and `AUTO_ENROL_IDENTITIES` (default on) additionally enrols a
tailnet login on first sight — the behaviour of the service this replaces, and how its
members actually joined. In public mode there is no tailnet to enrol from: a person
exists once a device of theirs has been enrolled from an invitation, and an
administrator (a person marked `admin` in the household file) creates the invitation.

**Development identity — stated plainly.** For running the server on a laptop, where
no Tailscale proxy exists, an identity may instead be named by an `x-dev-identity`
header or a `crossbar.dev.identity` cookie. It is refused unless the listener is
loopback *and* `ALLOW_DEV_IDENTITY` is set, the server refuses to start if that flag is
combined with a non-loopback listener or with public mode, and the name must appear in
`DEV_IDENTITIES` (or resolve to a configured family member). A production deployment
sets none of it.

---

## 3. Authorization

| Action | Who may do it | Enforced by |
| --- | --- | --- |
| Read bootstrap/contacts | any enrolled person | identity + enrollment |
| Create a call | any enrolled person, for configured contacts only | contact allow-list |
| Ring an invitee | any participant of that call | participant check |
| Respond to an invitation | only the invited participant, once | participant status |
| Join a call's signalling room | only a participant of that call, on a connection whose identity is trusted | admission checks identity, enrollment, participation and call state |
| Address a peer with SDP/ICE | only an admitted participant **of the same call**, to another admitted participant of that call | participant-scoped relay |
| Add a participant | only an accepted participant of an active call | participant + contact checks |
| Leave | any participant (call-wide end remains available) | participant check |
| Read another person's call | nobody | participant check on every call route |
| End a call | any participant | participant check |

Deliberately **absent**: a presenter role, a host/listener role, an admin role, and
any capability granted by being first to name a room.

---

## 4. Replay and freshness

| Vector | Control |
| --- | --- |
| Joining a call one is not part of | admission requires an authenticated participant of that call |
| Joining a call that is over | the call's state is re-checked on every join; `ended`, `cancelled`, `declined` and `missed` admit nobody |
| Sharing a room id | useless on its own — the room id is not a credential |
| Replaying an invitation answer | participant status transitions are single-shot; one answer each |
| Replaying SDP/ICE after leaving | relay requires a live admitted socket; a closed socket authorizes nothing |
| Ringing an old invitation | terminal states are absolute and expiry runs on the server |
| Duplicate call creation | the existing 6/min limit plus idempotency consideration on retryable mutations |
| Spoofing another peer's status | `peerStatus` is only accepted when its `peer_id`/`peer_name` match the server's record of the sender |

---

## 5. Input validation

Every message is validated **before** it can touch state, against a closed schema:
unknown keys are ignored, absent required keys reject the message, and every string
has a bounded length. This is the opposite of MiroTalk's `isValidData` (= "is a
non-empty object") applied to the two relays that carry the most attacker-controlled
data.

| Field class | Rule |
| --- | --- |
| ids (`peer_id`, `room`, `callId`) | opaque token, ≤64 chars, matched against server state — never used as an object key without a `Map`/`hasOwn` check |
| display strings (`peer_name`, `avatar`) | type + length caps; stored and echoed, never parsed, never used for authorization |
| SDP | ≤64 KiB; must begin `v=`; relayed verbatim, never parsed |
| ICE candidates | ≤4 KiB; must begin `candidate:`; `sdpMLineIndex` bounded |
| booleans/numbers | type-checked; no truthiness coercion |
| whole messages | ≤128 KiB, rejected before parse |

Two failure behaviours MiroTalk exhibits that must not be reproduced: a payload
that throws inside an async handler (it can kill the process), and a
fail-open sanitiser (an exception returns the original data).

**No HTML sanitiser is needed at all.** Crossbar's clients render strings as text
in native views; the vocabulary is kept for the native client, not for HTML
injection surface. If a browser client is ever pointed at this endpoint, escaping
belongs at that client's render layer, not in the signalling server.

---

## 6. Abuse resistance

| Control | Value | Gap it closes |
| --- | --- | --- |
| Per-socket message rate | 60/s relay, 10/s status | MiroTalk has no message-rate limit of any kind |
| Malformed-message budget | 10, then close | MiroTalk can be crashed to a restart loop |
| Participants per call | 4, enforced server-side | `ROOM_MAX_PARTICIPANTS` is only advertised today |
| Sockets per device | the newest wins, the previous one is evicted | MiroTalk leaves a ghost in the room after a reconnect |
| Calls, invitations, responses per person | 6/min, 12/min, 20/min | unchanged from the control plane |
| Message ceiling | 128 KiB total, 64 KiB SDP, 4 KiB candidates | 10 MB in MiroTalk, which is what made unbounded queue growth cheap |
| Connection ceiling | every connection is heartbeated and reaped, admitted or not | MiroTalk never reaps a socket that never joined |
| Processor safety | every handler wrapped; no unhandled rejection can end the process | MiroTalk has no `unhandledRejection` handler, and `Restart=on-failure` turns one bad message into an outage |
| No oracles | no room-existence oracle, no name oracle, no password oracle | MiroTalk has `checkPassword` and `checkPeerName` |

---

## 7. Transport and headers

| Layer | Decision |
| --- | --- |
| TLS | terminated by `tailscaled`; the Crossbar server ships **no** certificate |
| Bind | loopback only, refused at startup otherwise (as the control plane already does) |
| HTTP security headers | the existing control-plane set is retained for any HTML it serves — CSP, `X-Frame-Options: DENY`, `referrer-policy: no-referrer`, `x-content-type-options: nosniff`, `permissions-policy` |
| CORS | retained for the browser-facing API as a *browser read policy*. Explicitly **not** treated as admission control: a native WebSocket client sends no `Origin`, and the server must not rely on the header |
| Origin checking | kept on state-changing HTTP routes (present-and-mismatched is rejected) |
| `X-Forwarded-For` | **used for rate-limit keys, and only its last hop.** Behind the reverse proxy every connection arrives from loopback, so some client address is needed to distinguish callers at all; the last entry is the one our own proxy appended, and a client-supplied header lands at the front, where it is not believed. Never used for authorization |
| Compression | unnecessary; if enabled, the SSE stream must keep `no-transform` |

---

## 8. Secrets

| Secret | Handling |
| --- | --- |
| `TAILSCALE` state/keys | never read by the application; owned by `tailscaled` |
| MiroTalk API secret (PWA era only) | server-side, never sent to a client, never logged |
| VAPID key pair | server-side; only the public key is ever returned (as today) |
| Root signing material | none — the server holds no signing key of its own |
| `CROSSBAR_SESSION_SECRET` | signs session tokens; server-side only and never sent to a client. Rotating it invalidates every live session, which is the intended way to do that |
| `CROSSBAR_TURN_SHARED_SECRET` | shared with coturn alone, for temporary relay credentials. A client receives an HMAC derived from it and never the secret, and what it receives expires |
| Device public keys | not secret, but the only material that names a device. The private halves exist on devices and are never transmitted |
| Invitation tokens | never stored — only their SHA-256 hashes — and never logged. The plaintext is shown once, to whoever created the invitation |
| Environment file | `0600`, `EnvironmentFile=` in the unit, not world-readable |
| Startup logging | **redacted configuration only** — the current production MiroTalk prints its API key and JWT key on every start; that must never be reproduced |
| Failure logging | reasons and ids, never payload bodies, never headers, never SDP or ICE |

---

## 9. Logging policy

Logged: lifecycle events with internal ids (`call_created`, `call_accepted`,
`call_left`, `call_ended`, `call_missed`, `signal_admitted`, `signal_rejected`,
`relay_denied`, `peer_left`, `push_dispatched`, `request_error`).

Never logged: identity headers and logins beyond an internal user id, API
secrets, VAPID private keys, SDP bodies, ICE candidates, push endpoints, request
bodies, or full header dumps. MiroTalk's debug-level auth-failure log includes the
entire `req.headers`, i.e. the API secret; the equivalent line must not exist.

Operational consequence to fix while migrating: the Pi's journald is **volatile**,
so today a post-reboot diagnosis of a failed call is impossible. Either enable
persistent storage or write a bounded rotating file.

---

## 10. What is preserved from the current system, and why

| Preserved | Reason |
| --- | --- |
| Loopback bind + tailnet-only ingress | it is the reachability model, and it is what lets identity be trustworthy at all |
| Tailscale Serve TLS | no bespoke certificate handling, no exposed port |
| Tailscale identity as enrollment | proven on device with zero client credentials; replacing it would invent a new credential for no gain |
| Room-scoped membership checks | MiroTalk's one good boundary; extended here to the relays, which it excluded |
| An unguessable, opaque room/participant id | keeps ids non-enumerable even though authorization no longer depends on secrecy |
| The existing CSP/header set on HTML routes | already correct on the control plane |
| The existing rate-limit shape | adequate for a household, already proven |

## 11. What is deliberately *not* inherited

| Not inherited | Because |
| --- | --- |
| Room name as credential | the source of every authorization gap |
| Blind global relay | replaced by participant-scoped relay |
| Room passwords, locks, lobby, presenter, kick | product surface with no Crossbar function, and two of them are oracles |
| The `peers` roster broadcast with room metadata | leaks a plaintext password in MiroTalk; here the roster is native-optional and metadata-free |
| `in`-based socket lookup | prototype-chain keys make it a crash primitive |
| JWT/AES token subsystem, OIDC, Mattermost, Slack, ChatGPT, Whisper, ngrok, Sentry, email, webhooks, stats | all disabled or unused; each is attack surface with no function |
| The 10 MB message ceiling | 128 KiB with per-event caps |
| `checkXSS`/DOMPurify/jsdom and its fail-open path | no HTML render context on the native path |
| CORS-as-security assumptions | CORS constrains browsers, not clients |
| `LOGS_DEBUG`-gated silence | positive-path telemetry is required to debug a call |

---

## 12. Residual risk, stated plainly

1. **Anyone with a shell on the host can impersonate a family member through the
   loopback listener — where device authentication is off.** The identity header is
   trusted because it arrives from loopback, so root or the `admin` account can forge
   it; that is inherent to "the tailnet is the enrolment mechanism". Set
   `CROSSBAR_REQUIRE_DEVICE_AUTH=true` and it stops being sufficient: the forged
   request reaches the authentication step and no further, because a device key is
   required and the host has none. Public mode has no such path at all, because the
   header is not believed there. For a private deployment the mitigation is still host
   hygiene (no shared accounts, no untrusted local processes), not server code.
2. **Media is P2P and unobservable by the server.** A peer learns the other's
   candidate addresses as WebRTC requires. Without TURN, a failing pair fails
   silently at the media layer.
3. **A compromised client is a compromised participant.** It can relay SDP/ICE to
   its own peers — which is exactly what a participant may do.
4. **No forward secrecy beyond TLS** for anything in the database; call history
   and contacts are readable by whoever holds the SQLite file, as today.
5. **Denial of service from an authenticated family member** remains possible in
   kind (they can ring, then hang up), bounded by rate limits rather than
   prevented.
6. **A stolen device key is a stolen device.** The key lives in the Keychain — Secure
   Enclave where the device has one, which is what makes it hard to copy — and a
   revoked device is refused at authentication, at session creation, at the socket and
   at the ICE endpoint. What is *not* mitigated: a device unlocked and handed to
   somebody is a device they can use, as with any app on it.
7. **A misconfigured relay is an open relay.** coturn must run with
   `use-auth-secret` and the shared secret, never anonymously. The server refuses to
   start with a TURN host and no shared secret, and clients receive only credentials
   that expire. Whether the relay itself is configured correctly is the operator's
   check: `admin.js doctor` reports reachability, not a successful allocation, and says
   so rather than implying more.
8. **Public mode exposes the API to the internet, which is the point of it.** Every
   unauthenticated request costs a lookup and a comparison: three auth routes (limited
   per address and per device), one health line, and static files. Everything else needs
   a device key. An attacker can still spend the host's bandwidth and CPU — the reverse
   proxy's own limits are the outer boundary — but no unauthenticated endpoint writes
   anything except a challenge.
9. **Sessions are stateless, so individual sign-out is by expiry or by revocation.** A
   device cannot be logged out without either revoking it or rotating
   `CROSSBAR_SESSION_SECRET` (which ends every session). Acceptable at this scale, and
   named here so the limitation is a decision rather than a surprise.
