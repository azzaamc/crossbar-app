# Migration plan

How to get from today's two production services to a Crossbar-owned server
without a flag day, without breaking the Family Call PWA, and with a rollback at
every step.

**Status.** Stages 0 and 1 are **done**, and so is the native half of Stage 2: the
development server runs on `qatar-vpn` as `crossbar.service` behind its own Serve
port, and on 2026-09-20 the iPhone app and a browser on the Mac carried a real call
through it — audio and video both ways. What remains of Stage 2 and 3 is in the
implementation record's "Not yet verified" list.

Any step that touches `qatar-vpn` requires explicit approval for that exact
operation.

---

## 1. Constraints that shape the sequence

| Constraint | Consequence |
| --- | --- |
| The Family Call PWA must keep working throughout | It does, and it did so without a source change: the Crossbar server serves the PWA and hands it a `joinUrl` for the Crossbar browser client, which loads in its call frame exactly as MiroTalk's page did. MiroTalk therefore no longer sits on the PWA's critical path at all. |
| Production is read-only until explicitly approved | Development and validation happen locally first, then on a **new, separate** service — never by editing the existing ones. |
| The native client already supports a different backend | Migration needs no client release for the first cutover: `AppSettings.serviceAddress` and `AppSettings.signallingOrigin` already exist, plus the `CROSSBAR_BACKEND_URL` environment override. |
| MiroTalk's trees carry untracked rollback artifacts | Never clean, reset, or stage `/home/admin/mirotalk`. Never modify its source. |
| `tailscale serve reset` is forbidden | Routes are added; existing ones are never cleared. |

---

## 2. Stage 0 — off-host development (done)

Built and tested on the Mac, with no production interaction:

- the server lives at `/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/server`
  (see §7);
- it runs on `127.0.0.1:3010` locally, with development identity standing in for
  the tailnet proxy;
- **34 tests pass** — call state machine, HTTP behaviour, protocol framing, and
  authorization;
- **a real two-peer call was placed through it between two browsers**, with
  two-way audio and video measured, camera status relayed, and a departure that
  left the call standing for the person still in it.

**Exit criteria — met.** The end-to-end proof is the browser call; the tests cover
what a browser call cannot conveniently reach (a refused admission, a cross-call
relay, malformed input, a reconnect that must evict its own ghost).

**Rollback:** none needed; nothing shared was touched.

---

## 3. Stage 1 — the development server on the Pi (approval required)

Every command below changes production state. **None of them has been run.** Each
is additive: nothing existing is edited, restarted, or removed.

### Why its own port, and not a path on an existing handler

The obvious money-saving option — mount the service at `:8443/crossbar` and reuse
the existing TLS handler — **does not work**, and the reason is in the client:

```swift
// MiroTalkSignalClient.connect(room:)
components.scheme = origin.scheme == "https" ? "wss" : "ws"
components.path = "/socket.io/"        // the path is written here, not taken from the URL
```

and `origin` comes from `JoinTarget(joinUrl:)`, which keeps only scheme, host and
port. So whatever path a `joinUrl` carries is discarded, and the socket always
goes to `/socket.io/` on the **origin**. On port 8443 that is MiroTalk. The
development server therefore needs its own port, and `PUBLIC_ORIGIN` must be a
bare origin with no path.

### The operations

```bash
# 1. Directories (new; nothing existing is touched)
#    Run as admin on qatar-vpn.
mkdir -p /home/admin/crossbar && cd /home/admin/crossbar
git init -b main

# 2. Deliver the source. The control plane's precedent is a git bundle, since
#    there is no remote. Built on the Mac:
#      cd /Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/server
#      git bundle create /tmp/crossbar-server.bundle --all
#    Copied over, then:
git pull /tmp/crossbar-server.bundle main

# 3. Dependencies (only ws and web-push, plus their transitive tree).
#    `npm ci` rather than `npm install`: it installs exactly what the lockfile
#    says and never rewrites it.
npm ci --omit=dev

# 4. The household file. It is deliberately NOT in the repository — it names real
#    people and differs per deployment; `data/family.example.json` is the shape.
#    Copy the deployed one so identity matches production:
cp /home/admin/family-call/data/family.json /home/admin/crossbar/data/family.json
chmod 600 /home/admin/crossbar/data/family.json
# NOTE: that file still carries placeholder logins for dad and mum. With
# AUTO_ENROL_IDENTITIES=true (the default) they enrol on first contact anyway,
# under a derived id — exactly as they did on the existing service.
#
# What that costs, measured 2026-09-21: the household ends up holding two of each
# of them. The placeholder row keeps the id and the name from the file; the login
# becomes a second, device-less person named from their Tailscale profile. Their
# phone's key belongs to the first row, so a call to the second rings nothing at
# all — a contact that looks like them and reaches nobody. Replace the placeholder
# logins with the real ones before anyone calls anybody.

# 4b. Development data: make the other members callable.
#     The directory only shows people who have signed in at least once, so on a
#     fresh database the app shows no contacts and cannot place any call. This is
#     what their first sign-in would do, applied ahead of time — a development
#     step, never part of a real deployment.
node -e '
const {DatabaseSync}=require("node:sqlite");
const db=new DatabaseSync("/home/admin/crossbar/data/crossbar.sqlite");
const now=new Date().toISOString();
db.prepare("UPDATE users SET first_seen_at=COALESCE(first_seen_at,?) WHERE id IN (?,?)").run(now,"dad","mum");
db.prepare("INSERT OR IGNORE INTO contacts (owner_user_id, contact_user_id, sort_order) SELECT a.id,b.id,0 FROM users a JOIN users b ON a.id<>b.id WHERE a.first_seen_at IS NOT NULL AND b.first_seen_at IS NOT NULL").run();
db.close();'

# 5. Configuration (never committed; 0600)
cp .env.example .env
chmod 600 .env
${EDITOR:-vi} .env     # set PORT=3003, PUBLIC_ORIGIN=https://qatar-vpn.tailea67b0.ts.net:8445,
                       # and ALLOW_SELF_CALLS=true while testing

# 6. Unit (modelled on family-call.service, hardened the same way)
sudo cp deploy/crossbar.service /etc/systemd/system/crossbar.service
sudo systemctl daemon-reload
sudo systemctl enable --now crossbar.service

# 7. Publish it on the tailnet, on its own port
sudo tailscale serve --bg --https=8445 http://127.0.0.1:3003
```

**Do not run `tailscale serve reset`.** The two existing handlers (443 → MiroTalk,
8443 → family-call) are left exactly as they are.

### Exit criteria

```bash
curl -s https://qatar-vpn.tailea67b0.ts.net:8445/api/session   # from a tailnet device
journalctl -u crossbar.service -n 40 --no-pager                # startup line, no secrets
```

The session answer must report `authenticated: true` and `configured: true` with
the enrolled display name — the same evidence the control plane produced when its
identity path was first verified, and the proof that the proxy injects identity on
this route too.

### Rollback

```bash
sudo systemctl disable --now crossbar.service
sudo tailscale serve --bg --https=8445 off
rm /etc/systemd/system/crossbar.service && sudo systemctl daemon-reload
```

Nothing else is affected: the service has its own directory, its own database, its
own port and its own Serve route.

### Pointing the native client at it

In Crossbar's Settings:

| Field | Value |
| --- | --- |
| **Service address** | `https://qatar-vpn.tailea67b0.ts.net:8445` |
| **Signalling override** | **leave empty** |

The override is not needed, and leaving it empty is the correct configuration:
the server returns a `joinUrl` naming its own origin, and the client derives both
the room and the signalling host from it. Setting an override here would be the
one way to send the socket somewhere the API did not intend.

Everything else in the app stays as it is. The control plane's address is
unchanged until this is proven, so both can be tried on one device by switching
one field.

### One identity, several devices — and why `ALLOW_SELF_CALLS` exists

Every device on this tailnet is owned by the same Tailscale account
(`tailscale status` shows one owner for all of them), and the proxy attributes a
request to the account that owns the connecting node. So the phone, the Mac and
any browser present **the same identity**, and therefore the same Crossbar user.

`ALLOW_SELF_CALLS` (off by default) lets that person ring their own other devices
directly, which is otherwise refused as inviting yourself.

It is **not** required for the first test, which works on the existing behaviour:

1. **Phone** — Settings → Service address `https://qatar-vpn.tailea67b0.ts.net:8445`,
   signalling override **empty**. The app loads and shows Dad and Mum.
2. **Phone** — tap Call on Dad. Nobody answers, which does not matter: the caller
   is an accepted participant, so the phone is admitted to the room and the call
   becomes active.
3. **Mac, on the tailnet** — open `https://qatar-vpn.tailea67b0.ts.net:8445/`.
   That is the same PWA served by the Crossbar server, so it is the same person and
   it sees the call in its outgoing list. Press **Join**.
4. Both are now in one room: the server pairs them and media crosses both ways.

A call between two *different* people needs their own devices on the tailnet under
their own Tailscale accounts. With auto-enrolment on, the moment such a device
opens the PWA or the app it becomes a member and appears in everyone's directory.

---

## 4. Stage 2 — one-to-one validation with a real device

**Done for native ↔ browser, 2026-09-20.** The owner placed a call from the iPhone
app on the development server, joined it from a browser on the Mac, and saw and
heard both ends. The server's log of that call is quoted in
[`CROSSBAR_SERVER_IMPLEMENTATION.md`](CROSSBAR_SERVER_IMPLEMENTATION.md); what it
proves is listed under "Not yet verified", where the remaining gaps are now honest
and short.

- Point **one** device at the new backend using Settings (service address +
  signalling origin). The other family devices stay on the current stack.
- Place a real 1:1 call between that device and a family member — either another
  native device or the PWA, which is now served by the Crossbar server and whose
  call frame loads the Crossbar browser client.
  **This is the decisive test:** it is the first time the native client's
  signalling meets this server, and nothing about it has been verified on a phone
  yet.
- Repeat in the other direction (PWA initiates).

**Exit criteria:** audio and video both ways, ringing, accept, decline, cancel and
end all behave as they do today; the PWA is unaffected; the new server's logs
explain every event of the call without exposing secrets.

**Rollback:** clear the two Settings fields on the device. No server change.

---

## 5. Stage 3 — multiparty validation

Order matters: three people is where the mesh and per-participant leave are
actually exercised.

1. Three devices: two native on Crossbar, one on the PWA. The PWA's multiparty
   behaviour is unchanged because its room is still MiroTalk's.
2. Three native on Crossbar (2 leaves the PWA on MiroTalk, so this needs three
   native-capable devices; if unavailable, use the simulator plus two devices).
3. Four participants.
4. Exercise, deliberately: a participant leaving while others stay (must not end
   the call); a participant backgrounding the app; a participant killing the app
   (ghost reap within the heartbeat window); a device re-attaching and evicting
   its own ghost; a third participant joining an active call late.

**Exit criteria:** the mesh forms per pair, no duplicate tiles, departure does not
end the call, re-attach produces no ghosts, and the server enforces the
participant ceiling.

**Rollback:** per-device settings, as Stage 2.

---

## 6. Stage 4 — security validation, then production migration

**Security validation, against the criteria in
[`CROSSBAR_SECURITY_MODEL.md`](CROSSBAR_SECURITY_MODEL.md):**

- a socket that presents no trusted identity cannot join anything;
- a person who is not a participant of a call cannot join its room, even knowing
  the room id;
- SDP/ICE addressed outside the sender's call are refused, and the refusal is
  logged;
- an invitation cannot be answered twice, and a call that is over admits nobody;
- malformed messages — including prototype-chain ids (`constructor`, `toString`)
  and oversized payloads — are rejected without affecting the process;
- rate limits and participant ceilings hold;
- a device that reconnects replaces its own previous connection rather than
  leaving a ghost;
- the startup log and the failure logs contain no secret;
- a second local process with no tailnet identity cannot act as a member.

**Production migration:**

1. Move the family devices to the new backend, one at a time, each verified by a
   real call before the next.
2. The PWA is **already migrated**: it is served by the Crossbar server and gets a
   `joinUrl` pointing at the Crossbar browser client, which it loads in its call
   frame exactly as it used to load MiroTalk's page. It needed **no source
   change** — the call frame contract (a page URL in, a navigation to `/newcall`
   out) is unchanged, and the `allow="camera; microphone"` attribute it already
   carried is what lets the Crossbar client capture.
3. Decide where the PWA's *files* live: keep serving them from the existing
   repository through `WEB_ROOT` (no fork, two places to look), or move them into
   this project (one deployment, and the PWA's own repository becomes history).
4. Retire MiroTalk and remove its Serve route — only once the native client has a
   push path, since a locked phone currently rings only through the PWA.

**Rollback at every point:** each device's Settings fields point back to
`https://qatar-vpn.tailea67b0.ts.net` (MiroTalk) and
`https://qatar-vpn.tailea67b0.ts.net:8443` (control plane). Because the migration
is additive and per-device, rollback is a settings change, not a deployment.

---

## 7. Repository and code organisation

**Settled as:** the server lives at

```text
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/server
```

a self-contained Node project beside the (unmodified) PWA repository, reusing the
control plane's schema and behaviour by reimplementation rather than by import, so
that AGPL/provenance questions live in one place and the PWA repository's history
stays clean.

**Known gap:** that directory is inside the user-designated workspace, which is
**not** a Git repository, and the workspace rules forbid initialising another one.
The server is therefore not yet under version control. Reversibility is preserved
the coarse way — one directory, deletable or movable in a single step — but this
should be resolved deliberately: either initialise a repository there with explicit
approval, or move the directory into the existing Crossbar Git worktree.

---

## 8. What must not happen during migration

- No modification of `/home/admin/mirotalk` — no source edit, no config edit, no
  reset, no cleanup of its untracked rollback files.
- No `tailscale serve reset`; no Funnel; no new public or LAN listener.
- No change to ports 3000/3001 or to the existing 443/8443 handlers.
- No reuse of the control plane's or MiroTalk's `.env` or database by the new
  service.
- No restarts of `mirotalk.service` or `family-call.service` as part of a
  Crossbar deploy.
- No enabling of the inactive `mirotalk-family.service` / 3002 / 8444 path.
- No client release that removes the ability to point back at the old backend
  until the migration is complete.

---

## 9. Test strategy, honestly scoped

| Layer | What it proves | How |
| --- | --- | --- |
| Protocol framing | Engine.IO v4 / Socket.IO v5 subset correctness | a test client that speaks the native client's exact frames (`test/helpers.js`), against a real server on an ephemeral port |
| Call state machine | transitions, decline/cancel/leave/expiry, rejoin rules | unit tests over `src/calls.js`, which is pure |
| Authorization | admission rules, participant-scoped relay, spoofed status, ceilings | integration tests: an outsider is refused, a cross-call relay never arrives, a peer cannot claim another's id |
| Validation | malformed and oversized input cannot affect the process | a test that sends `peer_id: "constructor"` — the message that used to crash the old server — plus junk frames, then proves the server still admits someone |
| Real call | the whole thing actually carries media | two browsers through the real server: two-way audio and video measured, camera status relayed, and a departure that leaves the call standing |
| Regression | the PWA still works | the PWA is served by the server and its call frame loads the Crossbar client |

Tests are written where a plausible bug would fail them; the device calls are the
proof of the feature, and no simulator result will be reported as proving camera,
CallKit, audio routing or background behaviour.
