# Crossbar development workflow

## Start in the correct directory

OMP may start in:

```text
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar
```

The actual Git worktree and Xcode project are:

```text
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar
/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar/Crossbar.xcodeproj
```

Run Git commands from the nested `Crossbar` directory. Do not initialize a new
repository or create/move the Xcode project.

## Preferred OMP/Xcode integration

Both the outer workspace and the tracked nested worktree contain
`.omp/mcp.json` with an MCP server named `xcode` backed by:

```text
xcrun mcpbridge
```

The user must enable:

```text
Xcode -> Settings -> Intelligence -> Model Context Protocol
      -> Allow external agents to use Xcode tools
```

Keep `Crossbar.xcodeproj` open in Xcode while OMP uses the bridge. On every new
OMP session, discover the tools exposed by the `xcode` MCP server. Do not
hard-code tool names or assume that a prior tool catalog is unchanged.

Prefer Xcode MCP for:

- inspecting the open project, schemes, targets, and build settings;
- reading compiler diagnostics;
- Debug/Release builds;
- unit and UI tests;
- simulator boot/install/launch and semantic UI inspection;
- previews when exposed;
- connected-device build/install/launch and device logs when exposed.

Shell `xcodebuild` is a fallback only when the MCP cannot perform the operation.
Do not mix two build-control mechanisms casually; record which one produced
each result.

The Codex handoff used the official XcodeBuildMCP CLI rather than raw
`xcodebuild`, `xcrun`, or `simctl`. OMP is expected to use Apple's Xcode MCP
bridge first, but the CLI commands below are reproducible fallbacks.

## Current project facts

- Xcode 27.0 (`27A266a`) was installed at handoff.
- Scheme: `Crossbar`.
- No `.xcscheme` file is tracked in this repository, and
  `Crossbar.xcodeproj/xcshareddata/` contains no schemes. The scheme exists
  only inside the running Xcode instance; `xcodebuild -scheme Crossbar` and the
  `xcodebuildmcp` CLI both resolve it because Xcode auto-creates it, and that
  was verified on 2026-09-17, but a clean checkout does not carry it. The only
  scheme-related tracked artifact is
  `xcuserdata/azzaam.xcuserdatad/xcschemes/xcschememanagement.plist`.
- Targets: `Crossbar`, `CrossbarTests`, `CrossbarUITests`.
- Bundle ID: `com.abdullahchaudhry.Crossbar`.
- Minimum target: iOS 27.0.
- Signing: automatic; a Personal Team/development team is selected.
- No entitlements/capabilities/packages/third-party frameworks.
- Camera/microphone purpose strings are generated from build settings.

Do not document or commit certificates, provisioning profiles, signing keys, or
account credentials.

## Simulator procedure

With Xcode MCP:

1. Discover available projects/schemes/simulators.
2. Select `Crossbar.xcodeproj`, scheme `Crossbar`, and an installed iOS 27.0
   simulator.
3. Build Debug.
4. Build Release when changing conditional probe/build configuration behavior.
5. Build-and-run Debug for UI/manual probe work.
6. Wait for the status value `Runtime ready`; element existence alone is not
   sufficient because it first reads `Loading runtime…`.
7. Run tests and record individual pass/failure output.

Fallback commands used at handoff:

```sh
cd '/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar'

xcodebuildmcp simulator list-schemes \
  --project-path Crossbar.xcodeproj

xcodebuildmcp simulator list

xcodebuildmcp simulator build \
  --project-path Crossbar.xcodeproj \
  --scheme Crossbar \
  --simulator-id <SIMULATOR_UDID>

xcodebuildmcp simulator build \
  --project-path Crossbar.xcodeproj \
  --scheme Crossbar \
  --configuration Release \
  --simulator-id <SIMULATOR_UDID>

xcodebuildmcp simulator build-and-run \
  --project-path Crossbar.xcodeproj \
  --scheme Crossbar \
  --simulator-id <SIMULATOR_UDID>

xcodebuildmcp simulator test \
  --project-path Crossbar.xcodeproj \
  --scheme Crossbar \
  --simulator-id <SIMULATOR_UDID>
```

At handoff, an `iPhone 18 Pro` simulator on iOS 27.0 was used. Discover the
current UDID instead of persisting machine-specific simulator IDs in project
configuration.

### Known UI-test synchronization issue

`CrossbarUITests.testExample` waits for `probe.status` to exist and then asserts
that its label is `Runtime ready`. The element exists immediately with
`Loading runtime…`, so the test is timing-dependent. The 2026-09-17 handoff run
reported 2 passed and 1 failed for this reason. Use a predicate/value wait for
manual verification and do not claim the full suite is stable until the test is
corrected in an explicitly scoped change.

## Personal physical iPhone procedure

The next architecture experiment should run on a personal iPhone, not infer
CallKit behavior from the simulator.

1. Connect/unlock the iPhone and accept the computer trust prompt if needed.
2. Enable Developer Mode on the device if iOS requests it.
3. Open `Crossbar.xcodeproj` in Xcode.
4. In Signing & Capabilities, confirm automatic signing uses the user's Personal
   Team. Do not alter the bundle ID merely to silence an unexplained signing
   error without recording why.
5. Select the physical device.
6. Use the Xcode MCP device workflow to build/install/launch when exposed;
   otherwise use Xcode's Run action. Discover the device dynamically rather
   than checking a UDID into source/docs.
7. On first launch, exercise `Run media only` and explicitly record the native
   camera/microphone prompts, preview, physical front/rear switch, mute/camera
   controls, and capture-indicator teardown.
8. Then separately exercise `Start probe` and `Simulate incoming`, recording
   CallKit callbacks and `didActivate`/`didDeactivate` behavior.
9. Test receiver/speaker, wired/Bluetooth if available, interruption,
   background, lock, and foreground/resume.
10. Stop if behavior is ambiguous; preserve logs/results without adding
    MiroTalk/backend/APNs code during this experiment.

At the handoff audit a personal iPhone was visible to Xcode, but it was not used
for a probe run. Do not convert visibility into a “tested” claim.

## Tailscale requirements

The current local-media probe does not contact Family Call or MiroTalk, so
Tailscale is not required to run it.

When native backend/signaling work is explicitly authorized later:

- the iPhone and Mac must be connected to the correct private tailnet;
- use the existing tailnet-only Family Call/MiroTalk HTTPS endpoints described
  in the separate Family Call repository;
- do not print or hard-code private URLs in product UI;
- never enable Funnel, public ports, LAN binds, or third-party TURN;
- verify identity/session behavior through the actual native request path;
- keep production read-only unless a separate exact change is approved.

## Test-result recording

For every experiment record:

- date and environment (simulator/device model and OS);
- commit/tag;
- exact action;
- expected behavior;
- actual behavior;
- evidence location/result summary;
- conclusion and what remains unproven.

“Compiled,” “simulator tested,” and “physical-device tested” are separate
statuses. A green generated test with no assertions is not behavioral evidence.

## Git hygiene

Before a commit:

```sh
git status --short --branch
git diff --check
git diff --cached --check
git diff
git diff --cached
```

Do not commit DerivedData, `.xcresult` bundles, `.DS_Store`, user interface
state, secrets, signing credentials, runtime databases, or logs containing
private endpoints/tokens. The repository contains two already-tracked
user-specific files from the probe checkpoint:
`Crossbar.xcodeproj/project.xcworkspace/xcuserdata/azzaam.xcuserdatad/WorkspaceSettings.xcsettings`
and
`Crossbar.xcodeproj/xcuserdata/azzaam.xcuserdatad/xcschemes/xcschememanagement.plist`.
Do not treat them as a reason to commit additional `xcuserdata`.
