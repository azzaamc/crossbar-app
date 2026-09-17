# Architecture A probe

Last audited: 2026-09-17

## Purpose

The probe tests one narrow architectural seam:

```text
SwiftUI diagnostic shell
  -> native CallKit interface
  -> WKWebView
  -> original local JavaScript media runtime
```

It was built to answer whether a minimal, media-only WebKit surface can be
controlled from native Swift and return useful events. It is not a production
screen, a Family Call client, an extracted MiroTalk runtime, or a complete
WebRTC call.

Architecture A remains provisional:

```text
SwiftUI + CallKit + native product state
  -> minimal media-only WKWebView runtime
  -> smallest legally approved MiroTalk WebRTC core
  -> existing private MiroTalk signaling
```

## What was built

### `Crossbar/ContentView.swift`

The DEBUG build creates `CallProbeModel` as a `@StateObject` and renders:

- one `WebRuntimeView` media surface;
- status text with accessibility identifier `probe.status`;
- `Start probe` for a real `CXStartCallAction` request;
- `Simulate incoming` for `CXProvider.reportNewIncomingCall`;
- `Run media only` to isolate WebKit/media behavior from simulator CallKit;
- mute, camera, camera-switch, and end controls;
- a short native bridge-event log.

Release builds compile a plain `Text("Crossbar")` placeholder. The diagnostic
buttons are not production UI.

### `Crossbar/Prototype/CallKitManager.swift`

`CallKitManager` is `@MainActor`, DEBUG-only, and conforms to
`CXProviderDelegate`.

Important members:

- lazy long-lived `CXProvider` configured for video and up to four calls in one
  call group;
- `CXCallController` for transactions;
- `startOutgoing(video:)` creates `CXStartCallAction`;
- `reportIncoming(callID:video:)` reports a generic “Family member” update;
- `end(callID:)` and `setMuted(_:callID:)` request native actions;
- `reportConnected(callID:)` updates outgoing progress;
- delegate handlers for start, answer, end, mute, reset, audio activation, and
  audio deactivation;
- an `init()` that creates the provider eagerly, so the app is registered with
  CallKit before any transaction is requested (P8.7);
- **no `AVAudioSession` configuration at all.** An earlier revision of this
  document described a `prepareAudioSession()` that selected `.playAndRecord`,
  `.videoChat`, Bluetooth HFP, and default speaker. That method and its call
  sites were removed in P8.13 so that WebKit is the sole session owner on the
  media path, and it no longer exists.

The class exposes callbacks to the probe coordinator. It does not call Family
Call, store backend call IDs, handle remote termination, or implement PushKit.

### `Crossbar/Prototype/CallProbeModel.swift`

`CallProbeModel` coordinates the two independently testable halves.

Important behavior:

- maps CallKit start/answer to `WebMediaEngine.join`;
- maps CallKit mute to `setMuted`;
- maps CallKit audio activation/deactivation to
  `setAudioSessionActive`;
- maps end/reset/error to media leave and local state cleanup;
- implements `startMediaOnly()` so simulator WebKit behavior can be tested
  without pretending CallKit passed;
- reports web events as diagnostic status text;
- implements `-CrossbarSimulateIncomingCall` once per launch;
- keeps a synthetic UUID only for probe coordination.

There is no backend call-ID mapping or production state machine yet.

### `Crossbar/Prototype/WebMediaEngine.swift`

`WebMediaEngine` owns a weak reference to the hosted `WKWebView` and sends one
JSON envelope to the page's namespaced `window.CrossbarRuntime.receive` method.

Implemented commands:

- `join(callID:video:)`;
- `leave()`;
- `setMuted(_:)`;
- `setCameraEnabled(_:)`;
- `switchCamera()`;
- `setAudioSessionActive(_:)`.

`receive(_:)` accepts events from the `crossbar` script message handler and
records the event type plus an optional error message. It does not validate a
versioned schema, command ID, acknowledgement, or full typed payload.

`WebRuntimeView` is a `UIViewRepresentable` that:

- creates `WKWebViewConfiguration` with inline playback;
- registers the script-message coordinator;
- grants WebKit media capture through `WKUIDelegate`;
- loads bundled `RuntimeProbe.html` with local-file read access;
- removes the message handler when dismantled.

The capture delegate grants any requesting origin loaded by this DEBUG web
view. That is acceptable only for this fixed local probe. A real runtime must
restrict navigation/origin and define an explicit trust boundary.

### `Crossbar/Prototype/RuntimeProbe.html`

The page is original Crossbar diagnostic code. It contains no copied/adapted
MiroTalk implementation and no third-party library.

Important JavaScript:

- `emit(type, details)`: posts events to Swift;
- `stopStream()`: stops all current tracks and clears the preview;
- `acquire(videoEnabled)`: requests microphone plus optional camera using
  `navigator.mediaDevices.getUserMedia`, attaches the stream, plays it, and
  reports permission/local-media events;
- `commands.join`: acquires local media and reports `joining`/`joined`;
- `commands.leave`: stops local tracks and reports `left`;
- `commands.setMuted`: changes audio-track `enabled`;
- `commands.setCameraEnabled`: changes video-track `enabled`;
- `commands.switchCamera`: toggles ideal `facingMode`, reacquires, and reports
  completion;
- `commands.setAudioSessionActive`: reports the native state but does not
  change browser audio behavior;
- `window.CrossbarRuntime.receive`: dispatches commands and reports safe errors.

The page has one local `<video>` and no remote elements.

## Copied or adapted MiroTalk code

None.

No MiroTalk JavaScript, Socket.IO client, HTML, CSS, assets, license text, or
server source is present in the Crossbar repository. The probe uses browser API
concepts also present in MiroTalk, but its implementation was written for the
experiment. Consequently `ThirdParty/MiroTalkCore/` does not yet exist.

## Temporary diagnostic code

Everything under `Crossbar/Prototype/` and the DEBUG branch of `ContentView` is
diagnostic. In particular:

- `Run media only` is a simulator isolation aid, not a product path;
- the on-screen event log is temporary;
- generic names (“Family member”, “Architecture A probe”) are synthetic;
- the incoming-call button and launch argument are DEBUG mechanisms;
- current bridge events are intentionally shallow and not a stable API.

## Experiment results

Only compilation (P1) and the automated suite (P7) have retained machine
artifacts, and those artifacts live outside the repository under
`~/Library/Developer/XcodeBuildMCP/workspaces/Crossbar-f414c2a00dec/`. The
interactive simulator results (P2–P6) are recorded observations only: no
screenshot, bridge-event capture, or result bundle for them exists anywhere
readable, so they cannot be re-inspected or attached to a review. Treat P2–P6
as first-hand notes rather than reproducible evidence, and capture artifacts
for any experiment that replaces them.

### P1 — Project compilation

- Environment: Xcode 27.0, iOS 27.0 simulator SDK.
- Expected: Swift/HTML resource project compiles in Debug and Release.
- Actual: both configurations built successfully on 2026-09-16. On 2026-09-17
  Debug rebuilt and succeeded, but the Release invocation was an up-to-date
  no-op whose log contains no compile step. The most recent real Release
  compilation is therefore 2026-09-16, not 2026-09-17.
- Evidence: XcodeBuildMCP build logs under
  `~/Library/Developer/XcodeBuildMCP/workspaces/Crossbar-f414c2a00dec/logs/`,
  outside the repository and gitignored, so a fresh clone cannot reproduce
  them; current source at checkpoint.
- Conclusion: the project and conditional DEBUG structure compile.

### P2 — Local runtime and JavaScript-to-Swift bridge

- Environment: iOS 27.0 `iPhone 18 Pro` simulator.
- Expected: bundled page loads and posts `runtimeReady`.
- Actual: status changed from `Loading runtime…` to `Runtime ready`; semantic UI
  inspection found the final status.
- Evidence: manual UI automation on both 2026-09-16 and 2026-09-17.
- Conclusion: local-file WKWebView loading and the script message handler work
  in this simulator.

### P3 — Local camera/microphone acquisition

- Environment: iOS 27.0 simulator using the simulator's synthetic camera feed.
- Expected: `getUserMedia({audio:true, video:{facingMode}})` returns a stream and
  the preview plays inline.
- Actual: the synthetic camera image rendered; Swift received
  `permissionStateChanged`, `localMediaReady`, and `joined`.
- Evidence: visual simulator inspection and bridge event log on 2026-09-16.
- Conclusion: the local simulator capture path works. This does not establish
  physical permission prompts, audio quality, or device hardware behavior.

### P4 — Native media controls

- Environment: active media-only simulator probe.
- Expected: native buttons change JS track state and return events.
- Actual: mute/unmute, camera enable/disable, and camera switch returned their
  corresponding events; switch reacquired simulator media.
- Evidence: bridge event/status inspection on 2026-09-16.
- Conclusion: the current command channel can control this local runtime.

### P5 — Teardown

- Environment: active media-only simulator probe.
- Expected: End sends leave, stops tracks, clears preview, and reports left.
- Actual: status returned to `Call ended` and active-call controls disabled.
- Evidence: semantic UI wait and event log on 2026-09-16.
- Conclusion: explicit local-track teardown works in the simulator. Physical
  capture-indicator disappearance was not tested.

### P6 — CallKit request

- Environment: iOS 27.0 simulator.
- Expected: the system accepts a `CXStartCallAction` and invokes the provider
  delegate.
- Actual: CallKit rejected the transaction with
  `com.apple.CallKit.error.requesttransaction error 1`.
- Evidence: probe status on 2026-09-16.
- Conclusion: the simulator cannot validate the intended native call lifecycle.
  This is neither an Architecture A pass nor a failure.

### P7 — Automated tests

- Environment: iOS 27.0 simulator.
- Expected: all three configured tests pass.
- Actual:
  - a 2026-09-16 run reported 3 passed;
  - the 2026-09-17 handoff run reported 2 passed and 1 failed;
  - failure: `testExample` saw the existing status element while its label was
    still `Loading runtime…`.
- Evidence: XcodeBuildMCP result bundle from the handoff run and test source.
- Conclusion: the suite is timing-dependent. The unit test is also a no-op, so
  a green suite is weak evidence. Manual predicate-based waiting confirmed the
  unchanged runtime later reached `Runtime ready`.

### P8 — Physical iPhone device probe (2026-09-17)

- Environment: physical `iPhone 17 Pro` (iPhone18,1), iOS 27.0 (24A437),
  Developer Mode already enabled, paired over local network. Host Xcode 27.0
  (`27A266a`). Debug configuration, scheme `Crossbar`, automatic signing with a
  Personal Team. Probe source unchanged at commit `d769412`.
- Evidence channels: `xcrun devicectl device capture screenshot`; the Xcode MCP
  launch-session console (`GetConsoleOutput`) for device OSLog; and the probe's
  own on-screen event log.

Tooling limit recorded for future device work: Xcode's device-interaction MCP
tools (`DeviceInteractionStartWorkspaceSession`, `DeviceInteractionSynthesize`)
refuse a physical device and list only simulators, and `devicectl` exposes no
input injection. Every on-device tap therefore requires a human operator;
screenshots and console capture are fully automatable.

#### P8.1 — Signing, install, launch

- Result: **PASS**
- Actual: the device build succeeded through the Xcode MCP project build
  (12.5 s, zero errors); the app installed and launched as PID 4484 with the
  WebKit content process as PID 4491.
- Evidence: Xcode MCP build result and launch session; device OSLog; screenshots
  `01`/`02`.

#### P8.2 — Runtime init and JavaScript-to-Swift bridge on hardware

- Result: **PASS**
- Actual: status reached `Runtime ready` and the event log showed
  `web → native: runtimeReady` on the physical device.
- Evidence: device screenshot; device OSLog.
- Implication: the bundled local-file `WKWebView` and the script-message bridge
  are not simulator-specific.

#### P8.3 — Camera and microphone acquisition on hardware

- Result: **PASS** for acquisition; permission-prompt presentation **NOT
  TESTED**
- Actual: the event log showed `permissionStateChanged`, `localMediaReady`, and
  `joined`. `joined` is emitted only after
  `getUserMedia({audio: true, video: …})` resolves, and the preview rendered a
  live camera image of the operator on the device.
- Evidence: device screenshots `03`/`04`; event log.
- Not established: that the iOS permission sheet was presented as such. The
  grant is inferred, because the app had never been installed on this device
  before and capture nevertheless succeeded. Subjective microphone audio quality
  is untestable here: the probe has no remote peer and no playback path.

#### P8.4 — Camera switch command delivery

- Result: **PASS** for command delivery and re-acquisition; the visible
  front/rear change is **NOT YET CONFIRMED**
- Actual: `native → web: switchCamera` appeared in the event log, and device
  OSLog recorded WebKit `[WebRTC]` messages naming sources 164 and 253 as
  `Unable to find source … for videoFrameAvailable` at 16:54:16 and 16:54:18,
  i.e. real video-source teardown during re-acquisition.
- Implication: `switchCamera` in this runtime is a `facingMode` flip plus a full
  `getUserMedia` re-acquire, which also stops and re-requests the audio track.
  It is not `applyConstraints`. That mid-call audio-track interruption is a real
  product risk and is invisible in the simulator, where switching is cheap.

#### P8.5 — Mute/unmute round trip

- Result: **PARTIAL**
- Actual: the status read `Microphone state changed`, the only string set by the
  `mutedChanged` event, and the control returned to its `Mute` label, implying a
  completed toggle round trip.
- Not established: any audible effect. With no remote peer, mute is observable
  only as track state, and the probe never reports a track's live `enabled`
  value back to Swift.

#### P8.6 — AVAudioSession during local media (negative result)

- Result: **INCONCLUSIVE BY DESIGN**
- Actual: a session console query for
  `audio|callkit|avaudio|tcc|clock|interrupt` returned zero matches across the
  entire device session, while camera and microphone capture were live.
- Source corroboration: at the time of this measurement the session was set only
  from the `CXStartCallAction` and `CXAnswerCallAction` delegates, so the
  media-only path never set a category, a mode, or an active state. That setup
  was subsequently removed altogether in P8.13.
- Implication: this is a negative result about the probe, not about WebKit.
  WebKit may own a capture session outside the app process, so no conclusion was
  available until the CallKit path was exercised. That path has since been
  exercised: CallKit activation and deactivation are now recorded (P8.9) and the
  resulting WebKit conflict is characterised (P8.10). Audio *routing* itself
  remains untested.

#### P8.7 — CallKit outgoing transaction

- Result: **FAIL as shipped; PASS after two probe defects were fixed**
- Actual: on the unmodified probe, tapping `Start probe` produced
  `com.apple.CallKit.error.requesttransaction` **Code=1** at 16:59:16 and
  16:59:57 on the device. Code 1 is
  `CXErrorCodeRequestTransactionErrorUnentitled`, which Apple documents as most
  commonly caused by a missing `voip` entry in `UIBackgroundModes`; the project
  declared no `UIBackgroundModes` at all. After adding
  `UIBackgroundModes = [voip]`, the same tap returned **Code=2**
  (`CXErrorCodeRequestTransactionErrorUnknownCallProvider`) on a cold start.
  The probe's `CXProvider` is a `lazy var` and nothing on the outgoing path
  touches it, so the app was never registered as a call provider. After creating
  the provider at launch, the transaction returned **error `(null)`** —
  accepted — on a cold start at 17:15:35.106.
- Evidence: device unified log, `Received reply from transaction request with
  error: …` for PIDs 4484, 4555, 4568, 4572, 4577 and 4599.
- Implication: both failures were **probe defects, not architectural ones**. A
  native CallKit outgoing call is accepted on a physical iPhone.
- Correction to P6: the simulator's recorded `error 1` is this same
  `.unentitled` code. P6's conclusion that the simulator "cannot validate the
  intended native call lifecycle" attributed to the simulator what was in fact
  the missing background-mode declaration.

#### P8.8 — CallKit incoming report, answer and decline

- Result: **PASS**
- Actual: `Simulate incoming` presented the native incoming-call interface with
  Accept and Decline. The log records `Provider <CXXPCProvider: …> was asked to
  report a new incoming call with … localizedCallerName=Family member
  hasVideo=1` and `Received CSD reply for incoming call …: success`.
  `CXAnswerCallAction` and `CXEndCallAction` were both delivered and fulfilled.
- Evidence: device unified log; operator observation.

#### P8.9 — Audio session activation under CallKit

- Result: **PASS**
- Actual: `Notified that audio session activation state changed to: 1` on call
  start and `… to: 0` on call end, so `didActivate` and `didDeactivate` are
  delivered on hardware.
- Evidence: device unified log, e.g. 17:09:15.790 and 17:09:38.261.

#### P8.10 — WebKit capture under an active CallKit call

- Result: **FAIL** — the highest-value result of this experiment
- Actual: with the call active, `getUserMedia` succeeds and WebKit creates and
  starts both tracks (`Front Ultra Wide Camera`, `iPhone Microphone`), but then:
  `MediaSessionManageriOS::maybeActivateAudioSession(0) failed to activate
  AudioSession`; `sessionWillBeginPlayback(0) returning false, failed to
  activate AudioSession`; `HTMLMediaElement::playInternal(...) returning because
  of interruption`; then `RealtimeMediaSource::setMuted(...) true` and
  `RealtimeMediaSource::stop(...)`. The page's `await video.play()` consequently
  never settles, `acquire()` never emits, `joined` never reaches Swift, and the
  probe hangs at `Requesting camera and microphone…` indefinitely instead of
  reporting a failure.
- Evidence: device unified log for PIDs 4572 (17:09:16), 4577 (17:09:43 and
  17:10:03) and 4599 (17:15:35) — identical in all three.
- Implication: **WebKit's media engine cannot activate its audio session while
  CallKit holds the app's session, and WebKit responds by treating it as an
  interruption — it stops the capture sources and aborts playback.** This is the
  Architecture A risk the probe existed to test, and in this configuration the
  answer is negative. It is not a probe bug; it is a WebKit/CallKit ownership
  conflict.
- Secondary observation from the same runs:
  `HTMLMediaElement::mediaStreamCaptureStarted(...) autoplay blocked with reason:
  PageConsentRequired: Not enough data`. Autoplay of the capture stream is
  blocked independently of the session conflict, so a runtime must not `await`
  `video.play()` unconditionally.

#### P8.11 — Native in-call UI

- Result: **FAIL / unexplained**
- Actual: although the transaction was accepted and the system broadcast a new
  call to other processes, no native in-call screen or banner was ever observed,
  and the device screenshot at the hung state shows the probe in the foreground
  with no call UI and no privacy indicator lit.
- Not established: whether this is expected for a foreground app on this OS
  version, or a consequence of the call never reaching a connected state.
- Evidence: device screenshot `09`; operator observation.

#### P8.12 — Teardown

- Result: **PASS** for track release
- Actual: ending a call produced `didDeactivate` plus WebKit
  `WebPageProxy::deactivateMediaCapability` and
  `UserMediaPermissionRequestManagerProxy::stopCapture`, and the probe returned
  to `Call ended` with local media released.
- Not established: capture-indicator observation and relaunch cleanliness were
  not separately verified.

#### P8.13 — Single-owner audio-session experiment

- Hypothesis: if the app stopped configuring `AVAudioSession` on the CallKit
  path, WebKit would be the sole owner, activate its session successfully, and
  capture and play during a native call.
- Change: `prepareAudioSession()` was removed along with its two call sites, so
  the probe no longer sets a category, mode, or options on the CallKit path.
  Separately, `RuntimeProbe.html` no longer awaits `video.play()`; a refusal or
  interruption is emitted as `playbackBlocked` and surfaced as
  `Local playback blocked: …` instead of hanging the command.
- Result: **HYPOTHESIS REJECTED — the conflict is structural, not two-owner.**
- Actual: CallKit still accepted the transaction (`error: (null)` at
  17:24:57.422) and still delivered `didActivate` (state 1 at 17:24:57.539).
  WebKit then recorded
  `MediaSessionManageriOS::maybeActivateAudioSession(0) failed to activate
  AudioSession` at 17:24:57.850 — **the identical failure as before** — and
  muted and stopped the capture source. Playback was permitted this time
  (`sessionWillBeginPlayback(0) … returning true`, where the earlier runs
  returned false) and the element reached `setState(…) Playing`, so the runtime
  completed its acquisition and emitted `joined`. The player nonetheless settled
  at `updatePlayState(…) shouldBePlaying = 0, playerPaused = 1`, so no frames
  rendered and the preview stayed black.
- Evidence: device unified log, PID 4651, 17:24:57.
- Implication: **WebKit cannot activate its audio session while CallKit holds the
  app's session active, and it responds by muting and stopping capture.** This
  holds whether or not the app also configures the session, so it is not a
  competing-owner problem that a runtime can resolve by yielding ownership — the
  boundary itself is the defect. Consequently `Local media active` must not be
  read as "media works": with the non-blocking `play()`, that status now means
  only that capture was acquired.

#### P8.14 — Media-first ordering experiment

- Hypothesis: if local media were acquired and already producing data before
  CallKit took the audio session, WebKit would keep its session and the preview
  would survive the handover.
- Change: `startOutgoingCall()` now acquires local media first and requests the
  `CXStartCallAction` only after `joined` fires; `onStart` adopts the CallKit
  call instead of re-acquiring media.
- Result: **HYPOTHESIS REJECTED — ordering does not matter.**
- Actual: the preview appeared and rendered for approximately half a second,
  then went black the moment the CallKit transaction was accepted. The status
  reached `CallKit accepted; local media was already active`, so the media-first
  path ran as designed and the call really was started. Ending the call returned
  the probe to `Call ended` / `Runtime ready`.
- Evidence: operator observation of the live preview and the probe status text.
  No device unified log was collected for this run; the mechanism is established
  by P8.10 and P8.13, which recorded
  `maybeActivateAudioSession … failed to activate AudioSession` followed by
  `RealtimeMediaSource::setMuted` and `RealtimeMediaSource::stop` in exactly this
  situation.
- Implication: **WebKit loses the audio session the instant CallKit takes it, in
  every ordering and ownership arrangement tested.** Three configurations now
  fail identically: CallKit-first with an app-configured session (P8.10),
  CallKit-first with WebKit as sole owner (P8.13), and media-first with WebKit as
  sole owner (P8.14). Local capture and rendering demonstrably work while CallKit
  is idle — the preview rendered here before the handover — so this is
  specifically the CallKit/WebKit session boundary, not a general WebKit media
  defect.

#### P8 — device items still NOT TESTED

- Visible camera-off blanking and camera-on restore.
- The visible front/rear change on camera switch.
- Audio route behaviour (receiver, speaker, wired, Bluetooth).
- Interruption by another audio source.
- Lock/unlock survival, and background/foreground recovery of a live call.
- Multiparty and remote media (absent by construction).

## What the probe proves

Only these conclusions are supported:

1. The existing iOS project can host a local media-only `WKWebView`.
2. An original JavaScript runtime can request and preview media, verified in the
   simulator and now on a physical iPhone (P8.3).
3. Swift can send the implemented commands to that runtime.
4. JavaScript can return status/error events to Swift.
5. Local track toggles, reacquisition, and explicit stop can work in the
   simulator; on device, reacquisition is confirmed by OSLog, while stop and
   toggles are not yet confirmed (P8.4, P8.5).
6. The native/WebKit ownership boundary is technically constructible: on real
   hardware CallKit accepts outgoing calls, presents incoming calls, and
   delivers `didActivate` / `didDeactivate` (P8.7–P8.9).
7. WebKit capture and a CallKit-activated audio session conflict, and the
   conflict is not avoidable by configuration. With a call active, WebKit fails
   to activate its own audio session, treats the result as an interruption, and
   stops the capture sources. This holds with the app configuring the session
   (P8.10), with WebKit as sole owner (P8.13), and with media acquired and
   already rendering before the call starts (P8.14). The boundary is
   constructible but, on this evidence, not functional.

## What the probe does not prove

- real camera/microphone permission prompts on an iPhone;
- audible microphone capture or remote audio playback;
- CallKit action delivery on a physical device;
- CallKit audio activation controlling WebKit media;
- receiver, speaker, wired, or Bluetooth route behavior;
- interruption, lock screen, background, foreground, or web-process survival;
- Family Call authentication/API/SSE behavior from native `URLSession`;
- Socket.IO or installed MiroTalk signaling compatibility;
- `RTCPeerConnection`, offer/answer, local/remote descriptions, ICE, or
  candidate queueing;
- remote track rendering;
- one-to-one, three-way, or four-person calling;
- adding a participant to an active call;
- MiroTalk reconnect/rejoin behavior;
- PWA/native interoperability;
- production runtime origin/CORS policy;
- performance, thermal, memory, or battery behavior;
- PushKit/APNs remote ringing.

## Highest-risk unknowns, ranked

1. **CallKit/AVAudioSession/WebKit ownership on a physical iPhone.** WebKit owns
   capture/playback while CallKit activates a native audio session; public APIs
   do not guarantee the required routing/lifecycle behavior.
2. **Background, lock, interruption, and web-process survival.** A successful
   foreground capture says nothing about a durable iOS call.
3. **Real MiroTalk engine isolation.** The proven MiroTalk client is monolithic
   and UI-coupled; extracting only the call core without changing semantics
   remains engineering work.
4. **AGPLv3 distribution decision.** No engine code should be copied before the
   source/distribution obligations are accepted or a separate license is
   approved.
5. **Real signaling and PWA interoperability.** Join payload details,
   `peerStatus`, reconnection, and negotiation races have been audited but not
   executed from Crossbar.
6. **Multiparty performance/reliability.** The server creates a mesh, but the
   proposed runtime has not rendered or sustained remote peers.
7. **Private runtime origin and CORS.** Bundled local media works in the
   simulator; connecting that origin to the private MiroTalk Socket.IO server
   has not been tested.
8. **Current automated test reliability.** The ready-state UI assertion is
   racy and the unit test is empty.

## Next experiment boundary

The next experiment should use the unchanged original-code probe on the
connected personal iPhone. It should record CallKit start/incoming/answer/end/
mute callbacks, `didActivate`/`didDeactivate`, WebKit capture during the native
call, audio routes, interruptions, lock/background/resume, and teardown. Do not
add MiroTalk code, backend integration, APNs, or product UI during that test.
