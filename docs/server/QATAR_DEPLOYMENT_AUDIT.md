# Qatar deployment audit (read-only)

What is actually running on `qatar-vpn` today, established by read-only inspection
on 2026-09-20. Nothing in this document was inferred from prior documentation
where source or the host itself could answer — and where the two disagree, the
disagreement is recorded rather than smoothed over.

**Access:** `ssh admin@qatar-vpn` (key `~/.ssh/qatar_vpn_admin`, user `admin`).
The historical path `/home/admin/mirotalk` is **confirmed current**.

**Production safety:** every command behind this document is read-only. No service
was started, stopped, restarted, reconfigured, or updated, and no file on the Pi
was written. Two commands were deliberately **not** run: anything touching
`/api/session` (it writes to the production SQLite by enrolling the caller on
read — `src/server.js:190`, `src/db.js:191-244`) and anything that would print
undiluted secrets.

---

## 1. Host

| Fact | Value | Evidence |
| --- | --- | --- |
| Model | Raspberry Pi 4 Model B Rev 1.4, aarch64 | `/proc/cpuinfo` |
| OS | Debian GNU/Linux 13 (trixie), 13.7 | `/etc/os-release` |
| Kernel | `6.18.39+rpt-rpi-v8` | `uname -a` |
| Memory | 8,007,464 kB total, ~7.49 GB available | `/proc/meminfo` |
| Uptime at audit | 11 d 6 h, load 0.00 | `/proc/uptime`, `uptime` |
| Node | v22.23.2 (nodesource) | `node -v`; `/var/log/apt/history.log` |
| npm | 10.9.8 | `npm -v` |
| Tailscale | 1.102.3 | apt history; `tailscale version` |
| Human accounts | exactly one: `admin` (uid/gid 1000, in `sudo`) | `/etc/passwd` |
| Service users | none — both apps and `tailscaled` run as `admin`/`root` | unit files |
| SSH | `PermitRootLogin no`, pubkey + password auth | `/etc/ssh/sshd_config.d/10-qatar-vpn.conf` |
| Host firewall | none loaded: `/etc/nftables.conf` has an empty `table inet filter`, service not enabled | file inspection |
| Containers | none — no Docker, no coturn, no nginx/caddy/apache | `command -v docker`; `/etc/{nginx,apache2,caddy}` absent |

`admin` requires an interactive sudo password (`docs/OPERATIONS.md`), and the
kernel hardening on the family-call unit shows privileged steps were deliberate.

---

## 2. Services

Running: `mirotalk.service`, `family-call.service`, `tailscaled.service`, plus
stock Debian units (`ssh`, `cron`, `avahi-daemon`, `NetworkManager`,
`wpa_supplicant`, `bluetooth`, `dbus`, `unattended-upgrades`, `getty@tty1`,
`user@1000`).

Installed but **inactive**: `mirotalk-family.service` (not enabled, no cgroup, no
process, no listener).

### `mirotalk.service` — production signalling

```ini
[Unit]
Description=MiroTalk P2P
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=admin
Group=admin
WorkingDirectory=/home/admin/mirotalk
ExecStart=/usr/bin/node /home/admin/mirotalk/app/src/server.js

Restart=on-failure
RestartSec=5

Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
```

**No hardening directives at all** — no `ProtectSystem`, no `NoNewPrivileges`, no
`PrivateTmp`, no `UMask`. No `EnvironmentFile`; MiroTalk loads its own `.env` from
its working directory via dotenv. Current process: PID 24851, started
2026-09-15 13:48:48, up 5 d 4 h at audit. Two restarts occurred on 2026-09-15
(13:44:47 and 13:48:48) during configuration work; none since.

### `family-call.service` — control plane

```ini
[Unit]
Description=Family Call private PWA
After=network-online.target mirotalk.service
Wants=network-online.target

[Service]
Type=simple
User=admin
Group=admin
WorkingDirectory=/home/admin/family-call
Environment=NODE_ENV=production
Environment=NODE_NO_WARNINGS=ExperimentalWarning
EnvironmentFile=/home/admin/family-call/.env
ExecStart=/usr/bin/node /home/admin/family-call/src/server.js
Restart=on-failure
RestartSec=5
TimeoutStopSec=10
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/admin/family-call/data
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
```

Hardening is real and enforced: `/proc/28628/status` reports `Umask: 0077`,
`NoNewPrivs: 1`, `Seccomp: 2`, `CapEff: 0000000000000000`. Process: PID 28628,
started 2026-09-15 23:00:37, up 4 d 19 h. `NODE_NO_WARNINGS=ExperimentalWarning`
silences `node:sqlite`'s experimental warning.

**This unit is the pattern a Crossbar server should follow.** The MiroTalk unit is
the counter-example.

No application timers exist. Call expiry is an in-process `setInterval(…, 10s)`
(`family-call/src/server.js:363-372`).

---

## 3. Listeners and exposure

| Proto | Address | Port | Owner | Exposure |
| --- | --- | --- | --- | --- |
| TCP | `0.0.0.0` / `::` | 22 | `sshd` | LAN + tailnet |
| TCP | `127.0.0.1` | **3000** | node 24851 (`mirotalk`) | **loopback only** |
| TCP | `127.0.0.1` | **3001** | node 28628 (`family-call`) | **loopback only** |
| TCP | `100.77.42.16` / `fd7a:115c:a1e0::4e2d:2a11` | **443** | `tailscaled` 801 | **tailnet only** |
| TCP | same two addresses | **8443** | `tailscaled` 801 | **tailnet only** |
| UDP | `0.0.0.0` / `::` | 41641 | `tailscaled` 801 | tailnet WireGuard |

There is **no listener on the LAN address**. Every public-facing port is either
`sshd` or a tailnet-only socket.

### Tailscale Serve — verified live

```
$ tailscale serve status
https://qatar-vpn.tailea67b0.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:3000

https://qatar-vpn.tailea67b0.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:3001
```

Two handlers, both marked **tailnet only**:

| Serve endpoint | Proxies to | Serves |
| --- | --- | --- |
| `https://qatar-vpn.tailea67b0.ts.net:443/` | `http://127.0.0.1:3000` | MiroTalk (signalling + web client) |
| `https://qatar-vpn.tailea67b0.ts.net:8443/` | `http://127.0.0.1:3001` | Family Call (control plane + PWA) |

No third handler. The inactive 3002/8444 family-mode engine has **no** Serve route
and no listener.

**TLS terminates in `tailscaled`** — it is the only process bound to 443/8443, on
the tailnet addresses only. Certificates are the tailnet-provisioned ones for
`qatar-vpn.tailea67b0.ts.net`; there are no cert files for a web server because no
web server exists. MiroTalk's own `app/ssl/key.pem`/`cert.pem` are stock upstream
files and are not on the live path (`httpolyglot` is constructed with them, but
nothing binds to a TLS port).

**Funnel is not enabled.** Public DNS for the node name returns NXDOMAIN, and the
Serve status output labels both handlers "tailnet only".

---

## 4. Request path

There is exactly **one proxy hop, on-box**.

```
client (Crossbar iOS app / PWA on a tailnet device)
  |  MagicDNS: qatar-vpn.tailea67b0.ts.net → 100.77.42.16 (resolv.conf: nameserver 100.100.100.100,
  |                                                search tailea67b0.ts.net)
  v
tailscaled  (PID 801, uid 0) — TLS termination, Serve handler
  |  plain HTTP to loopback
  v
127.0.0.1:3000  MiroTalk         (signalling,  /socket.io/)
127.0.0.1:3001  Family Call      (/api/* + PWA)
```

Consequences that matter to a redesign:

1. **Both applications see `remoteAddress == 127.0.0.1` for every request.** That
   is *why* Family Call's listener refuses to bind anywhere else and why
   `resolveIdentity` accepts identity headers only from loopback
   (`family-call/src/identity.js:9-22`, `src/config.js:59-62`).
2. **`tailscaled` injects the identity headers** — `Tailscale-User-Login`,
   `-Name`, `-Profile-Pic` — and strips client-supplied copies. It does not
   populate them for Funnel traffic or for tagged devices, and it *does* populate
   them for external users who accepted a share of the node.
3. MiroTalk has `TRUST_PROXY=true`, so its `getSocketIP` reads the **first**
   `X-Forwarded-For` value (`mirotalk/app/src/server.js:2816-2821`). Whether
   Serve actually sets XFF was not established; nothing security-relevant depends
   on it today because `IP_WHITELIST_ENABLED=false`.

**Path-specific note:** `GET /api/session` is not read-only. `currentUser()` calls
`store.observeIdentity()`, which inserts/updates `users`, rewrites `contacts`,
touches `presence`, and may broadcast `directory-updated`
(`family-call/src/server.js:186-193`, `src/db.js:191-256`). It was therefore not
probed against production during this audit, and a health check must not use it.

---

## 5. Deployment state

### `/home/admin/mirotalk`

- Branch `master` at **`5af51e0cf2fd38bc296574f8d4aff9a19ea318c5`** — a pure
  upstream clone; the reflog contains **one line** (the clone) and there are **no
  local commits**.
- One uncommitted source edit, verified by diffing against upstream at the same
  commit:

  ```diff
  --- a/app/src/server.js   (upstream 5af51e0c)
  +++ b/app/src/server.js   (deployed)
  @@ -1235 +1235 @@
  -server.listen(port, null, async () => {
  +server.listen(port, '127.0.0.1', async () => {
  ```

  One token, same line number. This is the entire local source change.
- Untracked artifacts beside it: `app/src/server.js.before-local-bind` (the
  pre-edit copy) and `.env.original` (the pre-hardening environment). **These must
  not be cleaned, reset, or staged** — they are the documented rollback for the
  bind change.
- Everything else inspected is stock 1.9.64.

### `/home/admin/family-call`

- Branch `master` at **`e2b053d65ab3d4ab0ccba1611f649829318aed21`** — the
  documented deployed commit.
- Deployment transport is **git bundles**, not a remote: `/home/admin` holds
  `family-call-{069a397,1bedec7,64d65c5,e2b053d}.bundle`, and the reflog shows
  four `pull --ff-only …bundle` fast-forwards.
- Untracked backups: `.env.before-family-engine`, `.env.before-raw-audio-rollback`.
  No tracked source file is known modified.

### `/home/admin/mirotalk-family` — an experiment, inactive

A full second MiroTalk copy on branch `codex/family-mode`, two commits on top of
`5af51e0c` (`68a2a4f`, `cc6ea67`), prepared by
`family-call/deploy/prepare-family-engine.mjs`, configured for port 3002 and
embed origin 8443. Its two patches are the ones carried in the Family Call repo's
`engine-patches/`:

- `0001-family-raw-audio-default.patch` — a client-side `audioProcessing=0` path
  that disables echo cancellation, AGC and noise suppression.
- `0002-redact-startup-config.patch` — adds `getSafeServerConfig()` so the
  startup log stops printing secrets.

Inactive on three independent proofs: not in `multi-user.target.wants`, no
`invocation:` marker in `/run/systemd/units`, no cgroup and no listener.

> **Asymmetry worth naming:** the *inactive* copy carries the secret-redaction
> patch; the **active production instance does not**, and prints its API key and
> JWT key at `info` level on every start. See §7.

---

## 6. Configuration

### `/home/admin/mirotalk/.env` (key names; secret values redacted)

Non-secret effective values: `HOST=127.0.0.1`, `PORT=3000`, `TRUST_PROXY=true`,
`TZ=Asia/Qatar`, `LOGS_DEBUG=false`, `LOGS_COLORS=true`, `LOGS_JSON=false`,
`CORS_ORIGIN='"https://qatar-vpn.tailea67b0.ts.net"'`,
`CORS_METHODS='["GET","POST"]'`, `ALLOWED_EMBED_ORIGINS=` (empty),
`IP_WHITELIST_ENABLED=false`, `IP_WHITELIST_ALLOWED='["127.0.0.1","::1"]'`,
`OIDC_ENABLED=false`, `OIDC_AUTH_REQUIRED=false`, `SHOW_ACTIVE_ROOMS=false`,
`ROOM_MAX_PARTICIPANTS=1000`, `HOST_PROTECTED=false`, `HOST_USER_AUTH=false`,
`HOST_MAX_LOGIN_ATTEMPTS=5`, `HOST_MIN_LOGIN_BLOCK_TIME=15`, `JWT_EXP=1h`,
`PRESENTERS='[]'`, `NGROK_ENABLED=false`, **`STUN_SERVER_ENABLED=true`**,
**`STUN_SERVER_URL=stun:stun.l.google.com:19302`**,
**`TURN_SERVER_ENABLED=false`**, `IP_LOOKUP_ENABLED=false`,
**`API_DISABLED='["token","meetings"]'`**, `CUSTOM_NOISE_SUPPRESSION_ENABLED=true`,
and `STATS`/`SENTRY`/`SLACK`/`MATTERMOST`/`CHATGPT`/`WHISPER`/`EMAIL_ALERT` all
disabled. `API_KEY_SECRET` and `JWT_KEY` are custom (non-default) 64-hex values;
`API_KEY_SECRET` is the same value Family Call holds as `MIROTALK_API_SECRET`.

### Effective ICE — the operative answer

**Clients receive exactly `[{urls: 'stun:stun.l.google.com:19302'}]`, with no TURN
and no credentials.** Confirmed three ways: `.env`, the construction at
`app/src/server.js:200-213`, and the running process's own startup log line
`iceServers: [ { urls: 'stun:stun.l.google.com:19302' } ]`.

This settles a stale claim: the audit-time note that production "delivers
`iceServers: []` because STUN and TURN were disabled" is **wrong for the deployed
state**, and `docs/MIROTALK_INTEGRATION.md`'s "STUN: disabled" is likewise
out of date.

### `/home/admin/family-call/.env`

`HOST=127.0.0.1`, `PORT=3001`,
`PUBLIC_ORIGIN=https://qatar-vpn.tailea67b0.ts.net:8443`,
`MIROTALK_API_URL=http://127.0.0.1:3000/api/v1/join`,
`MIROTALK_PUBLIC_HOST=qatar-vpn.tailea67b0.ts.net`,
`MIROTALK_EMBED_ORIGIN=https://qatar-vpn.tailea67b0.ts.net`,
`TRUST_TAILSCALE_HEADERS=true`, `ALLOW_DEV_IDENTITY=false`, `CALL_RING_SECONDS=90`,
`DATA_DIR`/`FAMILY_CONFIG_PATH` under `/home/admin/family-call/data`, and a VAPID
key pair with **no `VAPID_SUBJECT`** (so it falls back to `PUBLIC_ORIGIN`).

`data/family.json` (0600) defines three users — `abdullah`
(`ibnfaisalc@gmail.com`), `dad` and `mum` (placeholder logins), a six-edge
contact allow-list, and one group containing all three.

### Secret hygiene

`.env` files are `0600`. No secret value was copied, printed in this document, or
committed. The one place production *does* expose secrets is the MiroTalk startup
log, recorded below.

---

## 7. State, storage, and observability

### Storage

| Service | Durable state | Notes |
| --- | --- | --- |
| MiroTalk | **none** | rooms/peers live only in process memory (`app/src/server.js:404-410`); a restart destroys every room |
| Family Call | `data/family-call.sqlite` (+ `-wal`, `-shm`), WAL mode | tables: `users`, `contacts`, `family_groups`, `group_members`, `calls`, `call_participants`, `presence`, `push_subscriptions` |
| Family Call | `data/family.json` (0600) | configured users, contacts, groups |
| Family Call | `data/tailscale-serve.before-family-call.json` | a Serve snapshot: `{"version":"0.0.1"}`, i.e. it contains **no** handlers |

### Logs

Both services log to **stdout → journald**, and the journal is **volatile**:
`/var/log/journal` is empty, the only journal is
`/run/log/journal/<machine-id>/system.journal`, and `journald.conf` is entirely
commented out (compile-time default `Storage=auto`). Total journal size is 8 MB
and `--list-boots` shows a single boot. **Every log is lost on reboot**, so
post-hoc diagnosis of a failed call is impossible.

`OPERATIONS.md` prescribes `journalctl -u family-call.service -n 100` as a health
check; that works only until the next reboot.

### What each service actually logs

**Family Call** (`console.info`) — structured and deliberately secret-free:
`family_call_started {host,port}`, `call_created {callId,callerId,inviteeIds}`,
`call_accepted`/`call_declined` (`call_<response> {callId,userId}`),
`call_invited {callId,inviterId,inviteeIds}`, `call_ended {callId,userId,status}`,
`call_missed {callId}`, `request_error {message}` (5xx only),
`push_dispatch_failed {message}`, `family_call_stopping {signal}`.
There is **no access log, no remote-address logging, and no log for an identity or
origin rejection**.

Observed live (last entries before audit):

```
2026-09-19T19:13:40 call_created   callId 7b181466-…  callerId abdullah
                                   inviteeIds [ 'ts_6220c7b11623fa364530a7a1' ]
2026-09-19T19:13:47 call_accepted  callId 7b181466-…  userId ts_6220c7b11623fa364530a7a1
2026-09-19T19:14:19 call_ended     callId 7b181466-…  userId abdullah  status ended
2026-09-19T19:15:57 call_declined  callId 1136f2ab-…  userId abdullah
```

These lines are also direct evidence of the identity model: a first-seen tailnet
identity is enrolled under a derived id `ts_<sha256(login)[0:24]>`, while the
pre-configured local user keeps its configured id (`abdullah`).

**MiroTalk** — `LOGS_DEBUG=false`, so `log.debug` **returns immediately** and
every connect/join/leave trace is suppressed. There is therefore **no positive
path telemetry at all**: no "peer joined room X", no peer-leave line, and — worse
— the API authorization failures that are logged at `debug` include
`header: req.headers`, meaning enabling debug would write the `authorization`
secret into the journal.

What *is* emitted at production level, and was observed live:

```
iceServers: [ { urls: 'stun:stun.l.google.com:19302' } ]
cors: { origin: 'https://qatar-vpn.tailea67b0.ts.net', methods: [ 'GET', 'POST' ] }
embed: { allowedOrigins: 'any', csp: 'not set (embedding allowed from any origin)' }
host_protected: false    presenters: []    ip_whitelist: false    turn_enabled: false
turn_enabled: false      server: '127.0.0.1'    trust_proxy: true
```

⚠️ **The same startup line prints `api_key_secret` and `jwtCfg.JWT_KEY`**
(`app/src/server.js:1177` feeds `getServerConfig()`, logged at `:1254`). The values
are deliberately not reproduced here. This is a real secret exposure to anything
that can read the journal, and a purpose-built server must not repeat it.

---

## 8. Documentation defects found

1. **`MIROTALK_INTEGRATION.md` says STUN and TURN are disabled** and that clients
   receive an empty `iceServers`. Deployed reality: one Google STUN server, no
   TURN. The `.env` and the running process both say so.
2. **`OPERATIONS.md` calls 8443 the "Development URL".** It is the production
   Family Call entry point — the native Crossbar client's compiled default is
   `https://qatar-vpn.tailea67b0.ts.net:8443`, and `PUBLIC_ORIGIN`/`VAPID_SUBJECT`
   are built from it.
3. **`OPERATIONS.md` documents the 3002/8444 family-mode engine as part of the
   runbook**; it was prepared but never activated.
4. **The old `MiroTalk HOST` note is misleading.** `.env` sets `HOST=127.0.0.1`,
   but the *actual* bind is the hardcoded `'127.0.0.1'` at
   `app/src/server.js:1235`. Changing `HOST` would neither bind nor unbind
   anything; it only mis-builds the `/icetest` and `/api/v1/docs` links (which is
   why the startup log shows `api_docs: '127.0.0.1/api/v1/docs'`).
5. **`AUDIT.md`'s "MiroTalk currently allows embedding from any origin" remains
   true** — `ALLOWED_EMBED_ORIGINS` is empty in production, so no
   `frame-ancestors`/`X-Frame-Options` is emitted.
6. **The Serve snapshot in `data/` contradicts `AUDIT.md`.** The snapshot holds no
   handlers while 443→3000 is provably live today. Unresolved read-only; the live
   `tailscale serve status` output in §3 is authoritative.

---

## 9. Reproduction recipe

```
Host   Raspberry Pi 4B rev 1.4 · Debian 13 (trixie) aarch64 · kernel 6.18.39+rpt-rpi-v8
       node 22.23.2 (nodesource) · npm 10.9.8 · tailscale 1.102.3 · user admin (uid 1000, sudo)
       no docker · no nginx/caddy/apache · no coturn · no host firewall rules

App A  /home/admin/mirotalk            git master @ 5af51e0c (upstream clone; no local commits)
       + uncommitted: app/src/server.js:1235 binds '127.0.0.1'
       + untracked:   app/src/server.js.before-local-bind, .env.original
       .env: HOST=127.0.0.1 PORT=3000 TRUST_PROXY=true TZ=Asia/Qatar LOGS_DEBUG=false
             CORS_ORIGIN='"https://qatar-vpn.tailea67b0.ts.net"'  ALLOWED_EMBED_ORIGINS= (any)
             STUN enabled (stun:stun.l.google.com:19302)   TURN disabled
             HOST_PROTECTED=false  HOST_USER_AUTH=false  OIDC=false  IP_WHITELIST=false
             API_DISABLED='["token","meetings"]'   custom API_KEY_SECRET + JWT_KEY
       unit   /etc/systemd/system/mirotalk.service   (no hardening, no EnvironmentFile)
       listen 127.0.0.1:3000

App B  /home/admin/family-call         git master @ e2b053d (deployed via git bundles)
       .env: HOST=127.0.0.1 PORT=3001 PUBLIC_ORIGIN=https://qatar-vpn.tailea67b0.ts.net:8443
             MIROTALK_API_URL=http://127.0.0.1:3000/api/v1/join
             MIROTALK_PUBLIC_HOST=qatar-vpn.tailea67b0.ts.net
             MIROTALK_EMBED_ORIGIN=https://qatar-vpn.tailea67b0.ts.net
             TRUST_TAILSCALE_HEADERS=true ALLOW_DEV_IDENTITY=false CALL_RING_SECONDS=90
             VAPID pair set (no VAPID_SUBJECT → derived from PUBLIC_ORIGIN)
       data/  family-call.sqlite(+wal,shm) · family.json (3 users / 6 contacts / 1 group)
       unit   /etc/systemd/system/family-call.service   (hardened; RW only data/)
       listen 127.0.0.1:3001

Serve  https://qatar-vpn.tailea67b0.ts.net        → http://127.0.0.1:3000   (MiroTalk)
       https://qatar-vpn.tailea67b0.ts.net:8443   → http://127.0.0.1:3001   (Family Call)
       8444 → 3002                                not deployed
TLS    terminated by tailscaled on 100.77.42.16 and fd7a:115c:a1e0::4e2d:2a11 only
       Serve adds Tailscale-User-Login / -Name / -Profile-Pic and strips spoofed copies
Funnel not enabled (public DNS NXDOMAIN; Serve reports "tailnet only")
ICE    [{ urls: 'stun:stun.l.google.com:19302' }] — no TURN; full mesh, no SFU
Logs   stdout → journald, VOLATILE (lost on reboot)
```

---

## 10. Open questions

- Whether `tailscaled` sends `X-Forwarded-For` to the loopback app was not
  established. Nothing depends on it today (`IP_WHITELIST_ENABLED=false`), but a
  Crossbar server must not trust a client-supplied XFF if it ever uses one.
- SQLite row counts were not read: the remote reader refuses binary files and
  there is no shell for `sqlite3`. Schema is source-derived and authoritative;
  contents were not inspected beyond the log evidence above.
- Whether a second Serve handler for a Crossbar service would need a new port or
  could take a path on an existing one is a design decision, not an audit result.
