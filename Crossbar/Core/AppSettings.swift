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
        /// The address this device was dialling before it followed a server that said it had
        /// moved, kept while the address it followed has not answered for it. See
        /// `previousServiceAddress`.
        static let previousServiceAddress = "crossbar.previousServiceAddress"
        /// How it was reaching that address, kept beside it: a move reshapes the way in as well as
        /// the name.
        static let previousConnectionMode = "crossbar.previousConnectionMode"
        /// The address a move this device followed ended at, when that address turned out not to
        /// take it. See `abandonedServiceAddress`.
        static let abandonedServiceAddress = "crossbar.abandonedServiceAddress"
        static let signallingOrigin = "crossbar.signallingOrigin"
        static let embeddedNode = "crossbar.embeddedNode"
        static let connectionMode = "crossbar.connectionMode"
        /// The release whose "what is new" has been read, so it is not shown twice.
        static let lastSeenVersion = "crossbar.lastSeenVersion"

        /// The rest are not defaults but keychain accounts, all under the one service:
        /// this device's signing key and handle, the id and name the service issued for
        /// it, and the session that key buys. Named here for the same reason the defaults
        /// are — one place, so a reader and a writer cannot disagree about the name.
        static let deviceService = "crossbar.device"
        static let deviceSigningKey = "crossbar.device.signingKey"
        static let deviceSigningKeyHandle = "crossbar.device.signingKeyHandle"
        static let deviceID = "crossbar.device.deviceId"
        static let deviceSessionToken = "crossbar.device.sessionToken"
        static let deviceSessionIssuedAt = "crossbar.device.sessionIssuedAt"
        static let deviceSessionExpiresAt = "crossbar.device.sessionExpiresAt"
    }

    /// The service's address, when someone has set one.
    ///
    /// Writable because an enrollment code carries the address of the service it enrolls
    /// with: the code is what points the app at its own backend, and having someone type
    /// the same host a second time is how the two end up disagreeing.
    ///
    /// One other writer: a move this device followed, which writes the address the server named —
    /// and writes where it came from into `previousServiceAddress` at the same moment, so that
    /// moving is never a one-way door.
    ///
    /// **Stored as the canonical origin**, and that is the one decision this key makes about
    /// spelling: what an enrollment code carries, what a server names in `/api/health`, and what a
    /// person types are the same place written three ways, and this is the form the rest of the
    /// app judges addresses in (`ServiceAddress.isSameDeployment`). A reader that compares the
    /// string rather than the address — `DeviceAuth.settle(from:)` does, against what a code names
    /// — then sees the same form the comparison would, and no writer can leave behind a spelling
    /// that reads as a different deployment later. Readers still get what they expect: a
    /// `scheme://host[:port]` string `URL(string:)` takes and `SettingsView` can show the host of,
    /// because an origin is all any of them dials.
    static var serviceAddress: String? {
        get { trimmed(UserDefaults.standard.string(forKey: Key.serviceAddress)) }
        set {
            guard let address = trimmed(newValue) else {
                UserDefaults.standard.removeObject(forKey: Key.serviceAddress)
                return
            }
            UserDefaults.standard.set(ServiceAddress.canonicalOrigin(address), forKey: Key.serviceAddress)
        }
    }

    /// Where this device was dialling before it followed a server which said it had moved.
    ///
    /// The app cannot know an address is going to work before it moves to it — the only proof is a
    /// load that authenticates this device, and that load is the thing that may fail — so the
    /// address it came from is written down first and forgotten last. Without it, following a move
    /// to a front door that is not up yet leaves the device holding the address that does not work
    /// with the one that did gone, and getting back costs an administrator a fresh invitation code
    /// and the person their enrollment: the exact cost following a move exists to avoid.
    ///
    /// A second key rather than one record holding both addresses, because the two are the same
    /// kind of fact spelled the same way and `serviceAddress` already shows how it is read and
    /// written. Absent means **no move outstanding** — a device with somewhere to come home to, or
    /// one without; never a default, and never "a move that worked".
    static var previousServiceAddress: String? {
        get { trimmed(UserDefaults.standard.string(forKey: Key.previousServiceAddress)) }
        set {
            guard let address = trimmed(newValue) else {
                UserDefaults.standard.removeObject(forKey: Key.previousServiceAddress)
                return
            }
            UserDefaults.standard.set(address, forKey: Key.previousServiceAddress)
        }
    }

    /// How this device was reaching the address above.
    ///
    /// Kept beside the address rather than left to the adoption, because a move can change the way
    /// in as well as the name (`/api/health` names the mode), and a device that comes home over the
    /// other network has not come home: the route is chosen from this mode
    /// (`TailnetNode.isEnabled`), so restoring the address without it dials the right name through
    /// the wrong one.
    static var previousConnectionMode: ConnectionMode? {
        get {
            UserDefaults.standard.string(forKey: Key.previousConnectionMode)
                .flatMap(ConnectionMode.init(rawValue:))
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: Key.previousConnectionMode)
                return
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.previousConnectionMode)
        }
    }

    /// Forgets the way home, both halves of it.
    ///
    /// One function rather than a `nil` written to each key at every site, because these are one
    /// fact — a device with an address to come home to and the route to reach it, or a device with
    /// neither — and clearing one while leaving the other is how coming home ends up dialling the
    /// right address over the wrong network.
    static func forgetPreviousAddress() {
        UserDefaults.standard.removeObject(forKey: Key.previousServiceAddress)
        UserDefaults.standard.removeObject(forKey: Key.previousConnectionMode)
    }

    /// The address a move this device followed ended at without taking it.
    ///
    /// Written when the device comes home — a followed address that answered with nothing, or
    /// that would not take this device — and read by the next load, which is the load that used
    /// to hear the same move again and make it again: a device that had already followed an
    /// address and come home was indistinguishable from one hearing the move for the first time,
    /// so every load re-adopted it and announced it. Measured on a stub 2026-09-26, before this
    /// existed: a load whose followed address was down logged `the server moved:` and announced
    /// the move, and so did the load after it, with the stored address ending where it began —
    /// the same signal on a pull-to-refresh as on a launch.
    ///
    /// It is **not a rejection**: the address is kept so the move is not *made blind* again, and
    /// the next load asks that address whether it takes this device before moving onto it
    /// (`CallSession.followMovedServer`), so a front door that comes up minutes later is still
    /// followed. It is forgotten as soon as any of the ways out arrives: the deployment naming a
    /// different address, the move landing after all (`forgetMove`), or this device being set up
    /// again.
    ///
    /// Stored canonically, like `serviceAddress`, because it is compared against the same
    /// `origin` the same way: a move named once as `HTTP://host:18080/` and once as
    /// `http://host:18080` is one move, not two.
    static var abandonedServiceAddress: String? {
        get { trimmed(UserDefaults.standard.string(forKey: Key.abandonedServiceAddress)) }
        set {
            guard let address = trimmed(newValue) else {
                UserDefaults.standard.removeObject(forKey: Key.abandonedServiceAddress)
                return
            }
            UserDefaults.standard.set(ServiceAddress.canonicalOrigin(address), forKey: Key.abandonedServiceAddress)
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

    /// The release whose "what is new" has been shown, so that it is shown once.
    ///
    /// The release rather than the build: a new build of the same release has the same notes, and
    /// showing them again for it would be the app repeating itself to somebody who read them
    /// yesterday.
    static var lastSeenVersion: String? {
        get { trimmed(UserDefaults.standard.string(forKey: Key.lastSeenVersion)) }
        set {
            guard let release = trimmed(newValue) else {
                UserDefaults.standard.removeObject(forKey: Key.lastSeenVersion)
                return
            }
            UserDefaults.standard.set(release, forKey: Key.lastSeenVersion)
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
