# Crossbar non-negotiable rules

- Never expose or commit secrets.
- Never modify production `qatar-vpn` without explicit approval.
- Never expose private services publicly or enable Tailscale Funnel.
- Never break the existing Family Call PWA.
- Do not recreate, relocate, or duplicate the Xcode project or Git repository.
- Do not replace Architecture A until evidence justifies that decision.
- Do not rewrite WebRTC merely because native code feels cleaner.
- Preserve one-to-one and two-to-four-person multiparty calling.
- Preserve MiroTalk AGPLv3 license notices and exact upstream provenance.
- Never claim a test passed unless it was actually executed in the stated environment.
- Keep changes reversible through focused Git commits.
- Prefer isolated experiments over broad rewrites.
- PushKit/APNs is later; do not block the current device probe on it.
