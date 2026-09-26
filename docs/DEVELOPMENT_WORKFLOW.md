# Crossbar development workflow

## Start in the correct directory

OMP may start in:

```text
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar
```

The actual Git worktree and Xcode project are:

```text
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar/Crossbar.xcodeproj
```

Run Git commands from the nested `Crossbar` directory. Do not initialize a new
repository or create/move the Xcode project.

## Preferred OMP/Xcode integration

Both the outer workspace and the tracked nested worktree contain
`.omp/mcp.json` with an MCP server named `xcode` backed by:

```text
xcrun mcpbridge
```

The user must enable:

```text
Xcode -> Settings -> Intelligence -> Model Context Protocol
      -> Allow external agents to use Xcode tools
```

Keep `Crossbar.xcodeproj` open in Xcode while OMP uses the bridge. On every new
OMP session, discover the tools exposed by the `xcode` MCP server. Do not
hard-code tool names or assume that a prior tool catalog is unchanged.

Prefer Xcode MCP for:

- inspecting the open project, schemes, targets, and build settings;
- reading compiler diagnostics;
- Debug/Release builds;
- unit and UI tests;
- simulator boot/install/launch and semantic UI inspection;
- previews when exposed;
- connected-device build/install/launch and device logs when exposed.

Shell `xcodebuild` is a fallback only when the MCP cannot perform the operation.
Do not mix two build-control mechanisms casually; record which one produced
each result.

The Codex handoff used the official XcodeBuildMCP CLI rather than raw
`xcodebuild`, `xcrun`, or `simctl`. OMP is expected to use Apple's Xcode MCP
bridge first, but the CLI commands below are reproducible fallbacks.

## Current project facts

- Xcode 27.0 (`27A266a`) was installed at handoff.
- Scheme: `Crossbar`.
- No `.xcscheme` file is tracked in this repository, and
  `Crossbar.xcodeproj/xcshareddata/` contains no schemes. The scheme exists
  only inside the running Xcode instance; `xcodebuild -scheme Crossbar` and the
  `xcodebuildmcp` CLI both resolve it because Xcode auto-creates it, and that
  was verified on 2026-09-17, but a clean checkout does not carry it. The only
  scheme-related tracked artifact is
  `xcuserdata/azzaam.xcuserdatad/xcschemes/xcschememanagement.plist`.
- Targets: `Crossbar`, `CrossbarTests`, `CrossbarUITests`.
- Bundle ID: `com.abdullahchaudhry.Crossbar`.
- Minimum target: iOS 27.0.
- Signing: automatic; a Personal Team/development team is selected.
- Third-party code: WebRTC via Swift Package (`stasel/WebRTC`), and on branch
  `tailscale-kit` the `TailscaleKit.xcframework` from `Vendor/` (gitignored;
  see `Scripts/build-tailscale-kit.sh`).
- Camera/microphone purpose strings are generated from build settings.

Do not document or commit certificates, provisioning profiles, signing keys, or
account credentials.

## App icon

The icon is an **Icon Composer document**, `Crossbar/Crossbar.icon`, wired with
`ASSETCATALOG_COMPILER_APPICON_NAME = Crossbar` (the document's name without the
extension — that name has to match). Xcode generates every appearance and size
from it at build time, the system applies the corner mask and the tinted/clear
treatments, and the app icon builds into `Assets.car` as `Crossbar` with the Any,
Dark and Tintable appearances plus a MultiSized entry. Verified 2026-09-19 by a
clean build and a device install.

`Crossbar/Crossbar.icon` is the **shipping** copy. The design workspace lives
outside this repository in `iconwork/`, alongside the SVG layers
(`IconLayers/01-background.svg` … `04-nodes.svg`), the tooling that writes the
document, and Icon Composer's exports. Those exports are **preview renders**: the
mask is already applied (transparent corners) and the tinted appearances carry a
sample tint. Apple's guidance is explicit that the mask is the system's job —
"Don't export the canvas mask because the system applies that automatically" —
so exports are not catalog artwork and were never meant to be.

Edit the copy in `Crossbar/` (or re-copy it after editing `iconwork/`), so the two
cannot drift.

There is **no app icon asset catalog**. `AppIcon.appiconset` was retired on
2026-09-19 in favour of the document, and `Assets.xcassets` now holds only
`AccentColor`.

## Accent colour

`AccentColor` is the icon's gold, adapted per appearance. A single bright gold
cannot be both a legible label on white and a legible fill under white text, and
iOS uses the accent for both, so the two appearances differ on purpose:

| Appearance | Value | Measured against | Contrast |
| --- | --- | --- | --- |
| Any (light) | `#8A6A00` sRGB | white | 5.07:1 |
| Dark | display-P3 `0.833, 0.666, 0` (renders `#DDA800`) | black | 9.68:1 |

The dark value is the icon's own authored P3 triple, so the mark and the app
carry literally the same gold. The light value is a darker gold chosen for
contrast: the icon's gold on white is only 1.79:1, which is what the first
screenshot of a `borderedProminent` button showed — white on gold, washed out.
Numbers measured 2026-09-19 from rendered pixels of simulator screenshots
(CoreGraphics, sRGB), not from the source values.

Known tradeoff: in **dark** mode `.borderedProminent` fills with the accent and
labels in white, which is 2.17:1 against that bright gold, so a dark-mode filled
button is the softest control in the app. Every other case measured passes: gold
label on white 5.07:1, gold label on black 9.68:1, white on gold in light mode
5.07:1. The light value reads as a dark gold/bronze rather than the mark's
brighter gold; if that matters more than contrast, `#B8860B` looks closer to the
mark but takes light-mode labels down to 3.28:1 (large text only).

`.orange` in `ContactsView` and `InCallView` is not the accent — it marks a
warning that the event stream is down.

## Simulator procedure

With Xcode MCP:

1. Discover available projects/schemes/simulators.
2. Select `Crossbar.xcodeproj`, scheme `Crossbar`, and an installed iOS 27.0
   simulator.
3. Build Debug.
4. Build Release when changing conditional probe/build configuration behavior.
5. Build-and-run Debug for UI/manual probe work.
6. Wait for the status value `Runtime ready`; element existence alone is not
   sufficient because it first reads `Loading runtime…`.
7. Run tests and record individual pass/failure output.

Fallback commands used at handoff:

```sh
cd '/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar'

xcodebuildmcp simulator list-schemes \
  --project-path Crossbar.xcodeproj

xcodebuildmcp simulator list

xcodebuildmcp simulator build \
  --project-path Crossbar.xcodeproj \
  --scheme Crossbar \
  --simulator-id <SIMULATOR_UDID>

xcodebuildmcp simulator build \
  --project-path Crossbar.xcodeproj \
  --scheme Crossbar \
  --configuration Release \
  --simulator-id <SIMULATOR_UDID>

xcodebuildmcp simulator build-and-run \
  --project-path Crossbar.xcodeproj \
  --scheme Crossbar \
  --simulator-id <SIMULATOR_UDID>

xcodebuildmcp simulator test \
  --project-path Crossbar.xcodeproj \
  --scheme Crossbar \
  --simulator-id <SIMULATOR_UDID>
```

At handoff, an `iPhone 18 Pro` simulator on iOS 27.0 was used. Discover the
current UDID instead of persisting machine-specific simulator IDs in project
configuration.

### Known UI-test synchronization issue

`CrossbarUITests.testExample` waits for `probe.status` to exist and then asserts
that its label is `Runtime ready`. The element exists immediately with
`Loading runtime…`, so the test is timing-dependent. The 2026-09-17 handoff run
reported 2 passed and 1 failed for this reason. Use a predicate/value wait for
manual verification and do not claim the full suite is stable until the test is
corrected in an explicitly scoped change.

## Personal physical iPhone procedure

The next architecture experiment should run on a personal iPhone, not infer
CallKit behavior from the simulator.

1. Connect/unlock the iPhone and accept the computer trust prompt if needed.
2. Enable Developer Mode on the device if iOS requests it.
3. Open `Crossbar.xcodeproj` in Xcode.
4. In Signing & Capabilities, confirm automatic signing uses the user's Personal
   Team. Do not alter the bundle ID merely to silence an unexplained signing
   error without recording why.
5. Select the physical device.
6. Use the Xcode MCP device workflow to build/install/launch when exposed;
   otherwise use Xcode's Run action. Discover the device dynamically rather
   than checking a UDID into source/docs.
7. On first launch, exercise `Run media only` and explicitly record the native
   camera/microphone prompts, preview, physical front/rear switch, mute/camera
   controls, and capture-indicator teardown.
8. Then separately exercise `Start probe` and `Simulate incoming`, recording
   CallKit callbacks and `didActivate`/`didDeactivate` behavior.
9. Test receiver/speaker, wired/Bluetooth if available, interruption,
   background, lock, and foreground/resume.
10. Stop if behavior is ambiguous; preserve logs/results without adding
    MiroTalk/backend/APNs code during this experiment.

### A locked phone fails the launch, not the build

Measured twice on 2026-09-24: with the phone locked, the build succeeded, the install
succeeded, and the launch failed. In a transcript that records only the last exit code this
reads as a build failure, and it was taken for one; it is not, and nothing needs rebuilding.
Unlock the phone and launch again. Only the launch needs the phone awake — the build and the
install do not — so a device run that stops here has already produced a build worth
launching.

At the handoff audit a personal iPhone was visible to Xcode, but it was not used
for a probe run. Do not convert visibility into a “tested” claim.

## Tailscale requirements

The current local-media probe does not contact Family Call or MiroTalk, so
Tailscale is not required to run it.

When native backend/signaling work is explicitly authorized later:

- the iPhone and Mac must be connected to the correct private tailnet;
- use the existing tailnet-only Family Call/MiroTalk HTTPS endpoints described
  in the separate Family Call repository;
- do not print or hard-code private URLs in product UI;
- never enable Funnel, public ports, LAN binds, or third-party TURN;
- verify identity/session behavior through the actual native request path;
- keep production read-only unless a separate exact change is approved.

Corrected 2026-09-24: the first bullet is only half true now, and the difference is the
app's connection mode. A device set up for a **private deployment carries its own tailnet** —
the app brings up its embedded userspace node and dials both clients through its SOCKS
loopback — so the phone does not need the Tailscale app installed or signed in. The tailnet
still has to approve the node once, which the app asks for on the screen where setup is
waiting, and the Mac in a rig still needs a tailnet connection of its own. A device set up
for a server at a hostname is the other way round: it dials the address it was given over
whatever route the phone has, and no node is brought up at all. The remaining bullets are
unchanged.

## Test-result recording

For every experiment record:

- date and environment (simulator/device model and OS);
- commit/tag;
- exact action;
- expected behavior;
- actual behavior;
- evidence location/result summary;
- conclusion and what remains unproven.

“Compiled,” “simulator tested,” and “physical-device tested” are separate
statuses. A green generated test with no assertions is not behavioral evidence.

## Git hygiene

Before a commit:

```sh
git status --short --branch
git diff --check
git diff --cached --check
git diff
git diff --cached
```

Do not commit DerivedData, `.xcresult` bundles, `.DS_Store`, user interface
state, secrets, signing credentials, runtime databases, or logs containing
private endpoints/tokens. The repository contains two already-tracked
user-specific files from the probe checkpoint:
`Crossbar.xcodeproj/project.xcworkspace/xcuserdata/azzaam.xcuserdatad/WorkspaceSettings.xcsettings`
and
`Crossbar.xcodeproj/xcuserdata/azzaam.xcuserdatad/xcschemes/xcschememanagement.plist`.
Do not treat them as a reason to commit additional `xcuserdata`.

## Local two-party rig (no second person needed)

Every lock/background/call question needs a real peer, and the directory's own members
cannot sign in (the deployed `Dad`/`Mum` logins are still `replace-with-…` placeholders
and no device is registered for them). The second participant is therefore the **Family
Call PWA as Dad**, taken from the server's own development identity mode, and the phone
is Abdullah over Serve — the same topology as production, on one Mac. Used 2026-09-20 to
find that CallKit, not the call, ends a call when the device locks
(`NATIVE_PROGRESS.md`, "Lock during a CallKit call").

1. **Server.** `cd server && npm start` with its own `.env` (loopback only,
   `ALLOW_DEV_IDENTITY=true`, `PORT=3010`). `.env` points `WEB_ROOT` at the PWA, so the
   server serves it. A separate `DIRECTORY_CONFIG_PATH` maps `abdullah` to the real tailnet
   login (so the phone is Abdullah) and keeps `dad@dev`/`mum@dev` for the browser;
   `DEV_IDENTITIES=dad@dev,mum@dev`. Nothing here touches production.
2. **Reachability.** The listener is loopback-only by design, so the phone needs
   `tailscale serve --bg --https=8445 http://127.0.0.1:3010` on the Mac. Verify from
   another tailnet node: `GET /api/session` must return `source: "tailscale"` with the
   rig's `userId`.
3. **Dad.** Open `http://127.0.0.1:3010/` and set `document.cookie =
   'crossbar.dev.identity=dad@dev; path=/'`. Loopback is what makes the dev identity
   legal, and the PWA's call frame inherits it because `PUBLIC_ORIGIN` stays loopback.
4. **The phone.** Point it at the Mac with the app's two Settings fields — `Address` and
   `Signalling address` — both to the Serve URL. Both are needed: the invitation's own
   origin is loopback, so the second one is what the socket dials. **Put them back
   afterwards**; the preferences daemon keeps its own cache, so writing the plist into
   the app's container does *not* change what the app uses.
5. **Answering.** The PWA rings and needs a click on `#answer-button`. To answer without
   a person watching, drive the open tab over CDP (`--remote-debugging-port` is on the
   omp-managed browser) and click when `#incoming-dialog` is open; the PWA then does the
   responding, the call frame and the media itself.

`GET /api/calls` is only origin-checked on writes, and a request with **no** `Origin`
header is always allowed — which is how a script answers a call as Dad without a browser.

### Which origin to publish, and what it costs

`PUBLIC_ORIGIN` decides what the invitation's `joinUrl` points at, and only one value can
be published at a time. The choice is a real trade, measured 2026-09-21:

| `PUBLIC_ORIGIN` | The phone needs | The browser needs |
| --- | --- | --- |
| the Serve URL | the server address only — everything else follows from it | it **cannot** take part: its POSTs carry `Origin: http://127.0.0.1:3010`, which no longer matches, so `checkOrigin` refuses them |
| loopback | the server address **and** the signalling override, because the `joinUrl` name it is handed is `127.0.0.1` | nothing: the origin matches and the dev cookie identifies it |

So: phone-only testing (enrolment, identity, a call the phone places alone) is simplest
with `PUBLIC_ORIGIN` set to the Serve URL, and a two-participant call is simplest with it
left at loopback plus the signalling override. Both were run.

### A device-auth rig

Setting `CROSSBAR_SESSION_SECRET` is what makes the `/api/auth/*` routes exist at all;
without it they answer 404, which a client is required to read as "this server does not
use device authentication" rather than as an error. To test enrolment:

```bash
DIRECTORY_CONFIG_PATH=/tmp/crossbar-rig-directory.json CROSSBAR_SESSION_SECRET=… \
  PUBLIC_ORIGIN=https://<mac>.ts.net:8445 node src/admin.js enroll --user abdullah
```

The payload it prints is what a device pastes — and its `server` field is `PUBLIC_ORIGIN`,
so set that to the address the device will actually dial before creating the invitation,
or the code will point the device at loopback. An invitation is single use: one per
device, and the CLI prints the plaintext exactly once because only its hash is stored.

One ordering point, worth knowing before a device is set up against a private rig: the
enrolment is the first request the app ever makes, and on a private deployment it can only
be made through the network the app carries. The screen reads the code first — the address
*and* the mode it names — brings that network up, showing the wait as itself with the
Tailscale approval page on the same screen, and enrols only once the carrier has carried a
request. So `server` and `mode` decide the whole sequence, and a device that cannot reach the
rig reports it as the network failing to come up, on the screen it is stuck on, rather than
as an enrolment that was refused.
