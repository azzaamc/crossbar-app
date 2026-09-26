# Crossbar native progress

Last audited: 2026-09-17 (Asia/Karachi), except the push and notification path, the setup
sequence and the embedded node's recovery, which were re-verified against the project and
against a device on 2026-09-24 — see the verification record for exactly which rows that
covers.

## Status in one sentence

Crossbar is a native SwiftUI iOS client for the Family Call platform. As of 2026-09-18
it has a **product shell** — contacts, placing and answering, an in-call screen with
video tiles and controls, and CallKit driven by the product flow rather than a debug
probe — over an engine that places and joins real calls to a real family member,
carrying audio and video both ways.

It **can** now be rung with the app closed, and told about a call it missed, on both sides
of the wire: PushKit, the CallKit report, two device tokens filed separately, and the
service's routes for them. Both tokens were filed from a signed build on a real device on
2026-09-24 — but that was an earlier device, and the device enrolled at 16:19 that day had
still filed no VoIP token at 17:31: PushKit announces a token once per launch *before any
load runs*, so on a private deployment the announcement went out over the direct route to an
address only the app's own network can resolve. The app now holds a token it could not file
and files it once a load has settled, so the next launch filed it — `dev_RhB3R7UuH9TqbmBJ …
RING yes` — and a test call produced `push_dispatched … phones: 1, dropped: 0`. What has
*not* been observed is delivery — no push has been seen arriving, so a ring on a locked
phone and a missed-call notification are implemented but unmeasured. Shipping to anyone else
needs a paid Apple Developer Program
membership: the current free personal team provisions one device and expires every seven
days. Instruments, reproduction commands and the list of what is *not* measured are in
`ARCHITECTURE_B_PROBE.md`.

As of 2026-09-19 the app also **carries its own tailnet**, so it no longer needs the
Tailscale app installed and signed in on the phone. `Core/TailnetNode.swift` brings up an
embedded userspace tsnet node at launch, and both clients dial through its SOCKS loopback
via `Core/CallTransport.swift` — the control plane and the MiroTalk signalling socket
alike, with the route named on the contacts screen so a direct session and a carried one
cannot be confused. What the node can carry is structural, not a setting: it carries those
two HTTP paths, and it **cannot carry media**, because a userspace node has no network
interface for libwebrtc to gather a candidate on. A call's audio and video take the
ordinary WebRTC path over the device's own interfaces. See `TAILSCALE_KIT_PROBE.md`.

## Repository and checkpoint

- User-designated workspace root:
  `/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar`
- Actual Git worktree and Xcode project directory:
  `/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar`
- Project: `Crossbar.xcodeproj`
- Branch at audit: `codex/architecture-a-spike`
- Probe checkpoint: `8c543e0` (`checkpoint: Architecture A iOS WebRTC probe`)
- Existing tag at audit: `codex-handoff` points to `8c543e0`

The outer workspace is not a Git repository. Do not “fix” that by moving the
project or initializing a second repository. OMP entry-point files exist at the
outer level, while their canonical tracked versions live in the nested
worktree.

## Xcode project inventory

| Item | Current value |
| --- | --- |
| Xcode | 27.0 (`27A266a`) |
| Scheme | `Crossbar`, now tracked as a shared scheme at `Crossbar.xcodeproj/xcshareddata/xcschemes/Crossbar.xcscheme` (added 2026-09-17). Before that, only Xcode's in-memory autocreated scheme existed, so a clean checkout had none |
| App target | `Crossbar` |
| Unit-test target | `CrossbarTests` (Swift Testing) |
| UI-test target | `CrossbarUITests` (XCTest) |
| App entry | `Crossbar/CrossbarApp.swift` |
| Interface/language | SwiftUI / Swift |
| Swift language setting | Swift 5.0 |
| Default actor isolation | MainActor |
| Bundle identifier | `com.abdullahchaudhry.Crossbar` |
| Version | 1.0 (build 1) |
| Minimum deployment target | iOS 27.0 |
| Device families | iPhone and iPad (`1,2`) |
| Signing | Automatic; an Apple development team is selected in the project |
| Generated Info.plist | Generated, from `Crossbar/Info.plist` plus `INFOPLIST_KEY_*` build settings |
| Privacy strings | Camera and microphone usage descriptions present |
| Entitlements file | `Crossbar/Crossbar.entitlements` — `aps-environment` only, as `$(APS_ENVIRONMENT)` |
| Capabilities | None toggled in the project; the APNs entitlement is written by hand in the entitlements file |
| Background modes | `voip` and `audio`, declared in `Crossbar/Info.plist` |
| PushKit/APNs | Implemented. `aps-environment` is per configuration (Debug → `development`, Release → `production`); a VoIP push rings a sleeping phone, and a second alert token carries a missed call. Both tokens are filed with the service, and a token PushKit announces before the app can file it — which is what every launch does — is held until a load has settled rather than dropped. See the verification record for what has been observed |
| Packages | `stasel/WebRTC` 153.0.0 via SwiftPM, pinned in `Package.resolved` (revision `4266157c`). The xcframework is a binary artifact fetched at build time — not vendored in the repository |
| Linked third-party frameworks | `WebRTC.framework` (BSD-3-Clause plus a Google patent grant), embedded in the app bundle and linked as `@rpath/WebRTC.framework/WebRTC` |
| Persistence | None; no SwiftData/Core Data |

Do not record team identifiers, certificates, profiles, or other signing
credentials in handoff documents. A Personal Team is sufficient for the next
local physical-device probe, subject to Xcode provisioning.

The iOS 27.0 minimum is inherited from the generated project. It has not been
selected from the directory device inventory and should not be treated as a
product decision.

## Current file map

### App shell

- `Crossbar/CrossbarApp.swift`: generated `@main` SwiftUI entry point; presents
  `ContentView`.
- `Crossbar/ContentView.swift`: the product root. Owns the single `CallSession` and
  shows whichever screen the state calls for — loading, unavailable, incoming, in-call,
  or contacts — so one place decides what "in a call" looks like.
- `Crossbar/Assets.xcassets/`: generated application assets.

### Product

- `Crossbar/Core/CallSession.swift`: the product state machine — identity, contacts,
  one call at a time, the media engine behind it, and the event stream. Every user
  action routes through CallKit, which calls back in.
- `Crossbar/Core/CallKitController.swift`: `CXProvider`/`CXCallController` for the
  product flow. Reports and calls back; keeps no call state of its own, because two
  owners of "which call is this" is how they come to disagree.
- `Crossbar/Features/ContactsView.swift`, `InCallView.swift`, `IncomingCallView.swift`:
  the three screens.

### Engine

Compiled in Release as well as Debug — product code cannot depend on Debug-only files.

- `Crossbar/Core/ServiceClient.swift`: the control plane — identity, contacts,
  create, respond, join, end, and the `/api/events` stream — plus `JoinTarget`, which
  recovers the room id and signalling origin from the `joinUrl`.
- `Crossbar/Core/TailnetNode.swift`: the family network the app carries itself. Brings up
  the embedded userspace tsnet node, surfaces its login page on a first run, hands out the
  carrier both clients dial through, and rebuilds the node when a suspension leaves its
  cached loopback dead.
- `Crossbar/Core/CallTransport.swift`: how a client's sockets leave the device — the
  configuration, and the label naming its route, because a carried session and a direct one
  are otherwise identical in a log.
- `Crossbar/Core/AppSettings.swift`: the few things a person can change — the service
  address, the signalling override, and whether the app carries its own tailnet.
- `Crossbar/Features/CallStage.swift`: the call's video composition — remote on the stage,
  the local capture as a draggable corner, two columns for three people, stage plus strip
  for four, and never a scroll.
- `Crossbar/Core/MiroTalkSignalClient.swift`: the Engine.IO v4 / Socket.IO v5 client,
  peer connections with the synthesised offer policy, remote video tracks and peer
  names, and per-transport ICE path reporting.
- `Crossbar/Core/CallMediaSource.swift`: one capture feeding many senders, camera
  switching, and the CallKit audio-session adoption with its forced gate transition.
- `Crossbar/Core/CallVideoGrid.swift`: `VideoTile` and `CallVideoGrid`, both observing
  the signalling client directly rather than through an outer model.
- `Crossbar/Core/RTCVideoSurface.swift`: the `RTCMTLVideoView` wrapper that draws any
  `RTCVideoTrack`.

### Instruments (`#if DEBUG`)

Reachable from Settings → Advanced → Instruments rather than owning the app.

- `Crossbar/Prototype/ProbeView.swift`: the entry point that assembles them.
- `Crossbar/Prototype/AudioSeamProbe.swift`: the seam spike — CallKit session
  adoption, a local loopback peer connection so the audio device module is genuinely
  exercised, produced video frames, app lifecycle, and its screen.
- `Crossbar/Prototype/SignalProbe.swift`: joins a room directly and reports what the
  protocol does, with no control plane involved.
- `Crossbar/Prototype/BackendReachabilityProbe.swift`: a bare `URLSession` GET used to
  establish that tailnet Serve injects the identity header for a non-browser client.
- `Crossbar/Prototype/CallFlow.swift`: the control-plane debug surface, kept
  because it exercises paths the product shell does not.
- `Crossbar/Prototype/CallKitManager.swift`, `CallProbeModel.swift`,
  `WebMediaEngine.swift`, `RuntimeProbe.html`: the Architecture A probe, retained as
  the evidence for why Architecture B exists at all.
- `Crossbar/Prototype/TailscaleProbe.swift`: drives the **product's** node rather than
  owning one — a second node pointed at the same state directory would fight the first for
  both the device identity and the path — and measures it: both halves of the wire contract
  through the carrier, and the node's own peer counters, which are the only evidence that
  says *which* carrier moved the bytes while the system Tailscale app is also installed.

The instruments write to the app's Documents directory (`seam.log`, `signal-*.log`,
`backend.log`, `familycall.log`, `tailscale.log`, the node's own `tailscale-node.log`, and
the product's `session.log`) so results can be pulled rather than read off a screenshot.

### Tests

Both generated scaffolds were removed on 2026-09-19, because neither could fail on a
plausible bug and one could not pass at all:

- the unit target held an empty `example()` with no assertions;
- `CrossbarUITests.testExample` asserted that the label of `probe.status` is
  `Runtime ready`, and no element with that identifier exists anywhere in the app — it
  belonged to the Architecture A web runtime. The identifier it waits for is gone, so it
  failed for a reason no wait could fix. (`ARCHITECTURE_B_PROBE.md` and the earlier
  revision of this file described it as a synchronization defect; it was also a stale one.)

`CrossbarUITests.testLaunchPerformance` remains: it measures launch time and nothing else.

`testExample` is timing-dependent because element existence occurs while the
label can still be `Loading runtime…`. See **Verification record**.

## What exists today

Architecture A (the WebKit probe — retained as evidence, not on the product path):

- Native SwiftUI host and diagnostic controls.
- A CallKit wrapper/interface and DEBUG incoming-call simulation path.
- A visible frameless WKWebView media surface.
- Native-to-JavaScript commands: `join`, `leave`, `setMuted`,
  `setCameraEnabled`, `switchCamera`, and `setAudioSessionActive`.
- JavaScript-to-native event delivery through one `crossbar` message handler.
- Explicit local track stop on leave.

Architecture B (DEBUG instruments, measured on the physical iPhone):

- Native WebRTC media under CallKit, with `RTCAudioSession` adopting the CallKit
  session and audio measured flowing through a full activate → deactivate → activate
  cycle.
- A native Engine.IO v4 / Socket.IO v5 client that connects to production MiroTalk,
  joins a room, and relays SDP and ICE in the audited shapes.
- Peer connections with a synthesised offer policy, a data-channel renegotiation
  answered against MiroTalk's own browser client, and a three-peer mesh.
- A shared local capture feeding every peer connection.
- One authenticated call to the Family Call API (`GET /api/session`) through tailnet
  Serve, with no backend change.
- A native Family Call control-plane client: identity, contacts, call create/respond/
  join/end, and the `/api/events` stream, with the room id and signalling origin taken
  from the `joinUrl` the backend returns.
- Native rendering of remote video: a remote track from MiroTalk's own browser client,
  decoded and drawn beside the local capture.

## What does not exist

Corrected 2026-09-19. This list was written against the 2026-09-17 audit and several of
its entries have since been built; what follows is what is actually absent now.

- **Inviting a second participant, and the group route.** Placement, answering, declining,
  rejoining and ending have all run for real calls. Nothing can start a call with more than
  one invitee, and `DirectoryGroup` is decoded and logged but never drawn.
- **A push that has actually been delivered.** PushKit, APNs, both device tokens and the
  service's routes for them exist and are committed, and a signed build filed both tokens
  against the service on a real device on 2026-09-24. A device enrolled later the same day
  filed nothing until the app was changed to hold a token announced before any load could
  file it; its next launch filed the VoIP token, and a test call dispatched a push. No VoIP
  push and no missed-call notification has been seen *arriving*, so whether a sleeping phone
  rings is not measured. There is no notification-service extension, and neither push needs
  one: neither carries a mutable payload.
- **Any measurement of video quality.** Rendering works; frame rate, resolution, latency
  and recovery from packet loss are unmeasured, and camera switching, orientation and
  size negotiation are untested.
- **Keychain, or any persistence beyond `UserDefaults`.** Defaults hold exactly two things:
  the call this device is in, and an optional tailnet auth key.
- **Extracted/copied/adapted MiroTalk source.** None — the client is original code written
  against `MIROTALK_CORE_AUDIT.md`, so the AGPL review still precedes any reuse.
- **Media over the overlay.** Not absent by omission: an embedded node structurally cannot
  carry it. A call's media is peer-to-peer over the device's own interfaces.

## Fixed after the first real call (2026-09-19)

The first real 1:1 call between this app and the family PWA worked — the app carried its
own tailnet, the call connected, and media crossed both ways — and the camera switch
crashed the app.

Two `EXC_CRASH` reports, both `SIGABRT` / `Abort trap: 6`, both faulting on
`org.webrtc.RTCDispatcherCaptureSession` and throwing from
`-[AVCaptureVideoDataOutput setVideoSettings:]`: an Objective-C exception, which Swift
cannot catch, so the process aborted the moment the camera was flipped.

Cause, from the SDK's own headers: `stopCapture` and `startCapture` are both
**asynchronous**, and the switch called them back to back, so the start reconfigured the
same video data output while the previous session was still being dismantled. A second
hazard sat in the same expression — the format passed was
`supportedFormats(for: device).last`, and the tail of an iPhone's format list is where the
high-frame-rate and semi-compressed formats live, while WebRTC derives `videoSettings` from
whatever format it is handed.

`CallMediaSource` now waits for the stop's completion handler before starting, flips its
position flag only once a start has actually succeeded, and chooses a format deliberately:
the SDK's `preferredOutputPixelFormat`, a frame rate inside that format's own range, and
720p preferred over the largest available.

Verified on the device with `CROSSBAR_CAMERA_SELFTEST=1`, which drives a start and two
switches with no call and no peer — the only way to reach that path without a live 1:1 call
and a finger on the button, which is why it reached a phone before it reached a probe:

```
camera self-test: capture starting on the front camera…
media: capture → Front Camera 1280x720@30
media: flip → Back Camera 1280x720@30
media: flip → Front Camera 1280x720@30
media: capture stopped
```

No crash report followed that run.

## Verification record

### Source checkpoint experiments (2026-09-16)

The `iPhone 18 Pro` iOS 27.0 simulator was used.

| Experiment | Expected | Actual evidence | Conclusion |
| --- | --- | --- | --- |
| Debug build | Project compiles | XcodeBuildMCP build succeeded without diagnostics | Compile pass only |
| Release build | DEBUG probe excluded from Release UI code | Release build succeeded; Release branch of `ContentView` is the placeholder | Compile pass only |
| Runtime load | Local HTML emits ready event | UI reached `Runtime ready`; event log showed `web → native: runtimeReady` | Bundled runtime and message handler work in simulator |
| Local media | `getUserMedia` returns local audio/video | Simulator synthetic camera rendered; events included `permissionStateChanged`, `localMediaReady`, `joined` | Local simulator media path works |
| Native controls | Swift commands reach JS | Mute/camera/camera-switch state events returned to Swift | Command bridge works for tested controls |
| Teardown | Tracks stop and state returns idle | `leave` event returned and UI reached `Call ended` | Local teardown path works in simulator |
| Outgoing CallKit request | System accepts transaction | Simulator returned `com.apple.CallKit.error.requesttransaction error 1` | Simulator cannot establish the required CallKit result |
| Test suite | Three configured tests pass | One 2026-09-16 run reported 3 passed | Historical pass; later shown to be timing-dependent |

The iOS permission sheet itself was not separately asserted by UI automation.
`WKUIDelegate` grants web-origin capture, but this is not evidence of a physical
iOS camera/microphone permission prompt.

### Handoff re-verification (2026-09-17)

Environment: Xcode 27.0, iOS 27.0 `iPhone 18 Pro` simulator.

- Debug simulator build: passed.
- Release simulator build: passed.
- Manual build-and-run: passed.
- UI automation waiting for `Runtime ready`: passed.
- Full test suite: **2 passed, 1 failed**.
- Failure: `CrossbarUITests.testExample` observed `Loading runtime…` after the
  element existed and immediately failed equality against `Runtime ready`.

This failure is a test synchronization defect, not evidence that the bridge is
permanently broken: the unchanged app subsequently reached `Runtime ready`
under a predicate-based UI wait. No test source was changed during this handoff.

A physical iPhone named `Azzaam’s iPhone` running iOS 27.0 was visible to Xcode
during the 2026-09-17 audit. The handoff did **not** install, launch, or test the
probe on it. Availability is not a test result.

The subsequent OMP takeover session did install, launch, and partially test the
unchanged probe on that device; see P8 in `ARCHITECTURE_A_PROBE.md` and the
matrix below. The probe UI remains a DEBUG diagnostic, not a product surface.

### Physical device probe (2026-09-17)

Device: `iPhone 17 Pro` (iPhone18,1), iOS 27.0 (24A437), Developer Mode enabled,
paired over local network. Host: Xcode 27.0 (`27A266a`). Debug build of the
unchanged probe at `d769412`.

Facts established on the installed device bundle rather than inferred:

- both privacy usage strings are present in the installed `Info.plist`;
- `UIBackgroundModes` is absent, so the probe has no background execution mode;
- the signed app's entitlements are limited to `application-identifier`, the
  team-identifier key, and `get-task-allow` — no capabilities, confirming there
  is no background audio and no VoIP background mode;
- `MinimumOSVersion` is 27.0 and `RuntimeProbe.html` is present in the device
  build.

Results obtained so far are recorded as P8 in `ARCHITECTURE_A_PROBE.md`. The
CallKit, audio-session, teardown, and lifecycle items remain untested and are
marked as such there.

### Push tokens filed from a signed build (2026-09-24)

Device: `Azzaam’s iPhone` (UDID `600A99C4-FB71-5C63-A3F3-E5A25515D41B`), iOS 27.0. A
Debug build of the app as committed at `b303b5d`, installed and launched with
XcodeBuildMCP's device build-and-run. The evidence is the app's own log, pulled off the
device with `devicectl device copy from --domain-type appDataContainer
--domain-identifier com.abdullahchaudhry.Crossbar --source Documents/session.log` — read
from the file after the fact rather than off a screen:

```
dialling direct — A Crossbar server
GET api/session (requesting)
POST https://call.azzaamc.com/api/devices/push-token
POST https://call.azzaamc.com/api/devices/push-token
  -> HTTP 200, 14 bytes
  filed this device's voip push token for the sandbox environment: saved=true
  -> HTTP 200, 14 bytes
  filed this device's alert push token for the sandbox environment: saved=true
GET api/session -> HTTP 200 authenticated=true name=Abdullah
GET https://call.azzaamc.com/api/bootstrap -> HTTP 200, 393 bytes
  bootstrap: 2 contacts, 0 ongoing, 0 open
GET https://call.azzaamc.com/api/calls/history -> HTTP 200, 3639 bytes
GET api/events -> HTTP 200
```

What this establishes:

- The permission path ran to its end. `registerForRemoteNotifications()` is reached only
  when the authorisation is not denied — either a prompt was answered yes, or a decision
  already in place allowed it — and a token came back, which is what the two uploads are.
  The build's entitlement is `development`, which is why both tokens are filed for
  `sandbox` rather than `production`.
- **Both** kinds of token are filed and the service accepted both: two
  `POST /api/devices/push-token` calls, `HTTP 200`, `saved=true`, one per kind. The
  service's two-column split is therefore exercised against a real device, not only
  against its tests.
- The ordinary session loaded normally behind them — identity, two contacts, a history of
  3639 bytes, and the event stream — so nothing in the push path delayed or broke a start.
- `dialling direct` says which route carried it, and it is not the embedded node: this run
  went straight to the service.

What it does **not** establish:

- That anything was delivered. No VoIP push and no missed-call notification has been seen
  arriving; a filed token is the precondition for delivery, not delivery.
- Which revision the deployed service is at. These two writes being *accepted* is all the
  log says; it is not evidence that the missed-call sender is live at that address.
- Anything about the foreground-presentation rule, the notification tap handler, or the
  haptics, none of which can be reached without a delivered push or a real two-party call.
  `simctl push` was attempted as a substitute and refused: "Repository could not save
  notification. Source is not authorized."

### The device enrolled later that day, and the four faults it found (2026-09-24)

A second device was set up against the private deployment later the same day, and it is the
run behind the rest of this record. It filed no push token, and could not bring its network
up at all until the state an earlier run had left behind was cleared. Four separate faults
were behind that, and the ring at the end of this section is what says they are fixed.

**A token announced before anything could file it.** PushKit announces the VoIP token once
per launch, *before any load runs*, and both of the ways the upload can then fail are races
the app loses by construction. A device that enrols during that same launch is announced
before it exists, so the upload has nothing to file against; and the transport is not up
yet, so on a private deployment the request leaves by the direct route, for an address only
the app's own network can resolve. The token was dropped, and `AppDelegate`'s "the next
launch is the retry" is false for a phone that is only backgrounded, because a backgrounded
app is not launched again. Measured: a phone that enrolled at 16:19 still had `voip_token =
null` at 17:31, on a launch whose `presence_broadcast` shows the load itself was fine. Now
`CallSession.heldPushTokens` holds the token across **both** failures and
`fileHeldPushTokens()` files it once a load has settled, clearing it only when the service
accepts it — so a failure is retried by the next load rather than lost. Measured after the
fix: the next launch filed it (`dev_RhB3R7UuH9TqbmBJ … RING yes`), and a test call produced
`push_dispatched … phones: 1, dropped: 0`.

**Setup enrolled before there was a network to enrol through.** The enrolment is the first
request this app ever makes, and on a private deployment it can only be made through the
network the app carries — so dialling it first meant the first screen anybody sees answered
"could not reach the service". Now `DeviceAuth.settle(from:)` reads the code without
dialling (the address and the mode it names), `CallSession.attachForSetup()` builds the
network through the one place that chooses a route (`attachTransport`, the same decision a
load makes), and `OnboardingView` enrols only after the carrier exists — showing the wait as
itself, "Bringing up your private network…", and offering the Tailscale approval page on
that screen.

**`needsSetup` was never cleared.** `forgetServer()` set the flag and nothing unset it, and
while it is set the root view shows onboarding *instead of* the app — so a device that was
set up again finished onboarding onto a screen that put it straight back there, permanently,
because the load that would have cleared the flag only runs in the branch the flag blocks.
Measured: "You're in" arrived, the enrolment was done, and `/api/bootstrap` never ran. Now
`CallSession.setupCompleted()` clears it, called from `ContentView`'s onboarding closure,
because answering the question and being set up are the same moment.

**The embedded node would not load the state it keeps its identity in.** A bring-up failure
the framework reports as *local* — `connectionClosed`, `badInterfaceHandle`,
`internalError` — means the node cannot load its state directory, and the existing
one-rebuild recovery cannot fix that, because the rebuild reuses the very directory that
will not load. Measured: a state directory two days old failed every bring-up with
`TailscaleError` code 3 — `connectionClosed`, "The underlying connection was closed", thrown
only by the local-API connection layer — until it was cleared. `TailnetNode.attach()` now
clears the state and tries once more. A **posix** error is the network and is deliberately
*not* cleared, because that would cost an approval and fix nothing. `TailnetNode.reset()` is
the same clearing asked for by hand: it removes the state directory and any stored auth key,
and it exists because `signOut()` needs a *running* node to ask, which a node that will not
start cannot be. Deleting the app would work, and this is that without losing everything
else on the device. The setup screen offers it when setup fails, with its cost stated — the
device gets a new identity and must be approved again — and that button was also the evidence
that the state directory was the cause: pressing it is what got past the failure.

**And then it rang.** The fixed build was verified end to end in private mode, with the call
placed from the service's own machine as `ringtest`, the directory's permanent test person:

```
call_created callerId="ringtest" inviteeIds=["abdullah"]
push_dispatched phones=1 dropped=0
call_accepted userId="abdullah"
signal_admitted deviceId="dev_RhB3R7UuH9TqbmBJ" peers=1
call_ended
```

A browser joined in the middle as a second peer (`deviceId="web-dc8b12e1-…"`), and both peers
left cleanly at the end. Ring, answer, signalling and a two-peer room all work in private
mode. What it does not show is delivery: the rings observed happened with the app **open**, so
the socket may have carried them. The push was dispatched and accepted by APNs, and nothing
has been seen arriving on a locked phone.

## Evidence classification

| Capability | Compiled | Simulator tested | Physical iPhone tested |
| --- | --- | --- | --- |
| SwiftUI DEBUG harness | Yes | Yes | Yes (P8.1) |
| Local WKWebView load | Yes | Yes | Yes (P8.2) |
| Swift ↔ JavaScript bridge | Yes | Yes | Yes (P8.2) |
| Camera acquisition | Yes | Simulator synthetic feed | Yes — live preview (P8.3) |
| Microphone track acquisition | Yes | Event/track path only | Yes — track created on device (P8.3, P8.10) |
| Native permission sheet | N/A | Not explicitly asserted | Not directly observed; inferred from successful capture (P8.3) |
| Local MediaStream preview | Yes | Yes | Yes, media-only path (P8.3) |
| Mute/camera track controls | Yes | Yes | Mute round trip only; camera off/on not observed (P8.5) |
| Camera switching | Yes | Simulator event completed | Re-acquisition confirmed by OSLog; visible change unconfirmed (P8.4) |
| Local teardown | Yes | Yes | Yes — capture released on call end (P8.12) |
| CallKit incoming | Yes | Not supported | **Yes** — native Accept/Decline; answer and decline delivered (P8.8) |
| CallKit outgoing | Yes | Rejected (`.unentitled`) | **Yes after two probe fixes** — error `(null)` on a cold start (P8.7) |
| `didActivate` / `didDeactivate` | Yes | Not tested | **Yes** — states 1 and 0 delivered (P8.9) |
| WebKit capture during a CallKit call | Yes | Not tested | **FAIL** — WebKit loses its audio session the instant CallKit takes it; capture muted/stopped and preview dies. Fails in all three arrangements tested: app-configured session, WebKit-only, and media-first ordering (P8.10, P8.13, P8.14) |
| Family Call API from native code | Yes | — | **Yes** — `URLSession` GET to `/api/session` through tailnet Serve returned `HTTP 200 authenticated=true identity.source=tailscale` with the enrolled display name, and no `Origin` header. No backend change needed for identity |
| Native WebRTC under CallKit (Architecture B spike) | Yes | — | **Passes in both orderings, audio measured flowing** — with a loopback running, inbound-RTP bytes continue through CallKit taking the session (after the re-arm fix) and through a full activate → deactivate → activate cycle. WebRTC makes no `setActive:` of its own while CallKit owns the session. WebKit's capture died in the same situation |
| Family Call control plane, read paths (native) | Yes | — | **Yes, on the device against production** — `GET /api/session` returned `authenticated=true` with the enrolled display name, `GET /api/bootstrap` returned 982 bytes and decoded into the client's models, and `GET /api/events` delivered its `ready` event through Serve. Establishes that Serve does not buffer SSE |
| Family Call control plane, call lifecycle (native) | Yes | — | **Yes, for what a two-person call runs** — two real calls to a real family member: `POST /api/calls` returned 201 with a `joinUrl`, the room was parsed from it, the invitee answered on MiroTalk's own browser client, `call-status` arrived as `active` over SSE, the native client joined the room, audio and video crossed both ways with the remote video rendered, and `POST /api/calls/:id/end` returned 200. `/join`, `/invite`, a decline and the group route remain unexercised |
| Remote video rendering (native) | Yes | — | **Yes, on real calls** — a remote track from MiroTalk's own browser client decoded and drawn natively, showing a different person in a different room beside the local capture, alongside roughly 2.4 Mbps of inbound video measured per kind |
| Product shell (native UI and CallKit) | Yes | — | **Yes** — a real call placed from the product UI through CallKit, answered on MiroTalk's own browser client, carrying audio and video both ways; ringing, accepting, declining and ending all verified on device, plus recovery of an invitation that arrived while the app was suspended. Audio-session configuration and speaker routing corrected, and confirmed by ear |
| Incoming call while the app is suspended | Yes | — | **No, and not fixable in the client.** iOS suspends the app when the screen locks, which kills the signalling socket, and only a push can wake a suspended app. A locked phone does not ring until the app is opened — at which point the waiting invitation is found by re-reading `/api/bootstrap`. Needs APNs and a server-side device-token model, neither of which exists. **Superseded 2026-09-24:** both now exist and are committed, and a signed build on an earlier device filed both of its tokens with the service — so this row's "No" still stands as a *measurement*, but no longer as a statement about what the client can do |
| Room id parsed from the `joinUrl` | Yes | — | **Yes** — production `joinUrl`s from two real calls each yielded their room and signalling origin, and the client joined those rooms |
| Native capture teardown (Architecture B spike) | Yes | — | **Yes** — after Stop, `capture stopped` is logged and the status-bar camera/mic privacy indicators are absent, which is the objective evidence capture was released. The preview keeps its last rendered frame, so the preview alone proves nothing |
| Native in-call UI for a started call | Yes | Not supported | Not observed (P8.11) |
| Audio route behaviour | Yes | Not meaningfully tested | **Spike (B) partial** — AirPods connect/disconnect produced route reasons 1 and 2 and WebRTC followed the route rather than fighting it; speaker override and wired not tested |
| RTCPeerConnection/SDP/ICE | Yes | — | **Spike (B) loopback** — two peer connections negotiate offer/answer locally over host candidates with real ICE, DTLS-SRTP and SRTP media; single process, no server |
| Remote media | Yes | — | **Yes** — inbound RTP measured flowing both ways with a real browser peer on a separate device, and the phone's camera rendered in MiroTalk's own client |
| MiroTalk signaling | Yes | — | **Yes** — native Engine.IO/Socket.IO connects to production MiroTalk, joins, receives `addPeer`/`serverInfo`, and relays SDP and ICE in the audited shapes |
| Two-device call | Yes | — | **Yes, with MiroTalk's own browser client** — a native peer and Safari on a second tailnet device negotiated, the browser answered the native offer and then renegotiated a data channel which the native client answered, ICE completed, and media crossed both ways with the phone's camera rendering in Safari |
| MiroTalk signalling through the embedded Tailscale node | Yes | — | **Yes** — a full two-peer call (admission, `addPeer`, SDP and ICE relay, negotiation to `pc state 2`, ~33 MB of video each way) ran with both sockets dialled through the node's SOCKS loopback. The node's own peer counters went 0 → ~86 KB at the moment the socket connected, which is what separates the node from the system Tailscale app that is also installed on the phone. Branch `tailscale-kit`; see `TAILSCALE_KIT_PROBE.md` |
| Embedded node as the app's transport | Yes | — | **Yes** — the product starts the node itself and dials both clients through it: `carried by the embedded node — node 127.0.0.1:61174`, then `GET api/session -> HTTP 200 authenticated=true name=Azzaam Chaudhry`, `GET api/bootstrap -> HTTP 200` (2 contacts) and `GET api/events -> HTTP 200`, measured from the app's own log pulled off the device on 2026-09-19. No Tailscale app involved; the tailnet lists the node as `crossbar-ios` (100.121.218.110). A carrier that answers nothing is reported as a failure rather than retried on the system route |
| Signalling through the node, by the product's own carrier | Yes | — | **Yes, 2026-09-19** — with `CROSSBAR_TAILNET_NODE` left at its default, two peers joined one MiroTalk room through `TailnetNode.attach()`, the same carrier `CallSession` hands to both clients: `connecting wss://… via node 127.0.0.1:61719` for both, then `pc state -> 2`, `ICE path … state=succeeded`, and media both ways (`bytesSent=177169`, `media IN … audio`). The instrument's route toggle now defaults to the node, since that is the product's route |
| Incoming invitation found at launch | Yes | Yes | **Yes** — against a stub control plane served over this Mac's tailnet name: the app logged `an invitation was waiting for this device — ringing it`, `incoming call … from Dad status=ringing`, `reported to CallKit`, and the incoming-call UI and system banner appeared. Before this the app opened onto the contacts list while somebody was still ringing, because an invitation survives only in `/api/bootstrap` → `calls[]` as `myStatus: "invited"` and `load()` looked only at `ongoingCalls` |
| Camera released when a call ends mid-start | Yes | — | **Yes** — `CROSSBAR_CAMERA_SELFTEST` drives the race deliberately: `media: capture stopped — the stop arrived before the start was confirmed`, and the status bar shows no camera indicator afterwards. The bug it fixes left the camera running after an outgoing call nobody answered |
| In-call video layout | Yes | **Yes** | **Partly** — measured on the simulator against a real remote peer (the phone, in the room through its own node): one remote filled the stage edge to edge (402×230 pt) while the local preview sat in a corner at 86×115 pt with a 10 pt inset, and a drag moved it to the diagonally opposite corner, where it stayed. The three- and four-participant arrangements are covered by geometry assertions rather than by a rendered call |
| Settings surface | Yes | **Yes** | **Yes** — Service (address, signalling override, reconnect), Network (route, embedded-node switch, sign-out, console link), Identity (name, source) and Advanced (instruments, camera and CallKit self-tests) all render; sign-out is disabled while the node is switched off, which is the correct state |
| Media over the overlay from an embedded node | Yes | — | **No, and structurally so** — a userspace tsnet node has no network interface (`"TUN":false`, `using fake (no-op) tun device`), so libwebrtc cannot gather a candidate on the overlay: the node's own address never appeared among the 55 candidates gathered during a node-carried call, while the system Tailscale tunnel's address did. Media rode the phone's Wi-Fi host pair, as it does today |
| Native peer ↔ MiroTalk browser client, over the embedded node | Yes | — | **Yes** — the phone's app signalling through the node with its Tailscale app *disconnected* called MiroTalk's own web client in Chromium on the Mac: the browser offered 3 m-lines (audio, video, data channel), the native client answered, `pc state 2` / `ice state 2`, and media crossed both ways over the LAN pair (phone `192.168.1.120` ↔ Mac `192.168.1.127`), ~18 MB of the phone's camera to the browser and the browser's pattern back, seen on both screens. Every pair to the Mac's tailnet address sat `in-progress sent=0 recv=0`. Branch `tailscale-kit` |
| Three-/four-person mesh | Yes | — | **Spike (B) three peers** — three native peers formed three links with two connections each; every link reached `pc state 2` and carried media both ways, with one shared capture feeding all senders. Four peers untested |
| Camera status signalled to peers | Yes | — | **Yes** — leaving the app sends MiroTalk's `peerStatus {element:"video", status:false}` and returning sends `status:true`, in the shape read from the deployed client. Verified by the far end: the browser's peer `<video>` went `display:none` with its avatar shown while the phone was away, and back to `display:block`, playing, with `currentTime` advancing on return. Also wired to the product's own camera button, which previously moved no status at all |
| Picture-in-Picture on leaving a video call | Yes | — | **Yes, after two corrections** — `AVPictureInPictureVideoCallViewController` armed while the call screen is in front, so the system opens the window on backgrounding and closes it on return (AVKit does not dismiss it itself). The first version showed a **still picture** because a `RTCMTLVideoView` renders with Metal, which is not driven in the background; the window now uses an `AVSampleBufferDisplayLayer` fed by an I420→NV12 conversion, Apple's own recommendation for video-call PiP. It also took the **camera** away, because iOS 16 puts camera access in PiP behind `AVCaptureSession.isMultitaskingCameraAccessEnabled`; with that set, a call in PiP keeps transmitting — measured: 20 fps into the window with 0 dropped while backgrounded, and the far end's `currentTime` advancing throughout. Only a call with no window falls back to audio |
| Background/lock/resume | Yes | No | **Revised 2026-09-19, and the earlier reading was incomplete** — the spike's `audioUnit=1` through lock and background was real but was measuring the seam loopback, which sets `isAudioEnabled` itself; the *call* path did not, so a probe call recorded and played nothing (`totalAudioEnergy` 0.000 in every poll) and iOS froze the process the moment the app was left: stats stopped, the far end's video froze, MiroTalk dropped the peer by +65 s. With audio actually running (manual-audio gate opened) **and** `audio` declared in `UIBackgroundModes`, the same swipe-away leaves the call up: 41 polls and 6 socket pings continued in the background, audio crossed both ways at ~6 KB per 3 s, `totalAudioEnergy` became non-zero, and video stopped on its own because iOS takes the camera. The far end was left staring at a frozen frame until camera status signalling was added, above |
| Lock during a CallKit call | Yes | No | **No, and CallKit is the cause — measured 2026-09-20.** With a real two-party call up (a browser client answered a call the phone placed, two peers in the room, remote video rendering into PiP at 20 fps with 0 dropped), pressing the lock button ended the call: the app logged `callkit: performing end`, i.e. the system asked *it* to end the call, having delivered **no** `willResignActive` and **no** `didEnterBackground` first. The control is the same app, same day, same call, **with no CallKit call behind it** (the app had joined an active call of its own, and `CallKit` rejected the teardown as an unknown call): locking produced `device locked`, `resigning active` and `entered the background`, all with `phase=inCall`; unlocking produced `returning to the foreground` and `device unlocked`, the socket re-dialled, and the call was **still up** — the server logged `peer_left … ended=false` and then `call_joined … peers: 2`. So the lock costs the camera and the signalling socket, and recovers the socket on unlock; it does not end the call. CallKit **requires** the `voip` background mode (removing it fails `CXStartCallAction` with `requesttransaction error 1`, `Unentitled`, on the device), and that mode is meant to be PushKit-backed — which needs `aps-environment`, and so the paid membership. Fix deferred until then; the diagnostics that produced this live in `CallKitController` (a `CXCallObserver`, the app's state at the moment of an end action) and `CallSession.wireDeviceLock` |
| PushKit/APNs | Yes | No | **Implemented and committed; delivery not observed.** The app starts the PushKit registry at launch and files both of its tokens — the VoIP one that rings it and an ordinary alert token for a call it missed — with the service. Measured on a signed build on a device, 2026-09-24: two `POST /api/devices/push-token` calls answered `HTTP 200 ... saved=true`, one per kind, both for the `sandbox` environment, followed by a normal session load. What no device has seen is a push being *delivered*, so the lock behaviour above is no longer blocked on a missing mechanism — it is unmeasured with one present. A device enrolled later the same day filed neither token until the app held one announced before a load could file it, and the launch after that filed the VoIP token |
| Private-mode setup sequence | Yes | — | **Yes, 2026-09-24** — a device enrolled against the private deployment with its network brought up first: the screen showed that wait as itself ("Bringing up your private network…") and offered the Tailscale approval page on it, and the enrolment went out through the carrier. When the enrolment was dialled first, the same screen answered "could not reach the service" |
| `needsSetup` cleared when onboarding finishes | Yes | — | **Yes, 2026-09-24** — a device that had been set up again opened onto the product, with `/api/bootstrap` running, once the flag was cleared from the onboarding closure. While nothing cleared it, the device finished onboarding onto the screen that returned it there for ever |
| Embedded node recovery (state that will not load) | Yes | — | **Yes, 2026-09-24** — a state directory two days old failed every bring-up with `TailscaleError` code 3 (`connectionClosed`) until it was cleared. `TailnetNode.reset()` is the by-hand clear the setup screen offers, and `attach()` now attempts the same clear once, for the framework's local failures only |

## Immediate maintenance issue

The UI test should eventually wait for the status label value to become
`Runtime ready`, not merely for the label element to exist. That is a test-only
synchronization correction; it must not be confused with the Architecture A
physical-device experiment. It was deliberately documented rather than fixed
during this handoff-only task.
