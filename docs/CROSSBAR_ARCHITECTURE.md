# Crossbar provisional architecture

## Decision status

Architecture B — native WebRTC plus a native Socket.IO client — was selected by
the owner on 2026-09-17, on the measured evidence in
`ARCHITECTURE_A_PROBE.md` P8.7–P8.14: CallKit works fully on physical hardware,
but WebKit cannot hold an audio session while CallKit owns one, and that failure
reproduced in three separate configurations. Architecture A's media layer is
therefore abandoned. The probe that demonstrated it is retained in the
repository as DEBUG-only diagnostic code and as the evidence record; the
native/WebKit media bridge is not part of the product path.

```text
SwiftUI product UI
  -> Call coordinator and native CallKit
     -> AVAudioSession owned by the app and adopted by RTCAudioSession
  -> native WebRTC media engine (mesh, SDP/ICE, capture, render)
  -> native Socket.IO client speaking the audited MiroTalk contract
  -> existing private MiroTalk Socket.IO server, reused unchanged
```

Architecture A remains described below as the alternative considered and
rejected, and its measured failure is what justifies B. See
"Architecture B scoping" for the dependency, effort and licensing position.

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

#### Reuse payoff

Would reusing MiroTalk's client cut the work? The answer is clear and it is not
the hoped-for one. MiroTalk's browser client is a monolithic, UI-coupled
~18,297-line `public/js/client.js` with no WebRTC module; there is no `webrtc.js`
to lift. Of the nine rebuild groups, only the two L-sized ones (mesh peer
lifecycle; negotiation and ICE) contain MiroTalk-specific logic, and even those
yield an **executable specification, not reusable code**. The other seven are
browser-API plumbing with no native equivalent, third-party library work
(`socket.io-client-swift`, `RTCMTLVideoView`), or native concerns MiroTalk says
nothing about (audio-session ownership, explicit teardown, reconnect policy).

**No group's size drops a band.** The saving is uncertainty, not volume: the
sub-task "reverse-engineer a non-standard handshake from a black-box server"
collapses into "translate known handler behaviour". That is real risk reduction
on the two largest groups and worth having, but it must not be booked as effort
saved. Read purely as a specification, MiroTalk's client is free to consult —
which is already what `docs/MIROTALK_CORE_AUDIT.md` does.

There is no client-side oracle upstream either: the repository's mocha suite
(`tests/*.js`) covers only server-side behaviour — API, validation, host
protection, room templates, whisper, XSS — with no mesh, SDP or ICE test or
fixture anywhere in the tree. The browser client is the only executable
reference for the client protocol, which is why the existing PWA matters as a
reference peer.

**Reimplementation verdict: tractable with care.** The wire protocol is fully
determined — what is sent and in what shape — and the offer/answer/ICE/teardown
sequence, the per-peer candidate queue, and the native API mapping are now
written down in `docs/MIROTALK_CORE_AUDIT.md` under "Mesh and negotiation
specification". Most of the usual porting risk is absent by construction: no SDP
munging, no transceiver API, no codec preferences, no ICE restart, and
`replaceTrack` maps one-to-one onto `RTCRtpSender.track`.

What is *not* determined is **when the local side decides to offer.** MiroTalk
delegates that entirely to the browser's `negotiationneeded` event — the only
`createOffer(` call in the file sits inside that handler — and **Objective-C
libwebrtc does not expose an equivalent**. A Swift port must therefore synthesise
the trigger as explicit policy: offer after adding tracks, offer after removing a
track, offer after answering when local transceivers went unmatched, and never
offer for a pure `replaceTrack` swap. That policy cannot be validated against a
specification, only against a live 1.9.64 peer — which is why the PWA-as-
reference-peer test matters and why the budget belongs in interop testing rather
than porting effort.

Sixteen specific divergence risks are catalogued in the audit, with the
likelihood of silent divergence for each. The ones rated *likely* are all in the
trigger rather than the payload: the missing `negotiationneeded`, an offerer with
zero tracks never offering, the late-track latch having no deterministic effect,
pre-existing local transceivers versus answer m-line association, the two
different camera-off paths, positional sender bookkeeping, and the mismatch
between a server-assigned offerer role and opportunistic bidirectional
renegotiation.

#### Licensing

MiroTalk P2P is **AGPL-3.0-only** (SPDX). `package.json` carries the deprecated
`AGPL-3.0` identifier and no file anywhere in the tree says "or later". There is
exactly one `LICENSE` — the stock AGPLv3 text — with no `NOTICE`, no `COPYING`,
no §7 additional terms and no per-file headers; authorship is asserted only as
`"author": "Miroslav Pejic"`, with no program-level copyright line. The only
vendored third-party component is an Emscripten RNNoise build
(`public/js/rnnoiseSync.js`) carrying no notice; upstream RNNoise is BSD-3-Clause,
so that is a notice obligation, not copyleft. Everything else is CDN-loaded at
runtime.

**AGPLv3 §13 already attaches to the production MiroTalk instance today, and
independently of Crossbar.** The operative sentence carries no "public"
qualifier: "if you modify the Program, your modified version must prominently
offer all users interacting with it remotely through a computer network … an
opportunity to receive the Corresponding Source of your version". The deployment
is modified — the deliberate loopback bind — and is reached remotely by household
devices over Tailscale, which is a computer network. The artefact owed is the
Corresponding Source **of the modified version**, so offering only the upstream
commit would not satisfy it, and nothing in either repository records such an
offer being made. Note that Family Call's own `docs/LICENSES.md` conditions its
concern on "distribution beyond the household", which is narrower than §13's
text.

Client-side options, stated as licence text and its plain requirements rather
than as legal conclusions:

| Option | Effect |
| --- | --- |
| Clean-room Swift reimplementation from a written specification | No MiroTalk-derived code in the app, so no AGPL obligation on the app. The server's §13 duty is unchanged either way. |
| Porting or translating the JS mesh logic | The app becomes a work based on the Program: §5(a)–(d) attach — modified-notice with date, licence notice, the whole work licensed under AGPL to recipients, and legal notices in interactive UIs — plus §6 if builds are conveyed to family devices. |
| Copying source verbatim | §4 conditions, plus §5(c) whole-work licensing if modified or combined beyond a §5 aggregate. |

A commercial alternative therefore matters: the upstream README offers a **paid
one-time licence via CodeCanyon** with terms different from AGPLv3. That is a
separate proprietary licence, not an exception inside the AGPL grant, and nothing
today assumes it. Worth knowing it exists — but per "Reuse payoff" above, even a
permissive licence would not unlock an effort saving, because there is no
portable mesh module to lift.

Third-party obligations for the shipped app are separate and permissive: the
WebRTC framework is BSD-3-Clause plus a Google patent grant, and
`socket.io-client-swift` is MIT with an Apache-2.0 Starscream dependency. BSD
binary redistribution requires the notice to travel with the binary, so extract
`WebRTC.xcframework/LICENSE` from the chosen release into the app's
acknowledgements; that file is also the authoritative transitive-licence list for
the binary actually shipped.

Unresolved and explicitly left to a lawyer: whether a specification-derived
clean-room rewrite is a derivative work; whether close porting engages §5(c) on
the whole app; whether AGPLv3 and App Store terms can be satisfied together under
§10; whether an iPhone is a §6 "User Product"; what "prominently offer" requires
in practice; and whether the deployment's §13 duty has been discharged to date.

#### Audio-seam spike result (2026-09-17)

The first Architecture B code was a DEBUG-only instrument, run on the physical
iPhone. It asks the one question that reading code cannot answer: does
`RTCAudioSession` adopt a CallKit-activated session, and does native capture
survive the handover where WebKit's did not?

Procedure: configure `RTCAudioSession` for `playAndRecord`/`voiceChat` with
`useManualAudio = 1` and `isAudioEnabled = 0`; start native camera capture with a
local `RTCMTLVideoView` preview; then start a real CallKit call with the web
engine deliberately out of the path.

| Step | Observed |
| --- | --- |
| Capture started | preview live, `rtcActive=0 audioEnabled=0 audioUnit=0` |
| CallKit call started | **preview still live**, `rtcActive=1 audioEnabled=1 audioUnit=0` |

Device log, verbatim: `didActivate #1: rtc.isActive before = false` →
`adopted by RTCAudioSession; isAudioEnabled = true`.

- **Proven:** CallKit activated the audio session; the app handed it to
  `RTCAudioSession` via `audioSessionDidActivate(_:)`; WebRTC did **not** attempt a
  competing activation; and **native capture kept running through the handover**.
  WebKit did the opposite in the same situation — `maybeActivateAudioSession …
  failed to activate AudioSession`, capture muted and stopped, preview dead in
  about half a second (P8.10, P8.13, P8.14).
- **Not yet proven:** that audio actually flows. `audioUnit=0` means the audio
  unit never started, because the spike creates an audio track but nothing consumes
  it, so WebRTC's ADM never configures itself and `canPlayOrRecord` never changes.
  Audio playout and record under CallKit are therefore unmeasured, as are routes,
  interruption and background behaviour.

**Update — loopback increment (2026-09-17).** Two defects in the first attempt made
that result unreadable rather than negative, and both are worth recording because
each would mislead a future reader:

1. Every method on `RTCAudioSessionDelegate` takes `RTCAudioSession`, not
   `AVAudioSession`. The delegate was written with the wrong type; the methods are
   `@optional`, so the compiler accepted it and **none of them were ever called** —
   no `canPlayOrRecord`, no audio-unit events at all.
2. With `useManualAudio = true`, WebRTC gates audio behind `isAudioEnabled`, which
   was only set inside CallKit's `didActivate`. A loopback with no call could
   therefore never start the audio unit.

After fixing both, with two peer connections negotiated in-app and audio flowing:

| Step | Observed |
| --- | --- |
| Capture + loopback, no call | `audio unit STARTED (play/record) #1`, `canPlayOrRecord = true`, `rtcActive=1 audioEnabled=1 audioUnit=1` |
| Then CallKit call started | `didActivate #1: rtc.isActive before = true`, `adopted by RTCAudioSession`, **metrics still `1 1 1`** — the audio unit kept running |

`WebRTC willSetActive true` / `didSetActive true` appear **in the loopback phase,
before the call**, which is correct: nothing else held the session, so WebRTC
activated it itself. After CallKit took over, no further activation was observed in
the captured log window and the audio unit did not stop. The route moved to
`Receiver` (route-change reason 3, category change).

- **Proven:** native audio runs, and it survives CallKit taking the session when
  media was already running. This is the WebKit failure case inverted.

**CallKit-first ordering (2026-09-17).** The real-world sequence — a call already
active, with media starting afterwards — and the one WebKit failed at:

| Step | Observed |
| --- | --- |
| Call started with nothing else running | `didActivate #1: rtc.isActive before = false` — CallKit activated the session itself |
| Capture started during the call | preview survived; this is where WebKit's capture was destroyed |
| Loopback started | `canPlayOrRecord = true`, `audio unit STARTED (play/record) #1` |
| End state | `rtcActive=1 audioEnabled=1 audioUnit=1` |

**No `WebRTC willSetActive` appeared at all.** Compare the loopback-first run, where
WebRTC owned activation and did call `setActive:`. When CallKit owns the session,
WebRTC makes no activation attempt of its own and simply adopts it — the suppression
its header describes, confirmed in the ordering that matters.

**Defect found by this run.** `configureAudioSession()` wrote `isAudioEnabled = false`
and `start()` calls it, so in this ordering starting capture silently cleared the
audio grant CallKit had just made — the log showed `isAudioEnabled` falling back to
0 mid-call, with only the loopback raising it again. The measurement still passed,
but the gate was dropped and re-raised rather than held. Setup must never write
`isAudioEnabled`; teardown owns that. Fixed in the same commit.

**Gate and teardown re-measured after the fix (2026-09-17):**

| Step | Observed |
| --- | --- |
| Call active, nothing else running | `rtcActive=1 audioEnabled=1 audioUnit=0` — no consumer for audio, so the unit correctly stays down |
| Capture started mid-call | metrics unchanged at `1 1 0`; log reads `... useManualAudio=1 isAudioEnabled=1 left alone` — CallKit's grant is now held, where before it fell to 0 here |
| Call ended | `didDeactivate #1: isAudioEnabled = false, session returned`, `canPlayOrRecord = false`, metrics `0 0 0` |
| Capture stopped | `capture stopped`; app responsive |

**On reading the preview as evidence.** `RTCMTLVideoView` keeps its last rendered
frame after the track is detached, so the preview still shows a picture once capture
has stopped and it cannot by itself show whether the camera was released. The
authoritative signal is the system privacy indicator in the status bar: after Stop
it is **absent**, which is what confirms both camera and microphone were released.
Do not use the frozen preview to argue that capture is still running.

**Lock, wake and backgrounding (2026-09-17).** Measured with the call active and the
loopback running, using produced-frame counts rather than the preview — the preview
cannot distinguish a frozen picture from a live one.

| Event | Lock/wake | Background |
| --- | --- | --- |
| `willResignActive` | frames=454 | frames=309 |
| `didEnterBackground` | frames=497 | frames=331 |
| `willEnterForeground` | frames=497 | frames=331 |
| `didBecomeActive` | frames=517 | frames=334 |
| after ~10s, capture stopped | 883 | 845 |

**Video capture stops on suspension and resumes cleanly.** Frames freeze exactly at
`didEnterBackground` (497 / 331) and are unchanged at `willEnterForeground`: the
camera produced nothing while the app was suspended, as iOS requires. They resume on
return (497 → 517 → 883; 331 → 334 → 845). No stale state, no intervention needed —
the capturer came back on its own. `audioUnit=1` throughout and no
`audio unit STOPPED` line in either test, **with the call active the audio unit kept
running across lock and background.**

**No route change on lock or unlock.** Reason 6 `wakeFromSleep` never appeared; the
session was not reconfigured.

Product implication: a backgrounded call keeps audio but loses video, so a remote
peer would see a frozen frame unless the app signals camera-off explicitly. That is
an application-level decision this probe deliberately does not make.

**Interruption (2026-09-17, partial).** With capture and the loopback running but
**no CallKit call**, a Clock alarm produced `AVAudioSession` interruption
notifications, which the probe's raw observer logged — so an alarm does interrupt a
`playAndRecord`/`voiceChat` session, and RTCAudioSession forwards it.

With a **CallKit call active**, the same alarm produced none: once CallKit owns the
session, iOS deconflicts audio above the app and never posts the interruption.

**Audio flow measured (2026-09-17).** Every "audio runs" statement before this rested
on the audio unit starting, which is a proxy: a started unit and a silent one are
indistinguishable from there. Polling inbound-RTP statistics on the *receiving* peer
connection shows audio actually crossing the loopback:

```
audio IN bytes=225995 delta=6515  energy=0.599
audio IN bytes=236583 delta=10588 energy=0.600
audio IN bytes=240500 delta=3917  energy=0.600
audio IN bytes=247757 delta=7257  energy=0.600
```

4–10 KB per 3s sample is roughly 11–27 kbps — the range Opus occupies for speech.
Silence under DTX would be near-zero bytes with a flat energy counter; here
`totalAudioEnergy` advances, so the stream carries real content rather than
keepalive. Audio genuinely flows: capture source → pc1 → pc2.

**What the alarm interruption actually did (2026-09-17).** With no CallKit call:

```
audio IN bytes=123668 delta=9564  energy=0.224
AVAudioSession interruption BEGAN (raw 1) options=0
INTERRUPTION began (RTCAudioSession)
audio IN bytes=128796 delta=5128  energy=0.225
AVAudioSession interruption ENDED (raw 0) options=1
INTERRUPTION ended, shouldResume=true
audio IN bytes=131574 delta=2778  energy=0.226
```

Audio never stopped. Bytes kept arriving across BEGAN and ENDED, the audio unit never
reported stopping, and the route moved to speaker and back. An alarm is therefore a
*notification without a teardown*: iOS announces the interruption but does not
deactivate this session, and the ADM leaves the unit running.

**This must not be recorded as "audio survives interruptions."** It shows this
particular interruption had no effect on the media path. A genuine interruption — one
that actually deactivates the session — remains unmeasured, and the realistic
instance (an incoming call during a live call) is not reproducible here: FaceTime
between the Mac and the iPhone is blocked by the shared Apple ID.

The session-teardown path is instead exercised through CallKit, which is how the
product will meet a real call: `didDeactivate` returned the session with
`canPlayOrRecord = false` and metrics `0 0 0`, and `didActivate` restored it.
Behaviour across a full activate → deactivate → activate cycle is measured separately
below.

- **Still unmeasured:** audio quality — there is no remote peer, so nothing in this
  probe demonstrates audible fidelity.

#### Status

Decided by the owner on 2026-09-17 in favour of B. Mesh and negotiation
reimplementation feasibility, and the precise licence position for this
deployment, are under separate investigation.

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
