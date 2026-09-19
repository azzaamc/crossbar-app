import Foundation

/// How a client's sockets leave the device.
///
/// Two routes exist and only two. `.direct` dials the origin over whatever the system
/// already provides — which is how every measurement before the embedded node ran, and
/// which requires the Tailscale app's tunnel to be up and signed in. A transport built by
/// `TailnetNode` dials the node's SOCKS loopback instead, so the app carries its own
/// tailnet and needs no other app for it.
///
/// The **label travels with the configuration** rather than beside it, because a
/// node-carried session and a direct one are otherwise indistinguishable in a log:
/// `proxyVia` writes the proxy into the configuration and nothing reads it back out, so
/// the two are the same object shape. A run that silently took the system's route while
/// the screen said otherwise is exactly the failure this project keeps finding, and the
/// label is what makes it visible.
struct CallTransport {
    var configuration: URLSessionConfiguration = .default
    var label = "direct"

    /// The node loopback this dials, when it dials one. Carried separately from the label
    /// so an instrument can report the address it actually used, which is the thing that
    /// goes stale after a suspension.
    var loopbackAddress: String? = nil

    /// What a client uses when there is no node: the system's own route.
    static let direct = CallTransport()

    /// A session that leaves by this route. Callers hold one per client rather than one
    /// per request, so a stream keeps its connection.
    func session() -> URLSession {
        URLSession(configuration: configuration)
    }
}
