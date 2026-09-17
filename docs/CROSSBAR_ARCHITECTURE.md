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
player paused, so no preview renders (P8.10). This was reproduced in two
different ownership arrangements — app-configured `AVAudioSession` and
WebKit-only (P8.13) — so it is not a competing-owner defect the runtime can fix
by yielding ownership.

Criteria 4, 5, and 9 remain unmeasured. No decision to replace Architecture A is
recorded here; this note records the measurement that decision now rests on.

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
