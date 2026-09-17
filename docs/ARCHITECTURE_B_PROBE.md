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
| `MiroTalkSignalClient.swift` | a reduced native Engine.IO v4 / Socket.IO v5 client, peer connections, and the shared media source | admission into a MiroTalk room, the mesh fan-out, SDP/ICE exchange, the offer policy, inbound RTP |
| `BackendReachabilityProbe.swift` | a bare `URLSession` GET | whether tailnet Serve injects the identity header for a non-browser client |

Each writes its output to a file in the app's Documents directory — `seam.log`,
`signal-A.log`, `signal-B.log`, `signal-C.log`, `backend.log` — truncated on the first
write of each launch. Screen-only output is not sufficient: it cost two measurements
before the files were added.

## Running it

Substitute the connected device's identifier, from `xcrun devicectl list devices`.

```bash
# build
xcodebuild -project Crossbar.xcodeproj -scheme Crossbar \
  -destination 'platform=iOS,id=<device-id>' -configuration Debug build

# install and launch (the Debug product path is under DerivedData)
xcrun devicectl device install app --device <device-id> "<path>/Crossbar.app"
xcrun devicectl device process launch --device <device-id> \
  --terminate-existing com.abdullahchaudhry.Crossbar

# pull a log
xcrun devicectl device copy from --device <device-id> \
  --domain-type appDataContainer \
  --domain-identifier com.abdullahchaudhry.Crossbar \
  --source Documents/signal-A.log --destination /tmp/signal-A.log

# screenshot, if a visual check is needed
xcrun devicectl device capture screenshot --device <device-id> --destination /tmp/s.png
```

Two operational facts that caused wasted runs:

- The Mac reaches the phone over the **network, not USB**. Turning the phone's Wi-Fi
  off also cuts `devicectl`, so a log cannot be pulled until it is back on. The log
  persists regardless.
- A suspended app's WebSocket **dies silently** — no close frame, no error. Leaving
  the app during a signalling test loses the call, and leaves nothing in the log to
  say so.

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

## What the spike does not show

Stated so the next session does not inherit an overclaim:

- **No product code.** Everything here is a measurement instrument. There is no call
  UI, no contacts, no CallKit-in-product-flow, no persistence.
- **The signalling socket does not survive backgrounding** — no background mode is
  configured. A call that outlives the screen needs one.
- **Video is negotiated but never rendered natively.** Frames are counted at the
  capture source and bytes are counted in RTP; nothing draws a remote video track.
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
   parseable from it. Decided: parse it. Not yet implemented.
2. **APNs/PushKit and a device-token model.** Background ringing is W3C Web Push with
   `{endpoint, p256dh, auth}` credentials; APNs tokens are a different class and no
   table, route or client exists.
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
