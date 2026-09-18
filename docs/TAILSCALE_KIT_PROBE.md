# The embedded Tailscale node (branch `tailscale-kit`)

This branch asks whether Crossbar can carry its own tailnet, so that a family member
never has to install the Tailscale app and keep it signed in.

It is deliberately isolated: branch `tailscale-kit`, cut from `architecture-b` at
`7462de8`. Nothing here is on the product branch, and reverting is `git checkout
architecture-b` plus deleting `Vendor/` and `Scripts/` — no other branch depends on
either.

**Status: the framework is built, embedded, signed, and loads on the physical iPhone.
The node starts on iOS and reaches the Tailscale control plane. It does not yet
finish registering, so nothing that depends on being *in* the tailnet — the loopback
proxy, the control plane, signalling, and the suspension question — is measured.**

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

**It stops at registration.** `statusJSON()` returns:

```json
{"Version":"1.94.1-dev20260831-t59d4bb827","TUN":false,"BackendState":"NeedsLogin",
 "AuthURL":"","TailscaleIPs":null,
 "Self":{"HostName":"localhost","PublicKey":"nodekey:000000…0000","InNetworkMap":false,…},
 "Health":["Tailscale is starting. Please wait."], …}
```

`AuthURL` is present as a field and **empty**; `Self.HostName` is still `localhost`
rather than `crossbar-ios`; `Health` still says it is starting. The node never reaches
the point of offering a login URL, so there is nothing to authorise against and nothing
downstream can be measured.

**The macOS loopback failure reproduces on iOS.** Both attempts through the node:

```
loopback=127.0.0.1:57338
check failed at loopback=127.0.0.1:57338: bad URL
```

`NSURLErrorBadURL` on `lo0` — the same failure seen 3 times in 4 on macOS. Here it
failed 2 of 2, but the node was unauthorised throughout, so this run cannot separate
"loopback uses `EINVAL`" from "the proxy has no tailnet to reach". Not yet a finding.

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
4. **The documented path to a login URL is the IPN bus**, not `statusJSON`. Upstream's
   README: "Set an auth key via the config.authKey parameter, or watch the ipn bus (see
   the example) for the browseToURL field for interactive web-based auth."
   `LocalAPIClient.watchIPNBus(mask:consumer:)` with `Ipn.Notify.BrowseToURL` is what
   the bundled example uses, and it is the obvious next thing to try if interactive
   authorisation is wanted rather than an auth key.

## What is not measured

Everything that depends on the node being *in* the tailnet:

- whether the loopback SOCKS proxy carries the control plane and the MiroTalk
  WebSocket on iOS (the macOS spike says yes; iOS is untested);
- whether identity resolves through Serve when the request comes from the embedded node;
- whether any of it survives suspension, which is the question that decides whether this
  approach is usable for a call app at all — the existing signalling instrument already
  showed a suspended app's WebSocket dies silently, with no close frame and no error;
- four-peer behaviour, and app size on the App Store.

## Next step

Authorise one node, then re-run. Either supply `TAILSCALE_AUTH_KEY` in the launch
environment from an auth key minted in the tailnet admin console, or implement the IPN
bus watcher above to obtain `BrowseToURL`. Until a node is in the tailnet, the loopback
cannot be judged at all.
