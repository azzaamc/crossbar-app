# Crossbar security model (proposed)

Security as a first-class component of the proposed server, defined before
implementation. **Not implemented.**

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

---

## 2. Authentication

| Subject | Mechanism | Notes |
| --- | --- | --- |
| Person | Tailscale Serve identity headers, accepted **only** when `remoteAddress` is loopback | already proven on device; unchanged from the control plane |
| Enrollment | an entry in the household file pins id/name/avatar before first sign-in; `AUTO_ENROL_IDENTITIES` (default on) additionally enrols a login that arrives from the tailnet on first sight | matches the service this replaces, which is how its members actually joined |
| Device | a `?device=` id on the socket, bound to the authenticated person and stored in `devices` | optional; closes the "Xcode preview joined a live call" defect and makes re-attach clean |
| Call participation | the person must be a participant of the call whose room they name | replaces "the room name is the password" |
| Signalling connection | the identity injected on the WebSocket upgrade request | the same mechanism as the API, because an upgrade is an HTTP request |
| Push delivery | provider credentials held server-side only; never sent to clients | unchanged |

There is **no password, no shared secret in a client, and no API key on a
device**.

**Who becomes a member — the perimeter, stated plainly.** With auto-enrolment on
(the default), anyone whose identity the proxy vouches for becomes a member on
first contact, under a derived id. The admission decision is therefore
**Tailscale's**, not this server's: the tailnet is invite-only, and a device that
is not on it cannot reach the listener at all. Set `AUTO_ENROL_IDENTITIES=false`
to make the household file the only way in — at the cost of having to add every
device's login before it can be used. This is the same choice the existing
service makes, and its member list shows it: the production database contains
members enrolled this way.

**Development identity — stated plainly.** For running the server on a laptop,
where no Tailscale proxy exists, an identity may instead be named by an
`x-dev-identity` header or a `crossbar.dev.identity` cookie. It is refused unless
the listener is loopback *and* `ALLOW_DEV_IDENTITY` is set, the server refuses to
start if that flag is combined with a non-loopback listener, and the name must
appear in `DEV_IDENTITIES` (or resolve to a configured family member). A
production deployment sets none of it.

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
| `X-Forwarded-For` | **not trusted**; if a client address is needed for logs, use the socket address, and never use it for authorization or rate-limit keys |
| Compression | unnecessary; if enabled, the SSE stream must keep `no-transform` |

---

## 8. Secrets

| Secret | Handling |
| --- | --- |
| `TAILSCALE` state/keys | never read by the application; owned by `tailscaled` |
| MiroTalk API secret (PWA era only) | server-side, never sent to a client, never logged |
| VAPID key pair | server-side; only the public key is ever returned (as today) |
| Root signing material | none — the server holds no signing key of its own |
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
   loopback listener.** The identity header is trusted because it arrives from
   loopback; root or the `admin` account can forge it. This is unchanged from
   today and is inherent to "the tailnet is the enrollment mechanism". Mitigation
   is host hygiene (no shared accounts, no untrusted local processes), not server
   code.
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
