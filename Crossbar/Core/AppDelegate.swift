import Combine
@preconcurrency import PushKit
import UIKit
import UserNotifications

/// The two things UIKit still owns: the registry that says where this device's calls arrive, and
/// the permission that lets this app say one was missed.
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
///
/// Two kinds of message arrive on a phone and they are not the same message. A VoIP push is a
/// call being placed to this device, and the registry above is the whole of that. A missed call
/// is an ordinary remote notification — the service's record of a call nobody answered — and it
/// is handled here because the permission is asked for once per app, the token is issued to the
/// app, and both are handed over by `UIApplication` itself, which is this object. A missed call
/// is never reported to CallKit and never rings: the call it names is over, and an app that rang
/// for one would be showing a person a call they cannot answer.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate, UNUserNotificationCenterDelegate {
    /// Held for the life of the app. PushKit holds its delegate weakly, so this is the only
    /// strong reference to the registry there is.
    private var registry: PKPushRegistry?

    /// What decides when this app is entitled to ask for the permission a missed call needs.
    private var cancellables = Set<AnyCancellable>()

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

        // The notification centre's delegate, before this method returns: iOS requires that,
        // and the reason is visible in the two methods it enables — a notification the user
        // taps at a cold launch is answered through the delegate, so one set a moment later
        // would miss the very tap that launched the app.
        UNUserNotificationCenter.current().delegate = self

        // The permission a missed call needs is asked for at the moment this app is first able
        // to deserve it, and never at launch on its own account. `$isEnrolled` is what carries
        // that moment: it arrives with whatever is already true, so an app set up on a previous
        // run is registered at this launch, and it fires when an enrollment lands — which is the
        // instant a person has just finished telling this app where its Crossbar is. See
        // `askForMissedCalls()`, which is what the two facts it depends on are.
        DeviceAuth.shared.$isEnrolled
            .sink { [weak self] _ in self?.askForMissedCalls() }
            .store(in: &cancellables)

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

    // MARK: - A call that was missed

    /// Asks for permission to show a missed call, and files the token it arrives on.
    ///
    /// Asked once, when this app has grounds, and the two grounds are both facts about this
    /// device rather than a moment in the screens. It has to have been told how to reach a
    /// service — until someone has answered the onboarding screen there is no server this device
    /// belongs to, no call can be missed on it, and a permission asked for there is a permission
    /// this app has nothing to do with. And that service has to have enrolled the device: a
    /// missed call is an ordinary notification, the token it is sent to is filed against the
    /// device id the service issued for this one (`CallSession.uploadAlertPushToken`), and a
    /// service that has issued none can send nothing to it. Every refusal is written down, on
    /// both paths that can produce one: a notification that never appeared and one that was
    /// never asked for look exactly alike from the phone.
    private func askForMissedCalls() {
        guard AppSettings.connectionMode != nil, DeviceAuth.shared.isEnrolled else { return }
        Task { await considerMissedCalls() }
    }

    /// What the authorisation this app already holds calls for.
    ///
    /// The status is read before anything is asked, rather than asking and reading the answer
    /// back: a prompt that has already been answered is never presented a second time, and
    /// asking anyway would make a decision this app already holds indistinguishable from one it
    /// has just been given — which is exactly the pair of states the two branches below have to
    /// tell apart.
    private func considerMissedCalls() async {
        let centre = UNUserNotificationCenter.current()
        let status = await centre.notificationSettings().authorizationStatus

        switch status {
        case .notDetermined:
            do {
                let granted = try await centre.requestAuthorization(options: [.alert, .sound])
                record(granted: granted, refusal: nil)
            } catch {
                // A prompt that failed rather than one that was answered. A different problem,
                // and worth telling apart in the log.
                record(granted: false, refusal: error.localizedDescription)
            }

        case .authorized, .provisional, .ephemeral:
            // Asked for on every launch, which is what a device token needs: iOS re-announces
            // one to whoever asks, and that is how the service's record stays right across a
            // reinstall, a restore or a token Apple rotates.
            registerForMissedCalls()

        default:
            // Deliberately not registered, and not asked again from here: a device whose
            // permission is switched off in Settings cannot show a notification, and a token
            // filed for one is a token APNs accepts and the phone drops — the service would be
            // told this device can be reached when nothing reaches it. Turning it back on in
            // Settings is what brings this path round again, at the next launch.
            CallSession.shared.log("missed calls cannot be shown — notifications are not allowed for this app, "
                + "so no alert token is filed until that is allowed in Settings")
        }
    }

    /// What the answer to the prompt means, once it has been given.
    ///
    /// The grant is what makes the token worth having, and a refusal is logged rather than
    /// followed by a registration: a token is a claim that this device can be reached, and
    /// filing one for a device that will not show anything is claiming something untrue.
    /// `refusal` is the system's own words for a prompt that failed rather than was answered,
    /// which is a different problem and worth telling apart.
    private func record(granted: Bool, refusal: String?) {
        guard granted else {
            CallSession.shared.log("missed-call notifications were not authorised"
                + (refusal.map { " (\($0))" } ?? "")
                + " — no alert token is filed, because a notification this device will not show is not one it should claim to receive")
            return
        }
        registerForMissedCalls()
    }

    /// Asks APNs for this device's ordinary-notification token.
    ///
    /// The answer arrives at `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`,
    /// and what it is for is the alert half of a call: the service's own record that a call
    /// nobody answered has finished. The VoIP token above is a different token from a different
    /// registry, filed under a different word — see `CallSession`, which is where both leave
    /// this app.
    private func registerForMissedCalls() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// iOS has accepted this device for ordinary notifications, and here is the token it accepts.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        // Filed through the session for the same reason the VoIP token is: the client that
        // carries the service's address, this device's bearer and the family network's own route
        // lives there. See `CallSession.uploadAlertPushToken`.
        Task { await CallSession.shared.uploadAlertPushToken(token) }
    }

    /// The token could not be had, which is written down rather than swallowed. It is not the
    /// same silence as a service that does not send: this one has a reason, and that reason is
    /// what says whether the thing to fix is the network or the permission.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        CallSession.shared.log("this device could not be registered for remote notifications: \(error.localizedDescription)")
    }

    /// Whether a missed call arriving with this app in front is shown at all.
    ///
    /// A call screen is the one place a banner must not go. `IncomingCallView` is a ring with an
    /// answer and a decline on it, `InCallView` is a call with an end button, and a banner over
    /// either covers the control the person is being asked to use — to tell them about a call
    /// this app is already showing them the shape of. So nothing is presented while this device
    /// has a call on screen, ringing, outgoing or answered. Everywhere else the notification is
    /// presented in full, sound included: this app being in front is not a reason to hide
    /// something the person would otherwise only find by opening Recents.
    ///
    /// Written as the asynchronous form of the delegate method rather than the
    /// completion-handler one, and not for brevity. The decision is about
    /// `CallSession.shared.phase`, which is main-actor state, and nothing says which queue a
    /// notification delegate is called on — Apple documents no queue for it, and this class is
    /// main-actor isolated because everything it touches is. An asynchronous requirement is
    /// answered *on the delegate's actor* however it was called, so this is decided where the
    /// phase lives rather than wherever the phone happened to be at the time — and the whole
    /// presentation hangs on getting it right.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let onACall = CallSession.shared.phase.call != nil
        if onACall {
            CallSession.shared.log("a missed call arrived while a call is on screen — held back rather than shown over it")
        }
        return onACall ? [] : [.banner, .sound, .list]
    }

    /// The notification was tapped.
    ///
    /// Opening the app is the whole of what it does, and that is not a gap left here. A missed
    /// call is an ordinary notification and not a call: there is nothing to accept, nothing to
    /// report to CallKit, and the call it names is already a finished row in Recents — which is
    /// the screen somebody would want, one tap away. Driving the tab bar there would mean a deep
    /// link into a view this notification has no business knowing the shape of, to answer a tap
    /// that opening the app has already answered. What is left is the log line, because a
    /// notification nobody opened and one that was never delivered are otherwise the same
    /// silence.
    ///
    /// The call id, and not the notification's own identifier. The identifier is Apple's and
    /// belongs to one delivery; the call id is the service's, and it is what the service filed
    /// its own record of sending this under — `push_missed`. A log line naming a value nothing
    /// else has ever heard of is a line nobody can look anything up with, and this project has
    /// spent enough time reading these logs to know the difference.
    ///
    /// Asynchronous for the same reason `willPresent` is: the log is written on the main actor,
    /// and this is not something to assume about the queue a notification is delivered on.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let callId = response.notification.request.content.userInfo["callId"] as? String
        CallSession.shared.log("a missed-call notification was opened for \(callId ?? "a call it did not name")")
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
