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
presents a Tailscale login page and needs no auth key anywhere. What remains unmeasured
is whether any of it survives suspension.**

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
3. **Reinstalling wipes the node state.** Each `devicectl install` produced a new data
   container (`…/Application/<new-UUID>/Documents/tailscale`), so the machine key and
   any authorisation are gone and the node re-registers from scratch. The development
   loop therefore re-authorises on every install — worth solving before this is used in
   anger, and worth knowing before concluding anything from a run that followed one.
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

## What is not measured

- **Whether any of this survives suspension**, which is the question that decides
  whether the approach is usable for a call app at all. Both halves of the wire
  contract are proven **in the foreground only**. The existing signalling instrument
  already showed that a suspended app's WebSocket dies silently, with no close frame
  and no error, and upstream documents that iOS reclaims the node's loopback listener
  on suspend while `loopback()` keeps handing back the stale cached address.
- Whether a call actually completes over the embedded node. What is proven is the
  control plane and the Engine.IO handshake; no call has been placed through it.
- Four-peer behaviour, and app size on the App Store — the framework adds ~25 MB to the
  device binary.

## Next step

The suspension measurement. Background the app, leave it long enough for iOS to suspend
it, then foreground it and read the log. The probe re-checks automatically on
`didBecomeActive`, and it runs `refreshStatus()` *before* the request, so a status that
still reports `Running` alongside a failing request proves the node is alive and only
the cached loopback address has gone stale.

Do not reinstall between the two halves of that test: a fresh install wipes the node
state, which forces a new login URL and destroys the continuity the test depends on.
