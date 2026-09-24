import Foundation

/// How this app reaches its service — a decision, not a detail.
///
/// Crossbar is deployed two ways and they are not two addresses for one thing. A server on a
/// private network is reachable only over the tailnet, and this app carries that network
/// itself so that a device needs nothing else installed. A public server answers at a
/// hostname on the internet and is reached the ordinary way. Which one this device belongs
/// to decides whether a node is brought up at all, whether requests leave through it, and
/// whether a sign-in page can ever be offered — so it is stored when someone chooses it,
/// and never inferred.
///
/// Inferred from what, exactly? Nothing observable says it. A `*.ts.net` name is one
/// private deployment, but a public server may sit on a tailnet too, and an address that
/// answers proves something is reachable rather than which network carried it. A node that
/// is up but not yet authorised answers every request with a refusal that looks exactly
/// like a broken server. Guessing one way puts a second network on a device that never
/// asked for one; guessing the other leaves someone unable to reach their service with no
/// sign-in page to fix it. So the onboarding screen asks, once, in plain words, and this is
/// what it writes down.
enum ConnectionMode: String, CaseIterable {
    /// A server on a network the app carries itself.
    case privateNetwork

    /// A Crossbar server at a hostname, reached the ordinary way.
    case publicServer

    /// The mode a code names, as this app's own.
    ///
    /// The service spells these `private` and `public` — what it trusts — and the app spells
    /// them for the screen that explains them. One place, so the two cannot drift apart.
    static func named(by value: String?) -> ConnectionMode? {
        switch value?.lowercased() {
        case "private": return .privateNetwork
        case "public": return .publicServer
        default: return nil
        }
    }

    /// What this mode is called where somebody chooses between them.
    var title: String {
        switch self {
        case .privateNetwork: return "Private network (Tailscale)"
        case .publicServer: return "Public internet (HTTPS)"
        }
    }

    /// The same thing again as a sentence, for the screen that shows what is in force.
    ///
    /// Both say what the server is reached *over* and nothing else. The mechanism is the whole
    /// of what the difference means to somebody choosing between them — which network carries
    /// the request, and what protects it on the way — and anything more is a description of the
    /// deployment's paperwork rather than of the choice.
    var summary: String {
        switch self {
        case .privateNetwork:
            return "The server is reached over a private Tailscale network (a tailnet), carried "
                 + "by the official Tailscale framework embedded in this app."
        case .publicServer:
            return "The server is reached over the public internet, using HTTPS encryption."
        }
    }
}
