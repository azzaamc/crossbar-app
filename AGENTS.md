# Crossbar project instructions

## Scope and repository layout

Crossbar is the native iOS client for the private Family Call platform. The
directory the user calls the repository root is:

`/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar`

The existing Git worktree and Xcode project are both nested one level below:

`/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar`

This layout is intentional for now. Do not initialize another repository, move
the `.git` directory, or create/relocate an Xcode project merely to make the
paths look cleaner.

## Read first

Before changing architecture or call behavior, read:

1. current source and executable tests;
2. Git history and tags;
3. `docs/NATIVE_PROGRESS.md`;
4. `docs/ARCHITECTURE_A_PROBE.md`;
5. `docs/MIROTALK_CORE_AUDIT.md`;
6. `docs/OMP_HANDOFF.md`;
7. `docs/DEVELOPMENT_WORKFLOW.md`;
8. `docs/CROSSBAR_ARCHITECTURE.md`.

The separate Family Call repository remains authoritative for PWA behavior:

`/Users/azzaam/Documents/ChatGPT/Family Call (MiroTalk)`

Read its `AGENTS.md`, `docs/CURRENT_SYSTEM.md`, `docs/PWA_HANDOFF.md`,
`docs/MIROTALK_INTEGRATION.md`, and `docs/CROSSBAR_BRIEF.md` before changing the
integration contract. Source wins when its documents disagree.

## Product boundary

Crossbar should feel like a normal private family calling app. Product concepts
are people, Call, Answer, Decline, Add Person, and End. Room identifiers,
MiroTalk, WebRTC, ICE, SDP, signaling, meeting terminology, URLs, and Tailscale
addresses are implementation details and must not leak into the product UI.

Family Call owns identity, contacts, groups, presence, call IDs, private room
IDs, invitations, lifecycle, ringing, and missed calls; the native push
registration contract is the Crossbar server's (`server/`,
`POST /api/devices/push-token`). Crossbar must consume that backend rather than
recreate its responsibilities.

MiroTalk P2P owns the currently proven browser WebRTC/signaling behavior.
Architecture A is the leading investigation: SwiftUI and CallKit around a
minimal media-only WKWebView runtime derived from the smallest legally approved
MiroTalk core. It is provisional, not a final decision.

## Current native state

The code under `Crossbar/Prototype/` is a DEBUG-only, original-code feasibility
probe. It validates a local bundled WKWebView runtime, `getUserMedia`, a narrow
Swift/JavaScript bridge, media controls, and teardown in the simulator. It does
not contain MiroTalk source, Socket.IO, `RTCPeerConnection`, remote media, or
backend integration. It has not completed the physical-device CallKit/audio/
background gate. Do not promote its diagnostic UI into the product UI.

CallKit is a native concern. PushKit/APNs is implemented: the app files two push
tokens per device — the VoIP token a ringing call arrives on and an alert token
for a call it missed — and the built app carries `aps-environment =
development`. A ring arriving on a closed app has not been observed yet.

## Production safety

- Never modify or restart production `qatar-vpn` services without explicit
  approval for that exact production operation.
- Never enable Tailscale Funnel, public port forwarding, public/LAN listeners,
  or third-party TURN by convenience.
- Production MiroTalk and Family Call must remain loopback-bound behind private
  Tailscale Serve.
- Never run `tailscale serve reset`.
- Do not break the existing Family Call PWA while developing Crossbar.
- Treat server `.env` values, MiroTalk API secrets, push endpoints/keys,
  Tailscale credentials, tokens, runtime data, and backups as secrets.

## Licensing and provenance

MiroTalk P2P is AGPLv3. No MiroTalk implementation code has been copied into
Crossbar as of the handoff checkpoint. Do not add extracted/adapted MiroTalk
code until the distribution/licensing decision is explicit. If approved,
preserve upstream URL, exact commit, original paths/functions, notices, license,
local changes, and corresponding-source obligations. Do not copy the whole
MiroTalk repository.

## Development and verification

Prefer the configured Xcode MCP bridge for project inspection, builds, tests,
simulator work, diagnostics, and device workflows. Discover its available tools
instead of assuming names. Keep Xcode open with this project loaded. Shell
`xcodebuild` is a fallback only when MCP cannot perform the operation.

Never claim simulator behavior proves physical camera/microphone prompts,
CallKit, AVAudioSession routing, lock/background continuity, or PushKit. Record
the environment and actual evidence for every experiment.

Keep changes focused and reversible. Review status/diff before committing. Do
not commit DerivedData, result bundles, secrets, runtime databases, or signing
credentials.
