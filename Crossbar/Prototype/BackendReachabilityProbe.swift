#if DEBUG
import Combine
import Foundation
import SwiftUI

/// The load-bearing assumption of the entire native control plane: that a request
/// from a native client through tailnet Serve arrives carrying
/// `tailscale-user-login`.
///
/// Family Call accepts that header only when the request arrives from loopback
/// (`src/identity.js:19-22`) and its listener refuses to bind anywhere but
/// loopback (`src/config.js:59-62`). A native client therefore cannot supply an
/// identity itself: it must traverse Serve. If Serve does not inject the headers
/// for a non-browser client, a native app has no identity path at all and every
/// API call returns `401 TAILSCALE_IDENTITY_MISSING` — which would change the
/// shape of the control plane, not merely a detail of it.
///
/// One request answers it. This is a measurement instrument, not product code.
@MainActor
final class BackendReachabilityProbe: NSObject, ObservableObject {
    @Published private(set) var status = "Not checked"
    @Published private(set) var lines: [String] = []
    private var logHandle: FileHandle?

    /// The private tailnet endpoint, already recorded in the Family Call docs.
    /// Overridable for a different deployment without editing this file.
    private var sessionURL: URL {
        let override = ProcessInfo.processInfo.environment["CROSSBAR_BACKEND_URL"]
        let base = override.flatMap(URL.init(string:))
            ?? URL(string: "https://qatar-vpn.tailea67b0.ts.net:8443")!
        return base.appendingPathComponent("api/session")
    }

    func check() async {
        let url = sessionURL
        append("GET \(url.absoluteString)")
        status = "Requesting…"

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 15
        // Deliberately no Origin header. checkOrigin rejects only a present,
        // mismatched Origin (`src/server.js:97-105`), which is why a native HTTP
        // client is viable at all.

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            append("HTTP \(code)")

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                append("unparseable body (\(data.count) bytes)")
                status = "Unparseable response"
                return
            }

            let authenticated = json["authenticated"] as? Bool ?? false
            let configured = json["configured"] as? Bool ?? false
            append("authenticated=\(authenticated) configured=\(configured)")

            if let identity = json["identity"] as? [String: Any] {
                let source = identity["source"] as? String ?? "?"
                let name = identity["name"] as? String ?? "?"
                append("identity.source=\(source) name=\(name)")
            } else {
                append("identity=null")
            }

            if let user = json["user"] as? [String: Any] {
                append("user.displayName=\(user["displayName"] as? String ?? "?")")
            } else {
                append("user=null")
            }

            // This is the whole point of the probe.
            if authenticated {
                status = "Serve injects the identity header"
            } else if code == 200 {
                status = "Reached the service, but no identity headers"
            } else {
                status = "HTTP \(code)"
            }
        } catch {
            append("error: \(error.localizedDescription)")
            status = "Unreachable — is Tailscale connected on this device?"
        }
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        writeToLogFile(line)
    }

    /// Same reasoning as the seam probe's log: screen-only output has already cost
    /// measurements twice, so results also go to Documents/backend.log for pulling.
    private func writeToLogFile(_ line: String) {
        if logHandle == nil {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("backend.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
            logHandle?.truncateFile(atOffset: 0)
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        logHandle?.write(data)
    }
}

/// Collapsed by default so the seam measurements stay unobstructed.
struct BackendReachabilitySection: View {
    @StateObject private var probe = BackendReachabilityProbe()
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Backend reachability (service)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Button("Check /api/session") {
                    Task { await probe.check() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("backend.check")

                Text(probe.status)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(probe.lines.joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }
}
#endif
