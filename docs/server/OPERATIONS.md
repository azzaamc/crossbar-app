# Operating a Crossbar deployment

What an operator does to a live Crossbar server, in the order they will need it: switching
modes, backing it up and restoring it, upgrading and rolling back, and installing a second
household. Written for the person holding the shell, not for someone reading the source.

**Two copies, one of them authoritative.** The host-side runbook is
`server/deploy/README.md` in the server repository — the same commands as here, plus the
host facts (DNS records, port forwards, the firewall, the coturn template, CGNAT) that only
that document carries. This document is the app repository's copy: the same runbooks, with
what each one does to a phone made explicit, because the phones are the part a server-side
runbook cannot see.

Production is at `/home/admin/crossbar` on the VPS; the checkout on this workstation is
`/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/server`. Everything below is written with
`/home/admin/crossbar` as the working directory, because that is where it runs.

> **Verification status — 2026-09-26.**
>
> Nothing in this document has been executed against production: **no agent has connected to
> it**, and the server unit files were authored on macOS, which cannot run them
> (`systemd-analyze verify` does not exist there), so the **integration owner has not yet**:
>
> - run the unit files, or performed a switch on the box — including whether a switch made
>   from the console reshapes the box (§2.4);
> - measured the switch overlap and its grace window (§2.5). Both are now in the server units —
>   the new door opens first, the old one is closed by a transient timer unit, and the window is
>   `CROSSBAR_SWITCH_GRACE_SECONDS` — but nothing has run them: `server/scripts/rehearse-switch.sh`
>   (which shortens the window to seconds and watches the door actually close) has not been
>   executed anywhere. Do not run it on a deployment anybody is using;
> - fired the backup timer or rehearsed the restore in §3.4;
> - run the server's distribution scripts on a Linux host. `server/scripts/install.sh`,
>   `release.sh`, `upgrade.sh` and `uninstall.sh` exist, are `bash -n` clean, and every
>   `--dry-run` was read on macOS — where a real run refuses at the systemd check rather than
>   reporting an install — and a release tarball was built for real and its checksum verified.
>   **No install, upgrade or uninstall has run against a host with systemd**, so §4.1, §4.3,
>   §4.5, §4.6 and §5 describe what the scripts do, read from them, not a run;
> - run the full server test suite on the merged tree.
>
> The app side is further along and is still short of a live switch: the following code is in
> this tree (§1, §2.4), but it has been exercised against a stub whose `/api/health` reports a
> different `origin`, **not** against a server being switched. That is exactly the check that
> makes a switch non-destructive, so treat "switching is safe for enrolled phones" as
> **expected, not measured**, until that run happens.

---

## 1. What the server and the phone exchange

A phone learns where its deployment is from three places, and only one of them moves:

| Where | Set by | Changes when |
| --- | --- | --- |
| The enrolment code | `node src/admin.js enroll`, which mints `{version, server, mode, enrollment_token}` | when the administrator issues a new one |
| Settings on the device | the onboarding screen, or the deployment itself | §2.4 |
| `GET /api/health` | the running server, unauthenticated | whenever the server starts |

### 1.1 `GET /api/health` is the address the phone may follow (frozen)

```bash
curl -fsS https://<public hostname>/api/health
{"status":"ok","mode":"public","version":"0.1.0","origin":"https://crossbar.example.net"}
```

- `mode` — `private` or `public`, the trust posture the server is in (§2).
- `version` — the version of the running process. This is the one question the CLI cannot
  answer, because the CLI may be a different checkout from the one the service runs.
- `origin` — the address the server believes it is reached at.

`origin` **is specified for this deployment and is added by the mode work**; as the server
tree stands, the route answers `status`, `mode` and `version` and nothing else. Until it is
there, a phone cannot follow a move and a switch still ends in being set up again (§2.4).

The route is **additive, and that is the frozen part of the contract**: a device and a server
are not upgraded together, so a phone may be a build behind the service answering it, or ahead
of it. Every field is read as optional, a missing field is an older peer rather than a
malformed answer, and nothing in the client may treat it as one. The app reads all three of
those fields for exactly this reason (`Core/ServiceClient.swift`, `ServiceHealth`).

### 1.2 What the app does with the answer

On every load, and *before* it asks `/api/session` or sends anything holding this device's
identity (`Core/CallSession.swift`, `followMovedServer`):

1. It asks the address it already holds for `/api/health`.
2. If `origin` names a different deployment, it writes that address into
   `AppSettings.serviceAddress` and the `mode` into `AppSettings.connectionMode`, logs
   `the server moved: <old> → <new> … the key this device holds is unchanged`, and shows
   *"Your Crossbar has moved, and this app followed it. Nothing here needs doing."*
3. **The device key is not touched.** What the phone holds is an identity, not a token tied to
   a host: the server remembers the public half of that key, and the same key authenticates at
   either door. Re-enrolment is never part of a switch.
4. If the answer has no `origin` — an older server — or an `origin` this app cannot dial
   (no scheme, no host), the device **stays where it is** and the load carries on. The app then
   reports the move through `serverMovedTo` and the person sets the deployment up again.

After authenticating, the same route is asked a second time in the same load: the first ask is
what lets a device *follow* a move, the second is the check for a move it could not follow.

---

## 2. Runbook: switching modes

### 2.1 What a switch is

A deployment holds both configurations, one block per mode, and moves between them with one
command plus the restart it asks for. The `mode` command only edits `.env`; the restart applies
it — to the process *and* to the box's shape.

```bash
cd /home/admin/crossbar
node src/admin.js mode public          # rewrite the generated section of .env
sudo systemctl restart crossbar        # apply it
```

### 2.2 The command, and what it says

Run it from the checkout: the CLI reads `.env` from the working directory (`./.env`), not from
the directory of the script, so `cd /home/admin/crossbar` first — the same directory systemd's
`WorkingDirectory=` names.

`node src/admin.js mode` with no argument lists both blocks and marks the one in force:

```
   MODE       HOSTNAME                              ORIGIN
-> private    -                                     (unset: invitations would carry the default origin)
   public     -                                     (unset: invitations would carry the default origin)

private is in force, and loads cleanly.
```

(The development checkout, whose blocks are empty; a deployment's lines carry its tailnet name
and its public hostname.) The exit code is 1 when the file does **not** load, so this is the
command to run before a restart when something is wrong.

`node src/admin.js mode public` rewrites the generated section and verifies it by starting a
child process that reads nothing but that file:

```
In public from the next start:
  systemctl restart crossbar
  (the reverse proxy too, when the two modes bind different addresses)
```

In the same mode it answers `Already in public; nothing to change.`

What it refuses:

- **An empty mode block** — it puts the file back and names what is missing, e.g.
  `Cannot switch to public: NETWORK_MODE_PUBLIC_HOSTNAME (or CROSSBAR_PUBLIC_HOSTNAME) is
  required in public mode: it is the host invitations send people to`, then
  `Fill in its block in .env — NETWORK_MODE_PUBLIC_HOSTNAME and NETWORK_MODE_PUBLIC_ORIGIN —
  and try again.`
- **A generated name outside the markers** (exit 1, file untouched):

  ```
  PUBLIC_ORIGIN is set outside the generated section, on line 6. Remove that line: the mode
  writes this name itself, and a line left outside would override what the mode decides.
  ```

  The names it refuses are `PUBLIC_ORIGIN`, `CROSSBAR_PUBLIC_HOSTNAME`,
  `CROSSBAR_NETWORK_MODE`, `CROSSBAR_BIND_ADDRESS`, `TRUST_TAILSCALE_HEADERS`,
  `CROSSBAR_REQUIRE_DEVICE_AUTH`. A top-level `PUBLIC_ORIGIN=` is a legitimate override for a
  run that is not a deployment (a laptop with a dev server); on a deployment it belongs in the
  mode's own block, and the refusal exists because a line outside the markers would silently
  win over the mode. The development checkout in the server repository refuses for exactly
  this reason — its hand-written `.env` carries `PUBLIC_ORIGIN=http://127.0.0.1:3010` at the
  top level — which is the rule working, not a regression. A refusal writes nothing: no
  `.env` change, and not even an `env.previous`.
- **Damaged markers** — one marker line without the other, or the pair reversed:
  `The generated section is damaged: this file has one of its two marker lines without the
  other, or has them the wrong way round. Fix that, then switch.`

The write is atomic: content is staged at `<DATA_DIR>/.env.writing` and the file it replaces is
kept at `<DATA_DIR>/env.previous` (both mode 0600) before the staged file is renamed into
place. `env.previous` is one generation, not a history — it is what to reach for if a switch
was interrupted or a setting was saved by mistake.

### 2.3 What the restart applies

`sudo systemctl restart crossbar` restarts the server and re-runs the two shaping units, each a
oneshot whose `ExecCondition` is a whole-line grep of `.env`:

```
ExecCondition=/usr/bin/grep -qx CROSSBAR_NETWORK_MODE=public /home/admin/crossbar/.env
```

Exactly one passes. Each unit then does three things, in order: **open the new door** (public:
`systemctl start caddy`; private: `tailscale serve --bg ${PORT:-3003}`), **schedule the close of
the old one** for the end of the grace window, and **try-restart the relay** — coturn's realm and
`external-ip` are rendered from `.env` when it starts, so a switch that left it running would
advertise the old realm, which presents as calls that fail to relay rather than as a
configuration error. The tailnet node stays joined throughout: `tailscale down` would take the
address with it and coming back means a re-approval.

The scheduled close is a transient unit, `crossbar-grace-public` or `crossbar-grace-private`,
created by `systemd-run --on-active=…`; it re-reads the mode from `.env` with the same whole-line
grep when it fires, so a switch back inside the window keeps the door it just opened. That
transient unit exits non-zero when the guard declines — a normal journal line, not a fault. One
detail looks like a bug and is not: systemd does not expand `${NAME:-default}` in `Exec*=`, so
the units wrap those command lines in `/bin/sh -c`, whose shell does; both the unit's
`Environment=` line and the shell fall back to 900 seconds.

Neither unit has `RemainAfterExit=yes`, deliberately: a oneshot without it goes inactive after
running, which is what makes the next restart run it again. Adding `RemainAfterExit=yes` would
silently stop every future switch from reshaping the box.

### 2.4 What the phone sees

- **With `origin` on `/api/health`:** nothing in particular. The old address keeps answering
  during the grace window, so the next load asks it, is told the new `origin`, adopts the address
  and the mode, and carries on with the same device key. The person sees one notice: *"Your
  Crossbar has moved, and this app followed it. Nothing here needs doing."*
- **Without `origin`:** the phone cannot be told, so a device still dialling the old address
  reports that the server is reached one way and this device is set up the other, and the person
  has to set the deployment up again — which means an administrator issuing an enrolment code for
  a device that did nothing wrong. As the server tree stands, `/api/health` carries `status`,
  `mode` and `version` and no `origin`, so this is still what a switch does to a phone.
- **Inside the grace window:** the outgoing door is still open (that is what it is for), so
  `systemctl is-active caddy` and `tailscale serve status` show *both* front doors alive — in
  public mode the tailnet is still serving, in private mode Caddy is still up, until the timer
  fires. And after every boot too: the shapers run on every start, so a door that was open stays
  open up to the window rather than being closed during boot. That is the overlap, not a stuck
  unit.

The console switch is the other path: the console performs the same edit and then exits so
systemd's `Restart=always` starts the server again. Whether that also re-runs the two shaping
units is **not established**; check the box's shape after any console switch:

```bash
systemctl is-active caddy
tailscale serve status
systemctl list-timers --all | grep crossbar-grace     # a close still pending?
```

`caddy` active with tailnet serving off is public mode; `caddy` inactive with `tailscale serve`
publishing the loopback port is private — but only once nothing is pending. If the shaping units
did not run, `sudo systemctl restart crossbar` applies them.

### 2.5 The grace window

A switch opens the new front door and closes the old one **after** the window rather than at
once. The window is one setting, read by the mode units: **`CROSSBAR_SWITCH_GRACE_SECONDS` in
`.env`, in seconds, 900 (fifteen minutes) by default**, with the 900 written into each unit as a
floor for a file that says nothing. It is not in `.env.example`; add the line to change it. In
the rehearsal host's script it is shortened (`GRACE=2`), which is how the window is exercised —
`server/scripts/rehearse-switch.sh`, which must not be run on a deployment anybody is using.

During the window both doors answer, which is safe because the trust posture follows the
**mode**, not the door: in public mode the identity header is not believed at all, so the
tailnet door only admits devices whose keys check out; in private mode Caddy strips the identity
headers from outside, and a request with neither header nor device is refused. Both claims are
stated in the units' comments as measured on the rehearsal host before a deploy, and **neither
has been measured yet**.

### 2.6 What is unsafe mid-switch

- **Reading the file as the running mode.** Between `mode public` and the restart, the file
  says public and the process is still private: `mode` reads the file, `status` and
  `/api/health` read the process. Their disagreeing in that window is the command working.
- **Expecting the box to look switched immediately.** The outgoing door stays open for up to
  `CROSSBAR_SWITCH_GRACE_SECONDS` (and for the same window after every boot). That is the overlap,
  and it is the window in which a phone finds the new address; it is not a stuck unit.
- **A second switch inside the window** is handled rather than forbidden — the deferred close
  re-reads the mode when it fires, so it leaves the door the second switch opened alone, and
  `systemd-run` refuses to create a second timer under the same name (tolerated on purpose).
  Expect one failed `crossbar-grace-*.service` journal line where the guard declined.
- **Hand-editing the generated section.** The next switch overwrites it, a generated name left
  outside it makes the next switch refuse, and a hand edit skips the verification the CLI
  performs. Edit the `NETWORK_MODE_*` block instead.
- **Switching while anything is live.** The restart stops and starts `crossbar.service`, so
  every open signalling socket ends and a call in progress drops.
- **`tailscale down`, `tailscale serve reset`, or `RemainAfterExit=yes`.** These cost a
  re-approval, clear routes that are not this deployment's to clear, and stop switches from
  reshaping the box, respectively.
- **Killing the process instead of restarting the unit.** `Restart=always` brings the server
  back; only a restart of the unit runs the shaping units, which is the half of a switch that
  moves Caddy and the tailnet.

### 2.7 Undoing a switch

```bash
node src/admin.js mode private && sudo systemctl restart crossbar
```

If the file itself is broken, restore the copy taken before the last write:

```bash
sudo install -o admin -g admin -m 600 \
  /home/admin/crossbar/data/env.previous /home/admin/crossbar/.env
node src/admin.js mode          # confirm it loads, and which mode is in force
sudo systemctl restart crossbar
```

---

## 3. Runbook: backup and restore

### 3.1 What is backed up, and where

Two things cannot be reconstructed:

- **the database**, `$DATA_DIR/crossbar.sqlite` — device keys, push tokens (VoIP and alert),
  invitations, and the record of who called whom;
- **the directory file**, `$DIRECTORY_CONFIG_PATH`, `data/directory.json` — people, contacts and
  groups: the only thing in the deployment a person typed.

Backups live in `/home/admin/crossbar/data/backups/` (mode 0700):

| Entry | Written by | Kept |
| --- | --- | --- |
| `<UTC stamp>/` holding `crossbar.sqlite` and `directory.json`, both 0600 | `src/backup.js` — from the timer or by hand | newest 14 |
| `crossbar-before-v<N>-<UTC stamp>.sqlite`, 0600 | the server, before it applies a database migration | newest 5 |

The stamp is fixed-width and sorts chronologically: `2026-09-26T09-41-02-123Z`. Each routine
prunes only names it wrote, so a copy you place there yourself is never deleted. The
pre-migration snapshot is **not** a substitute for the daily backup: it only appears when a
migration is about to run.

The database copy uses SQLite's `VACUUM INTO`, never `cp`: this database runs in WAL mode, so
the newest transactions live in `crossbar.sqlite-wal` until a checkpoint and a plain file copy
can silently capture a database several transactions old.

### 3.2 The automatic backup

`crossbar-backup.timer` runs `crossbar-backup.service` daily, with `Persistent=true` so a box
that was off at the scheduled moment runs the missed backup when it comes back.

```bash
systemctl list-timers crossbar-backup.timer     # last run, next run
journalctl -u crossbar-backup -n 20             # what it said
systemctl start crossbar-backup.service         # run one now
```

Nothing here carries the copies off the box. Keeping them somewhere else is the operator's job
and is not automated — see §3.6.

### 3.3 Taking one now, and reading the result

```bash
cd /home/admin/crossbar
node src/backup.js; echo "exit=$?"
```

Real output from a run on the development checkout:

```
{"ts":"2026-09-26T12:25:05.752Z","level":"info","event":"backup.complete","path":".../data/backups/2026-09-26T12-25-05-748Z","databaseBytes":192512,"directoryBytes":993,"pruned":[]}
exit=0
```

One JSON line on stdout, in the logger's shape; `pruned` lists what it removed and is empty
most days. A failure prints `{"level":"error","event":"backup.failed","error":"<why>"}` and
exits non-zero. A failed run leaves nothing behind: a directory holding the database copy but
not the directory file would look like a backup on the worst day of the year.

Run it by hand before anything risky — an upgrade, a switch, a directory edit you are unsure
about. It is safe while the server is running.

### 3.4 Restoring the database

Stop the service, restore as the service account (`admin:admin`, mode 600), delete the stale
write-ahead log, start:

```bash
STAMP=2026-09-26T12-25-05-748Z
sudo systemctl stop crossbar
sudo install -o admin -g admin -m 600 \
  /home/admin/crossbar/data/backups/$STAMP/crossbar.sqlite \
  /home/admin/crossbar/data/crossbar.sqlite
sudo rm -f /home/admin/crossbar/data/crossbar.sqlite-wal \
           /home/admin/crossbar/data/crossbar.sqlite-shm
sudo systemctl start crossbar
node src/admin.js status
```

Each of those three steps matters: restoring under a running server is two databases in one
file; a stale `-wal` beside a replaced database is at best ignored and at worst applied to a
file it does not belong to; and a root-owned file is a server that starts and then fails on the
first request, because the service runs with `UMask=0077`.

Restoring a **pre-migration snapshot** is the same procedure with the file at the top level
instead of in a stamp directory:

```bash
sudo systemctl stop crossbar
sudo install -o admin -g admin -m 600 \
  /home/admin/crossbar/data/backups/crossbar-before-v6-2026-09-26T09-41-02-123Z.sqlite \
  /home/admin/crossbar/data/crossbar.sqlite
sudo rm -f /home/admin/crossbar/data/crossbar.sqlite-wal /home/admin/crossbar/data/crossbar.sqlite-shm
sudo systemctl start crossbar
```

### 3.5 Restoring the directory file

People, contacts and groups come from this file and are re-applied to the database on every
start, so restoring it is restoring the file and restarting:

```bash
sudo install -o admin -g admin -m 600 \
  /home/admin/crossbar/data/backups/$STAMP/directory.json \
  /home/admin/crossbar/data/directory.json
sudo systemctl restart crossbar
```

For a bad edit rather than a disk failure, look first at `data/directory.json.previous`: every
write of the directory file keeps the version before it beside the file, so that is one edit
back.

A directory restore does not touch device keys, and a database restore does not lose people —
the file wins at the next start. Restore both from the same stamp when you can, so the two
agree at the moment they are put back.

### 3.6 What is lost if you do not

- **No database backup** — every device key, push token, invitation and call record. Every
  phone must be enrolled again with a hand-issued code, and cannot be rung while asleep until
  each one files a fresh VoIP token. This is the loss that cannot be repaired from anywhere
  else.
- **No directory-file backup** — the household, as typed. The server will not start without a
  directory file (`No directory file at <path>.`), and refuses one with no people or no active
  administrator. In private mode the console refuses directory edits while any person lacks a
  login, so a damaged file has to be repaired by hand before the console can help.

**Nothing copies the backups off the host, so a lost host loses them with it.** Copy
`/home/admin/crossbar/data/backups/` somewhere else on a schedule you control, and treat the
copies as being as sensitive as the box: they hold every login in the house and every device
key.

---

## 4. Runbook: upgrading and rolling back

### 4.1 The commands that do this

The server repository now has four scripts, each with `--dry-run` (every command printed,
none run):

| Command (in `server/`) | What it is |
| --- | --- |
| `scripts/release.sh [--out DIR]` | builds `crossbar-server-<version>.tar.gz` and the `.sha256` beside it, from a clean tree |
| `scripts/install.sh [--prefix DIR] [--user NAME] [--source DIR] [--with-relay]` | §5 below as one command |
| `scripts/upgrade.sh --from <tarball>` | stop, snapshot, unpack, install, start, verify §4.2's version, roll back if it is not healthy |
| `scripts/uninstall.sh [--prefix DIR] [--user NAME] [--purge-data]` | stop and remove the units; `--purge-data` for the data directory and `.env` |

They are also `npm run release`, `deploy`, `upgrade`, `uninstall` in the server checkout, with
extra arguments after `--`. They do not carry a tarball anywhere (no remote, no SSH — the
transport is the operator's), do not configure Caddy/DNS/ports/firewall/the relay, and do not
copy backups off the box (§3.6). Everything below is what they do, and what to do by hand.

**Nothing here has run on a host with systemd**: the scripts were written and their `--dry-run`
read on macOS, and the rehearsal host is where an install, an upgrade and an uninstall are first
actually executed (`server/deploy/README.md` §2.10 lists what to check).

### 4.2 Where the version is reported

```bash
node src/admin.js status | head -1        # Version           0.1.0
curl -fsS https://<public hostname>/api/health
```

`/api/health`'s `version` is the running process's own — the question the CLI cannot answer,
because the CLI may be a different checkout from the one the service runs. That is the check
after an upgrade: same command, different version.

### 4.3 Upgrading

Two commands. On the machine with the server repository, from a clean tree:
`scripts/release.sh --out /tmp/release`. On the deployment host:

```bash
sudo scripts/upgrade.sh --from /tmp/release/crossbar-server-0.1.0.tar.gz --dry-run   # read it first
sudo scripts/upgrade.sh --from /tmp/release/crossbar-server-0.1.0.tar.gz
```

It stops `crossbar`, snapshots with `src/backup.js` (and starts the old service again and stops if
that snapshot fails), unpacks the tarball beside the running tree and `npm ci`s it there, swaps the
trees while carrying `data/` and `.env` across — the tarball carries neither — reinstalls the units
rendered for this host, starts, and requires `/api/health` (§4.2) to answer with the version in the
tarball. Anything else is an automatic rollback (see §4.5); the replaced tree is kept at
`/home/admin/crossbar.previous` so a rollback later is possible too.

**An upgrade is not a switch, as far as a phone is concerned.** `origin` does not change (same
`.env`, same mode), so the app's follow-the-server path (§1, §2.4) has nothing to follow, and the
device key is untouched. What an upgrade *does* do is restart the service, which ends every open
signalling socket — the same fact §2.6 lists for a switch, for the same reason — so do it when
nobody is on the phone.

By hand, or when watching a step:

```bash
cd /home/admin/crossbar
node src/admin.js status                  # note the version, and that the box is healthy
node src/backup.js                        # a copy you can go back to
git status --porcelain                    # empty: local edits are how an upgrade goes wrong
git log --oneline -3

# bring the new code in — the software cannot see how, and there is no remote configured
# in the checkout this was written in (git pull / git bundle / rsync are all operator choices)
git pull

npm ci --omit=dev
node src/admin.js mode                    # the .env still loads cleanly
node src/admin.js doctor                  # if the server is up
sudo systemctl restart crossbar
node src/admin.js status                  # the version changed
journalctl -u crossbar -n 50 --no-pager
```

**A code update does not install the units; `scripts/upgrade.sh` does.** If `deploy/*.service`
changed and you are installing by hand, re-install them and reload:

```bash
sudo install -m 644 deploy/crossbar.service deploy/crossbar-public.service \
                    deploy/crossbar-private.service deploy/crossbar-backup.service \
                    deploy/crossbar-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart crossbar
```

Node must be 22.5.0 or newer (`node --version`); the server uses `node:sqlite`.

### 4.4 The pre-migration snapshot

A running server whose database is behind the newest migration snapshots it before applying
anything, to `data/backups/crossbar-before-v<N>-<stamp>.sqlite`, keeping the newest 5. If the
snapshot cannot be written, the start is refused (`Refusing to migrate to v6 without a
snapshot: <why>`) — a deployment that is down but intact rather than one that may be neither.
A fresh install gets none, because a database with no tables protects nothing. So after a
failed upgrade, `ls -lt data/backups/` answers the important question: a new
`crossbar-before-v*` file means the new build migrated the database, and §3.4's second
procedure is the way back.

### 4.5 Rolling back

`scripts/upgrade.sh` does the order below by itself, the moment the new build does not answer
`/api/health` with its own version: the previous tree comes back from
`/home/admin/crossbar.previous`, the database from the snapshot taken before anything was replaced,
the previous units are reinstalled, and the service is started and checked again. It reports what
it did and exits non-zero, and leaves the tree that failed at
`/home/admin/crossbar.failed-<stamp>` for the journal and the diff.

The same order by hand, for a failure that shows up later:

1. **The code** — `git checkout <the commit you came from>`, `npm ci --omit=dev`,
   `sudo systemctl restart crossbar`, `node src/admin.js status`.
2. **The units**, if they changed — copy the previous files back, `daemon-reload`, restart.
3. **The database**, if it was migrated — restore the `crossbar-before-v*` snapshot (§3.4).

Migrations are forward-only: there is no down-migration, and an older build is not promised to
read a file a newer one migrated. Restoring the snapshot loses everything recorded since —
calls, enrolments, tokens — which is why the snapshot is taken before the migration rather
than after. Test the rollback you intend to rely on before you need it.

### 4.6 Removing a deployment

```bash
sudo scripts/uninstall.sh --dry-run          # the units it would remove, and nothing else
sudo scripts/uninstall.sh
```

It stops and disables the units, removes them from `/etc/systemd/system` and the relay's rendered
template from `/etc/crossbar/`, and reloads systemd. It leaves the checkout, `.env` and `data/` —
the database, the directory file and the backups — and says so, so the units can be put back by
installing again. `--purge-data` also deletes `data/` and `.env`, names both first, and refuses
unless the prefix looks like a Crossbar checkout. **Take the two things in §3.1 off the machine
before either**, because that is the only place they exist (§3.6).

By hand it is the same sequence: `sudo systemctl disable --now crossbar crossbar-backup.timer
crossbar-turn` (the two mode units have no `[Install]` and are reached through `crossbar`), remove
the unit files, `daemon-reload`, then delete the checkout and `data/` yourself.

---

## 5. Installing a second household

The host-side steps are in `server/deploy/README.md` §2, verbatim for the commands.
`server/scripts/install.sh` is steps 1–7 as one command — `--dry-run` first, then the real run as
root — and it renders the unit paths for `--prefix`/`--user` instead of leaving them to edit. What
it does not do is 8 and 9: Caddy, DNS, the port forwards and the firewall are host facts, and the
first phone is a conversation with a person. In the order they have to happen:

1. **A host with systemd** and an account that owns the checkout. Everything ships assuming
   `admin` and `/home/admin/crossbar`; a different user or path is what `install.sh --prefix …
   --user …` renders into the units — `User=`, `Group=`, `WorkingDirectory=`,
   `EnvironmentFile=`, `ReadWritePaths=`, the two mode units' `ExecCondition` greps and their
   grace-window `systemd-run` lines, and `/etc/crossbar/coturn.conf` in the relay unit.
2. **Node 22.5.0 or newer.** `node --version`. There is no build step.
3. **Clone and install dependencies**: `sudo -u admin git clone <repository>
   /home/admin/crossbar && cd /home/admin/crossbar && npm ci --omit=dev`.
4. **`.env`**: `cp .env.example .env`, `chmod 600`, then `HOST=127.0.0.1`, `PORT=3003`,
   `DATA_DIR`, `DIRECTORY_CONFIG_PATH`, `WEB_ROOT`, `CROSSBAR_SESSION_SECRET`
   (`openssl rand -hex 32`), and both mode blocks (`NETWORK_MODE_PRIVATE_*`,
   `NETWORK_MODE_PUBLIC_*`). Optionally the switch window, `CROSSBAR_SWITCH_GRACE_SECONDS`
   (seconds, default 900) — it is not in `.env.example`. Do not write the generated section
   between the markers by hand, and do not leave a copy of any of its names elsewhere in the
   file.
5. **The directory file — required.** `cp data/directory.example.json data/directory.json`,
   `chmod 600`, at least one person and one of them `"admin": true`. Without it the server does
   not start: `No directory file at /home/admin/crossbar/data/directory.json.` Then
   `node src/admin.js password` for the console.
6. **Units**: `crossbar.service`, `crossbar-public.service`, `crossbar-private.service`, the
   backup pair, and (if this deployment relays media) `crossbar-turn.service` +
   `/etc/crossbar/coturn.conf`. Install, then **`sudo systemctl daemon-reload`** — without it
   the mode units are not live and the box has no front door —
   `sudo systemctl enable --now crossbar` and `enable --now crossbar-backup.timer` (the timer,
   not the service).
7. **Check it**: `node src/admin.js mode`, `status`, `doctor`. `doctor` prints one `OK`/`FAIL`
   line per check and exits 0 only when every line is `OK`; the shapes are in
   `server/deploy/README.md` §6.
8. **Public mode only**: the Caddy drop-in that gives Caddy the same `.env`
   (`systemctl edit caddy` → `EnvironmentFile=/home/admin/crossbar/.env`), the `Caddyfile` at
   `/etc/caddy/Caddyfile`, the DNS record, the port forwards and the firewall rules. The last
   three are **host facts the software cannot see** — documented in `server/deploy/README.md`
   §8, including how to tell whether the ISP puts the connection behind CGNAT, which makes
   public mode infeasible on IPv4 no matter what the router is told.
9. **The first phone**: `node src/admin.js enroll --user <id>` prints the invitation once. The
   payload carries `server` (the address), `mode` and `enrollment_token`; the app configures
   itself from the mode, so the person holding the code does not have to know which of the two
   this deployment is. For a phone that must ring while asleep, configure APNs — `status` says
   so plainly when it is missing.

A second household that inherits this deployment's backups inherits every device key in it:
enrol the new household's phones against the new server, and do not copy `data/` from one
deployment to another unless that is exactly what is intended.

---

## 6. Where the rest is written down

| Question | Document |
| --- | --- |
| Host-side runbooks, DNS, ports, firewall, coturn, CGNAT | `server/deploy/README.md` |
| The wire contract the app relies on | `CURRENT_CLIENT_CONTRACT.md` |
| Signalling, security model, architecture | `CROSSBAR_SIGNALING_PROTOCOL.md`, `CROSSBAR_SECURITY_MODEL.md`, `CROSSBAR_SERVER_ARCHITECTURE.md` |
| How this deployment was actually reached | `CROSSBAR_SERVER_IMPLEMENTATION.md`, `QATAR_DEPLOYMENT_AUDIT.md` |
