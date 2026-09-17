# Crossbar provisional architecture

## Decision status

Architecture A is the leading investigation but has not been selected as the
final media architecture.

```text
SwiftUI product UI
  -> Call coordinator and native CallKit
  -> minimal media-only WKWebView runtime
  -> smallest legally approved MiroTalk browser WebRTC core
  -> existing private MiroTalk Socket.IO server
```

Architecture B—native WebRTC plus a native Socket.IO client—remains the fallback
if physical-device evidence shows WebKit cannot reliably participate in CallKit
audio routing, background/lock, interruption, or resume behavior.

The existing probe proves only the local native/WebKit bridge shape. See
`ARCHITECTURE_A_PROBE.md`.

## Product boundary

Crossbar is a native private family calling application, not a meeting client.
Users see family members, Call, Answer, Decline, Add Person, and End. They do not
see MiroTalk, meetings, room IDs/URLs, WebRTC, SDP, ICE, signaling, or Tailscale
addresses.

Initial call sizes are two frequently, three reasonably often, and four
occasionally. Multiparty is mandatory. Adding a participant must keep the same
Family Call/MiroTalk room and extend the existing pairwise mesh.

## Existing control plane

Family Call remains authoritative for:

- Tailscale-derived identity and first-seen enrollment;
- contacts, groups, presence, and ongoing-call directory;
- opaque application call IDs and private MiroTalk room IDs;
- participant invitations and authorization;
- ringing, accept, decline, cancellation, missed-call expiry, and call status;
- Web Push for the PWA and future native APNs registration/delivery;
- authenticated server-to-server calls to MiroTalk's loopback join API;
- keeping the MiroTalk API secret off clients.

Crossbar must not create room names, call the secret MiroTalk REST endpoint, or
become a second source of truth for contacts/call state.

Current native-relevant Family Call routes, verified in the separate source:

| Route | Purpose |
| --- | --- |
| `GET /api/session` | resolve trusted current identity |
| `GET /api/bootstrap` | user, contacts, groups, pending/active/ongoing calls |
| `GET /api/events` | foreground SSE for incoming calls, lifecycle, presence, directory |
| `GET /api/calls/:id` | participant call refresh |
| `POST /api/calls` | start ad hoc one-to-one/multiparty call |
| `POST /api/groups/:id/calls` | start configured group call |
| `POST /api/calls/:id/respond` | accept/decline |
| `POST /api/calls/:id/invite` | add participants to the same call/room |
| `POST /api/calls/:id/join` | rejoin/join active call |
| `POST /api/calls/:id/end` | current call-wide end/cancel |

Current constraints: a ring expires after 90 seconds; presence is only an SSE
hint; `/end` is call-wide, not participant-specific; media connection state is
not reported to Family Call.

## Proposed native layers

```text
CrossbarApp
  AppEnvironment
    FamilyCallAPI
    EventStreamClient
    ContactDirectory
    CallCoordinator
      CallKitManager
      CallStateReconciler
      MediaEngine protocol
        MiroTalkWebMediaEngine (Architecture A candidate)
        NativeWebRTCMediaEngine (Architecture B fallback)
    IncomingCallSource
      ForegroundEventSource
      DebugIncomingCallSource (DEBUG)
      VoIPPushIncomingCallSource (later)

SwiftUI
  HomeView
  IncomingCallView
  ActiveCallView
    MediaSurface
    CallControls
    AddParticipantSheet
```

Keep backend, CallKit, and media states separate:

```text
Backend: ringing -> active -> ended/declined/cancelled/missed
CallKit: requested -> connecting -> connected -> ended
Media: idle -> preparing -> joining -> connected -> reconnecting -> stopped/failed
```

Backend `active` does not prove media connected. A transient signaling reconnect
must not automatically end the application call.

## Architecture A ownership

### Swift owns

- Family Call API/authentication/session models;
- contacts, groups, presence, navigation, and accessibility;
- native incoming/outgoing/active call state;
- `CallKitManager` and AVAudioSession coordination;
- app lifecycle and recovery policy;
- user controls and Add Person;
- future PushKit/APNs;
- user-facing errors.

### Web runtime owns

- camera/microphone acquisition where browser WebRTC requires it;
- local streams/tracks;
- one `RTCPeerConnection` per remote participant;
- offer/answer, local/remote description, and ICE queueing;
- Socket.IO MiroTalk protocol;
- remote track attachment and media-only layout;
- mesh peer lifecycle, reconnection, and explicit teardown.

Remote media should remain in a visible, frameless WKWebView surface. Native
controls occupy their own SwiftUI layout. Exporting browser streams to native
renderers would introduce a second media pipeline and erase much of
Architecture A's value.

### Intended bridge direction

Commands:

```text
configure({ signalingOrigin, joinBootstrap, mediaKind })
join()
leave()
setMuted({ muted })
setCameraEnabled({ enabled })
switchCamera()
setApplicationState({ state })
```

Events:

```text
runtimeReady
permissionStateChanged
localMediaReady
joining / joined
peerAdded / peerRemoved
peerMediaChanged
connectionStateChanged
reconnecting / rejoined
mutedChanged / cameraChanged
left
failed({ code, recoverable, safeMessage })
```

The production bridge should be versioned, typed, and acknowledge commands. The
current probe is fire-and-forget and intentionally simpler.

## Runtime-origin choices still open

1. Same MiroTalk HTTPS origin: cleanest secure-origin/Socket.IO behavior, but
   requires an isolated server patch first and creates a maintained AGPL fork.
2. App-bundled runtime: app/runtime versions stay together; local-origin
   Socket.IO/CORS and physical capture must be proven.
3. Family Call HTTPS origin: may simplify trusted bootstrap but introduces
   cross-origin signaling and mixes AGPL runtime distribution into the backend.

No production route/service has been changed to test these choices.

## Architecture B comparison

Architecture B would add a native WebRTC framework and native Socket.IO client
and recreate:

- capture constraints and camera switching;
- peer-connection factory and one connection per socket ID;
- MiroTalk join metadata;
- server-selected offer direction;
- SDP/ICE sequencing and pending-candidate queues;
- remote tracks/renderers;
- sender replacement and renegotiation;
- peer status interoperability;
- reconnect, rejoin, mesh rebuild, and teardown;
- all two-/three-/four-person races.

That may be the stronger platform fit for CallKit/audio/background behavior,
but it is not reuse of MiroTalk's browser engine.

| Criterion | A: WebKit runtime | B: native WebRTC |
| --- | --- | --- |
| MiroTalk engine reuse | High if extraction is approved | Low; signaling only |
| Initial implementation | Moderate extraction/bridge | High full engine rewrite |
| Multiparty parity | Preserves installed mesh behavior | Must recreate/test it |
| Native UI | Native shell; media in WebKit | Fully native |
| CallKit/audio control | Main physical-device unknown | Direct native integration |
| Debugging | Split native/web processes | Native, but much more code |
| Upgrade coupling | Pinned MiroTalk extraction | MiroTalk protocol + WebRTC dependency |
| Licensing | AGPL central if code copied | Still needs review; may avoid code copying |

## Decision gate

Architecture A becomes final only after evidence on physical iPhones and then
an isolated MiroTalk test proves:

1. real permission and capture behavior;
2. two-way audio/video and remote rendering;
3. CallKit start/incoming/answer/end/mute;
4. receiver, speaker, wired, and Bluetooth routes;
5. interruption, lock, background, and resume;
6. Tailscale/signaling loss and reconnect;
7. camera off/on and front/rear switching;
8. third participant joins without disturbing the first pair;
9. explicit teardown leaves no capture indicator;
10. web-process failure is surfaced/recoverable;
11. acceptable four-person CPU, thermal, memory, and battery behavior;
12. acceptable AGPL distribution plan.

If public WebKit APIs cannot meet CallKit audio/background requirements, choose
Architecture B. Do not accumulate private WebKit workarounds or a native frame
bridge until Architecture A has effectively become a second engine.

### Measured status (physical iPhone, 2026-09-17)

Criterion 3 is now measured and passes at the CallKit layer. After two DEBUG
probe defects were fixed — a missing `UIBackgroundModes = [voip]` declaration
and a `CXProvider` that was never instantiated before the first transaction —
CallKit accepts outgoing calls, presents incoming calls, and delivers
`didActivate` / `didDeactivate` on real hardware (P8.7–P8.9).

The separating seam fails. With a call active, WebKit reports
`MediaSessionManageriOS::maybeActivateAudioSession(0) failed to activate
AudioSession`, then mutes and stops its capture sources and leaves the media
player paused, so no preview renders (P8.10). This was reproduced in three
arrangements — app-configured `AVAudioSession`, WebKit-only (P8.13), and
media-first ordering where the preview renders and then dies on handover
(P8.14) — so it is neither a competing-owner defect nor an ordering defect. It
is the CallKit/WebKit session boundary itself.

Criteria 4, 5, and 9 remain unmeasured, and are now largely moot until the audio
ownership question is settled, because they all sit on the disabled capture
path. No decision to replace Architecture A is recorded here; this note records
the measurement that decision now rests on.

### Architecture B scoping (2026-09-17)

Undertaken after the media-first experiment (P8.14) closed the question of
whether Architecture A's audio conflict was a probe defect. It is not. Apple
documents the rule the experiment hit: activating a session with category
`record` or `playAndRecord` "when another app is already hosting a call" fails
with `AVAudioSessionErrorInsufficientPriority`, because "the session fails to
activate if another audio session has higher priority than yours (such as a
phone call) and neither audio session allows mixing". WebKit's capture runs in
the WebContent process, so it competes with the CallKit-hosted call session as a
separate client and loses. Under B the app's own session *is* the call session,
so the rule does not apply.

#### Dependencies (pinned, verified from primary sources)

| Component | Version | Channel | License |
| --- | --- | --- | --- |
| `stasel/WebRTC` prebuilt xcframework | M153 (153.0.0), 2026-09-11, ~45 MB, SHA-256 `3e3a8946…b78f` | binary/SPM | WebRTC BSD-3-Clause |
| `socketio/socket.io-client-swift` | 16.1.1 (2024-10-01) | SPM | MIT, plus Starscream Apache-2.0 |

The Socket.IO client is in maintenance mode; its own release notes record
reconnect-hang and 60-second socket-close fixes, so reconnect behaviour is the
part of that dependency with the most defect history and needs its own test
harness.

#### Why the native audio path is separated by construction

Code evidence from the WebRTC source tree — **not** a hardware measurement.
`RTCAudioSession` publishes an activation delegate whose own header states it
exists "to inform `RTCAudioSession` when the audio session activation state has
changed outside of `RTCAudioSession`… The current known use case of this is when
CallKit activates the audio session for the application."

`audioSessionDidActivate:` sets `isActive = YES`, after which `setActive:`
computes `shouldSetActive = (active && !isActive) || …` — false — so **WebRTC
deliberately makes no `AVAudioSession.setActive:` call when CallKit already holds
the session.** That is the precise inversion of WebKit's `MediaSessionManageriOS`,
which owns activation inside the web process and therefore tries, and fails, to
activate a session CallKit already owns. The native design has exactly one owner,
which is what Apple's CallKit model requires.

This separation holds only if the app does its part: `provider(_:didActivate:)`
must call `RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)`,
and `didDeactivate` must call `audioSessionDidDeactivate(_:)`. Omitting that
leaves `isActive` false, the ADM falls through to activating the session itself,
and competing activation is reintroduced.

| When | Do |
| --- | --- |
| Before reporting or answering | category `.playAndRecord`, mode `.voiceChat`, include `.allowBluetooth`; `useManualAudio = true`; `isAudioEnabled = false` |
| In `perform CXStartCallAction` / `CXAnswerCallAction` | configure the session; do **not** call `setActive(true)`; then fulfill |
| `didActivate` | `audioSessionDidActivate(audioSession)`; then `isAudioEnabled = true` |
| `didDeactivate` | `isAudioEnabled = false`; then `audioSessionDidDeactivate(audioSession)` |
| `providerDidReset` | disable audio; tear media down |

`RTCAudioSession` also observes interruptions, route changes, media-services
resets, and `canPlayOrRecord` transitions and drives the ADM from them, so
criteria 4 and 5 need policy rather than hand-built plumbing.

**On-device confirmation is still unrun**, for either architecture. The code
evidence above shows the native path is separated by construction; it does not
show that a Crossbar media engine produces capture, two-way audio, and route
changes on a physical iPhone under a live CallKit call.

#### Distribution decision

There is no official Google prebuilt iOS binary: prebuilt mobile binaries were
discontinued around the M80 release, and the `GoogleWebRTC` pod has been frozen
at 1.1.32000 since March 2023. The practical route is a maintained community
xcframework consumed through SwiftPM, pinned to a tag — `stasel/WebRTC` 153.0.0
as primary, `webrtc-sdk/Specs` if the fork's iOS audio patches are ever wanted.

Building from source is a ~6 GB checkout plus 1–3 hours per xcframework and is
not justified here. CocoaPods should be avoided outright for a new project:
CocoaPods trunk becomes permanently read-only on 2026-12-02.

The framework is dynamic and prebuilt, so App Store thinning cannot dead-strip
it; a roughly 30–40 MB download-size delta is the expectation. **That is an
inference from the framework's shape, not a measurement**, and must be confirmed
from `App Thinning Size Report.txt` before it is treated as fact.

One API correction worth recording because most tutorials get it wrong:
`RTCCameraPreviewView` no longer exists in the current SDK. The local preview is
an `RTCMTLVideoView` attached to the local `RTCVideoTrack` — the same mechanism
as remote rendering.

One shared risk: an Apple developer forum thread (837211) reports an iOS 27
`callservicesd`/`mediaservicesd` race in which `didActivate` is not delivered,
with a workaround of refreshing `CXProvider.configuration` before reporting
calls. That is **CallKit behaviour affecting A and B equally**, so it is a reason
to instrument `didActivate` delivery in either architecture rather than a reason
to prefer one. The thread could not be read directly; its substance is recorded
as a lead to check by hand, not as a finding.

#### Signaling surface

Nine events are mandatory for a 2–4 person mesh: `connect`, `join`, `addPeer`,
`relaySDP`/`sessionDescription`, `relayICE`/`iceCandidate`, `removePeer`, and
`disconnect`, plus two error paths that must be handled even if never hit
(`unauthorized`, `roomIsLocked`/`roomIsJoinLocked`). Everything else in the
audit is optional for a family client. The MiroTalk server is reused unchanged.

Transport must be forced WebSocket-only: production is configured
`transports: ['websocket']` and the browser client forces it too, so a Swift
client left on its default polling-then-upgrade path would exercise a code path
the deployment never uses.

#### What survives, what is rebuilt

Survives: `CrossbarApp.swift`, the SwiftUI shell concept, `Assets.xcassets`,
`Info.plist` (including `UIBackgroundModes = [voip]`, already required), and
`CallKitManager.swift` with modification — its `CXProvider`/`CXProviderDelegate`
surface is the single largest reusable asset. The test *targets* survive; their
contents do not.

Discarded entirely: `WebMediaEngine.swift` (the Swift↔JS bridge),
`RuntimeProbe.html`, and `CallProbeModel.swift`. Under B there is no WebView, no
`WKScriptMessageHandler`, and no JavaScript in the media path.

Rebuilt from nothing, with no existing equivalent: mesh peer lifecycle and
sender replacement (L); negotiation and ICE, including the server-selected
offerer and per-peer pending candidate queues (L); capture and camera switching
(M); remote rendering into SwiftUI (M); signaling transport (M);
reconnect/rejoin (M); teardown (S); audio-session ownership (S–M); device
selection (S).

Largest risk: recreating MiroTalk's non-standard negotiation and mesh semantics
precisely enough to interoperate with installed 1.9.64 peers and the existing
PWA, with no native reference implementation. The audio-session problem that
motivates B is *not* the top risk — native session ownership under CallKit is
the supported path, and it is small code.

#### Backend requirement (verified in the Family Call source)

`callPublic()` returns `{id, callerId, status, createdAt, answeredAt,
participants}` and **omits the room identifier**. The room *is* available
server-side — `createCall` persists `room_id` and `store.call()` selects
`room_id AS roomId` — and it reaches clients today only inside the `joinUrl`
field returned by `POST /api/calls`, `/respond`, and `/join`
(`src/server.js:183, 291, 325`).

Architecture B therefore requires one small additive backend change: expose the
room identifier, or a bootstrap object containing it plus the signaling origin,
so Crossbar never has to parse an HTML join URL. The MiroTalk API secret must
stay server-side and is correctly hidden today — it is read from the environment
and used only inside `src/mirotalk.js:joinUrl()`.

One unverified prerequisite: if the deployed MiroTalk has `hostCfg.protected` or
`user_auth` enabled, a native first-joiner that bypasses the `/join` page cannot
satisfy the Socket.IO auth gate without a `peer_token`. That is server
configuration outside this repository and has not been checked.

#### What is lost

MiroTalk engine reuse and its audited in-device provenance; the probe bridge and
its device-verified capture path; near-free PWA↔native parity (under A both
clients would run the same browser engine); and single-engine maintenance. The
one-to-one and 2–4 person requirements survive in intent but inherit nothing —
they must be rebuilt and re-proven.

#### Licensing

Documented facts: MiroTalk P2P is AGPLv3; the WebRTC framework is BSD-3-Clause
plus a Google patent grant (perpetual, no-charge, irrevocable, with defensive
termination and an explicit carve-out for claims infringed only as a consequence
of further modification); `socket.io-client-swift` is MIT with an Apache-2.0
Starscream dependency. Crossbar currently contains no MiroTalk source.

Under B no MiroTalk code is copied, so no AGPL-covered work enters the binary,
and the modified production MiroTalk service remains a separate network-service
question unaffected by the client's media architecture. The framework itself
imposes no copyleft obligation. BSD binary redistribution does require the
notice to travel with the binary, so the actionable step is to extract
`WebRTC.xcframework/LICENSE` from the chosen release and surface it in the app's
acknowledgements. That file is also the authoritative transitive-licence list
for the binary actually shipped: component licences asserted from build metadata
— notably Opus, which does not appear in the pinned `DEPS` — are unverified and
should be resolved from it rather than assumed.

Unresolved and not decided here: whether a native reimplementation of the
protocol is a derivative work, and whether AGPLv3 terms are compatible with App
Store distribution if MiroTalk code is ever included.

#### Status

Measured, not decided. The evidence points to B for the media layer; the
decision is the owner's.

## Backend changes before a usable native release

No backend change is required for the next local media/CallKit experiment.
Later, prefer small additive changes that preserve PWA behavior:

- API versioning/idempotency for retryable mutations;
- participant-specific leave separate from call-wide end;
- persisted audio/video call kind;
- minimal validated media bootstrap without exposing the MiroTalk API secret;
- optional coarse engine states, never SDP/ICE;
- APNs/VoIP token records supporting multiple devices/environments;
- monotonic call-state revisions for HTTP/SSE ordering.

## Storage choices

Do not add SwiftData initially. Contacts/calls are server-authoritative. Use
memory for the first integration, UserDefaults only for lightweight
preferences, and Keychain only when an actual token/credential exists.
