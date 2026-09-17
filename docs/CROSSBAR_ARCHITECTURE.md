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

### Native client contract, verified against Family Call source (2026-09-17)

Read-only audit of `src/server.js`, `src/db.js`, `src/identity.js`,
`src/mirotalk.js`, `src/push.js`, `public/app.js`, `public/sw.js`. The route table
above is confirmed correct against source. What follows are the facts that
constrain a native client, and the gaps that need a backend decision rather than
a client workaround. Load-bearing claims were re-verified directly.

**Identity is network position, not a token.** `resolveIdentity` accepts
`tailscale-user-login` only when the request arrives from loopback
(`src/identity.js:19-22`) and `loadConfig` throws unless the listener is loopback
(`src/config.js:59-62`). A native client cannot set an identity header; it must
reach the tailnet Serve URL and let Serve inject it.

**Verified on the device, 2026-09-17.** A bare `URLSession` GET from Crossbar to
`<tailnet-host>:8443/api/session` returned:

```
HTTP 200
authenticated=true configured=true
identity.source=tailscale name=<enrolled display name>
user.displayName=<enrolled display name>
```

So Serve does inject the identity headers for a non-browser client, and the
existing API authenticates a native app with no backend change at all. This was
the load-bearing assumption of the entire control plane and it holds. The request
deliberately sent no `Origin` header, which `checkOrigin` permits
(`src/server.js:97-105`); that is why `URLSession` is viable without a CORS layer.
The probe that measured it is DEBUG-only and retained at
`Crossbar/Prototype/BackendReachabilityProbe.swift`.

**The room id is never exposed. This is the blocking question for Architecture
B.** `callPublic` returns `{id, callerId, status, createdAt, answeredAt,
participants}` and deliberately omits `roomId` (`src/server.js:150-159`,
verified). The only media coordinates any client receives are the `joinUrl`
string from `POST /api/calls`, `POST /api/calls/:id/respond` when accepted, and
`POST /api/calls/:id/join`. That string is a *web page* URL —
`https://<embed-origin>/join?room=<uuid>&…` — minted server-side and validated to
carry `pathname === '/join'` and `room === roomId` before the origin is rewritten
(`src/mirotalk.js:34-42`, verified). A native Socket.IO client needs the room name
and the MiroTalk origin, and both are *derivable* by parsing that URL — but
`docs/PWA_HANDOFF.md` explicitly warns against inferring a native signalling
contract from the join URL, and the parser would depend on MiroTalk's web route
shape. Two options, and this is a decision rather than a detail: parse the URL, or
return the room id, or a native join descriptor, from a native-appropriate field.

Read from the deployed client (`/js/client.js`, `getQueryParam` at `:1410` and its
callers), the parameters that URL can carry are `room`, `name`, `avatar`, `token`,
`audio`, `video`, `screen`, `chat`, `notify`, `hide` and `duration`. `room` is the
only one a native client needs, plus the origin for its own Socket.IO connection;
the rest configure MiroTalk's browser client and are inert for native. A bare
`/join?room=<uuid>` does **not** auto-join — the client shows a pre-join dialog
asking for a name, and the Socket.IO connection is not opened until after it. That
is why Family Call sends `name` to the join API and why the returned URL carries it.

**Ringing has no native path.** Foreground ringing is SSE (`GET /api/events`);
background ringing is W3C Web Push/VAPID with the credential stored as
`{endpoint, p256dh, auth}` (`src/db.js:421-458`). APNs device tokens are a
different credential class: there is no APNs table, route or client library
anywhere, and `package.json` has exactly one dependency (`web-push`). CallKit plus
PushKit therefore requires a device-token model server-side. This is consistent
with PushKit being explicitly deferred; it is recorded here so the requirement is
not discovered late.

**There is no leave — only a call-wide end.** `'left'` is a declared participant
status (`src/db.js:9`) that is never written, `left_at` is only ever set to NULL,
and no leave endpoint exists in the exhaustively enumerated route list
(`src/server.js:186-341`). `POST /api/calls/:id/end` sets the whole call terminal
(`src/db.js:385-399`). Today one participant hanging up ends the call for
everyone. Since multiparty is mandatory and Add Person must extend the same room,
this needs an explicit product decision; a per-participant leave does not exist in
the backend.

**No audio-only concept.** The join request hardcodes `audio: true, video: true`
(`src/mirotalk.js:25-26`, verified) and no route accepts a media-type field. An
audio-only call cannot be requested today.

**Constraints that would affect a native client silently.** SSE carries no event
ids and no replay (`src/server.js:236-254`), so a client reconnecting mid-ring
loses `incoming-call` and must reconcile through `GET /api/bootstrap` and
`GET /api/calls/:id`. Rate limits are in-memory, per process: create 6/min,
respond 20/min, invite 12/min (`src/rate-limit.js`). Bodies cap at 16 KB. `GET
/api/session` mutates the database by enrolling on read (`src/server.js:190`), so
using it as a health check writes rows. A MiroTalk failure aborts call creation
entirely, because the join URL is minted before the call row is written
(`src/server.js:175-178`, verified).

**Two documentation defects found by this audit, both in the Family Call
repository and neither fixed here** (that repository is out of scope for Crossbar
work). `deploy/map-session-identity.mjs` requires `session.identity.login` (`:17`,
`:26`, `:30`), a field `GET /api/session` never returns (`src/server.js:194`,
verified) — that helper cannot pass against current source, so source wins and the
helper is stale. Separately, that repository's `docs/MIROTALK_UI_INTEGRATION.md`
describes a `family=1` join marker and a bidirectional `postMessage` bridge; no
such code exists anywhere in its `src/` or `public/`, the only `postMessage` use
being the service-worker-to-page channel. That document reads as implemented and
is not.

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

**Native signalling executed (2026-09-17).** That contract had never been run
outside a browser. A reduced native Engine.IO v4 / Socket.IO v5 client
(`Crossbar/Prototype/MiroTalkSignalClient.swift`) connected to production MiroTalk
and was admitted:

```
connecting wss://<host>/socket.io/?EIO=4&transport=websocket
engine.io open {"sid":"…","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":10000000}
socket.io connected {"sid":"…"}
emit join channel=<uuid>
event ["serverInfo",{"peers_count":1,"host_protected":false,"user_auth":false,
                    "is_presenter":true,"join_locked":false,"maxRoomParticipants":1000,…}]
```

So the wire protocol is executable from native code, and the `join` payload shape
derived by reading 1.9.64 rather than running it was accepted verbatim.
`peers_count: 1` correctly reflects the single socket in that room; no `addPeer`
arrived because no other peer was present.

This proves **admission, not a call**: no peer connection, no SDP, no ICE. It also
leaves the central unknown exactly where it was — what replaces the browser's
`negotiationneeded`, which Objective-C libwebrtc does not expose.

**Two-peer fan-out confirmed live (2026-09-17).** Two native peers joining one room
produced the mesh exactly as specified. Peer A, joining after a browser peer, was
told to offer to it (`should_create_offer: true`) and *not* to offer to peer B,
which joined later (`false`). Peer B, the joiner for both, was told to offer to
both. `serverInfo.peers_count` tracked the room 1 → 2 → 3; each `addPeer` carried
the whole `peers` map including the recipient itself; a `peerName` event followed
each. The browser peer appeared as `Mobile Safari 27.0`, so a real 1.9.64 browser
client and native clients shared one room and were paired by the server. The
offerer-selection rule the audit derived by reading `server.js:2433-2451` is
therefore verified against the running server, not merely transcribed.

**A contradiction with our own documentation.** Every `addPeer` carried:

```
"iceServers":[{"urls":"stun:stun.l.google.com:19302"}]
```

`docs/MIROTALK_CORE_AUDIT.md` finding 6 and `docs/OMP_HANDOFF.md` both state that
production delivers an empty `iceServers` list because STUN and TURN are disabled.
The live server hands out Google's public STUN. Either the production
configuration changed after the 2026-09-16 audit or that reading was wrong; either
way the docs are not current. The impact is not cosmetic: a public third-party
STUN server sits in the ICE path of a deliberately private application, and it
learns the peers' reflexive addresses. Re-checking the effective MiroTalk ICE
configuration is a read-only production task and should precede any decision about
what Crossbar does with server-supplied `iceServers`.

**Why the first two-peer attempt saw nothing.** In that run the native client was
admitted and then received no `addPeer` for the browser peer. The cause is now
clear: joining the room required switching to Safari, which backgrounded the app,
and a suspended app's WebSocket dies silently — no close frame, no error, nothing
any log can show. The second run kept both peers in the foreground inside the app
and both exchanges completed. Signalling does not survive backgrounding without a
background mode, which the product will need for a call that outlives the app
being on screen.

**A native call completed (2026-09-17).** With peer connections implemented, two
native peers in one room negotiated and carried media with no browser involved:

```
B: addPeer … should_create_offer=true iceServers=1
B: policy: offering … after appending tracks
B: signaling state -> 1                 (have-local-offer)
B: offer -> … (3912 chars)
A: addPeer … should_create_offer=false iceServers=1
A: policy: awaiting an offer
A: offer <- … (3912 chars)
A: signaling state -> 3                 (have-remote-offer)
A: answer -> … (3771 chars)
A: signaling state -> 0                 (stable)
both: remote audio track, remote video track, remote stream (1a/1v)
both: pc state -> 2, ice state -> 2 (B reached 3, completed, then settled at 2)
A: media IN bytes=9591  delta=8145  energy=0.020
B: media IN bytes=10236 delta=8169  energy=0.020   — climbing to ~85 KB each way
```

**The offer trigger is resolved.** The audit's stated one undetermined part was when
the local side decides to offer, because MiroTalk delegates it to the browser's
`negotiationneeded` event and Objective-C libwebrtc exposes no equivalent. The
synthesised policy — append tracks, then offer exactly once because the server said
`should_create_offer` — produced a usable offer with both media m-lines and
completed against a peer built only from the written contract. Divergence risks A2
(an offerer with no tracks never offering) and A11 (server-assigned offerer role
against opportunistic renegotiation) did not materialise in this configuration.

**Three peers, three links (2026-09-17).** The same run extended to multiparty, which
is mandatory for the product. Joining order decided the offers exactly as specified:
the first peer offered to nobody, the second offered only to the first, and the third
offered to both.

| Peer | Offered to | Connections | Media received |
| --- | --- | --- | --- |
| A (first) | — | 2 | from B, from C |
| B (second) | A | 2 | from A, from C |
| C (third) | A and B | 2 | from A, from B |

Every link reached `pc state -> 2` and `ice state -> 2`, each reported a remote audio
track, a remote video track and a `1a/1v` stream, and all six directed streams carried
bytes. This also confirms the one-capture-many-senders model: a single shared
`RTCAudioTrack` and `RTCVideoTrack` were added to every connection, which is what the
product needs and what the previous revision got wrong by giving each peer its own
camera capturer.

One observation is recorded rather than explained: `totalAudioEnergy` concentrated in
the A↔B link (≈0.047) and stayed near zero on the links to C (≈0.002), while the byte
rates were comparable everywhere (~6–17 KB per sample, far above the near-zero bytes
DTX silence produces). The byte rate is the load-bearing evidence that audio flows on
all six streams; the energy split is unexplained and would need a longer run with
known speech to interpret.

**Interop with MiroTalk's own browser client (2026-09-17).** The audit requires the
offer policy be validated against a live 1.9.64 peer rather than against our own
reading of the contract, and a browser cannot share the foreground with Crossbar on
one phone. With a second tailnet device — Safari on the Mac, joined first as
`MacPeer` so that the native side had to offer:

```
addPeer J8_efcyt should_create_offer=true iceServers=1
policy: offering to J8_efcyt after appending tracks
signaling state -> 1                                        (have-local-offer)
offer -> J8_efcyt (3914 chars, 2 m-lines (audio,video))
answer <- J8_efcyt (3823 chars, 2 m-lines (audio,video))    ← MiroTalk's browser answered
signaling state -> 0
offer <- J8_efcyt (5201 chars, 3 m-lines (audio,video,application))   ← then re-offered
signaling state -> 3 → 0
answer -> J8_efcyt (10227 chars, 3 m-lines (audio,video,application))
remote audio track, remote video track, streams (1a/0v) and (0a/1v)
pc state -> 2, ice state -> 2 → 3 (completed)
media IN delta ≈ 5000 bytes per sample, steady
```

The browser accepted our offer, then renegotiated on its own to add a data channel,
and our client applied that and answered again — while the phone's camera rendered in
Safari, so media crossed in both directions.

This closes the audit's requirement and retires the risks it rated *likely*: A1 (no
`negotiationneeded`) is answered by the synthesised policy; A2 and A11 did not appear;
A4 (no glare handling) was exercised by a real browser-initiated renegotiation and did
not fail; and A6 (candidates carrying only `sdpMLineIndex`) did not prevent ICE
completing against Chrome, which is stricter here than libwebrtc-to-libwebrtc.

The `&name=` parameter was required: a bare `/join?room=<uuid>` shows MiroTalk's
pre-join dialog and opens no Socket.IO connection at all.

**The STUN finding is now concrete.** Both peers' candidate lists contained srflx
candidates resolved through `stun:stun.l.google.com:19302`:

```
candidate:1923698751 1 udp 1686052607 119.154.255.67 64841 typ srflx …
candidate:3649812590 1 udp 1685921535 154.80.38.134 60608 typ srflx …
```

A third-party STUN server is being consulted and is returning this device's public
egress addresses. Tailscale host candidates (`100.88.61.34`, `fd7a:115c:a1e0::…`)
were present alongside them and are what a tailnet-only deployment actually needs.
This is the ICE decision flagged above, now with evidence for it rather than a
reading of configuration.

**Which pair actually carried the media (2026-09-17).** Gathered candidates say what
was available; only the selected pair says what is load-bearing. Measured with the
two devices on **different networks** — phone on cellular, Mac on Wi-Fi — which is the
product's real topology:

```
ICE path [T01] local=srflx 154.80.38.134:60615 remote=srflx 119.154.255.67:63718 state=succeeded bytesSent=132468
ICE path [T01] local=prflx 192.168.1.130:53530 remote=host  192.168.1.127:63718 state=succeeded bytesSent=206979
… growing to bytesSent=898047
```

**The public path carried the off-LAN call.** With Wi-Fi off, the selected pair was
`srflx ↔ srflx`, resolved through `stun.l.google.com`, and it moved 132 KB of media.
When Wi-Fi returned, ICE migrated to a host pair and the byte count grew to ~900 KB.
So the server-supplied public STUN server is load-bearing off-LAN, not decorative.

Earlier the same measurement on a shared LAN selected `host ↔ host`, confirming host
candidates outrank srflx when reachable — which is why the first attempt could not
answer this question.

**With STUN discarded (2026-09-17).** The probe was changed to drop the
server-supplied `iceServers` entirely and run on host candidates alone:

```
iceServers: server=1 applied=0 (STUN IGNORED)
gathered: host only, no srflx — 169.254.210.170, 10.187.100.156, 192.0.0.6,
          100.88.61.34, fd74:6572:6d6e:7573:c:…, fd74:6572:6d6e:7573:d:…,
          fd7a:115c:a1e0::9a32:3d22
ICE path [T01] local=prflx 192.168.1.130:52397 remote=host 192.168.1.127:49513
                state=succeeded bytesSent=… 819259
```

ICE completed and carried ~819 KB with no STUN at all. But **the path was the LAN, not
the overlay**: the selected pair's local port matches the Tailscale candidate's port,
yet the Mac received those packets from `192.168.1.130`, an address it had never been
advertised and therefore learned as peer-reflexive. Packets only arrive from a LAN
address over the LAN, so Wi-Fi was up by the time ICE paired. The run therefore shows
that STUN is not always required, but **does not** show that the Tailscale overlay can
carry a call between networks.

That last question needs a run where Wi-Fi stays off for the whole exchange and the
selected pair is read while it is still off. Until then, what Crossbar should do with
server-supplied `iceServers` is undecided by evidence, and the conservative reading is
that dropping them is unproven rather than free.

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

**Finding: media already running dies when CallKit activates the session
(2026-09-17).** With capture and the loopback running, audio flowed at ~5 KB per 3s
sample. Starting a CallKit call stopped it dead — `delta=0` for the entire call — and
it returned only when a *later* call re-armed the path:

| | media running → call | call ended → new call |
| --- | --- | --- |
| `isAudioEnabled` before | already true | false, from `didDeactivate` |
| so `didActivate` sets | true → true — *not a change* | false → true — *a change* |
| `canPlayOrRecord` line | **absent** | **present** |
| `WebRTC willSetActive` | **absent** | **present** |
| audio | **dead for the whole call** | flows |

Setting `isAudioEnabled = true` on a gate that is already true raises no
notification, so `RTCAudioSession` never tells the ADM that `canPlayOrRecord` changed,
the ADM never re-evaluates its audio unit, and no `setActive` reaches the session —
while CallKit has reconfigured that session underneath it. Every working case in the
log has that transition followed by `willSetActive`; the one dead case has neither.

**No other instrument saw this.** Throughout the dead period the metrics read
`rtcActive=1 audioEnabled=1 audioUnit=1`, `playOrRecordCount` never advanced, the
preview stayed live and `canPlayOrRecord` reported true. Only the inbound-RTP byte
counter showed the audio was gone. This is the defect that ships as "the call connects
and nobody can hear anything".

**Fix, verified (2026-09-17).** `callKitDidActivate` now forces the gate through false
and back, raising the `canPlayOrRecord` notification that re-arms the ADM. Audio
survives the activation:

```
didActivate #1: rtc.isActive before = true
adopted by RTCAudioSession; forced canPlayOrRecord transition
canPlayOrRecord = false        ← the forced transition
canPlayOrRecord = true
WebRTC willSetActive false
audio unit STOPPED
WebRTC willSetActive true
WebRTC didSetActive true
audio IN bytes=77099  delta=4882     ← alive, where it was previously dead
audio IN bytes=88479  delta=11380
audio IN bytes=98657  delta=10178
```

Ending the call gates audio off (`canPlayOrRecord = false`, `audio unit STOPPED`,
`delta=0`) and starting another call restores it — both correct under
`useManualAudio`, where media follows the call.

Cost, stated because it is not free: the re-arm is a deliberate audio-unit teardown
and restart, visible as `willSetActive false` → `audio unit STOPPED` →
`willSetActive true`. It is applied at call activation, which is before media normally
begins. Any implementation that instead starts media *before* CallKit activates must
include this re-arm, or it will ship a call with no audio and healthy-looking
telemetry.

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
