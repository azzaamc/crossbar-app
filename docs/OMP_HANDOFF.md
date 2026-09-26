# Codex to OMP handoff

Handoff date: 2026-09-17

## Repository

The user-designated workspace root is:

```text
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar
```

That directory is not a Git repository. The existing Git worktree and Xcode
project are nested at:

```text
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar/Crossbar.xcodeproj
```

Do not initialize another repository, move `.git`, or recreate/relocate the
project.

- Branch this handoff was written on: `codex/architecture-a-spike`, which is
  **not** the current branch. The repository now also carries `architecture-b`
  (the architecture B spike, from `main`) and `tailscale-kit` (the embedded
  Tailscale node, cut from `architecture-b` at `7462de8`). Read
  `docs/ARCHITECTURE_B_PROBE.md` for what the B spike is made of and
  `docs/TAILSCALE_KIT_PROBE.md` for the node; this document describes the
  repository, the product and the production service, which have not moved.
- Initial scaffold: `f15031f` (`Initial Commit`).
- Probe checkpoint: `8c543e0` (`checkpoint: Architecture A iOS WebRTC probe`).
- Existing tag `codex-handoff` points to the probe checkpoint and must not be
  overwritten.
- Final documentation checkpoint/tag: inspect `git log` and the dated
  `codex-handoff-2026-09-17` tag created for this handoff.

## Product

Crossbar is intended to be a very simple private native family-calling app for
one-to-one and small two-to-four-person calls. Product vocabulary is people,
Call, Answer, Decline, Add Person, and End. Meeting IDs, rooms, URLs, MiroTalk,
WebRTC, SDP, ICE, signaling, and Tailscale addresses remain hidden
implementation details.

## Current system architecture

### Family Call backend/PWA

Separate repository:

```text
/Users/azzaam/Documents/ChatGPT/Family Call (MiroTalk)
```

Family Call owns identity, contact/group directory, presence, application call
IDs, private MiroTalk room IDs, invitations, ringing/lifecycle, Web Push, and
the custom PWA. Its backend is the authority Crossbar will consume.

Last deployment verification in the Family Call documents was 2026-09-16:

- source/deployment path on `qatar-vpn`: `/home/admin/family-call`;
- deployed commit: `e2b053d`;
- listener: `127.0.0.1:3001`;
- private Tailscale Serve route: HTTPS 8443;
- local documentation repository commit: `e861585` plus uncommitted Crossbar
  audit documents at handoff time.

### Production MiroTalk

MiroTalk P2P owns the currently proven browser capture, Socket.IO signaling,
peer connections, SDP, ICE, tracks, and multiparty mesh. Production is a
separate AGPLv3 service on `qatar-vpn`, loopback-bound behind private Tailscale
Serve. Do not modify it during ordinary Crossbar development.

Last documented production state (verified 2026-09-16):

- path `/home/admin/mirotalk`;
- MiroTalk 1.9.64 at upstream commit `5af51e0c...`;
- listener `127.0.0.1:3000`;
- private Tailscale Serve route HTTPS 443;
- intentional local loopback-bind source change plus untracked backups that
  must not be reset/cleaned/staged;
- STUN and TURN disabled in the effective ICE list — **corrected 2026-09-17: a
  native client's `addPeer` payloads carried
  `"iceServers":[{"urls":"stun:stun.l.google.com:19302"}]`, so the deployed
  server does hand out Google's public STUN. This bullet is not current. See
  `CROSSBAR_ARCHITECTURE.md`, "Native signalling executed".**
- no Funnel/public/LAN application listener.

The inactive `/home/admin/mirotalk-family` experiment, port 3002, and the
removed 8444 route are not production and must not be reactivated implicitly.

### Native Crossbar

Crossbar currently has only a DEBUG Architecture A feasibility probe. It does
not contact either service.

### Architecture A (leading, not final)

```text
SwiftUI product shell and CallKit
  -> typed native/JavaScript bridge
  -> minimal media-only WKWebView runtime
  -> smallest approved MiroTalk WebRTC core
  -> existing MiroTalk signaling
```

Architecture B (native WebRTC plus native Socket.IO) is a fallback only if
physical-device evidence shows WebKit cannot meet CallKit/audio/background
requirements. Do not choose B merely because native code looks cleaner.

## What works today

Verified in the iOS 27.0 simulator:

- Debug and Release builds compile.
- Bundled `RuntimeProbe.html` loads in `WKWebView`.
- JavaScript emits `runtimeReady` to Swift.
- The original probe acquires simulator audio/video and displays the synthetic
  local camera feed.
- Swift commands reach JavaScript for mute, camera enable/disable, camera
  switch, and leave.
- Events return to Swift.
- Local track teardown returns the probe to `Call ended`.

The 2026-09-17 full test run reported 2 passed and 1 timing-dependent UI-test
failure. See `NATIVE_PROGRESS.md`; do not summarize the suite as green.

## What is being investigated

Whether a WebKit-owned media call can be reliable while native CallKit and
AVAudioSession own iOS call presentation, activation, routing, interruptions,
background/lock, and resume behavior.

No MiroTalk code has been copied. The next extraction/signaling step is gated by
physical-device results and AGPL licensing disposition.

## Current file map

- `AGENTS.md`: durable project context and safety boundaries.
- `.omp/AGENTS.md`: concise OMP startup routing.
- `.omp/RULES.md`: non-negotiable rules.
- `.omp/mcp.json`: tracked Xcode MCP bridge configuration.
- `docs/NATIVE_PROGRESS.md`: exact project state and evidence matrix.
- `docs/ARCHITECTURE_A_PROBE.md`: probe implementation/results/unknowns.
- `docs/MIROTALK_CORE_AUDIT.md`: audited MiroTalk engine and signaling map.
- `docs/CROSSBAR_ARCHITECTURE.md`: provisional A/B design and decision gate.
- `docs/DEVELOPMENT_WORKFLOW.md`: Xcode MCP, simulator/device, and Git workflow.
- `Crossbar/CrossbarApp.swift`: generated SwiftUI entry.
- `Crossbar/ContentView.swift`: DEBUG probe UI / Release placeholder.
- `Crossbar/Prototype/CallKitManager.swift`: native CallKit/AVAudioSession probe.
- `Crossbar/Prototype/CallProbeModel.swift`: diagnostic coordinator.
- `Crossbar/Prototype/WebMediaEngine.swift`: WKWebView and bridge.
- `Crossbar/Prototype/RuntimeProbe.html`: original local-media JavaScript.
- `CrossbarTests/`: generated no-op unit test.
- `CrossbarUITests/`: ready-state and launch-performance tests.

## Native build/run and tests

Read `DEVELOPMENT_WORKFLOW.md`. Preferred flow:

1. open `Crossbar.xcodeproj` in Xcode;
2. enable Xcode's external-agent Model Context Protocol setting;
3. discover the `xcode` MCP server's current tools;
4. use MCP for scheme/settings/build/test/simulator/device workflows;
5. treat raw shell `xcodebuild` as fallback only.

Current scheme: `Crossbar`. Current targets: `Crossbar`, `CrossbarTests`, and
`CrossbarUITests`. Automatic signing is configured; no entitlements,
capabilities, packages, or third-party frameworks are configured.

The local probe needs no Tailscale connection. Future backend/signaling tests
do require the private tailnet — **but not necessarily the Tailscale app**: on
branch `tailscale-kit` the app embeds its own userspace node, and a two-peer
call's signalling runs through it with the system client disconnected, at the
same service and the same identity. Its limits are measured there too: the node
carries signalling only, since it has no interface for WebRTC to gather
candidates on, and its cached loopback cannot be trusted after a suspension.

## CallKit and PushKit status

CallKit exists only as DEBUG probe code:

- `CXProvider` and `CXCallController`;
- outgoing transaction;
- synthetic incoming report;
- start/answer/end/mute delegates;
- audio activation/deactivation callback surface;
- `.playAndRecord` / `.videoChat` preparation.

> Superseded 2026-09-17. The `.playAndRecord` / `.videoChat` preparation was
> removed in probe experiment P8.13, and this CallKit code has since been
> validated on a physical iPhone. See `docs/ARCHITECTURE_A_PROBE.md`
> P8.7–P8.14. This section records the state at handoff and is kept as history.

The simulator rejected the outgoing transaction, so at handoff none of this was
physically validated. That rejection is now explained rather than mysterious:
error 1 is `CXErrorCodeRequestTransactionErrorUnentitled`, caused by the missing
`UIBackgroundModes = [voip]` declaration (P8.7). The `Simulate incoming` DEBUG button and
`-CrossbarSimulateIncomingCall` launch argument both call the real probe
`CallKitManager`; neither is a remote notification.

PushKit/APNs does not exist: no code, entitlement, capability, token storage,
backend route, credential, or remote ringing. It is a later paid-developer
phase and must not block the physical-device local probe.

> Superseded 2026-09-24. PushKit and APNs exist now, in the product rather than in a probe:
> the app starts the PushKit registry at launch and files two tokens per phone with the
> service — `kind: "voip"`, which rings it, and `kind: "alert"`, which carries a call it
> missed — and the service has the route and the columns for them. The entitlement was never
> the problem: the built app carries `aps-environment = development`, and the server reports
> `APNs configured (com.abdullahchaudhry.Crossbar)`. Two details are worth carrying forward.
> PushKit announces a token *before any load runs*, so an app that cannot file it then has to
> hold it until a load has settled rather than drop it; and delivery to a **closed** app is
> still unmeasured, because the rings seen so far all had the app open. The paid membership
> remains what shipping to anyone else needs. See `NATIVE_PROGRESS.md`, "The device enrolled
> later that day".

## Known issues

1. `CrossbarUITests.testExample` is racy: it waits for status-element existence,
   not for its value to become `Runtime ready`.
2. The unit test is a generated no-op.
3. The iOS 27.0 deployment target is not yet a product decision.
4. Two user-specific files remain tracked from the probe checkpoint:
   `Crossbar.xcodeproj/project.xcworkspace/xcuserdata/azzaam.xcuserdatad/WorkspaceSettings.xcsettings`
   and
   `Crossbar.xcodeproj/xcuserdata/azzaam.xcuserdatad/xcschemes/xcschememanagement.plist`.
   `.gitignore` now blocks new `xcuserdata`, but gitignore cannot untrack
   existing entries, and neither file was removed during handoff. Earlier
   revisions of this document under-counted them as one.
5. The outer user-designated root is not the Git root. Canonical docs/rules are
   tracked in the nested worktree; outer entry files are present but untracked
   by design of the existing layout.
6. The probe bridge is unversioned/fire-and-forget and trusts the fixed local
   page's capture requests. It is diagnostic, not production hardening.

## Source/documentation discrepancies resolved by this handoff

- The user-designated `/crossbar` root is not the Git root; the actual worktree
  is `/crossbar/Crossbar`. The layout was documented, not moved.
- Before this handoff the Crossbar Git repository had no `docs/`, `AGENTS.md`,
  `.gitignore`, or tracked `.omp/` context even though the separate Family Call
  repository contained two untracked native audit documents.
- The earlier architecture narrative said no physical iPhone was connected at
  the 2026-09-16 probe. On 2026-09-17 a physical iPhone was visible to Xcode,
  but it remained untested; both facts are now dated explicitly.
- A prior test run reported 3/3 passing. Fresh handoff verification produced
  2/3 because the ready-state UI test races the asynchronous bridge. The source
  and latest execution result take precedence over a generic “tests pass”
  statement.
- Conversational summaries described the probe as testing Architecture A or
  MiroTalk feasibility broadly. The source proves a narrower result: local
  `getUserMedia`, preview, controls, teardown, and the native/JS bridge only.
  There is no MiroTalk signaling or peer connection in Crossbar today.
- The `codex-handoff` tag already existed on the probe checkpoint before the
  documentation handoff. It was preserved; a dated tag is used for the final
  documentation checkpoint.

## Architectural constraints

- Preserve one-to-one and two-to-four-person multiparty calling.
- Adding C uses the existing room and extends the mesh.
- Keep Family Call authoritative for product state.
- Do not expose the MiroTalk API secret to Crossbar.
- Keep remote media in a minimal WebKit surface under Architecture A; do not
  build a native frame bridge casually.
- Keep backend, CallKit, and media states separate.
- Do not add SwiftData without a concrete local persistence need.
- Use Keychain only for real secrets/tokens and UserDefaults only for
  lightweight preferences.
- No public services, analytics, trackers, Sentry, advertising, or automatic
  third-party TURN.

## Do-not-break list

- Existing Family Call PWA behavior and API routes.
- Production loopback binds and tailnet-only Serve ingress.
- Existing MiroTalk 443 route and Family Call 8443 route.
- Production MiroTalk worktree's deliberate local bind change/backups.
- Opaque application call ID vs private room ID separation.
- Same-room multiparty invitation behavior.
- AGPLv3 notices/provenance and licensing gate.
- DEBUG-only nature of the current probe UI.

## Recommended first OMP task

Do not implement product features. Run the unchanged probe on the connected
personal iPhone and create a results-only update to
`docs/ARCHITECTURE_A_PROBE.md`:

1. verify physical camera/microphone prompts and local preview;
2. verify front/rear switch and teardown/capture indicator;
3. exercise outgoing and simulated incoming CallKit actions;
4. record `didActivate`/`didDeactivate` and whether WebKit capture/audio obeys
   the native call session;
5. test speaker/receiver and available wired/Bluetooth routes;
6. test interruption, lock, background, foreground, and resume.

Do not add MiroTalk, backend, APNs, or product UI during that experiment. Fixing
the racy UI-test wait is a separate, small test-maintenance task.

## Longer-term roadmap

1. Physical-device Architecture A gate.
2. Licensing/distribution decision for MiroTalk-derived code.
3. Isolated—not production—minimal MiroTalk runtime/signaling integration.
4. Two-device Crossbar/PWA interoperability test.
5. Three-person same-room mesh test, then four-person performance test.
6. Final Architecture A/B checkpoint.
7. Native Family Call API/SSE models and simple product UI.
8. Backend additive changes only where proven necessary.
9. PushKit/APNs after Apple Developer Program capability is available.

## Production safety reminder

No production service, source, route, listener, firewall, Tailscale setting, or
runtime data was modified for the probe or this handoff. Keep it that way unless
the user separately approves an exact production change.
