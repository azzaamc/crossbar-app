# Crossbar native progress

Last audited: 2026-09-17 (Asia/Karachi)

## Status in one sentence

Crossbar is an Xcode-generated SwiftUI application containing a DEBUG-only,
original-code Architecture B spike. As of 2026-09-18 that spike authenticates
against the real Family Call API, speaks MiroTalk's signalling protocol natively,
renders remote video, and has placed a **real call to a real family member** from
native code: the call was created through the Family Call API, the room was recovered
from the returned `joinUrl`, the native client joined it, the family member answered on
MiroTalk's own browser client, and media crossed both ways. It contains **no product
code**: no call UI, no contacts UI, no CallKit-in-product-flow, no persistence.
Instruments, reproduction commands and the list of what is *not* measured are in
`ARCHITECTURE_B_PROBE.md`.

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
- `Crossbar/ContentView.swift`: in DEBUG, renders the Architecture A diagnostic
  controls and media surface; in Release, renders only `Crossbar` text.
- `Crossbar/Assets.xcassets/`: generated application assets.

### DEBUG-only probe

- `Crossbar/Prototype/CallKitManager.swift`: `CXProvider`/`CXCallController`
  wrapper with start, incoming report, answer, end, mute, connected, reset, and
  audio-session activation callbacks, plus eager provider registration in
  `init()`. It does **not** configure `AVAudioSession`; that setup was removed in
  probe experiment P8.13 so WebKit owns the session on the media path.
- `Crossbar/Prototype/CallProbeModel.swift`: observable coordinator for probe
  UI, CallKit callbacks, WebKit commands, media-only bypass, state text, and the
  `-CrossbarSimulateIncomingCall` launch argument.
- `Crossbar/Prototype/WebMediaEngine.swift`: `WKWebView` host,
  `WKScriptMessageHandler`, media-capture permission delegate, JSON command
  serialization, and bounded diagnostic event log.
- `Crossbar/Prototype/RuntimeProbe.html`: original local HTML/JavaScript runtime
  that performs `getUserMedia`, attaches a local stream to one video element,
  toggles track state, reacquires for camera switching, stops tracks, and emits
  bridge events.

All four files are inside `#if DEBUG` on the Swift side. The HTML resource may
still be copied into a Release bundle by Xcode's synchronized group, but no
Release Swift code loads or exposes it.

The Architecture B instruments live beside them and are also `#if DEBUG`:

- `Crossbar/Prototype/AudioSeamProbe.swift`: the seam spike — CallKit session
  adoption, a local loopback peer connection so the audio device module is genuinely
  exercised, produced video frames, app lifecycle, and the SwiftUI screen.
- `Crossbar/Prototype/MiroTalkSignalClient.swift`: a reduced native Engine.IO v4 /
  Socket.IO v5 client, peer connections with the synthesised offer policy, a shared
  media source, and per-transport ICE path reporting.
- `Crossbar/Prototype/BackendReachabilityProbe.swift`: a bare `URLSession` GET used to
  establish that tailnet Serve injects the identity header for a non-browser client.
- `Crossbar/Prototype/FamilyCallClient.swift`: the real control plane — identity,
  contacts, create, respond, join, end, and the `/api/events` stream — plus the
  `JoinTarget` that recovers the room id and signalling origin from the `joinUrl`.
- `Crossbar/Prototype/FamilyCallFlow.swift`: the flow over that client and its debug
  screen, composing one `MiroTalkSignalClient` with a shared `ProbeMediaSource`.
- `Crossbar/Prototype/RTCVideoSurface.swift`: the `RTCMTLVideoView` wrapper that draws
  any `RTCVideoTrack`, used for both local and remote video.

Each writes to a file in the app's Documents directory (`seam.log`, `signal-*.log`,
`backend.log`, `familycall.log`) so results can be pulled rather than read off a
screenshot.

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

- Call ending, declining, inviting, rejoining and the group route. Placement and
  answering have run for a real call; the rest of the lifecycle has not.
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
| Family Call control plane, call lifecycle (native) | Yes | — | **Yes, for what a first call runs** — `POST /api/calls` returned 201 with a `joinUrl`, the invitee answered on MiroTalk's own browser client, `call-status` arrived as `active` over SSE, and the native client joined the room and carried media both ways. `/join`, `/invite`, `/end`, a decline and the group route remain unexercised |
| Remote video rendering (native) | Yes | — | **Yes, against a real browser peer** — a remote track from MiroTalk's own Safari client was decoded and drawn natively, with the phone's own camera beside it on screen showing a visibly different scene |
| Room id parsed from the `joinUrl` | Yes | — | **Yes** — a production `joinUrl` yielded its room and signalling origin, and the client joined that room. Seen once |
| Native capture teardown (Architecture B spike) | Yes | — | **Yes** — after Stop, `capture stopped` is logged and the status-bar camera/mic privacy indicators are absent, which is the objective evidence capture was released. The preview keeps its last rendered frame, so the preview alone proves nothing |
| Native in-call UI for a started call | Yes | Not supported | Not observed (P8.11) |
| Audio route behaviour | Yes | Not meaningfully tested | **Spike (B) partial** — AirPods connect/disconnect produced route reasons 1 and 2 and WebRTC followed the route rather than fighting it; speaker override and wired not tested |
| RTCPeerConnection/SDP/ICE | Yes | — | **Spike (B) loopback** — two peer connections negotiate offer/answer locally over host candidates with real ICE, DTLS-SRTP and SRTP media; single process, no server |
| Remote media | Yes | — | **Yes** — inbound RTP measured flowing both ways with a real browser peer on a separate device, and the phone's camera rendered in MiroTalk's own client |
| MiroTalk signaling | Yes | — | **Yes** — native Engine.IO/Socket.IO connects to production MiroTalk, joins, receives `addPeer`/`serverInfo`, and relays SDP and ICE in the audited shapes |
| Two-device call | Yes | — | **Yes, with MiroTalk's own browser client** — a native peer and Safari on a second tailnet device negotiated, the browser answered the native offer and then renegotiated a data channel which the native client answered, ICE completed, and media crossed both ways with the phone's camera rendering in Safari |
| Three-/four-person mesh | Yes | — | **Spike (B) three peers** — three native peers formed three links with two connections each; every link reached `pc state 2` and carried media both ways, with one shared capture feeding all senders. Four peers untested |
| Background/lock/resume | No | No | **Spike (B) yes** — with a call active, audio survived lock and background (`audioUnit=1` throughout, no stop); video capture stopped on suspension (frame count frozen) and resumed cleanly on return |
| PushKit/APNs | No | No | No |

## Immediate maintenance issue

The UI test should eventually wait for the status label value to become
`Runtime ready`, not merely for the label element to exist. That is a test-only
synchronization correction; it must not be confused with the Architecture A
physical-device experiment. It was deliberately documented rather than fixed
during this handoff-only task.
