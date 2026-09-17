# OMP context for Crossbar

This is Crossbar, the planned native iOS client for the private Family Call
platform.

OMP may be launched from `/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar`, but
the actual Git worktree and Xcode project are nested at
`/Users/azzaam/Desktop/MASTER/PERSONAL/crossbar/Crossbar`. Do not create another
repository/project or move either one.

Read in this order:

1. current source and executable tests;
2. Git history/tags;
3. `docs/NATIVE_PROGRESS.md`;
4. `docs/ARCHITECTURE_A_PROBE.md`;
5. `docs/MIROTALK_CORE_AUDIT.md`;
6. `docs/OMP_HANDOFF.md`;
7. `docs/DEVELOPMENT_WORKFLOW.md`;
8. `docs/CROSSBAR_ARCHITECTURE.md`;
9. root `AGENTS.md` and `.omp/RULES.md` for standing constraints.

The backend/PWA source of truth is the separate repository at
`/Users/azzaam/Documents/ChatGPT/Family Call (MiroTalk)`. Read its `AGENTS.md`
and handoff documents before changing an integration contract.

Architecture A is the leading but uncommitted direction: native SwiftUI,
CallKit, and product state around the smallest media-only WKWebView runtime that
can reuse MiroTalk's proven WebRTC core. The existing `Crossbar/Prototype/`
code is an original DEBUG-only local-media/bridge probe. It is not MiroTalk
integration and must not be described as an actual call engine.

Use the configured `xcode` MCP server backed by `xcrun mcpbridge` when
available. Discover its tools dynamically. Keep the Crossbar project open in
Xcode. Do not assume exact MCP tool names.
