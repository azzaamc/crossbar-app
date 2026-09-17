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
- `prepareAudioSession()` selects `.playAndRecord`, `.videoChat`, Bluetooth HFP,
  and default speaker.

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

### P1 — Project compilation

- Environment: Xcode 27.0, iOS 27.0 simulator SDK.
- Expected: Swift/HTML resource project compiles in Debug and Release.
- Actual: both configurations built successfully on 2026-09-16 and were
  re-verified successfully on 2026-09-17.
- Evidence: XcodeBuildMCP build results; current source at checkpoint.
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

## What the probe proves

Only these conclusions are supported:

1. The existing iOS project can host a local media-only `WKWebView`.
2. An original JavaScript runtime can request and preview simulator media.
3. Swift can send the implemented commands to that runtime.
4. JavaScript can return status/error events to Swift.
5. Local track toggles, reacquisition, and explicit stop can work in the
   simulator.
6. The proposed native/WebKit ownership boundary is technically constructible.

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
