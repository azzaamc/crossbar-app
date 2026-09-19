import Foundation

/// The handful of things a person can change about this app.
///
/// Deliberately small, and deliberately not a "everything is configurable" surface: what
/// the app *does* is not a preference. What can move is its deployment — the address of the
/// service, since every household may run its own — plus two switches that exist because
/// they are the ones that unblock a device in the field: whether the app carries its own
/// tailnet, and whether to override the signalling address an invitation normally carries.
///
/// Read on the main actor in the UI, and off it everywhere else, so the readers here are
/// plain functions over `UserDefaults` rather than a published object: the node's carrier
/// check and the control plane both ask for the address from wherever they happen to be.
enum AppSettings {
    enum Key {
        static let serviceAddress = "crossbar.serviceAddress"
        static let signallingOrigin = "crossbar.signallingOrigin"
        static let embeddedNode = "crossbar.embeddedNode"
    }

    /// The service's address, when someone has set one.
    static var serviceAddress: String? {
        trimmed(UserDefaults.standard.string(forKey: Key.serviceAddress))
    }

    /// The signalling address, when someone has overridden it.
    ///
    /// Empty by default, and that is the correct default: the address arrives inside the
    /// call's own `joinUrl`, so the client and the backend cannot disagree about which host
    /// to dial. This exists for a deployment whose signalling host is not the one its
    /// invitations name.
    static var signallingOrigin: String? {
        trimmed(UserDefaults.standard.string(forKey: Key.signallingOrigin))
    }

    static var signallingOverrideURL: URL? {
        signallingOrigin.flatMap(URL.init(string:))
    }

    /// Whether the app carries its own tailnet. Off means it dials over whatever the system
    /// provides, which is the pre-node behaviour and needs the Tailscale app connected.
    static var usesEmbeddedNode: Bool {
        UserDefaults.standard.object(forKey: Key.embeddedNode) as? Bool ?? true
    }

    /// The tailnet's machine list, for inspecting or revoking this device.
    static let tailnetConsole = URL(string: "https://login.tailscale.com/admin/machines")!

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
