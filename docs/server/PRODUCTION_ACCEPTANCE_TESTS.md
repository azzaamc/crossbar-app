# Production acceptance tests

What to run against the **deployed** system to establish that Crossbar works where it actually
lives — the VPS, with its real Tailscale node, Caddy, DNS and relay, and the app on a real phone.
The suite and the rehearsal host prove a great deal (165 tests; 38 rehearsal checks) but neither
can reach a public front door, a real certificate, a routable hostname or a live phone. This
document is the part that can only be done on the deployment itself.

Two things it is for: **the changes just made** (durability, mode completeness, visibility,
distribution, the app following a moved server), and **the product criteria** — can this be
packaged, distributed, installed, configured and operated by somebody who is not its author.

## How to read this

- **Tier** decides the risk. T0 changes nothing; T1 runs on production while the family is using
  it; T2 switches the deployment's mode and is the only tier that can interrupt a call; T3 needs a
  host that can be thrown away.
- Every test states **what it establishes** and **what counts as passing**. A test with no failure
  mode is not a test.
- **A skip is not a pass.** Record skips explicitly, with the reason, or the report lies by
  omission.
- Keep the evidence: the command, its output, and the criterion it settles. The value of this
  document is in what it can show afterwards.

---

## T0 — Reconnaissance (read-only, no window)

Establish what this deployment can even test. Measured 2026-09-26:

| what | state | why it matters |
|---|---|---|
| `caddy` binary + unit + `override.conf` drop-in with `EnvironmentFiles=…/crossbar/.env` | present, unit disabled | the entire public-mode plumbing is already installed on this box |
| `call.azzaamc.com` | resolves to `186.240.159.17` this box | a real hostname with real DNS, so Caddy can get a real certificate |
| port 80 | free | ACME HTTP-01 needs it |
| port 443 | held by `tailscaled` on the **tailnet** address only | Caddy can bind 443 on the **public** address; the two coexist |
| `NETWORK_MODE_PUBLIC_*` in `.env` | **absent** | a switch to public would be refused; this is the one thing to add |
| relay | `call.azzaamc.com:3478`, reaching coturn | the relay is real and the mode shapers now move it |

Re-run with: `grep -E '^(NETWORK_MODE_PUBLIC|CROSSBAR_PUBLIC_HOSTNAME|PUBLIC_ORIGIN|CROSSBAR_BIND_ADDRESS)' .env`,
`getent hosts call.azzaamc.com`, `ss -lntp | grep -E ':(80|443)'`, `systemctl show caddy -p EnvironmentFiles --value`.

---

## T1 — Non-disruptive, on production, while it is in use

None of these change the running mode or interrupt a call.

### 1. The doctor, as the deployment account
`sudo -u admin node src/admin.js doctor`
**Establishes:** the configuration, directory file, data directory, listener, mode's own front door
and configuration surface are all sound. **Passes when:** every line is OK or warned, with the
reason named. The private-mode reachability line must read **OK** — it asks the loopback listener,
and a running server answers there.

### 2. The backup is usable, not merely present
Take a real backup (`systemctl start crossbar-backup`), then restore it **into a scratch directory**
and read it back:
- the copied database opens, and `SELECT COUNT(*) FROM users` matches the live one;
- the directory file inside the backup has every login the live one has;
- both are mode 0600, owned by the deployment account.
**Establishes:** the artefact that exists in order to be used can be used. **Passes when:** a
restored copy answers real questions. A backup nobody has ever opened is a file, not a backup.

### 3. A migration cannot run without its snapshot
Copy the database to a scratch directory, `PRAGMA user_version = <latest − 1>`, start a server
against that copy.
**Establishes:** the one irreversible operation is guarded. **Passes when:** a
`crossbar-before-v<N>-*.sqlite` appears beside it, the row counts are unchanged, and the server is
healthy afterwards. And when the backup path is made unwritable, the server refuses to start
**without** migrating.

### 4. The installer, over its own work
`sudo bash scripts/install.sh` against the live prefix.
**Establishes:** it is idempotent and it does not eat the deployment. **Passes when:** `.env` is
untouched (it must never overwrite one), the rendered units are byte-identical to the installed
ones at the default prefix, the service is healthy afterwards, and the backup timer is still
enabled. Then `--dry-run` with a different `--prefix`/`--user` and confirm it would touch nothing
real.

### 5. An upgrade to the same version is a no-op that still snapshots
`sudo bash scripts/upgrade.sh --from <the released tarball>`
**Establishes:** the upgrade path is safe before it is needed. **Passes when:** it takes a
snapshot, deploys, verifies `/api/health` says the same version, and reports what it did. Then
break it deliberately — point `--from` at a corrupt tarball — and confirm it puts the previous tree
back and says so.

### 6. The console surfaces (needs the operator's password)
In a browser at `/admin`: the Version card; the sheet of people; and the **unlisted** section,
which should be empty. Then mint a person through the network without adding them to the file —
`curl -H 'Tailscale-User-Login: probe@example.com' https://<origin>/api/session` — and reload.
**Establishes:** an identity that exists but is not in the directory file is visible to the person
who administers it, instead of invisible. **Passes when:** the probe appears as unlisted, and is
gone from that list (either as a real person or by removing the device) once dealt with.

### 7. Reporting is coherent
`/api/health`'s `version` = `node src/admin.js status`'s = the release tarball's name = the
package's. **Establishes:** an operator can answer "which build is this" three ways and get one
answer.

---

## T2 — The real switch, in a window (the only place the public half exists)

This is the test the VPS exists for, and the one the whole overlap design was built for. It must be
chosen deliberately, not slipped in: while in public mode, anybody reaching the box over the
tailnet alone is outside, and the grace window decides how long both doors are open.

### Preconditions
1. **The public block, in `.env`** — this is the one missing thing. `call.azzaamc.com` already
   resolves here and 443 is free on the public address, so it can be reused; or a new name can be
   pointed at the box. Fill in:
   `NETWORK_MODE_PUBLIC_HOSTNAME=<the name>`, `NETWORK_MODE_PUBLIC_ORIGIN=https://<the name>`,
   `NETWORK_MODE_PUBLIC_BIND_ADDRESS=<the public address>`.
2. **A grace window**, chosen rather than defaulted: `CROSSBAR_SWITCH_GRACE_SECONDS` (900 by
   default). For a test, five minutes is enough to watch the overlap and follow it.
3. Backups taken: the database, `.env`, the directory file, and a tarball of the working tree.
4. **Their phone awake**, on the build that follows a move, with somebody able to watch it.
5. Two vantage points: a machine **on** the tailnet (the Mac) and one **off** it (a phone hotspot or
   any outside shell) — the overlap only means something if both doors are watched at once.

### The switch, and what to watch

| # | watch | establishes | passes when |
|---|---|---|---|
| 1 | `mode public`, then the restart | the file is the only input | `status` says public; the generated section is correct; nothing outside it moved |
| 2 | `curl -sI https://<the name>/api/health` **from off the tailnet** | real TLS, real DNS, real ingress | HTTP 200, a certificate that validates, `mode` = public |
| 3 | the phone | **the app follows a moved server** | the log shows the old address → the new one, `deviceId` unchanged, and the person sees it followed rather than a failure |
| 4 | `tailscale serve status` from on the tailnet, immediately | the overlap | the tailnet door is **still open** right after the switch |
| 5 | the same, after the grace | the close is real | the tailnet door is gone; and the box never had *neither* door open |
| 6 | a tailnet header sent to the public origin | the trust posture moved with the mode | the header is ignored; a device key is required |
| 7 | a call, placed and answered | the whole thing still works | it connects; the relay is used when direct media fails |
| 8 | `mode private` and the reverse | a switch survives being done twice | the phone follows back; Caddy stays through the grace, then stops; the tailnet door returns |

### Rollback
Backups from the preconditions, plus the tree tarball. `mode private` and a restart is the
immediate reversal and needs no restore at all — which is the point of the file being the only
input.

---

## T3 — The product criteria, on a host that can be thrown away

The rehearsal guest is the "second household". Nothing here touches production.

### 8. Install from the artefact, not from a checkout
`npm run release` on the workstation → copy the tarball → verify its checksum → unpack → **install
from that directory**, on a host with nothing but Debian and systemd.
**Establishes:** it can be distributed. **Passes when:** the only hand-written file is the
directory file, and `doctor` passes afterwards. Anything an operator has to know that is not in the
installer's output or `deploy/README.md` is a finding, not a shortcut.

### 9. Upgrade and roll back
Install version A, then upgrade to a built version B, then use `upgrade.sh`'s rollback (or restore
the previous tree).
**Establishes:** a deployment can be moved forward and back. **Passes when:** both versions come up
healthy, the data survives, and the rollback is one command.

### 10. Uninstall
`uninstall.sh` without `--purge-data`.
**Establishes:** removal is safe by default. **Passes when:** units and the timer are gone, the
service stops, and the data directory and `.env` are **still there** and named in the output. Then
`--dry-run --purge-data` and confirm it says exactly what it would delete.

### 11. The operations criteria
- **The backup timer fires**: `systemctl start` it and see a new dated directory; then watch one
  fires on its own.
- **Logs survive**: the journal's contents across a restart; and what an operator sees when the
  service is deliberately broken (a corrupt `.env`, a missing directory file) — each must produce a
  sentence naming the cause, not a stack.
- **The first-run preflight fails usefully**: on a bare host, `doctor` must report *every* missing
  thing and exit non-zero without throwing.

---

## T4 — The app criteria

### 12. A move, on the simulator, before it is a move on the phone
Already done once: a stub server whose `/api/health` reports a different `origin`, with the app's
stored address pointed at the old one. **Passes when:** the log shows the adoption with `deviceId`
unchanged. Cheap to repeat, and it is the dry run for T2's third row.

### 13. What a person sees
On the phone, during T2: not a spinner, not a failure — the move, named. If it shows a failure
banner, that is a finding even if the move worked underneath.

---

## Reporting

For each test: what ran, what it printed, what it established, and what was skipped with the
reason. The failures worth having are the ones this document is designed to produce — a
deployment whose tests all pass has usually not been tested hard enough.
