import Foundation

/// The handful of things a person can change about this app.
///
/// Deliberately small, and deliberately not a "everything is configurable" surface: what
/// the app *does* is not a preference. What can move is its deployment — which of the two
/// Crossbar deployments this device belongs to, and the address of the service — plus two
/// switches that exist because they are the ones that unblock a device in the field:
/// whether the app carries its own tailnet, and whether to override the signalling address
/// an invitation normally carries.
///
/// Read on the main actor in the UI, and off it everywhere else, so the readers here are
/// plain functions over `UserDefaults` rather than a published object: the node's carrier
/// check and the control plane both ask for the address from wherever they happen to be.
enum AppSettings {
    enum Key {
        static let serviceAddress = "crossbar.serviceAddress"
        static let signallingOrigin = "crossbar.signallingOrigin"
        static let embeddedNode = "crossbar.embeddedNode"
        static let connectionMode = "crossbar.connectionMode"

        /// The rest are not defaults but keychain accounts, all under the one service:
        /// this device's signing key and handle, the id and name the service issued for
        /// it, and the session that key buys. Named here for the same reason the defaults
        /// are — one place, so a reader and a writer cannot disagree about the name.
        static let deviceService = "crossbar.device"
        static let deviceSigningKey = "crossbar.device.signingKey"
        static let deviceSigningKeyHandle = "crossbar.device.signingKeyHandle"
        static let deviceID = "crossbar.device.deviceId"
        static let deviceName = "crossbar.device.deviceName"
        static let deviceSessionToken = "crossbar.device.sessionToken"
        static let deviceSessionIssuedAt = "crossbar.device.sessionIssuedAt"
        static let deviceSessionExpiresAt = "crossbar.device.sessionExpiresAt"
    }

    /// The service's address, when someone has set one.
    ///
    /// Writable because an enrolment code carries the address of the service it enrols
    /// with: the code is what points the app at its own backend, and having someone type
    /// the same host a second time is how the two end up disagreeing.
    static var serviceAddress: String? {
        get { trimmed(UserDefaults.standard.string(forKey: Key.serviceAddress)) }
        set {
            guard let address = trimmed(newValue) else {
                UserDefaults.standard.removeObject(forKey: Key.serviceAddress)
                return
            }
            UserDefaults.standard.set(address, forKey: Key.serviceAddress)
        }
    }

    /// How this app reaches its service, when someone has chosen.
    ///
    /// Absent means *not chosen yet*, which is a state of its own rather than a default
    /// that happens to equal one: the onboarding screen exists for it, and folding it into
    /// a fallback would decide on someone's behalf which deployment they are in. See
    /// `ConnectionMode` for why this is stored rather than worked out from the address.
    static var connectionMode: ConnectionMode? {
        get {
            UserDefaults.standard.string(forKey: Key.connectionMode)
                .flatMap(ConnectionMode.init(rawValue:))
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: Key.connectionMode)
                return
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.connectionMode)
        }
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

    /// Whether the app carries its own tailnet, within the private mode.
    ///
    /// Only a private deployment has a network for the app to carry, so this is a
    /// preference inside that mode rather than the thing that decides it — see
    /// `ConnectionMode`. Off means dialling over whatever the system provides, which is the
    /// pre-node behaviour and needs the Tailscale app connected.
    static var usesEmbeddedNode: Bool {
        UserDefaults.standard.object(forKey: Key.embeddedNode) as? Bool ?? true
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
