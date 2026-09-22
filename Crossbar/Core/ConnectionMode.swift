import Foundation

/// How this app reaches its service — a decision, not a detail.
///
/// Crossbar is deployed two ways and they are not two addresses for one thing. A private
/// household server is reachable only over the tailnet, and this app carries that network
/// itself so that a device needs nothing else installed. A public server answers at a
/// hostname on the internet and is reached the ordinary way. Which one this device belongs
/// to decides whether a node is brought up at all, whether requests leave through it, and
/// whether a sign-in page can ever be offered — so it is stored when someone chooses it,
/// and never inferred.
///
/// Inferred from what, exactly? Nothing observable says it. A `*.ts.net` name is one
/// household's private deployment, but a public server may sit on a tailnet too, and an
/// address that answers proves something is reachable rather than which network carried
/// it. A node that is up but not yet authorised answers every request with a refusal that
/// looks exactly like a broken server. Guessing one way puts a second network on a device
/// that never asked for one; guessing the other leaves someone unable to reach their
/// service with no sign-in page to fix it. So the onboarding screen asks, once, in plain
/// words, and this is what it writes down.
enum ConnectionMode: String, CaseIterable {
    /// This household runs its own network, and the app carries it.
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

    /// What this mode is called on screen. One spelling, because two screens name it.
    var title: String {
        switch self {
        case .privateNetwork: return "This household's own network"
        case .publicServer: return "A Crossbar server"
        }
    }

    /// The same thing again as a sentence, for the screen that shows what is in force.
    var summary: String {
        switch self {
        case .privateNetwork:
            return "Reached over your household's private network, which this app carries "
                 + "with it so that nothing else has to be installed."
        case .publicServer:
            return "Reached at a server address, the ordinary way. This app carries no "
                 + "network of its own in this mode."
        }
    }
}
