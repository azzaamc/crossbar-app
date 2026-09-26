# The embedded Tailscale node (branch `tailscale-kit`)

This branch asks whether Crossbar can carry its own tailnet, so that a family member
never has to install the Tailscale app and keep it signed in.

It is deliberately isolated: branch `tailscale-kit`, cut from `architecture-b` at
`7462de8`. Nothing here is on the product branch, and reverting is `git checkout
architecture-b` plus deleting `Vendor/` and `Scripts/` — no other branch depends on
either.

**It is the product's transport now (2026-09-19), not an instrument.** `TailnetNode` is
product code; `CallSession.load()` attaches to it before it asks for anything; and both
clients dial through its carrier — the control plane (`FamilyCallClient`, through an
injectable `CallTransport` in place of `URLSession.shared`) and the signalling socket
(`MiroTalkSignalClient`). Measured on the phone with the app's own log pulled from its
container: `carried by the embedded node — node 127.0.0.1:61174`, then `GET api/session ->
HTTP 200 authenticated=true name=Azzaam Chaudhry`, `GET api/bootstrap -> HTTP 200`, and
`GET api/events -> HTTP 200`, with the contacts screen showing `Family network: node
127.0.0.1:61174`. The tailnet lists the node as a machine of its own (`crossbar-ios`,
`100.121.218.110`), so nothing about the app's access depends on the Tailscale app being
installed on the phone. The DEBUG instrument that used to own the node now drives the same
object and only measures it.

**Status: the node is authorised and running on the physical iPhone as `crossbar-ios`,
and it carries both halves of the wire contract — the Family Call control plane
including Serve's injected identity, and the MiroTalk signalling WebSocket. A first run
presents a Tailscale login page and needs no auth key anywhere. It also survived a
genuine suspension: backgrounded for 150 s, frozen by iOS, then resumed as the same
process, and the cached loopback still carried both checks.**

**Suspension also breaks it, and cannot be predicted (2026-09-18).** An identical run held
for 600 s came back with the node still `Running` and its cached loopback dead — a fresh
`URLSession` timed out against an address that had worked minutes earlier — and a repeat
of the same 600 s run did not. So the failure is real and intermittent, there is no safe
suspension length, and the cached carrier cannot be trusted after one. The repair is to
build a new node: seconds, the same tailnet identity, no login, a new loopback — measured,
and followed in the product by re-establishing whatever was riding on the old one.

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

It starts a node, polls `statusJSON()`, and performs the same two checks the macOS spike
did (HTTP to `/api/session` and the Engine.IO handshake) through the node's SOCKS
loopback.

The carrier itself is **product code** now: `TailnetNode.attach()` returns a
`CallTransport` whose session leaves through the node, and the transport carries the label
naming its route, so a log line cannot claim a route the socket did not take. Both clients
take one — `FamilyCallClient` for the control plane and `MiroTalkSignalClient` for the
signalling socket. What is left DEBUG-only in this file is only the measuring:

- `check()` — both halves of the wire contract through the carrier: HTTP to `/api/session`
  and the Engine.IO handshake, the same two checks the macOS spike made.
- `logNodeTraffic()` — the node's own peer counters, read from the raw status JSON
  (`Status.Peer` drops them), reported as deltas. This is the only evidence that says
  *which* carrier moved the bytes while the system Tailscale app is also installed.

The re-check on `didBecomeActive` is product behaviour now, in
`CallSession.reverifyCarrier()`: it verifies the carrier and rebuilds the node when the
verify fails, then re-dials whatever the rebuild invalidated. The verify runs before any
rebuild on purpose — `statusJSON()` goes through tsnet's in-memory LocalAPI and never
touches the loopback, so a status document that still reports a running backend while the
request fails means the node is alive and only the cached address has gone stale; and a
backend that is *not* running means the network went away, where rebuilding would turn an
outage into a bring-up loop. See the constraint below.

### Driving it without a human

The node needs no gate and no button: `CallSession.load()` starts it at launch, because
every route the app needs is tailnet-only. The gates that remain
(`CROSSBAR_PROBE_AUTOSHOW`, `CROSSBAR_SIGNAL_AUTOROOM`, `CROSSBAR_SIGNAL_VIANODE`) follow
the pattern this codebase already used, with one correction from 2026-09-19: they are read
**before** the first `await` in the view's task. A `.task` on a view whose identity changes
— and the phase switch does change it — is cancelled, so a gate sequenced after
`await session.load()` never fires at all. The probe screen silently never appeared until
that was moved.

To check that a `-e` payload reached the app at all, point the backend at a URL that cannot
answer and watch the carrier refuse it rather than fall back:

```bash
xcrun devicectl device process launch --device <id> --terminate-existing \
  -e '{"CROSSBAR_BACKEND_URL":"https://example.invalid:8443"}' \
  com.abdullahchaudhry.Crossbar
# the app's log then reads:
#   carrier 127.0.0.1:61283 carried nothing in 10 attempts — last: no answer
```

`CROSSBAR_TAILNET_NODE=off` dials direct instead of through the node, for an instrument
that needs the other route. It is an override rather than a fallback: nothing selects it
silently, because a run that took the system's path while the screen said otherwise is the
failure this branch keeps finding.

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
has a path — so the tell is the magnitude at connect, not zero-versus-nonzero. Later runs
show a few KB more at baseline for a second reason: the carrier is now proved ready with a
real request before it is handed out (constraint 9), and that request travels through the
node like any other.

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
it shows is that the stale-loopback failure did not occur across a 150-second suspend —
the run below, at 600 seconds, found it.

**The warning is real, and it is intermittent (2026-09-18).** Holding the app for **600
seconds** instead of 150 — on a call whose sockets were carrying media through the node
when it was suspended — produced the failure the shorter run did not:

```
— didEnterBackground —
— willEnterForeground —
— didBecomeActive, re-checking through the node —
— check —
loopback=127.0.0.1:57816
check failed at loopback=127.0.0.1:57816: The request timed out.
```

Three facts separate that from "the network went away", and all three are present:

- **The node was still up.** `starting node in …` appears exactly once in the whole log,
  so no new node was built, and `refreshStatus()` — which only writes on *change* — wrote
  nothing across the resume, so the status was still `Running` with the same addresses.
  Its control connection and DERP relay came back with the process; only the loopback did
  not.
- **The address was the casualty, not the session.** `check()` builds a fresh
  `URLSession` on every call, and that fresh session timed out against the cached address.
- **The call did not survive, and said so only on resume.** `ice state -> 4`,
  `pc state -> 4`, media frozen at a fixed byte count, then
  `receive failed: … Socket is not connected` on the first receive after the freeze.

**Then an identical 600-second run did not reproduce it.** Same procedure, same build
family, same room size, same cached-address shape — and the cached loopback answered:

```
— didBecomeActive, re-checking through the node —
— check —
loopback=127.0.0.1:57915
HTTP 200
authenticated=true identity=Azzaam Chaudhry
ws first frame: 0{"sid":"SRzZfLOPAz5qPkEmAADA",…}
signalling handshake OK
```

So the failure is real, and **the clock does not predict it**. That is the finding that
matters, and it is worse than a threshold would have been: there is no duration the
product may treat as safe, so the cached address cannot be trusted after *any*
suspension and the app has to verify rather than assume. The natural suspicion is that
the OS reclaims the listener under memory pressure rather than on a timer — upstream's
comment says the OS reclaims it — but nothing here separates the mechanism from the
clock, and the run that failed is not distinguishable from the run that did not by
anything in the logs.

**And it recovers, in seconds and without a login (2026-09-18).** `loopback()` cannot be
invalidated and nothing exposes the listener, so the only way back to a live carrier is a
new node. Forced on foreground — `CROSSBAR_TAILSCALE_REBUILD=force`, which exists precisely
because the failure it answers cannot be provoked on demand:

```
— rebuilding the node: forced, to test the recovery itself —
node closed
starting node in …/Documents/tailscale
no auth key — expecting interactive login
BackendState=NoState → bus state: NoState → bus state: Starting
node is up
BackendState=Running
IPs=100.121.218.110, fd7a:115c:a1e0::d12d:da6f      ← the same identity
node rebuilt
— check —
loopback=127.0.0.1:58056                             ← a new listener
HTTP 200
authenticated=true identity=Azzaam Chaudhry
ws first frame: 0{"sid":"ekQuVj1YU24oE8XrAADG",…}
signalling handshake OK
```

The whole repair took seconds, kept the same tailnet address, and **never asked for a
login or an auth key** — the machine key on disk is the authorisation, which is the same
fact that makes an upgrade install free. What it does *not* repair is anything built on
the old node: the signalling socket died with it (`receive failed: … Socket is not
connected`) and the call's peer connections went with it. A product rebuilds the carrier
**and** re-establishes what was riding on it, which a call has to do anyway after a
screen lock.

**A call can survive the app being left — and what it needs is audio, not a background
mode (2026-09-19).** This was asked as a product question — swipe away mid-call, and does
everything drop? Measured with the far end as the observer, in three configurations:

| Configuration | Result |
| --- | --- |
| audio gated, `UIBackgroundModes = [voip]` | process frozen within seconds |
| audio gated, `+ audio` | identical — declaring the mode changed nothing |
| **audio running, `+ audio`** | **call survives; audio keeps flowing, video stops** |

The first two look the same from the phone and from the far end: the stats timer stops
writing mid-line with a non-zero byte delta (14–16 polls, then silence), the far end's
video time freezes, and MiroTalk removes the peer by about +65 s. Nothing is logged as a
failure, because a frozen process logs nothing — which is why the far end is the only
useful observer here.

The third is a different process. Backgrounded for 100 s and sampled throughout:

```
media OUT -> LwJUiwUX audio bytes=266941 delta=6129      ← still sending, ~6 KB per 3 s
media IN  <- LwJUiwUX audio bytes=231210 delta=5620 energy=0.006
media OUT -> LwJUiwUX video bytes=5836421 delta=0        ← camera gone, as iOS intends
                    …41 polls, 6 engine.io pings, no receive failure…
```

Audio crossed both ways for the whole background period, `totalAudioEnergy` was non-zero
for the first time in any of these runs, the signalling socket never dropped, and the peer
stayed in the room. **Video stopped on its own** — iOS takes the camera away from a
backgrounded app — so leaving the app already *is* the audio-only switch, without the call
ending.

The mechanism was a gate nobody had opened. `CallMediaSource.prepareAudioSession()` puts
WebRTC into **manual audio**, so nothing is recorded or played until `isAudioEnabled` is
set — and the probe path never set it, because in the product that is CallKit's job in
`didActivate`. A process that is neither recording nor playing audio has no claim on
background execution, so iOS suspended it: the background mode was never the missing
piece, the audio was. `CallMediaSource.enableAudio()` is that gate opened explicitly, for
a caller with no CallKit call to wait for.

Two gaps this leaves, both worth knowing before the product relies on it:

- **The far end is left staring at a frozen frame.** The phone stops sending video, but
  nothing tells the peer, so the browser's tile kept its last picture and the call looked
  alive-but-broken rather than audio-only. MiroTalk has the messages for it — the audit
  catalogues the two camera-off paths — and this is the case that needs them.
- **The product path opens the gate through CallKit**, which this probe run did not
  exercise: `didActivate` → `adoptAudioSession` → the forced `canPlayOrRecord` transition.
  So the same survival is expected there and is *not* measured; what is measured is that
  the ingredients it depends on — the `audio` background mode and running audio I/O — are
  what make the difference.

Neither configuration was tested for the converse (audio running *without* the `audio`
mode), so how much of the effect belongs to the mode rather than to the audio itself is
not separated here.


**Leaving the app is now a decision rather than an accident (2026-09-19).** A call that
survives backgrounding leaves two things to fix, and both are built:

- **The far end was never told the camera went away**, so it kept drawing the last frame
  it received — a frozen picture that looks like a working call. MiroTalk's contract for
  this is `peerStatus`, read from the *deployed* client because no MiroTalk checkout
  exists on this machine: `emitPeerStatus('video', myVideoStatus)` sends
  `{room_id, peer_name, peer_id, element: "video", status, extras}`, and its receive side
  (`setPeerVideoStatus`) hides that peer's video element and shows their avatar. Sent on
  leaving, and again on return, by both the probe path and the product's camera button.
- **The remote picture should not just disappear** when the app is left during a video
  call. `AVPictureInPictureVideoCallViewController` is the surface Apple provides for
  calls, and it is *armed while the app is in front* — the system watches the source
  view's frame and starts the window itself when the app backgrounds; asking for it from
  inside the background transition is the unreliable version of the same request.

```
PiP: PiP armed (supported=true, possible=true)     ← while the call screen was in front
PiP: PiP started                                    ← the system opened it on backgrounding
camera off — peerStatus video=false
left the app — PiP armed=true active=true
camera back on — peerStatus video=true
PiP: PiP window closed on return to the app
PiP: PiP stopped
```

The far end is the honest observer of all of that, and it changed state twice:

```
foreground  display=block  playing=true  t=24.5  avatar shown=false
away        display=none   playing=true  t=25.0  avatar shown=true     ← told, not frozen
returned    display=block  playing=true  t=47.4  avatar shown=false
```

The window itself was confirmed on the phone's screen while the app was away, floating
over **Safari** — which is what makes it the system's window rather than an overlay of
ours — and gone after returning, with the remote video drawing again.

Four things this cost, all worth keeping:

- **`@State` written from `makeUIView` is dropped, silently.** The tile's view is handed
  over during a SwiftUI update, and assigning it to `@State` there produced no error and
  no value — the first attempt armed nothing and reported `tileView=false`. It lives in a
  class box now, and arming happens outside the update.
- **Arming has to react, not just wait.** The first version polled for 40 seconds and gave
  up; in this harness the browser joins about 50 seconds after launch, so it timed out
  before there was anything to show. It now arms on the track arriving as well as on the
  wait.
- **AVKit does not close the window when the app returns.** Left alone it floats over the
  call screen showing the same call twice — measured, then fixed by closing it on
  foreground while keeping the arrangement armed, so the next trip to the background
  opens it again.
- **The obvious log line lied.** Reading `isPictureInPictureActive` immediately after
  asking for a stop reports `true` for a window that is already going away, so the line
  now records whether it *was* active. Same family as the peer state label that described
  the join rather than the call.

Not built, and deliberately so: **PiP for an audio-only call**, where the system's own
surface (CallKit's lock screen and banner) is the right one and a window would be noise.

**Two ways the first version was wrong, both visible on the phone (2026-09-19).** It
opened a window and took the call's video away:

- **The window showed a still picture.** It hosted the same `RTCMTLVideoView` the call
  screen uses, and Metal rendering is not driven while an app is in the background — so the
  window showed the last frame drawn before the app left and looked frozen until the user
  came back. Apple's guidance for video-call PiP names the fix: *"Video-calling apps need
  to display the remote view, so use `AVSampleBufferDisplayLayer` to do so."* The window now
  renders into a sample-buffer layer fed by a frame renderer, which is the system's own
  path and keeps presenting with the app behind.
- **The camera stopped, so the call silently went audio-only.** iOS 16 moved camera access
  in PiP behind a per-session flag — `AVCaptureSession.isMultitaskingCameraAccessEnabled` —
  and until it is set, going to PiP costs the camera. That is why the far end's video
  froze, and why "my video should still be transmitting in PiP" was exactly right. The
  session opts in when PiP is armed, and a call that is *in* PiP now keeps its camera; only
  a call with no window (audio only, or a device that cannot) falls back to audio, and that
  is when `peerStatus video=false` goes out.

Measured on the next run, with the browser watching our camera and the renderer counting
its own frames:

```
PiP: PiP renderer: 698 frames total (20.0 fps over 5 s, 0 dropped)
PiP: PiP renderer: 899 frames total (20.0 fps over 5 s, 0 dropped)
far end while away:  display=block  playing=true  t=26.3 → 41.7 → 51.5
far end on return:   display=block  playing=true  t=63.7
PiP: PiP window closed on return → PiP stopped
```

Two screenshots nine seconds apart differed, and the picture in the window was the far
end's own green test pattern rather than a corrupted image — which is the check that
matters after a colour conversion (I420 interleaved into NV12), because a wrong conversion
still counts frames.

Two smaller corrections from the same run, both the same family as the rest of this
document: the frame line divided a *cumulative* count by one interval and printed "140 fps"
for a 20 fps stream, and the frames on this device arrive as **I420** rather than the decoded
pixel buffers the first attempt assumed — which the renderer reported once in the log
instead of dropping silently.

The other gap is unchanged and now matters more: the *product* path is wired the same way
but still has no measured real call behind it, so what is verified here is the mechanism
both paths share, exercised through the probe.

**A real call to MiroTalk's own browser client, over the node (2026-09-19).** Everything
above put two peers in one process on one phone, which answers "can the node carry a
call" but not "will it carry a call to somebody else's client". This one does: the
phone's app, signalling through the node with its Tailscale app **disconnected**, against
MiroTalk's own web client in Chromium on the Mac, on the same LAN.

```
connecting wss://qatar-vpn.tailea67b0.ts.net/socket.io/… via embedded node 127.0.0.1:60182
addPeer 6Bab4be4 should_create_offer=false iceServers=1
policy: awaiting an offer from 6Bab4be4
offer <- 6Bab4be4 (6062 chars, 3 m-lines (video,audio,application))
answer -> 6Bab4be4 (3791 chars, 3 m-lines (video,audio,application))
pc state -> 2   ice state -> 2
ICE path [T01] local=host 192.168.1.120:60601/udp remote=host 192.168.1.127:55214/udp state=succeeded bytesSent=18209062
media IN <- 6Bab4be4 video delta=263352 energy=0.000
media IN <- 6Bab4be4 audio delta=5534 energy=0.000
node traffic [during call] — qatar-vpn rx=39436(+20096) tx=24916(+12112)
```

The browser offered three m-lines — a real client adds a data channel to the two media
lines — the native client answered, ICE nominated the LAN pair (phone `192.168.1.120` to
Mac `192.168.1.127`), and ~18 MB of the phone's camera crossed to the browser while the
browser's camera came back. Both directions, two devices, one of which had no Tailscale
app at all. Confirmed on both screens rather than inferred from byte counts: the
browser's page drew the phone's room beside its own test pattern, and the phone's `A` tile
drew the browser's pattern beside its own camera.

Two details worth keeping:

- **The Mac does advertise tailnet candidates** — it runs the Tailscale app, so
  `100.80.10.12` and its `fd7a:115c:a1e0::b635:a0c` appear in the browser's offer. Every
  pair against them sat `in-progress sent=0 recv=0` for the whole call, because the phone
  has no interface that can reach `100.64/10`. So "the overlay is not the media path" holds
  in a two-device call too, and this time it holds *visibly* — the dead pairs and the live
  one are in the same report.
- **The node carried the exchange**: ~20 KB in and ~12 KB out during the SDP and ICE
  relay, against a few hundred bytes of housekeeping before it. The phone's system client
  stayed offline throughout — `iphone181 … offline, last seen 15h ago` on the Mac's peer
  list while the call ran.

Two traps the harness set, both worth knowing before repeating it:

- **A browser with no camera is not a media peer.** The first attempt joined with a
  synthetic-data-channel-only offer — `1 m-lines (application)` — and negotiated
  successfully, ICE and all, with no media anywhere. It looked like a working call
  everywhere except the m-line count and the byte counts. Chromium needs
  `--use-fake-device-for-media-stream` (and `--use-fake-ui-for-media-stream` to skip a
  permission prompt nobody is there to click) before it is a peer worth testing against.
- MiroTalk's page carries "Connection lost / Reconnecting to signaling server…" elements
  in its DOM. They are not visible in the rendered frame, and the call negotiated and
  carried media throughout, so this reads as that client's own UI state rather than
  anything about the transport — recorded rather than chased.

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

**The node is unusable when it cannot load the state it keeps its identity in, and that
looks like the network (2026-09-24).** Measured on the device: a state directory two days
old — `Documents/tailscale`, where the node keeps its machine key — failed *every* bring-up
with `TailscaleError` code 3, `connectionClosed`, "The underlying connection was closed".
That error is thrown only by the local-API connection layer, which is the tell: the node
never got as far as an address of its own, so nothing about the wire contract or the control
plane was involved, and the network underneath was fine.

The recovery that existed could not help. Both of the rebuilds this branch relies on build a
*new* node, and a new node reuses the same state directory, so a directory that will not
load fails its replacement in exactly the same way. `CallSession.reverifyCarrier()` repairs
a *stale loopback* on a node that is up; this one never came up at all. The state had to be
deleted, and nothing in the app could do that, because `signOut()` asks a *running* node to
forget its machine key and a node that will not start cannot be asked.

Two things followed, both product code now:

- **`TailnetNode.reset()`** clears the state directory and any stored auth key. It is the
  recovery that needs no running node, and it is close to what deleting the app does — the
  device gets a *new* identity in the tailnet and has to be approved again — without losing
  everything else on the device. The setup screen offers it when setup fails, with that cost
  stated. That button was also the evidence that the directory was the cause: pressing it is
  what got past the failure.
- **`TailnetNode.attach()` clears the state and tries once more** when the bring-up failed
  with an error the framework reports as *local* — `connectionClosed`, `badInterfaceHandle`,
  `internalError`, all of which mean the node could not get itself going, which is what an
  unloadable state directory looks like from outside. A **posix** error is the network
  underneath and is left alone: clearing the state for that would cost an approval and fix
  nothing. `blamesStateDirectory` is that rule, in one place.

What is measured here is the failure and the clear that got past it. The automatic
clear-and-retry was added afterwards, for that same failure, and has not been provoked
separately.

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
   gates already existed, but the probe screen is reached from Settings → Advanced →
   Instruments (it was a toolbar tap in the contacts list when this was written), so an
   unattended run loaded the app, started the node, and joined
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
9. **`up()` returning is not the carrier working, and neither is a listener that answers
   — readiness is a request that went through.** The macOS spike recorded this first and
   the iOS runs reproduce it: a socket dialled immediately after bring-up died with

   ```
   connecting wss://qatar-vpn.tailea67b0.ts.net/socket.io/… via embedded node 127.0.0.1:57887
   receive failed: bad URL
   ```

   Nothing retried it, so that run went on to measure a node carrying nothing while
   presenting as a test of one — the same shape of wrong answer as a stale log file. The
   first fix was too weak to catch all of it, which is its own small lesson: a knock on the
   listener's LocalAPI endpoint, on the same port the proxied session uses, **answered** —
   and the very next request through the SOCKS path failed with `bad URL` anyway. So the
   readiness condition is now a real request over the carrier, to the endpoint the control
   plane uses, with any HTTP status counting and ten attempts before it refuses, because
   the failure arrives without warning and the same build fails it on one launch and not
   the next.
10. **The cached loopback cannot be trusted after a suspension, and the duration does not
   tell you which suspensions are safe.** 150 s survived; 600 s failed once and then
   succeeded on an identical repeat. Since `loopback()` offers no invalidation, the only
   carrier that can be relied on is one that has just answered, and the only repair for
   one that has not is a new node — which costs seconds, keeps the identity, and needs no
   login, because the machine key is the authorisation. Two consequences follow for
   anything built on top: a new node gets a **new port**, so every carrier and socket
   created against the old one is dead the moment a rebuild happens, and a rebuild
   therefore has to be followed by re-establishing whatever was riding on it.

11. **The node is up only after a load, and the app's first request at launch is not one a
    load makes.** A private deployment is reached at an address only the node's own network
    can resolve, so a request attempted before the carrier exists has nowhere to go. That is
    not hypothetical: PushKit announces the VoIP token *before any load runs*, so the upload
    went out over the direct route and the token was dropped — and nothing retries it,
    because PushKit announces once per launch and a backgrounded app is never launched
    again. Measured on 2026-09-24: a device enrolled at 16:19 had filed nothing by 17:31, on
    a launch whose load itself was fine. The same ordering shapes a first run, where the
    enrolment is the first request the app ever makes: the setup screen now brings the
    network up before it dials, rather than sending the enrolment first and answering "could
    not reach the service" on the first screen anybody sees. See `NATIVE_PROGRESS.md`, "The
    device enrolled later that day".

## What is not measured

- **Whether the product dials through the node — answered on 2026-09-19, and the answer is
  yes.** When this list was written the instrument's sockets took the node while the
  product's `FamilyCallClient` reached the network at four places on `URLSession.shared`,
  which is why the Family Call screen reported that it could not reach the service while the
  probe screen beside it was talking to the same host. `CallSession` now hands the one
  carrier to both clients, and the product's own log shows all of it: `carried by the
  embedded node — node 127.0.0.1:61174`, then `GET api/session -> HTTP 200`,
  `GET api/bootstrap -> HTTP 200` and `GET api/events -> HTTP 200` (`NATIVE_PROGRESS.md`,
  "Embedded node as the app's transport"). What remains unmeasured about the product's route
  is not the route but its *timing* — the carrier exists only once a load has built it,
  which is constraint 11 above.
- Whether any of this holds for a call between **two devices on different networks**, one
  or both without the system Tailscale app. Two real devices have now been measured — the
  phone with no Tailscale app at all calling MiroTalk's own client on the Mac — but on one
  LAN, where ICE nominated a host pair. The two-directory case is where the
  STUN-versus-TURN question bites, and it needs two phones on two networks.
- **What to do about media over the overlay.** This branch answers that it cannot ride
  the node as built, and the audit's STUN/TURN decision is unmoved by it: media still
  takes whatever ICE finds. Nothing here says which of a relay, TURN, or accepting the
  public path is right for two directories behind CGNAT.
- **What actually triggers the stale loopback.** 150 s survived, 600 s failed once and then
  succeeded on an identical repeat, and nothing in the logs separates the run that broke
  from the run that did not. Memory pressure is the obvious suspect — upstream's comment
  says the OS reclaims the listener, which is not a timer — and the useful number for the
  product would be the condition rather than the duration: a device that can name the
  trigger can decide when to verify, instead of verifying on every foreground.
- Behaviour when the node is **not** available at launch, with one case now measured. A node
  whose state directory will not load is measured on 2026-09-24, above: the state is cleared
  and the bring-up is retried once, and the setup screen can clear it by hand. Still
  unmeasured: no network at all, the control plane unreachable, and a machine revoked in the
  tailnet — the instrument has only ever been run where the node came up in the end, or where
  its own state directory was what stopped it.
- Four-peer behaviour, and app size on the App Store — the framework adds ~25 MB to the
  device binary.
- The product question underneath all of this: whether every family member's device
  should join the tailnet as its own node. This branch proves the transport works; it
  does not argue that it is the right product.

## Next step

The signalling path is proven and the system app is not needed for it, so what is left is
narrower than it was.

1. **Wire the product through the same `NodeSession`.** *Done on 2026-09-19 — `CallSession`
   hands the node's one carrier to both clients, so what follows is the reasoning that
   shaped that wiring rather than work still outstanding, and the two behaviours it asks for
   at the end (verify before dialling, rebuild on foreground when the verify fails) are
   product code as well, in `CallSession.reverifyCarrier` and `TailnetNode.attach`.*
   `FamilyCallClient` reached the network at four places, all `URLSession.shared`, and every
   one of them was a decision about which tailnet carries the app: `send()` (which every JSON
   call funnels through), `session()`, `pushConfig()`, and `events()` — the SSE stream opened
   with `bytes(for:)`. The first three were the same shape as the signalling client's
   `Transport`; **the stream was the one to watch**: it is long-lived, it was the only path an
   incoming call could take, and this project has already lost a measurement to an SSE client
   that connected, reported HTTP 200, and delivered nothing for twenty seconds. Whether the
   node's loopback proxy streams promptly or buffers is unmeasured, and it is the first thing
   that wiring should log.

   Until it was done, the honest statement was that the *instrument* ran over the node —
   not the app. That boundary is measured rather than inferred, from one launch with the
   system app disconnected:

   ```
   session.log   GET api/session (requesting)
                 load failed: A server with the specified hostname could not be found.
   signal-A.log  connecting wss://qatar-vpn.tailea67b0.ts.net/socket.io/… via embedded node 127.0.0.1:57748
   ```

   One process, one host. The product's socket cannot resolve the name; the node-carried
   one resolves it and completes a call on it, and the only difference between them is
   which carrier the socket was built on.

   Two behaviours belong with that wiring rather than after it, both now measured in the
   probe: **verify before dialling** (a socket dialled during bring-up dies with
   `bad URL`, and nothing retries it), and **rebuild on foreground when the verify
   fails**, then re-establish the sockets, because the stale-loopback failure is
   intermittent and arrives without warning. The probe's gated path is the shape; the
   product's version of it is not optional.
2. **Decide the media question on its own terms.** The node cannot carry media, so the
   overlay is not what makes a two-directory call work — the public STUN path is, exactly
   as before. The next measurement that would change anything is a call between two
   *different* phones with no shared LAN, where the only options are srflx hole punching
   or TURN.
3. **Re-establish what a first run looks like.** A fresh install still needs a login URL
   approved by hand, and the bus that delivers it dies after ~60 s. Nothing here has
   changed that, and it is the first thing a family member would meet.

The gates that make an unattended run possible:

```bash
xcrun devicectl device process launch --device <id> --terminate-existing \
  -e '{"CROSSBAR_TAILSCALE_AUTOSTART":"1","CROSSBAR_PROBE_AUTOSHOW":"1",
       "CROSSBAR_SIGNAL_AUTOROOM":"room","CROSSBAR_SIGNAL_AUTOPEERS":"2",
       "CROSSBAR_SIGNAL_VIANODE":"1","CROSSBAR_TAILSCALE_REBUILD":"1"}' \
  com.abdullahchaudhry.Crossbar
```

`AUTOPEERS=2` gives the two-peer call; leave `VIANODE` off for the control run whose flat
node counters are what make the routed run's growth meaningful. Pull `Documents/tailscale.log`
for the counters and `Documents/signal-A.log`/`signal-B.log` for the negotiation.
`REBUILD=1` repairs a node whose loopback failed a foreground check, and `REBUILD=force`
repairs one unconditionally — the latter exists because the stale-loopback failure is
intermittent, so the recovery cannot be tested by waiting for the failure to show up.

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
