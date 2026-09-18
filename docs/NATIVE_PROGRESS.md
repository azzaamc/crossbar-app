# Crossbar native progress

Last audited: 2026-09-17 (Asia/Karachi)

## Status in one sentence

Crossbar is a native SwiftUI iOS client for the Family Call platform. As of 2026-09-18
it has a **product shell** — contacts, placing and answering, an in-call screen with
video tiles and controls, and CallKit driven by the product flow rather than a debug
probe — over an engine that places and joins real calls to a real family member,
carrying audio and video both ways.

It cannot yet **receive** a call with the app closed. Ringing needs APNs and a
server-side device-token model, neither of which exists, and shipping to anyone else
needs a paid Apple Developer Program membership: the current free personal team
provisions one device and expires every seven days. Instruments, reproduction commands
and the list of what is *not* measured are in `ARCHITECTURE_B_PROBE.md`.

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
| Generated Info.plist | Yes |
| Privacy strings | Camera and microphone usage descriptions present |
| Entitlements file | None |
| Capabilities | None configured |
| Background modes | None configured |
| PushKit/APNs | Not implemented; no capability or entitlement |
| Packages | `stasel/WebRTC` 153.0.0 via SwiftPM, pinned in `Package.resolved` (revision `4266157c`). The xcframework is a binary artifact fetched at build time — not vendored in the repository |
| Linked third-party frameworks | `WebRTC.framework` (BSD-3-Clause plus a Google patent grant), embedded in the app bundle and linked as `@rpath/WebRTC.framework/WebRTC` |
| Persistence | None; no SwiftData/Core Data |

Do not record team identifiers, certificates, profiles, or other signing
credentials in handoff documents. A Personal Team is sufficient for the next
local physical-device probe, subject to Xcode provisioning.

The iOS 27.0 minimum is inherited from the generated project. It has not been
selected from the household device inventory and should not be treated as a
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

- `Crossbar/Core/FamilyCallClient.swift`: the control plane — identity, contacts,
  create, respond, join, end, and the `/api/events` stream — plus `JoinTarget`, which
  recovers the room id and signalling origin from the `joinUrl`.
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

Reachable from the product's Probe button rather than owning the app.

- `Crossbar/Prototype/ProbeView.swift`: the entry point that assembles them.
- `Crossbar/Prototype/AudioSeamProbe.swift`: the seam spike — CallKit session
  adoption, a local loopback peer connection so the audio device module is genuinely
  exercised, produced video frames, app lifecycle, and its screen.
- `Crossbar/Prototype/SignalProbe.swift`: joins a room directly and reports what the
  protocol does, with no control plane involved.
- `Crossbar/Prototype/BackendReachabilityProbe.swift`: a bare `URLSession` GET used to
  establish that tailnet Serve injects the identity header for a non-browser client.
- `Crossbar/Prototype/FamilyCallFlow.swift`: the control-plane debug surface, kept
  because it exercises paths the product shell does not.
- `Crossbar/Prototype/CallKitManager.swift`, `CallProbeModel.swift`,
  `WebMediaEngine.swift`, `RuntimeProbe.html`: the Architecture A probe, retained as
  the evidence for why Architecture B exists at all.

The instruments write to the app's Documents directory (`seam.log`, `signal-*.log`,
`backend.log`, `familycall.log`, and the product's `session.log`) so results can be
pulled rather than read off a screenshot.

### Tests

- `CrossbarTests/CrossbarTests.swift`: generated placeholder unit test; it has
  no assertions and proves no behavior.
- `CrossbarUITests/CrossbarUITests.swift`:
  - `testExample` launches the app, waits for the `probe.status` element to
    exist, then immediately compares its label to `Runtime ready`;
  - `testLaunchPerformance` is Xcode's generated launch metric.

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

- Declining, inviting, rejoining and the group route. Placement, answering and ending
  have run for real calls; the rest of the lifecycle has not.
- Product call UI, contacts UI, ringing UI, navigation, or CallKit in the product flow
  (CallKit is exercised only by the DEBUG Architecture A probe).
- PushKit, APNs, VoIP token registration, notification extension, or backend
  native-device registration routes.
- Background-audio capability or VoIP background mode. None is configured, so the
  signalling socket does not survive backgrounding.
- Any measurement of video quality. Rendering works; frame rate, resolution, latency
  and recovery from packet loss are unmeasured, and camera switching, orientation and
  size negotiation are untested.
- Persistence, Keychain, or UserDefaults usage.
- Extracted/copied/adapted MiroTalk source. None — the spike is original code written
  against `MIROTALK_CORE_AUDIT.md`, so the AGPL review still precedes any reuse.

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
| Incoming call while the app is suspended | Yes | — | **No, and not fixable in the client.** iOS suspends the app when the screen locks, which kills the signalling socket, and only a push can wake a suspended app. A locked phone does not ring until the app is opened — at which point the waiting invitation is found by re-reading `/api/bootstrap`. Needs APNs and a server-side device-token model, neither of which exists |
| Room id parsed from the `joinUrl` | Yes | — | **Yes** — production `joinUrl`s from two real calls each yielded their room and signalling origin, and the client joined those rooms |
| Native capture teardown (Architecture B spike) | Yes | — | **Yes** — after Stop, `capture stopped` is logged and the status-bar camera/mic privacy indicators are absent, which is the objective evidence capture was released. The preview keeps its last rendered frame, so the preview alone proves nothing |
| Native in-call UI for a started call | Yes | Not supported | Not observed (P8.11) |
| Audio route behaviour | Yes | Not meaningfully tested | **Spike (B) partial** — AirPods connect/disconnect produced route reasons 1 and 2 and WebRTC followed the route rather than fighting it; speaker override and wired not tested |
| RTCPeerConnection/SDP/ICE | Yes | — | **Spike (B) loopback** — two peer connections negotiate offer/answer locally over host candidates with real ICE, DTLS-SRTP and SRTP media; single process, no server |
| Remote media | Yes | — | **Yes** — inbound RTP measured flowing both ways with a real browser peer on a separate device, and the phone's camera rendered in MiroTalk's own client |
| MiroTalk signaling | Yes | — | **Yes** — native Engine.IO/Socket.IO connects to production MiroTalk, joins, receives `addPeer`/`serverInfo`, and relays SDP and ICE in the audited shapes |
| Two-device call | Yes | — | **Yes, with MiroTalk's own browser client** — a native peer and Safari on a second tailnet device negotiated, the browser answered the native offer and then renegotiated a data channel which the native client answered, ICE completed, and media crossed both ways with the phone's camera rendering in Safari |
| MiroTalk signalling through the embedded Tailscale node | Yes | — | **Yes** — a full two-peer call (admission, `addPeer`, SDP and ICE relay, negotiation to `pc state 2`, ~33 MB of video each way) ran with both sockets dialled through the node's SOCKS loopback. The node's own peer counters went 0 → ~86 KB at the moment the socket connected, which is what separates the node from the system Tailscale app that is also installed on the phone. Branch `tailscale-kit`; see `TAILSCALE_KIT_PROBE.md` |
| Media over the overlay from an embedded node | Yes | — | **No, and structurally so** — a userspace tsnet node has no network interface (`"TUN":false`, `using fake (no-op) tun device`), so libwebrtc cannot gather a candidate on the overlay: the node's own address never appeared among the 55 candidates gathered during a node-carried call, while the system Tailscale tunnel's address did. Media rode the phone's Wi-Fi host pair, as it does today |
| Three-/four-person mesh | Yes | — | **Spike (B) three peers** — three native peers formed three links with two connections each; every link reached `pc state 2` and carried media both ways, with one shared capture feeding all senders. Four peers untested |
| Background/lock/resume | No | No | **Spike (B) yes** — with a call active, audio survived lock and background (`audioUnit=1` throughout, no stop); video capture stopped on suspension (frame count frozen) and resumed cleanly on return |
| PushKit/APNs | No | No | No |

## Immediate maintenance issue

The UI test should eventually wait for the status label value to become
`Runtime ready`, not merely for the label element to exist. That is a test-only
synchronization correction; it must not be confused with the Architecture A
physical-device experiment. It was deliberately documented rather than fixed
during this handoff-only task.
