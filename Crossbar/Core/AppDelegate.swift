@preconcurrency import PushKit
import UIKit

/// The one thing UIKit still owns: the registry that says where this device's calls arrive.
///
/// PushKit is not CallKit and not the call session, and the three are kept apart on purpose. A
/// push is a message from Apple saying a call is being placed to this device; CallKit is the
/// system's UI for a call that exists; `CallSession` is what this app knows about that call.
/// Keeping the registry out of `CallKitController` is deliberate — a push is not a call, and a
/// class about the system's call UI has no business knowing what APNs sends.
///
/// This object exists before any screen does, and that is the whole reason it is a delegate
/// rather than another controller: a locked phone rings because the app is woken **by** the
/// push, with nothing on screen, and iOS ends an app that takes such a push and reports no call.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate {
    /// Held for the life of the app. PushKit holds its delegate weakly, so this is the only
    /// strong reference to the registry there is.
    private var registry: PKPushRegistry?

    /// Built at launch, because a launch that a push caused is a launch with no screen: the
    /// registry has to exist before anything a person can see, or the first push of a cold
    /// launch finds nobody listening.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        self.registry = registry
        // Set last, and deliberately: PushKit begins delivering the moment the desired types
        // are assigned, and what it delivers first is the token — which is the next method in
        // this file.
        registry.desiredPushTypes = [.voIP]
        return true
    }

    // MARK: - Where the service should send this device's calls

    /// iOS has accepted this device for VoIP pushes, and here is the token it accepts.
    ///
    /// Called on every launch, not once: PushKit re-announces the token it holds, which is what
    /// makes the service's record self-correcting across a reinstall, a restore or a rotated
    /// token. It is also why nothing here is retried or remembered — the next launch is the
    /// retry.
    ///
    /// The token is hex because that is how it travels — the service stores it and hands it to
    /// APNs, both as text. It is the one spelling that survives the trip: raw bytes in a JSON
    /// body would need an encoding agreed on at both ends, and APNs wants the bytes back.
    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        // Given to the session rather than uploaded from here. The client that carries the
        // service's address, this device's bearer token and the family network's own route
        // lives there, and a client built here would dial the system's route while the rest of
        // the app went down the node's — see `CallSession.createDeviceInvitation`, which is the
        // same arrangement for the same reason.
        Task { await CallSession.shared.uploadVoIPPushToken(token) }
    }

    /// The token this app was given no longer works.
    ///
    /// There is nothing to unfil: the service has one route for a device's push token and no
    /// way to withdraw one, and a token APNs has invalidated is refused at APNs regardless. It
    /// is written down because the silence would otherwise be indistinguishable from a token
    /// that never arrived — the failure this project has paid for more than any other, and the
    /// one it has no other way to see from the device.
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        CallSession.shared.log("the VoIP push token was invalidated — this device cannot be rung until PushKit issues a new one")
    }

    // MARK: - A call is being placed to this device

    /// Reports the push to CallKit, and **does it before this method returns**.
    ///
    /// The ordering is not a style choice. Since iOS 13 the system terminates an app that takes
    /// a VoIP push without reporting a call, and stops delivering VoIP pushes to an app that
    /// does it repeatedly — so nothing may stand in front of the report. There is no network
    /// call and no `await` here before it: the payload is read out, the call is reported from
    /// what it said, and only afterwards is anything else allowed to happen. The completion
    /// handler is called after that, because PushKit wants to know the push has been dealt with
    /// and the report is not a reply to it.
    ///
    /// The newer PushKit method — `didReceiveIncomingVoIPPushWithPayload:metadata:
    /// withCompletionHandler:` — is deliberately **not** implemented. Apple recommends it so
    /// that an app can ignore a push it does not need to report, and two of the cases in which
    /// its `mustReport` flag is false are cases this app must not ignore: the app is in the
    /// foreground, or it already has a call. Every call here belongs to CallKit — the audio
    /// session, the lock screen, the route picker and the answer button all do — so a call this
    /// app did not report is a call it cannot join. `CallSession` says the same thing about
    /// answering behind CallKit's back, and a call arriving while the app is open is this app's
    /// ordinary case rather than an edge one. The cost of not honouring `mustReport` is a call
    /// that rings while a screen is already showing it, which is the arrangement that has
    /// always been here.
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        guard let pushed = PushedCall(payload: payload.dictionaryPayload) else {
            // A push that names no call cannot become one, and this is where the two options
            // visibly differ. CallKit is told about a call by its identity: the answer, the end
            // and the join that follow all name the call the app reported. An identity made up
            // here would put a ringing call on the lock screen that nothing can answer — the
            // person would be offered an answer button that leads nowhere while the caller
            // heard ringing — so no call is reported, and this app pays what iOS charges for a
            // push it did not report: this process is ended, and its VoIP pushes may be
            // throttled if it keeps happening. That is the honest reading of a payload this app
            // cannot use, and it is why the payload is checked before anything is reported
            // rather than after. Nothing else can be done about it from here — the payload is
            // the service's, and a service sending calls this app cannot name is the thing to
            // fix.
            CallSession.shared.log("a VoIP push arrived naming no call this app can report — "
                + "\(payload.dictionaryPayload.count) keys, no usable callId")
            completion()
            return
        }

        // The report, and then the half of answering that is not CallKit's — a load, so that
        // there is a call to accept when the answer comes. See `CallSession.reportPushedCall`
        // for why that is safe to do from here and why it may not come first.
        CallSession.shared.reportPushedCall(callID: pushed.id, callerName: pushed.callerName, video: pushed.video)
        completion()
    }
}

/// What a VoIP push says about the call it announces.
///
/// The service's own words, read where the push arrives and nowhere else: the payload is
/// Apple's envelope around the service's dictionary, so its shape is this file's business and
/// the call session is handed the three things it can use — an identity, a name and a kind.
private struct PushedCall {
    /// The call's identity, and the service's own: the same id it minted for the call and the
    /// same one CallKit is given here. Nothing is derived from it, because a call this app
    /// invented an identity for could not be answered, joined or ended.
    let id: UUID

    /// Who to say is calling.
    let callerName: String

    /// Whether the call has pictures.
    let video: Bool

    /// `nil` when the payload does not name a call that can be reported.
    ///
    /// `caller` is a display name and the service sends it empty for someone who has never set
    /// one, so the id beside it is the next thing to show, and "Unknown caller" is the last —
    /// the same words `CallSession.displayName(for:)` falls back to. A call on the lock screen
    /// with no name at all is worse than one named by whatever there is.
    ///
    /// `expiresAt` is deliberately not read. Using it would mean a clock that disagrees with the
    /// service — or an instant this build could not parse — refusing to ring for a call that is
    /// really being placed, and a ring that did not happen cannot be recovered. A call that
    /// rings for a few seconds after it was given up on can be, and is: the session ends a call
    /// it finds it has no business being in.
    init?(payload: [AnyHashable: Any]) {
        guard let raw = payload["callId"] as? String, let id = UUID(uuidString: raw) else { return nil }

        let name = [payload["caller"] as? String, payload["callerId"] as? String]
            .compactMap { $0 }
            .first { !$0.isEmpty }

        self.id = id
        self.callerName = name ?? "Unknown caller"
        // `audio` is the one kind with no pictures; anything else — including a kind this build
        // has never heard of — is drawn as a video call, which is the same reading
        // `FamilyCall.isVideo` makes of a call the service describes.
        self.video = (payload["kind"] as? String) != "audio"
    }
}

/// Which APNs environment this build's device tokens belong to.
///
/// Not the build configuration, and not a preference. Apple mints a device token for the
/// environment the app was **signed** for, and the service delivers through whichever of its two
/// endpoints matches the word filed beside the token. A sandbox token filed as production is
/// not a slow ring: it is a phone that never rings, with nothing on either side saying why —
/// the request to the service succeeds and APNs refuses the delivery. The failure looks exactly
/// like a service that does not send pushes at all, which is why the word has to be right.
///
/// The project sets `aps-environment` from the configuration — Debug is `development`, Release
/// and TestFlight are `production` — but that is how the entitlement is *chosen*, not what it
/// turned out to be. A Release configuration signed with a development profile mints sandbox
/// tokens, and that is the build someone would be handed to test with. So the entitlement is
/// read back out of the profile that signed this copy rather than inferred from the
/// configuration that asked for it.
enum PushEnvironment {
    /// The service's word for the two environments, which is Apple's own vocabulary translated:
    /// the entitlement calls the development environment `development` and the push endpoint
    /// calls it `sandbox`. The request body is written in the second.
    static var current: String {
        switch entitlement ?? declared {
        case "production": return "production"
        default: return "sandbox"
        }
    }

    /// `aps-environment` as this copy of the app was actually signed.
    ///
    /// Asked of the profile rather than of the running process: a signed app's entitlements are
    /// not readable from inside it on iOS — that is a Mac-only API — and the profile is the same
    /// record of them, shipped inside the app.
    private static var entitlement: String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return nil }

        // A profile is a CMS envelope around a property list, so the list is taken out of the
        // middle of the bytes rather than parsed from all of them. There is exactly one property
        // list in there, and it is the one Apple's signature covers.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], options: [], format: nil
              ),
              let shape = parsed as? [String: Any],
              let entitlements = shape["Entitlements"] as? [String: Any]
        else { return nil }

        return entitlements["aps-environment"] as? String
    }

    /// What the project asked for, for a copy whose profile cannot be read — an App Store
    /// install ships the effect of its profile rather than the profile itself. This is the
    /// decision `$(APS_ENVIRONMENT)` makes in the entitlements file, written a second time in
    /// Swift, and it is only reached when the entitlement it should have matched is unreadable.
    private static var declared: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }
}
