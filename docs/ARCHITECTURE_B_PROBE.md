# Architecture B spike: instruments, evidence, reproduction

This records the DEBUG-only Architecture B spike built and measured on the physical
iPhone during 2026-09-17, and how to run it again. It is an index and a
reproduction guide, not a second copy of the findings:

| Document | Holds |
| --- | --- |
| `CROSSBAR_ARCHITECTURE.md` | the architecture decision, and each finding in detail with its raw output |
| `NATIVE_PROGRESS.md` | the capability matrix |
| `MIROTALK_CORE_AUDIT.md` | the MiroTalk wire contract, and the divergence risks |
| `ARCHITECTURE_A_PROBE.md` | the WebKit probe that failed and justified B |
| `TAILSCALE_KIT_PROBE.md` | the embedded Tailscale node, on its own branch: why it exists, what is built, and what is still unmeasured |
| this file | what the spike is made of, how to run it, and what it does **not** show |

## Why B, and what this spike had to answer

Architecture A embedded MiroTalk's browser client in a `WKWebView`. It failed on
hardware: WebKit loses its audio session the instant CallKit takes one, in all three
arrangements tried (P8.10, P8.13, P8.14 in `ARCHITECTURE_A_PROBE.md`). B replaces the
browser client with native WebRTC and a native Socket.IO client speaking the same
wire contract.

The spike therefore had to establish, on real hardware, that:

1. native WebRTC can hold a CallKit call's audio session rather than compete for it;
2. audio actually flows, not merely that an audio unit starts;
3. a native client can authenticate against the existing Family Call API;
4. a native engine can speak MiroTalk's signalling protocol;
5. and it interoperates with MiroTalk's own browser client.

All five are now measured. See the matrix in `NATIVE_PROGRESS.md`.

## Instruments

All are `#if DEBUG` and live in `Crossbar/Prototype/`. None is product code.

| File | What it is | What it measures |
| --- | --- | --- |
| `AudioSeamProbe.swift` | the original Architecture B seam spike, plus its SwiftUI screen | CallKit audio-session adoption, a local loopback peer connection so the ADM is genuinely exercised, produced video frames, app lifecycle |
| `MiroTalkSignalClient.swift` | a reduced native Engine.IO v4 / Socket.IO v5 client, peer connections, and the shared media source | admission into a MiroTalk room, the mesh fan-out, SDP/ICE exchange, the offer policy, inbound RTP, and which carrier the socket took — since 2026-09-19 through `CallTransport`, a session configuration *and* the label naming its route, which the product now sets from the embedded node's loopback |
| `BackendReachabilityProbe.swift` | a bare `URLSession` GET | whether tailnet Serve injects the identity header for a non-browser client |
| `FamilyCallClient.swift` | the Family Call control plane: session, bootstrap, create, respond, join, end, and the `/api/events` stream | whether a native client can drive the real call lifecycle, and whether the room id can be recovered from the `joinUrl` |
| `FamilyCallFlow.swift` | the flow over that client, plus one `MiroTalkSignalClient` and a shared capture | whether the product call path works end to end — identity, contacts, ringing, answering, media |
| `RTCVideoSurface.swift` | a `UIViewRepresentable` over `RTCMTLVideoView` for any track | nothing on its own; it is how local and remote video reach the screen. Promoted out of the seam probe once the product path needed it too |

Each writes its output to a file in the app's Documents directory — `seam.log`,
`signal-A.log`, `signal-B.log`, `signal-C.log`, `backend.log` — truncated on the first
write of each launch. Screen-only output is not sufficient: it cost two measurements
before the files were added.

## Running it

Substitute the connected device's identifier, from `xcrun devicectl list devices`.

```bash
# build — a generic destination needs no device connection at all, which matters
# because xcodebuild's build-destination connection to the phone fails far more
# readily than devicectl's does ("A connection to this device could not be
# established" while devicectl installs to the same phone without complaint).
xcodebuild -project Crossbar.xcodeproj -scheme Crossbar \
  -destination 'generic/platform=iOS' -configuration Debug -quiet build

# install and launch (the Debug product path is under DerivedData)
xcrun devicectl device install app --device <device-id> "<path>/Crossbar.app"
xcrun devicectl device process launch --device <device-id> \
  --terminate-existing -e '{"CROSSBAR_AUTOLOAD":"1"}' \
  com.abdullahchaudhry.Crossbar

# pull a log
xcrun devicectl device copy from --device <device-id> \
  --domain-type appDataContainer \
  --domain-identifier com.abdullahchaudhry.Crossbar \
  --source Documents/signal-A.log --destination /tmp/signal-A.log

# screenshot, if a visual check is needed
xcrun devicectl device capture screenshot --device <device-id> --destination /tmp/s.png
```

The Family Call section does not load on appear — it would otherwise open an SSE
stream and call the API on every launch, including the ones made for the seam and
signalling measurements. `CROSSBAR_AUTOLOAD=1` makes it load. This is an environment
variable rather than a launch argument because `devicectl` passes those cleanly and
parses a leading-dash argument as one of its own options.

Launch arguments cannot be used to drive the UI otherwise: the `xcode` MCP server's
device-interaction tools only offer simulators here, so buttons on the phone have to
be pressed by hand or replaced by a gated automatic path like this one.

The signalling section has the same gate, and joins one peer by default:

```
-e '{"CROSSBAR_SIGNAL_AUTOROOM":"room","CROSSBAR_SIGNAL_AUTOPEERS":"2"}'
```

`AUTOPEERS=2` joins A and B as well, which is how remote rendering was verified with
no external peer — two peers in one room each receive the other's video. Use `1` when
an external peer is what is under test, because a second native peer competes for the
same remote-track slot and makes the tile ambiguous.

Two further gates, added on branch `tailscale-kit`, and the first is the one that
matters when a run produces nothing:

```
-e '{"CROSSBAR_PROBE_AUTOSHOW":"1","CROSSBAR_SIGNAL_VIANODE":"1"}'
```

`PROBE_AUTOSHOW` presents the probe screen over whatever the product is showing, because
the screen is otherwise reached from **Settings → Advanced → Instruments** and none of the
gates above can fire from a screen that was never mounted. It is set from `onAppear` — a
`fullScreenCover` whose binding is already true when the view is inserted is never
presented at all — and not from the root view's `.task`, which is cancelled when the phase
switch changes the view's identity.

**Put `-e` before the bundle identifier.** It is an option of `devicectl`, not an argument
to the app, and `device process launch` takes a variadic list of arguments for the app: a
payload placed *after* the bundle identifier is handed to the app as `argv`, never as
environment, so every gate inside it silently does nothing. That cost seven runs on
2026-09-19, in which the same payload presented the screen in one run and nothing in the
next — which reads as a flaky presentation, or as a variable that arrives and is ignored,
and was neither:

```
xcrun devicectl device process launch --device <id> -e '{"CROSSBAR_PROBE_AUTOSHOW":"1"}' \
  com.abdullahchaudhry.Crossbar          # ✓ the gates see it
xcrun devicectl device process launch --device <id> com.abdullahchaudhry.Crossbar \
  -e '{"CROSSBAR_PROBE_AUTOSHOW":"1"}'   # ✗ arrives as an argument, changes nothing
```

Two more `devicectl` facts from the same session, each of which looks like something else:

  - `device process terminate` requires `--pid <pid>`; a bundle identifier alone fails, and
    with output redirected that failure is invisible. An app that was never terminated
    makes every later launch a no-op — it is re-activated with its old environment and its
    old node — which reads as a sticky environment or as a gate that does not work.
  - A Debug build's `Crossbar.app/Crossbar` is a ~90 KB stub; the code lives in
    `Crossbar.debug.dylib`. Grepping the stub for a gate's string finds nothing, and says
    nothing about what was installed.

`VIANODE` routes the signalling sockets through the embedded Tailscale node's
SOCKS loopback instead of the system's route, and logs which carrier each socket took plus
the node's own peer counters; leave it off for the control run whose flat counters are
what make a routed run's growth mean anything.

**A stub control plane is how a launch path that needs somebody to call you gets tested.** A
ringing invitation survives on exactly one surface a client can find after the fact —
`/api/bootstrap` → `calls[]` with `myStatus: "invited"` — so a small HTTP stub answering
`/api/session`, `/api/bootstrap` and `/api/events` exercises it with no second person, and
serving it over this Mac's own tailnet name keeps App Transport Security happy without a
certificate of our own:

```bash
python3 /tmp/invite-stub.py &                        # answers on 127.0.0.1:8080
tailscale serve --bg --https=10000 http://127.0.0.1:8080
xcrun devicectl device process launch --device <id> \
  -e '{"CROSSBAR_BACKEND_URL":"https://<this-mac>.<tailnet>.ts.net:10000"}' \
  com.abdullahchaudhry.Crossbar
tailscale serve --https=10000 off                    # when finished
```

Measured 2026-09-19: the app logged `an invitation was waiting for this device — ringing it`,
`incoming call … from Dad status=ringing` and `reported to CallKit`, with the incoming-call UI
and the system banner on screen. The same stub drives the call screen when its `joinUrl` names
a real MiroTalk room, which is how the in-call layout gets exercised without ringing a relative.

There is no rebuild gate any more. `CROSSBAR_TAILSCALE_REBUILD` was removed on 2026-09-19
when the node became the product's transport: the app now verifies the carrier every time
it comes forward and rebuilds the node when the verify fails, because the failure it
answers is intermittent and cannot be provoked on demand — a gate that had to be switched
on to get the correct behaviour was the wrong default for product code. See
`TAILSCALE_KIT_PROBE.md`.

**Check the log files' timestamps before believing their contents.** The instrument leaves
the previous run's files in place when it does not run, and stale files read exactly like
fresh ones: a `signal-B.log` showing a completed call with ~59 MB sent, and a
`signal-A.log` with one line in it, both turned out to be from the previous day on
2026-09-19, while the run that produced them had never joined anything. List the container
(`devicectl device info files`) and compare the times before drawing a conclusion.

Two operational facts that caused wasted runs:

- The Mac reaches the phone over the **network, not USB**. Turning the phone's Wi-Fi
  off also cuts `devicectl`, so a log cannot be pulled until it is back on. The log
  persists regardless.
- A suspended app's WebSocket **dies while the app is frozen** — no close frame, no error is
  delivered during the freeze. Leaving the app during a signalling test therefore loses the
  call with nothing in the log to say so. What arrives afterwards depends on the client: on
  the next receive after a 600 s freeze the node-carried instrument reported
  `receive failed: … Socket is not connected`, alongside `ice state -> 4` and
  `pc_state -> 4`, so the loss becomes visible on resume rather than at the moment it
  happens. Either way the socket does not come back by itself, and nothing reconnects it.
  **But "backgrounded" and "suspended" are not the same thing**, which is worth knowing
  before designing around this: on 2026-09-19 a call whose audio was actually running, in an
  app declaring the `audio` background mode, kept its socket alive through 100 s in the
  background — six engine.io pings, no close, no error — because iOS never froze the
  process. The freeze is what kills the socket, not leaving the app.

`CROSSBAR_BACKEND_URL` and `CROSSBAR_MIROTALK_ORIGIN` override the endpoints used by
the backend and signal probes, so no deployment detail is baked into the source.

## Defects found in the instruments themselves

Recorded because a silent instrument produces confident wrong answers, and most of
these were found only because a result was suspicious rather than negative.

1. **`RTCAudioSessionDelegate` methods written with the wrong type.** The protocol
   takes `RTCAudioSession`, not `AVAudioSession`. They are `@optional`, so the
   compiler was satisfied and **no delegate method was ever called**: no
   `canPlayOrRecord`, no audio-unit events. The instrument was dead and looked idle.
2. **`isAudioEnabled` set to a value it already had.** CallKit's `didActivate` set it
   `true` when the loopback had already done so — not a change, so no
   `canPlayOrRecord` notification, so the ADM never re-evaluated and **audio stayed
   dead for an entire call** while metrics read `1 1 1`. Fixed by forcing the gate
   through false and back.
3. **Setup revoked CallKit's grant.** `configureAudioSession()` wrote
   `isAudioEnabled = false` and `start()` called it, so starting capture mid-call
   silently cleared the audio CallKit had just enabled.
4. **Reading the preview to infer capture state.** `RTCMTLVideoView` keeps its last
   rendered frame after the track is detached, so a frozen picture and a live one look
   identical. The status-bar privacy indicator is the real evidence.
5. **`statistics.values.first(where: { $0.type == "transport" })`.** Dictionary
   iteration order is arbitrary, so with two transports this returned a different one
   each poll and two candidate pairs appeared to alternate — an artifact that would
   have been read as ICE flapping.
6. **`sdp.split(separator: "\n")` on CRLF text.** In Swift `"\r\n"` is a single
   `Character`, so no line matched and an offer with two m-lines was reported as zero.
7. **One camera capturer per client.** Several peers each started their own capture and
   contended for the session; both reported "media prepared" while only audio was
   verifiably flowing. One `ProbeMediaSource` is now shared by all peers, which is also
   how the product must work.
8. **A log view anchored to its oldest lines**, and logs that existed only on screen.
   Both were fixed with `defaultScrollAnchor(.bottom)` and the per-launch files.
9. **`AsyncBytes.lines` omits empty lines, and the empty line is the SSE dispatch
   signal.** The event stream connected, reported `HTTP 200`, received bytes
   promptly, and yielded **no event at all** — the parser waited for a blank line
   that this sequence never produces, so every event accumulated in a buffer that
   was thrown away when the connection ended. A local mirror of the service isolated
   it: the same server delivered the ready event at `0.00s` at the socket while the
   Swift client saw nothing until the 20-second heartbeat, and then only the
   heartbeat comment. Reading the stream byte by byte and splitting on `\n` — keeping
   empty lines — dispatches the same event at `0.02s`. Two corollaries worth keeping:
   the failure was invisible in every respect except the one that mattered, and
   **Tailscale Serve does not buffer SSE**, which was the other candidate explanation
   and is now ruled out.
10. **Failure paths that set state without logging it.** `load()` reported a failure
    by assigning to the published `phase` and writing nothing to the log, so a thrown
    error and a hung request were indistinguishable from outside — and three runs
    produced a log containing only `section appeared`. The reason
    (`NSURLErrorCannotFindHost`) became visible only after the catch was logged and
    the request line was written *before* the request rather than after it.
11. **A nested `ObservableObject` does not republish.** The first real call rendered
    its local tile and **nothing else**, while the log plainly showed the remote video
    track had been received. `FamilyCallSection` observes the flow, but the remote
    tracks live on the signal client the flow owns, so a change there never reached the
    view. The signalling screen had the same code and worked, because it holds the
    clients itself and therefore observes them directly — which is what made the
    comparison misleading. Fixed by giving the video area its own view that observes
    the signal client. **Verified on the next real call**: the second tile drew a
    different person, in a different room, from a different camera angle, while the
    log showed 4.1 MB of inbound video.
12. **A stats line that only counted audio.** `media IN` reported the first inbound
    stat whose kind was `audio`, so a live video call logged a steady audio byte count
    and no video at all — indistinguishable from one that was receiving no picture.
    Every inbound kind is now reported. This one was caught only because the rendered
    screen disagreed with the log, and the screen was right to be trusted over it.
    On the next call the same line immediately answered the question it previously
    could not: 4.1 MB of inbound video, about 890 KB per three-second poll.
13. **An Xcode preview joined a real call.** A third participant appeared in a family
    call with a black camera, and the member on the other end saw someone "whose video
    keeps loading". It was this project's own `#Preview` of `ContentView`: rendering
    that view runs the whole session, so the preview authenticated through the Mac's
    Tailscale identity — the same person — concluded it was a participant in an active
    call, and joined it. A black camera follows naturally, because a preview has no
    real capture. Two lessons, both kept in the code: a preview of the root view is not
    a harmless mock when the root does network I/O, so previews belong on leaf views
    that take plain data; and **Family Call's identity is a person, not a device**, so
    "am I in a call?" answers identically for every client authenticating as that
    person, which is why resuming is now scoped to a call the device actually joined.
14. **The audio session was never configured, so there was no echo cancellation.** The
    session sat in `AVAudioSessionCategorySoloAmbient` with `AVAudioSessionModeDefault`
    — what an app is left with when it configures nothing. SoloAmbient is playback-only
    and `Default` mode engages no voice processing, so the voice-processing audio unit
    that cancels echo never ran; the result was echo loud enough that the microphone had
    to be muted to hold a conversation. **Every metric was healthy**: RTP byte counts,
    audio energy, CallKit's own state, all fine. It was found only by logging the
    session's category and mode after a report of echo, having already chased and
    dismissed a byte-count theory.
15. **A route override that needed a lock, whose failure was inaudible as an error.**
    The speaker toggle was written, compiled and shipped, and did nothing: audio stayed
    on the receiver. `RTCAudioSession.overrideOutputAudioPort` requires
    `lockForConfiguration` first — the same requirement `setConfiguration` was given and
    this was not — and the resulting error is invisible to anyone listening. The log
    line added for the previous defect named it verbatim on the first call. Also worth
    keeping: **CallKit owns the route once it activates the session and defaults a call
    to the receiver**, so the category's `defaultToSpeaker` option is not honoured and
    the route has to be overridden explicitly.
16. **An event stream that was never reconnected.** An incoming call never arrived: the
    PWA rang, the app stayed silent with its screen open on the contacts list. The
    stream had dropped — as it does every time iOS suspends the app — and nothing ever
    brought it back, so the phone was deaf until someone reloaded by hand. With no push in
    the app at all, that stream was the *only* path an incoming call could take.
17. **A gate that could never fire, because its screen was never mounted.** The
    signalling instrument's launch gates were correct and complete, and an unattended run
    still joined nothing: the probe screen sat behind a toolbar tap in the contacts
    list, so nothing presented it, and the log files still held the *previous* run's
    contents — which is very hard to tell from a run that produced nothing. The only tell
    was a timestamp. Fixed at the root rather than in the instrument, with
    `CROSSBAR_PROBE_AUTOSHOW=1` presenting the probe screen over whatever the product is
    showing. Same lesson as the rest of this list: a gate is only as good as the path that
    reaches it, and a stale file reads exactly like a silent failure.

## What the spike does not show

Stated so the next session does not inherit an overclaim:

- **The call lifecycle is verified for the paths a two-person call takes, and no
  further.** Placing, answering and ending are measured end to end against production
  with a real family member on MiroTalk's own browser client, carrying audio and video
  both ways with the remote video drawn on screen. The routes a two-person call never
  touches **remain unexercised**: `/join` (only used to rejoin an active call),
  `/invite`, a declined call, and the group route. Nothing beyond what these calls
  actually ran should be described as working.
- **The room-id parse is verified.** Production `joinUrl`s from two real calls each
  yielded their room and signalling origin, and the client joined those rooms. It is
  proven for the shape the service produces now, not for every shape it could produce.
- **The event stream is no longer the only way a call can arrive, and it is still one
  connection.** Drop it and the phone used to be deaf — that happened once, costing an
  incoming call that rang only on the PWA while Crossbar sat open on the contacts screen — and
  the client now reconnects with capped backoff and re-reads `/api/bootstrap` on every
  reconnect, because the stream carries no event ids and no replay. That is still a repair
  rather than a fix, and the fix now exists beside it: PushKit and APNs, with two tokens filed
  per device and the service dispatching a ring to a phone (2026-09-24). What that does
  **not** establish is delivery — the rings seen so far had the app open, so the socket may
  have carried them, and nothing has been seen arriving on a locked phone. See
  `NATIVE_PROGRESS.md`.
- **The product shell is thin.** Contacts, placing, answering, an in-call screen and
  CallKit now exist and have carried a real call, but there is no persistence, no call
  history, no settings, no audio-route selection and no call duration — and the
  multiparty path is unbuilt. The instruments remain where most of the measurement
  happened; the shell is what those measurements now support.
- **The signalling socket survives backgrounding *when the app is not suspended*, and that
  is a configuration, not a given.** Measured 2026-09-19: with audio actually running and
  the `audio` background mode declared, a backgrounded call kept its socket, its audio both
  ways and its place in the room for 100 s; with WebRTC's manual-audio gate left closed, the
  same app was frozen within seconds and lost everything. The `voip` mode the app declared
  was not enough on its own, because there was no audio running for a background mode to
  justify. What the app does on *resume* is still unbuilt: nothing reconnects a socket that
  was genuinely killed, and nothing re-acquires the camera or tells the peer that video
  stopped.
- **Video renders, but nothing about its quality is measured.** A remote track from
  MiroTalk's own browser client is decoded and drawn natively — verified by two
  visibly different scenes on screen at once, the phone's own camera beside the Mac's —
  so the transport, decode and render path is real. Frame rate, resolution, latency and
  recovery from packet loss are unmeasured, and no camera switching, orientation change
  or size negotiation has been exercised.
- **Four peers untested.** Three form a working mesh; four is the same mechanism, but
  unverified.
- **Interruption was not conclusively tested.** An alarm produced BEGAN/ENDED and moved
  the audio route, but never stopped the audio unit — so it was a notification without
  a teardown. A genuine session-deactivating interruption (a real incoming call) is not
  reproducible with the hardware available, since FaceTime between the Mac and the
  iPhone is blocked by the shared Apple ID. The closest available evidence is CallKit's
  own `didActivate`/`didDeactivate` cycle, which is measured.
- **Audio quality is unmeasured.** Bytes and energy say audio flows; nothing here says
  it sounds right.
- **The AGPL position is unresolved.** No MiroTalk source has been copied — this is
  original code written against the audit's specification — so the licensing gate has
  not been crossed, but it still precedes any reuse.

## Open decisions

1. **How the native client obtains the room id.** `callPublic` never exposes `roomId`;
   the only media coordinates are inside the `joinUrl`, and the `room` parameter is
   parseable from it. Decided and now implemented in `FamilyCallClient.JoinTarget`,
   which also takes the signalling origin from the same URL rather than from a second
   constant. Unverified against a live `joinUrl` — see above.
2. **APNs/PushKit and a device-token model.** **Settled 2026-09-24.** Background ringing for
   the PWA is W3C Web Push with `{endpoint, p256dh, auth}` credentials, a different class
   from APNs tokens, and at the spike there was no table, route or client for the latter.
   All three exist now: the service files a `voip` and an `alert` token per device
   (`POST /api/devices/push-token`), the app files both — holding a token PushKit announced
   before a load could file it — and a test call dispatched one (`phones: 1, dropped: 0`).
   Delivery to a *closed* app is still unmeasured.
3. **Per-participant leave.** The backend has none; `/end` is call-wide, which matters
   because multiparty is mandatory.
4. **The `iceServers` exposure.** Decided: consume them unchanged, accepting that a
   third-party STUN server observes each peer's reflexive address. See
   `CROSSBAR_ARCHITECTURE.md` for why filtering was rejected, and revisit if TURN is
   introduced.
5. **Two documentation defects** in the Family Call repository, reported and not fixed
   there: `deploy/map-session-identity.mjs` requires a `session.identity.login` field
   the API does not return, and `docs/MIROTALK_UI_INTEGRATION.md` describes a
   `postMessage` bridge that exists nowhere in its source.
