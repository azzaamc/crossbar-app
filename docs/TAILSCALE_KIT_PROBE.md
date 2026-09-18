# The embedded Tailscale node (branch `tailscale-kit`)

This branch asks whether Crossbar can carry its own tailnet, so that a family member
never has to install the Tailscale app and keep it signed in.

It is deliberately isolated: branch `tailscale-kit`, cut from `architecture-b` at
`7462de8`. Nothing here is on the product branch, and reverting is `git checkout
architecture-b` plus deleting `Vendor/` and `Scripts/` — no other branch depends on
either.

**Status: the node is authorised and running on the physical iPhone as `crossbar-ios`,
and it carries both halves of the wire contract — the Family Call control plane
including Serve's injected identity, and the MiroTalk signalling WebSocket. A first run
presents a Tailscale login page and needs no auth key anywhere. It also survived a
genuine suspension: backgrounded for 150 s, frozen by iOS, then resumed as the same
process, and the cached loopback still carried both checks.**

**It now carries a real call.** Two native peers joined one MiroTalk room with both
sockets dialled through the node's loopback, negotiated, and carried ~33 MB of video
each way; the node's own peer counters — the only evidence that says *which* carrier
moved the bytes, because the system Tailscale app is also installed on this phone —
went from zero to ~86 KB at the moment the socket connected. So the signalling path is
proven, not just the transport. **Repeated with the system Tailscale app disconnected,
which is the decisive version**: with that tunnel down the phone has no route to
`100.64/10` at all, and the call completed anyway, ~22 MB each way.

**The node carries signalling and nothing else.** It has no network interface, so
libwebrtc cannot offer an ICE candidate on the overlay: the node's own address never
appears among the candidates gathered in these runs, while the *system* Tailscale
tunnel's does — until the system app is disconnected, at which point the candidate list
contains no tailnet address at all and the call still completes. Media rode the phone's
Wi-Fi host pair. That is not a defect in the run; it is what an embedded userspace node
can and cannot do, and it is the finding that shapes the product question at the end of
this document.

## What TailscaleKit is, and why it is not committed

`TailscaleKit` is Tailscale's BSD-3-Clause Swift wrapper around `libtailscale`, which
is `tsnet` — the Tailscale client as a Go library — compiled to a C archive. It runs
entirely in userspace: no Network Extension, no packet-tunnel entitlement, no
`NEPacketTunnelProvider`. That is the whole reason it is viable for an App Store app.

It is built from a checkout of `github.com/tailscale/libtailscale`, pinned at
`59d4bb8` (`build: let the environment override MACOS_TARGET`, 2026-08-31), clean with
no local modifications. The upstream tree is **not** vendored into this repository: it
is a large tree pinned by commit, not by copy, and copying it would obscure which
revision is inside the binary.

```bash
./Scripts/build-tailscale-kit.sh            # → Vendor/TailscaleKit.xcframework
LIBTAILSCALE_SRC=/path/to/libtailscale ./Scripts/build-tailscale-kit.sh
```

The output is ~70 MB (device arm64, minOS 18.1; plus an arm64+x86_64 simulator slice)
and `Vendor/` is gitignored. **A fresh clone of this branch does not build until that
script has been run once.**

Two notes on the script, both of which cost time to find:

- `xcodebuild -create-xcframework` under Xcode 27 exits 70 reporting
  *"TailscaleKit.framework couldn't be copied to ios-arm64_x86_64-simulator because an
  item with the same name already exists"* — **after** writing a complete, correct
  framework. The script therefore does not trust that exit code; it validates the
  artifact instead (slice binaries present, `Info.plist` lints), so a genuine failure
  still stops the build.
- The Go side needs `GOEXPERIMENT=nojsonv2`. Some Go 1.27 toolchains enable json/v2, and
  libtailscale's dependency graph does not build under it; the failure surfaces as
  unrelated errors deep in `encoding/json`.

## How it is wired into the project

Four edits to `Crossbar.xcodeproj/project.pbxproj`, all on the `Crossbar` app target:

| Change | Why |
| --- | --- |
| `PBXFileReference` + a `Vendor` group | the xcframework, resolved relative to the source root |
| `PBXBuildFile` in the existing `Frameworks` phase | links `@rpath/TailscaleKit.framework/TailscaleKit` |
| a new `PBXCopyFilesBuildPhase` (`dstSubfolderSpec = 10`, "Embed Frameworks") | puts the framework in the bundle; the framework ships unsigned and must be signed on copy, hence `CodeSignOnCopy` |

Verified at the binary level, not by "it compiles":

```
$ otool -L Crossbar.app/Crossbar.debug.dylib | grep Tailscale
	@rpath/TailscaleKit.framework/TailscaleKit (compatibility version 1.0.0, …)

$ nm -u Crossbar.app/Crossbar.debug.dylib | grep -c TailscaleKit
16          # statusJSON, up, close, LoopbackConfig.address, the initialiser, …

$ codesign --verify --deep --strict Crossbar.app   # exit 0
```

(Debug builds put the app's code in `Crossbar.debug.dylib`; the `Crossbar` binary
itself only links that dylib, so checking `Crossbar` alone shows no TailscaleKit.)

## The instrument

`Crossbar/Prototype/TailscaleProbe.swift`, `#if DEBUG`, following the conventions of
the other probes: a `DisclosureGroup` section in `ProbeView`, and output to
`Documents/tailscale.log` because screen-only output has already cost measurements.
The node's own Go log goes to `Documents/tailscale-node.log` on its own file
descriptor — the Go runtime writes it from its own threads, so interleaving it into the
probe's line buffer would corrupt both.

It starts a node, polls `statusJSON()`, performs the same two checks the macOS spike
did (HTTP to `/api/session` and the Engine.IO handshake) through the node's SOCKS
loopback, and re-checks automatically on `didBecomeActive`.

It is also the node's *carrier*, which is what the call measurement needed and what the
product will need next. Three entry points, all DEBUG-only for now:

- `runningNode()` — waits for the bring-up, shared, so a caller that arrives mid-`up()`
  never dials a loopback the node has not opened yet (the autostart path and a peer
  joining at launch are exactly that race).
- `proxiedSession()` — a `URLSessionConfiguration` that leaves through the node, with the
  loopback it dials returned alongside, because `proxyVia` writes the address into the
  configuration and nothing reads it back out: without it, a node-carried session and a
  direct one are indistinguishable in a log.
- `logNodeTraffic()` — the node's own peer counters, read from the raw status JSON
  (`Status.Peer` drops them), reported as deltas. This is the only evidence that says
  *which* carrier moved the bytes while the system Tailscale app is also installed.

`MiroTalkSignalClient` takes the first two as a `Transport` — a configuration and the
label naming its carrier, so a log line cannot claim a route the socket did not take.

The re-check runs `refreshStatus()` *before* `check()` on purpose. `statusJSON()` goes
through tsnet's in-memory LocalAPI and never touches the loopback, so if the status
still reports a running backend while the request fails, the node is alive and only the
cached loopback address has gone stale — see the constraint below.

### Driving it without a human

The node cannot be started by a button when nobody can press one, and the interesting
measurement is what happens across a suspend — when nobody can press one by definition.
So it follows the pattern already in this codebase (`CROSSBAR_CALLKIT_SELFTEST`,
`CROSSBAR_AUTOLOAD`, `CROSSBAR_SIGNAL_AUTOROOM`):

```bash
xcrun devicectl device process launch --device <id> --terminate-existing \
  -e '{"CROSSBAR_TAILSCALE_AUTOSTART":"1"}' \
  com.abdullahchaudhry.Crossbar

xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier com.abdullahchaudhry.Crossbar \
  --source Documents/tailscale.log --destination /tmp/tailscale.log
```

`TAILSCALE_AUTH_KEY` is also read from the environment, and an auth key can be stored
in the app's defaults from the probe screen, so a fresh node can be authorised either
interactively or non-interactively. **No key is compiled in and none belongs in this
repository.**

Note that `xcodebuild`'s build-destination connection to this phone fails while
`devicectl` installs to the same phone without complaint, so build with
`-destination 'generic/platform=iOS'` and install with `devicectl`.

## Evidence

Recorded on the physical iPhone 17 Pro, iOS 27.0, 2026-09-18.

**The node runs on iOS, in userspace, in the app sandbox.** From
`Documents/tailscale-node.log`:

```
[v1] using fake (no-op) tun device
Creating WireGuard device...
Bringing WireGuard device up...
HostInfo: {"IPNVersion":"1.94.1-dev20260831-t59d4bb827","OS":"iOS","App":"libtailscale",
           "Package":"tsnet","GoArch":"arm64","GoVersion":"go1.27.1-X:nojsonv2",
           "Userspace":true,"UserspaceRouter":true,"StateEncrypted":true}
Start: updated prefs: Prefs{… host="crossbar-ios" …}
generating new machine key
machine key written to store
control: control server key from https://controlplane.tailscale.com: ts2021=[fSeS+], legacy=[nlFWp]
control: RegisterReq: onode= node=[mLrR6] fup=false nks=false
```

So: tsnet builds a WireGuard device with a no-op TUN, writes a machine key, and reaches
the Tailscale control plane over the network from inside the app. That much is answered.

**It did not stop there — the node completed registration and reached `Running`.** The
node's own log records the whole lifecycle:

```
Switching ipn state NoState -> NeedsLogin (WantRunning=true, nm=false)
control: AuthURL is https://login.tailscale.com/a/…          ← redacted; single-use
Switching ipn state NeedsLogin -> Starting (WantRunning=true, nm=true)
peerapi: serving on http://100.121.218.110:60167
magicsock: home is now derp-23 (dbi)
Switching ipn state Starting -> Running (WantRunning=true, nm=true)
magicsock: derp-23 connected; connGen=1
netcheck: [v1] report: udp=true v6=false v4a=119.154.255.67:62365 derp=23
          derpdist=3v4:97ms,20v4:152ms,23v4:39ms
```

So the node has a tailnet address (`100.121.218.110`, `fd7a:115c:a1e0::d12d:da6f`), a
working DERP relay 39 ms away, and UDP with a reflexive endpoint — all inside the app
sandbox, in userspace, with no entitlement.

**The control plane works through the node.** This is the finding that matters most,
because it is the one that could have invalidated the whole approach. The check runs
through the node's SOCKS loopback, not `URLSession.shared`:

```
loopback=127.0.0.1:57421
HTTP 200
authenticated=true identity=Azzaam Chaudhry
```

Family Call's Serve injected `tailscale-user-login` for a request that originated from
an embedded userspace node inside an iOS app, and the service resolved it to the
enrolled member. Identity survives the change of transport, with no `Origin` header and
no backend change.

**MiroTalk signalling works through the node.** The same session carried the WebSocket,
and the Engine.IO handshake came back on the first frame:

```
ws first frame: 0{"sid":"vKRzlDNlFm31LnrPAACn","upgrades":[],"pingInterval":25000,…}
signalling handshake OK
```

Both halves of the wire contract therefore survive being carried by the embedded node.

**A call completes over the node (2026-09-18).** The Engine.IO handshake said the socket
worked; a call says the path does. Two native peers (A and B, the same pair the
signalling instrument already runs) joined one room with **both** sockets dialled
through the node's loopback, and the whole exchange ran on it — admission, `addPeer`,
the offer policy, SDP relay, ICE relay, and media:

```
connecting wss://qatar-vpn.tailea67b0.ts.net/socket.io/?EIO=4&transport=websocket via embedded node 127.0.0.1:57650
engine.io open {"sid":"FczYcUzIdoGvSNTaAACt","upgrades":[],"pingInterval":25000,…}
emit join channel=crossnode3
addPeer 9-iX9gn2 should_create_offer=false iceServers=1
answer -> 9-iX9gn2 (3771 chars, 2 m-lines (audio,video))
pc state -> 2 [9-iX9gn2]
ice state -> 2 [9-iX9gn2]
media IN <- 9-iX9gn2 video bytes=33107200 delta=940486 energy=0.000
```

Both peers reached `pc state -> 2` and `ice state -> 2`, each received the other's
video, and each measured ~33 MB inbound by the end of the window. The instrument that
produced this is the same `SignalProbeSection` as before, with one added toggle:
`Transport` on the signalling client is now a configuration *and* the label that names
its carrier, so a log line cannot claim a route the socket did not take
(`CROSSBAR_SIGNAL_VIANODE=1` drives it without a hand).

**Which carrier moved those bytes (2026-09-18).** A working socket proves a working
route, not *which* route — this phone also has the system Tailscale app installed and
connected, so both carriers are live at once, and the run above would have looked
identical had `URLSession` ignored the proxy. The node's own peer counters settle it:
they belong to the node's WireGuard state and cannot move for traffic it did not carry.
The typed `Status.Peer` omits the byte counters, so the probe reads the raw JSON:

```
node traffic [before connecting] — nothing carried; peer fields: …,RxBytes,…,TxBytes,…
node traffic [during call] — qatar-vpn rx=47212(+47212) tx=38980(+38980)
node traffic [during call] — qatar-vpn rx=47628(+416) tx=39460(+480)
node traffic [during call] — qatar-vpn rx=48044(+416) tx=39980(+520)
```

Zero before the socket connects; ~86 KB to `qatar-vpn` (100.77.42.16) the moment it
does; then +416/+520 every 20 s, which is Engine.IO's 25 s ping and its pong.

**The control run (2026-09-18).** The same app and the same room with the sockets
dialled directly, system Tailscale app still disconnected:

```
connecting wss://qatar-vpn.tailea67b0.ts.net/socket.io/?EIO=4&transport=websocket via direct
receive failed: A server with the specified hostname could not be found.
node traffic [during call] — qatar-vpn rx=628(+628) tx=452(+452)
```

It settles two things. The direct path could not even **resolve** the name without the
system client — `NSURLErrorCannotFindHost`, not a timeout — which is what makes the
node-carried run's resolution a finding rather than something the OS resolver had already
done for it. And the node's counters stayed at that housekeeping level (~600 bytes, its
own peer handshake traffic to `qatar-vpn`) for the whole run instead of jumping by ~47 KB,
so the growth in a routed run is the call and nothing else. It also corrects the sentence
above: the baseline is not always zero — the node's own peer traffic appears there once it
has a path — so the tell is the magnitude at connect, not zero-versus-nonzero.

**The node carries signalling, not media (2026-09-18).** This is the part that had to be
measured rather than assumed, and the answer is structural. The node has no interface —
its own log says `using fake (no-op) tun device`, and its HostInfo reports
`"Userspace":true,"TUN":false`. libwebrtc gathers ICE candidates from interfaces, so it
cannot offer anything on the overlay. In the run above, 55 candidates were gathered and
the node's own address never appeared among them:

```
169.254.210.170   192.168.1.120   192.0.0.6   10.187.100.156
100.88.61.34      fd7a:115c:a1e0::9a32:3d22   fd74:6572:6d6e:7573:{c,d}:…
```

`100.88.61.34` and its `fd7a:115c:a1e0::9a32:3d22` are the **system** Tailscale app's
tunnel, which does install a utun — and `100.121.218.110`, `crossbar-ios`'s own address,
is absent. Whatever carries media here, it is not the embedded node. The selected pair
was the phone's own Wi-Fi address in both directions:

```
ICE path [T01] local=host 192.168.1.120:62514/udp remote=host 192.168.1.120:63271/udp state=succeeded bytesSent=8152949
```

The framework offers no way around this either, which matters before anyone plans on it.
Its only transport surface is the `URLSession` SOCKS proxy plus tsnet TCP/UDP dial and
listen (`Listener`, `OutgoingConnection`) — both TCP/stream and packet APIs, but nothing
that a WebRTC peer connection accepts. WebRTC 153.0.0 (`stasel/WebRTC`) exposes no
pluggable packet transport in its Objective-C API. So the media path stays whatever ICE
finds: the LAN, or the server-supplied STUN path measured earlier, which is exactly the
path it took *with* the system app too — the overlay was never nominated even then.
Carrying media over the overlay from an embedded node is a subsystem, not a
configuration: a local TURN server for libwebrtc to talk to on loopback, bridged to the
tailnet through tsnet's socket API.

**And it does so with the system Tailscale app disconnected (2026-09-18).** This is the
run that closes the argument, because with that tunnel down the phone has no route to
`100.64/10` at all: whatever completes, completes through the node. The same call
completed:

```
connecting wss://qatar-vpn.tailea67b0.ts.net/socket.io/?EIO=4&transport=websocket via embedded node 127.0.0.1:57748
engine.io open {"sid":"7pyaK49ZQrYHsryOAAC0","upgrades":[],"pingInterval":25000,…}
emit join channel=crossnode5
addPeer nVZHrx3L should_create_offer=true iceServers=1
offer -> nVZHrx3L (3912 chars, 2 m-lines (audio,video))
answer <- nVZHrx3L (3771 chars, 2 m-lines (audio,video))       ← the other native peer
pc state -> 2 [nVZHrx3L]
ice state -> 2 [nVZHrx3L]
media IN <- nVZHrx3L video bytes=22124347 delta=941770 energy=0.000
ICE path [T01] local=host 192.168.1.120:52900/udp remote=host 192.168.1.120:49155/udp state=succeeded bytesSent=23045598
```

Both peers carried ~22 MB of video, and the node's counters moved by the same ~79 KB as
before (`qatar-vpn rx=43852(+43852) tx=35396(+35396)`). Two things follow that the
system-app-on runs could not show. **The name was resolved and the Serve certificate
validated with no MagicDNS anywhere on the phone** — the control run above settles that
this is the node's doing rather than the OS resolver's, because with the same configuration
the direct path fails to resolve the name at all while this one completes a call. And the
gathered candidates contained **no tailnet address of any kind**:

```
10.187.100.156   169.254.210.170   192.0.0.6   192.168.1.120
fd60:5c57:bcb1::1   fd74:6572:6d6e:7573:c:…   fd74:6572:6d6e:7573:d:…
```

`100.88.61.34` and `fd7a:115c:a1e0::9a32:3d22` are gone with the system client, and
`100.121.218.110` was never there. The call is over the node; the media is not, and
cannot be.

**It also survives suspension.** This was the measurement that decides whether the
approach is usable for a call app, and it is the one upstream gave reason to fear: the
node's own comment on `statusJSON` says the OS reclaims the loopback TCP listener from
a suspended process on iOS, "where the cached loopback address goes permanently stale",
and `loopback()` caches the address with no way to invalidate it.

Backgrounding the app by launching another one, leaving it **150 seconds** so iOS
genuinely froze the process, then resuming it (`devicectl device process launch` without
`--terminate-existing`, so the same process came back — the pid did not change):

```
— didEnterBackground —
— willEnterForeground —
— didBecomeActive, re-checking through the node —
— check —
loopback=127.0.0.1:57421
HTTP 200
authenticated=true identity=Azzaam Chaudhry
ws first frame: 0{"sid":"ubQgn7rv3usguRP2AACo","upgrades":[],"pingInterval":25000,…}
signalling handshake OK
```

Three things follow, and the distinction between them matters:

- **The cached loopback address still worked.** It is the same `127.0.0.1:57421` as
  before the suspend — `loopback()` handed back its cached value, and that value was
  still live. So the listener was not reclaimed in this instance.
- **The node never re-registered.** No new `Switching ipn state` lines appear after the
  resume, and the status poll reported no change, so the node stayed `Running`: its
  control connection and DERP relay came back with the process.
- **The signalling socket was re-established and got a new session id**
  (`ubQgn7rv3usguRP2AACo`, against `vKRzlDNlFm31LnrPAACn` earlier). The old socket did
  not survive the freeze — consistent with what the signalling instrument already showed
  about suspended WebSockets — but a fresh one worked immediately through the same
  node. A call that resumes must therefore re-establish its socket, which it would have
  to do anyway.

**This does not disprove upstream's warning, and should not be read as doing so.** What
it shows is that the stale-loopback failure did not occur across a 150-second suspend.
Whether it needs a longer one, memory pressure, or a reinstall to appear is not known.

**Getting a login URL requires the IPN bus, not the status document.** `statusJSON()`
has an `AuthURL` field and it read `""` on every poll while the node sat at
`NeedsLogin` — including a raw dump of the whole document, which showed the field
present and empty. The URL arrives on the bus:

```
watching the IPN bus for a login URL
bus state: NeedsLogin
login URL ready — open it to authorise this device
```

This is what upstream's README says to do, and it is the shape the product wants: first
run sends someone to a Tailscale login page, and there is no auth key to distribute.
The one wrinkle is recorded under constraints below — the bus subscription times out
after about a minute.

**The phone is already on the tailnet by other means.** The node's link-state log shows
`utun7:[100.88.61.34/32 fd7a:115c:a1e0::9a32:3d22/48]` alongside `ipsec0`/`ipsec5` —
the system Tailscale app's tunnel. That is how every earlier probe reached the backend,
and it is the dependency this branch exists to remove.

## Constraints found in the source, which shape the product

1. **`up()` does not return until the node is authorised** — it blocks on login. An
   instrument that awaits it and then reads the status never surfaces the login URL,
   which is exactly what the first device run did. The probe now polls status
   concurrently with `up()`.
2. **`loopback()` caches its address forever.** `URLSessionConfiguration.proxyVia`
   calls it, and it returns the cached `LoopbackConfig` on every subsequent call with
   no invalidation and no API to clear it. Upstream's own comment on `statusJSON`
   states that the OS reclaims the loopback TCP listener from a suspended process on
   iOS, "where the cached loopback address goes permanently stale". **Any long-lived
   session built before a suspend is therefore suspect**, and the fix is not simply to
   rebuild the session — `loopback()` would hand back the same dead address. This is
   the single most important thing to measure before any of this reaches the product,
   and it is why the probe logs the cached address on every check.
3. **Reinstalling does *not* wipe the node state — an uninstall does.** This corrects an
   earlier entry on this branch, which read the container path (and with it the
   authorisation) as a casualty of every `devicectl install`. Two upgrade installs on
   2026-09-18 kept the same container: `Documents/tailscale/tailscaled.state` was copied
   off the phone, the new build installed over the old, and the file came back
   **byte-identical**, with the node reaching `Running` on the next launch and no login
   prompt. What wipes it is deleting the app, which is when iOS destroys the container.
   So the development loop does not re-authorise per install, and a state loss points at
   an uninstall rather than at `devicectl`. Keep the habit anyway, since the cost of
   being wrong is a login no one is standing at the phone to approve:

   ```bash
   xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
     --domain-identifier com.abdullahchaudhry.Crossbar \
     --source Documents/tailscale/tailscaled.state --destination /tmp/node-state/tailscaled.state
   ```

   The file is opaque (the node reports `"StateEncrypted":true`), so it is worth treating
   as a blob to be restored verbatim rather than inspected.
4. **The documented path to a login URL is the IPN bus**, not `statusJSON` — confirmed
   on hardware above. Upstream's README: "Set an auth key via the config.authKey
   parameter, or watch the ipn bus (see the example) for the browseToURL field for
   interactive web-based auth." `LocalAPIClient.watchIPNBus(mask:consumer:)` with
   `Ipn.Notify.BrowseToURL` is what the bundled example uses.
5. **The bus subscription dies after about a minute.** The long-poll is torn down by
   `URLSession`'s default 60 s timeout:

   ```
   bus error: Error Domain=NSURLErrorDomain Code=-1001 "The request timed out."
     NSErrorFailingURLStringKey=http://127.0.0.1:…/localapi/v0/watch-ipn-bus?mask=6
   ```

   The login URL arrives well inside that window, so first-run authorisation is fine.
   But anything that needs to watch the bus across a longer life — a re-login after a
   credential expiry, say — must re-establish the subscription on timeout, and nothing
   does that yet.
6. **The loopback address changes when the node does, so it is a per-launch fact.**
   `loopback()` caches per `TailscaleNode` instance and nothing persists it: 57421 on an
   earlier run, 57597 and 57650 on today's. A log line naming the address is therefore
   only meaningful within the launch that produced it — which also means the cached
   address can never be handed to a new process, only to code that shares the node.
7. **An instrument gate cannot fire if its screen is never mounted.** The signalling
   gates already existed, but the probe screen is reached by a toolbar tap in the
   contacts list, so an unattended run loaded the app, started the node, and joined
   nothing — the log files still held the *previous* afternoon's run, which is the kind
   of silent no-op this project keeps having to design out. Fixed at the root rather than
   in the instrument: `CROSSBAR_PROBE_AUTOSHOW=1` presents the probe screen over whatever
   the product is showing.
8. **The loopback accepts connections before the node can carry anything, so
   `node != nil` is not readiness.** A node object exists from the first moment of
   bring-up, and the loopback listener comes with it — but nothing works over it until
   `up()` has returned. Measured on 2026-09-18, on a launch that dialled during bring-up:

   ```
   connecting wss://qatar-vpn.tailea67b0.ts.net/socket.io/… via embedded node 127.0.0.1:57718
   receive failed: A TLS error caused the secure connection to fail.
   ```

   Both the probe's check and the signalling socket failed that way, the check roughly
   eleven seconds before `node is up` appeared, and the node's own status document still
   reported `no peers`. That is a dial the instrument should not have made, not a
   property of the wire contract — and it is worth knowing that the symptom is a *TLS*
   error, which reads like a certificate problem and is nothing of the sort. Every wait
   in the probe now goes through `runningNode()`, which waits for whatever bring-up is in
   flight rather than trusting the object's existence; the first attempt at this only
   tested `node == nil`, which is exactly the bug it was written to prevent.

## What is not measured

- Whether the **product** dials through the node. The instrument's sockets do, and the
  product's `FamilyCallClient` does not: `/api/session`, `/api/bootstrap` and the event
  stream are still `URLSession.shared`, which is why the Family Call screen reports that
  it cannot reach the service while the probe screen beside it is talking to the same
  host through the node. That is a wiring task against the same `NodeSession`, not an
  open question — but nothing about the product path is proven until it is done.
- Whether any of this holds for a call between **two devices on different networks**, one
  or both without the system Tailscale app. Every call here put two peers in one process
  on one phone, where the media path is the device's own Wi-Fi address. The
  two-household case is where the STUN-versus-TURN question actually bites, and it needs
  two phones.
- **What to do about media over the overlay.** This branch answers that it cannot ride
  the node as built, and the audit's STUN/TURN decision is unmoved by it: media still
  takes whatever ICE finds. Nothing here says which of a relay, TURN, or accepting the
  public path is right for two households behind CGNAT.
- Whether the stale-loopback failure appears under a **longer** suspend, under memory
  pressure, or after a reinstall. 150 seconds did not trigger it; nothing here rules it
  out, and upstream observed it on iOS.
- Behaviour when the node is **not** available at launch — no network, control plane
  unreachable, or the machine revoked. The instrument has only ever been run in the
  happy path.
- Four-peer behaviour, and app size on the App Store — the framework adds ~25 MB to the
  device binary.
- The product question underneath all of this: whether every family member's device
  should join the tailnet as its own node. This branch proves the transport works; it
  does not argue that it is the right product.

## Next step

The signalling path is proven and the system app is not needed for it, so what is left is
narrower than it was.

1. **Wire the product through the same `NodeSession`.** `FamilyCallClient` reaches the
   network at four places, all `URLSession.shared`, and every one of them is a decision
   about which tailnet carries the app: `send()` (which every JSON call funnels through),
   `session()`, `pushConfig()`, and `events()` — the SSE stream opened with
   `bytes(for:)`. The first three are the same shape as the signalling client's
   `Transport` and should be mechanical. **The stream is the one to watch**: it is
   long-lived, it is the only path an incoming call can take, and this project has already
   lost a measurement to an SSE client that connected, reported HTTP 200, and delivered
   nothing for twenty seconds. Whether the node's loopback proxy streams promptly or
   buffers is unmeasured, and it is the first thing that wiring should log.

   Until it is done, the honest statement is that the *instrument* runs over the node —
   not the app, which is why the product screen reports that it cannot reach the service
   while the probe screen beside it is talking to the same host through the node.
2. **Decide the media question on its own terms.** The node cannot carry media, so the
   overlay is not what makes a two-household call work — the public STUN path is, exactly
   as before. The next measurement that would change anything is a call between two
   *different* phones with no shared LAN, where the only options are srflx hole punching
   or TURN.
3. **Re-establish what a first run looks like.** A fresh install still needs a login URL
   approved by hand, and the bus that delivers it dies after ~60 s. Nothing here has
   changed that, and it is the first thing a family member would meet.

The two gates that make an unattended run possible:

```bash
xcrun devicectl device process launch --device <id> --terminate-existing \
  -e '{"CROSSBAR_TAILSCALE_AUTOSTART":"1","CROSSBAR_PROBE_AUTOSHOW":"1",
       "CROSSBAR_SIGNAL_AUTOROOM":"room","CROSSBAR_SIGNAL_AUTOPEERS":"2",
       "CROSSBAR_SIGNAL_VIANODE":"1"}' \
  com.abdullahchaudhry.Crossbar
```

`AUTOPEERS=2` gives the two-peer call; leave `VIANODE` off for the control run whose flat
node counters are what make the routed run's growth meaningful. Pull `Documents/tailscale.log`
for the counters and `Documents/signal-A.log`/`signal-B.log` for the negotiation.

The suspension measurement can be extended at almost no cost, now that the mechanism is
automated — background the app by launching another one, wait, then resume:

```bash
# background it
xcrun devicectl device process launch --device <id> com.apple.mobilesafari
# … wait …
# resume the same process: without --terminate-existing it must not be restarted
xcrun devicectl device process launch --device <id> com.abdullahchaudhry.Crossbar
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier com.abdullahchaudhry.Crossbar \
  --source Documents/tailscale.log --destination /tmp/tailscale.log
```

If the app is restarted rather than resumed, the pid changes and `didEnterBackground`
with no matching `willEnterForeground` in the same run is the tell.

An install over the existing app no longer has to be feared — the container and the
node's authorisation survive one, measured twice on 2026-09-18. Deleting the app does not,
so copy `Documents/tailscale/tailscaled.state` off the phone first if anything on this
branch is about to remove it.
