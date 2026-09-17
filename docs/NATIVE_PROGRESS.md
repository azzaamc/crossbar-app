# Crossbar native progress

Last audited: 2026-09-17 (Asia/Karachi)

## Status in one sentence

Crossbar is an Xcode-generated SwiftUI application containing a DEBUG-only,
original-code Architecture A feasibility probe; it is not connected to Family
Call or MiroTalk signaling and has not made a real device-to-device call.

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
| Scheme | `Crossbar` (only discoverable scheme; **no `.xcscheme` file is tracked** — Xcode auto-creates it, so `-scheme Crossbar` resolves on this machine but is absent from a clean checkout) |
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
| Packages | None |
| Linked third-party frameworks | None |
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

- Native SwiftUI host and diagnostic controls.
- A CallKit wrapper/interface and DEBUG incoming-call simulation path.
- A visible frameless WKWebView media surface.
- Native-to-JavaScript commands: `join`, `leave`, `setMuted`,
  `setCameraEnabled`, `switchCamera`, and `setAudioSessionActive`.
- JavaScript-to-native event delivery through one `crossbar` message handler.
- Local camera/microphone acquisition and local preview in the probe runtime.
- Explicit local track stop on leave.
- Camera and microphone Info.plist purpose strings.

## What does not exist

- Family Call HTTP API client, models, contacts, groups, presence, or SSE.
- Tailscale/backend session verification from the native app.
- Socket.IO client or MiroTalk signaling.
- `RTCPeerConnection`, SDP, ICE, remote tracks, or peer state.
- Any two-device or multiparty call.
- Extracted/copied/adapted MiroTalk source.
- Production call UI.
- PushKit, APNs, VoIP token registration, notification extension, or backend
  native-device registration routes.
- Background-audio capability or VoIP background mode.
- Keychain/UserDefaults usage.

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
| Native in-call UI for a started call | Yes | Not supported | Not observed (P8.11) |
| Audio route behaviour | Yes | Not meaningfully tested | Not tested |
| Remote media | No | No | No |
| MiroTalk signaling | No | No | No |
| RTCPeerConnection/SDP/ICE | No | No | No |
| Two-device call | No | No | No |
| Three-/four-person mesh | No | No | No |
| Background/lock/resume | No | No | Background observed only; lock/relaunch not tested |
| PushKit/APNs | No | No | No |

## Immediate maintenance issue

The UI test should eventually wait for the status label value to become
`Runtime ready`, not merely for the label element to exist. That is a test-only
synchronization correction; it must not be confused with the Architecture A
physical-device experiment. It was deliberately documented rather than fixed
during this handoff-only task.
