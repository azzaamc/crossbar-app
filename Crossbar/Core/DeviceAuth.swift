import Combine
import Foundation

/// The client half of Crossbar's device identity: enroll this device with a code, then
/// exchange a signed challenge for a session token.
///
/// The service's half is `/api/auth/*`. The one part of it that cannot be guessed is the
/// canonical message, which is fixed: the scheme version, the device id, the challenge id
/// and the nonce, newline-separated with no trailing newline, hashed with SHA-256 and
/// signed with the device's P-256 key. A trailing newline there is a different message and
/// a rejected signature, with nothing on either side able to say why — hence the bytes
/// being built in exactly one place, in exactly one spelling.
///
/// Everything on the request path here is silent. A service with no `/api/auth/*` routes —
/// which is every private deployment, including the one this app ships against — answers
/// 404, and that means "this service does not use device auth" rather than "something went
/// wrong". The app then presents no session and behaves exactly as it did before device
/// identity existed.
@MainActor
final class DeviceAuth: ObservableObject {
    /// One per process, beside `TailnetNode.shared` and for the same reason: two of these
    /// would hold two views of the same key and two sessions, and the one that minted the
    /// session would not be the one the control plane asked.
    static let shared = DeviceAuth()

    /// This device's key and the id the service issued for it.
    let identity = DeviceIdentity()

    /// Mirrored for the views, which cannot observe `DeviceIdentity` through this object.
    @Published private(set) var deviceId: String?
    @Published private(set) var isEnrolled = false

    /// Where the enrollment, challenge and session requests leave by.
    ///
    /// Set by `FamilyCallClient` to the carrier its own requests use. In the embedded
    /// node's case the service is reachable over the node's loopback and nowhere else, so
    /// a session minted over the system route would be a session the control plane could
    /// not then use.
    var transport: CallTransport = .direct {
        didSet { http = transport.session() }
    }

    /// The session token, once one has been exchanged. Opaque, secret, never logged.
    private var session: Session?

    /// Whether the service last answered the device-auth routes at all.
    ///
    /// Remembered so a service that does not implement them is asked once rather than on
    /// every request. Set back to true by an explicit enrollment, which is someone saying
    /// that this service does use them.
    private var serverUsesDeviceAuth = true

    /// The re-authentication already running, if any.
    ///
    /// Held so that a stale session and a 401 arriving together produce one exchange
    /// rather than several: the challenge is rate-limited on the service's side, and a
    /// burst of identical attempts is what that limit is for.
    private var authentication: Task<Bool, Never>?

    private var http = URLSession(configuration: .default)

    private init() {
        session = Self.loadSession()
        mirrorIdentity()
    }

    // MARK: - What the client sees

    /// The token to present, if this device has one worth presenting.
    var sessionToken: String? { session?.token }

    /// Makes sure there is a usable session, exchanging one if there is not.
    ///
    /// Returns whether the app may present a token at all. Silent on every failure, because
    /// this runs on the request path: a service that does not use device auth, or one that
    /// cannot be reached for the exchange, must not turn a request that would otherwise
    /// have worked into a failure.
    ///
    /// `forcing` skips the freshness check and exchanges a session now. That is what a 401
    /// calls for: the service has just said the token in hand is not good, so the app's own
    /// opinion of its age is beside the point.
    @discardableResult
    func ensureSession(forcing: Bool = false) async -> Bool {
        guard identity.isEnrolled, serverUsesDeviceAuth else { return false }
        if !forcing, let session, session.refreshAt > Date() { return true }
        if let authentication { return await authentication.value }

        let attempt = Task { await authenticate() }
        authentication = attempt
        let authenticated = await attempt.value
        authentication = nil
        return authenticated
    }

    // MARK: - Enrollment

    /// Enrolls this device from an enrollment code.
    ///
    /// The code may be the service's JSON payload — what a QR code carries — or a bare
    /// token. When it names a service, that address is applied here: the code is how the
    /// app is told which service it belongs to, and asking someone to type the same host
    /// twice is how the app and its code end up disagreeing about it.
    func enroll(code: String) async throws {
        guard let parsed = EnrollmentCode(code) else { throw DeviceAuthError.codeInvalid }

        if let server = parsed.server, server != AppSettings.serviceAddress {
            AppSettings.serviceAddress = server
            // A session is only meaningful to the service that issued it.
            discardSession()
        }

        // Which kind of deployment this is, settled before anything is dialled: the mode
        // decides whether the app brings up a network of its own, so an enrollment that ran
        // first would be knocking on the wrong door.
        if let mode = parsed.mode, mode != AppSettings.connectionMode {
            AppSettings.connectionMode = mode
            discardSession()
        }

        try identity.createKeyIfNeeded()
        guard let publicKey = identity.publicKeyBase64 else { throw DeviceAuthError.noKey }

        let result = try await call("POST", "api/auth/enroll", body: [
            "token": parsed.token,
            "publicKey": publicKey,
            "algorithm": "ES256",
            "deviceName": DeviceIdentity.defaultDeviceName,
            "platform": "ios",
        ])
        guard (200..<300).contains(result.status) else {
            throw DeviceAuthError(status: result.status, shape: result.shape)
        }
        guard let device = result.shape["device"] as? [String: Any],
              let id = device["id"] as? String, !id.isEmpty else {
            throw DeviceAuthError.malformed("The service enrolled this device but did not name it.")
        }

        identity.enroll(as: id)
        serverUsesDeviceAuth = true
        mirrorIdentity()

        // Enrollment answers with a session already, and taking it saves the challenge
        // exchange that would otherwise follow within the same second. A service that
        // answers without one is not an error — the device is enrolled either way — so the
        // ordinary route is taken instead.
        if !storeSession(result.shape) {
            _ = await authenticate()
        }
    }

    /// Whether the service at the current address asks a device to enroll before it will
    /// answer anything — asked by the screen that has to say so *before* a failure does.
    ///
    /// Asked rather than assumed, because the two deployments differ exactly here and the
    /// person holding the phone is the only one who can produce a code. Told on the way in,
    /// they paste one; told by a load that fails a moment later, they get a sentence about
    /// identity and no idea there was ever something to paste.
    ///
    /// The answer comes from the *refusal*, not from the status. A service with no
    /// `/api/auth/*` routes and a service that has switched them off both answer 404,
    /// deliberately indistinguishable, while a service that does use them answers about a
    /// device it has never heard of. The error code is what tells those two apart.
    ///
    /// `nil` when the service could not be asked at all, which is not a statement about the
    /// service: the caller carries on and lets the ordinary path report the refusal, with
    /// the address in it.
    func requiresEnrollment() async -> Bool? {
        guard let result = try? await call("POST", "api/auth/challenge", body: ["deviceId": ""]) else {
            return nil
        }
        let code = ((result.shape["error"] as? [String: Any])?["code"] as? String) ?? ""
        return result.status == 404 ? code == "DEVICE_UNKNOWN" : true
    }

    /// Deletes this device's identity, and the session that went with it.
    func forget() {
        identity.forget()
        discardSession()
        // Whoever enrolls next is telling the app about a service that does use these
        // routes, so a previous "it does not" does not survive that.
        serverUsesDeviceAuth = true
        mirrorIdentity()
    }

    // MARK: - The exchange

    /// One challenge-and-signature exchange, or nothing.
    private func authenticate() async -> Bool {
        guard let deviceId = identity.deviceId, identity.isEnrolled else { return false }

        do {
            let challenge = try await call("POST", "api/auth/challenge", body: ["deviceId": deviceId])
            guard (200..<300).contains(challenge.status),
                  let challengeId = challenge.shape["challengeId"] as? String,
                  let nonce = challenge.shape["nonce"] as? String else {
                registerRefusal(challenge)
                return false
            }

            let signature = try identity.sign(Self.canonicalBytes(
                deviceId: deviceId,
                challengeId: challengeId,
                nonce: nonce
            ))
            let exchange = try await call("POST", "api/auth/session", body: [
                "deviceId": deviceId,
                "challengeId": challengeId,
                "signature": signature.base64EncodedString(),
            ])
            guard (200..<300).contains(exchange.status) else {
                registerRefusal(exchange)
                return false
            }
            return storeSession(exchange.shape)
        } catch {
            // Including a signature the Enclave refuses. The request that wanted this
            // session still goes out, unauthorised, which is the state the app is in on a
            // service that does not ask for one.
            return false
        }
    }

    /// The exact bytes the service verifies.
    ///
    /// Newline-terminated on the scheme, device and challenge lines and nowhere else: the
    /// message ends with the nonce.
    static func canonicalBytes(deviceId: String, challengeId: String, nonce: String) -> Data {
        Data("crossbar-device-auth-v1\n\(deviceId)\n\(challengeId)\n\(nonce)".utf8)
    }

    /// What a refusal from `/api/auth/*` means for the app.
    ///
    /// A 404 is the one that matters: it says the service has no device auth at all, so
    /// this device stops asking for the life of the process. Any other refusal means the
    /// session in hand is dead — the token is dropped rather than kept, because a token the
    /// service has already refused is one it will refuse again, and holding it would put a
    /// rejected credential on every request the app makes.
    private func registerRefusal(_ result: (status: Int, shape: [String: Any])) {
        if result.status == 404 { serverUsesDeviceAuth = false }
        discardSession()
    }

    // MARK: - The session in storage

    private func mirrorIdentity() {
        deviceId = identity.deviceId
        isEnrolled = identity.isEnrolled
    }

    /// Takes the session out of a response envelope, if it carries a usable one.
    ///
    /// An expiry that cannot be placed in time, or one that has already passed, makes the
    /// session unusable — and a session whose age the app cannot reason about is one it
    /// cannot know when to replace, so it is not kept either. The device is still enrolled;
    /// the next request simply starts the exchange again.
    private func storeSession(_ shape: [String: Any]) -> Bool {
        guard let envelope = shape["session"] as? [String: Any],
              let token = envelope["token"] as? String, !token.isEmpty,
              let expires = Self.date(envelope["expiresAt"]),
              expires > Date() else {
            discardSession()
            return false
        }

        let session = Session(token: token, issuedAt: Date(), expiresAt: expires)
        self.session = session
        DeviceKeychain.set(token, for: AppSettings.Key.deviceSessionToken)
        DeviceKeychain.set(String(session.issuedAt.timeIntervalSince1970), for: AppSettings.Key.deviceSessionIssuedAt)
        DeviceKeychain.set(String(session.expiresAt.timeIntervalSince1970), for: AppSettings.Key.deviceSessionExpiresAt)
        return true
    }

    private func discardSession() {
        session = nil
        DeviceKeychain.remove(AppSettings.Key.deviceSessionToken)
        DeviceKeychain.remove(AppSettings.Key.deviceSessionIssuedAt)
        DeviceKeychain.remove(AppSettings.Key.deviceSessionExpiresAt)
    }

    private static func loadSession() -> Session? {
        guard let token = DeviceKeychain.string(for: AppSettings.Key.deviceSessionToken),
              let issued = DeviceKeychain.string(for: AppSettings.Key.deviceSessionIssuedAt).flatMap({ Double($0) }),
              let expires = DeviceKeychain.string(for: AppSettings.Key.deviceSessionExpiresAt).flatMap({ Double($0) }) else {
            return nil
        }
        let session = Session(
            token: token,
            issuedAt: Date(timeIntervalSince1970: issued),
            expiresAt: Date(timeIntervalSince1970: expires)
        )
        return session.expiresAt > Date() ? session : nil
    }

    // MARK: - Talking to the service

    /// One request to the service, answered as the service's own JSON.
    ///
    /// Parsed loosely rather than decoded into types: the three routes here differ only in
    /// their envelope, and the status and the error code have to be read together for the
    /// mapping below to say anything a person can act on.
    private func call(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil
    ) async throws -> (status: Int, shape: [String: Any]) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            throw DeviceAuthError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let shape = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, shape)
    }

    /// Built through `URLComponents` rather than `appendingPathComponent`, the same way the
    /// control plane builds them, so a configured address with a path cannot move where a
    /// request lands.
    private func url(_ path: String) -> URL {
        var components = URLComponents(url: FamilyCallService.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/" + path
        return components.url!
    }

    /// The service states an expiry as an ISO-8601 instant; epoch seconds are accepted too,
    /// because a session this app cannot place in time is a session it cannot use.
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            if let date = iso8601.date(from: text) { return date }
            return iso8601Fractional.date(from: text)
        }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    private static let iso8601 = ISO8601DateFormatter()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A session token and the span it is good for.
    ///
    /// The service states an expiry rather than a lifetime, so the moment the token was
    /// issued is kept beside it. What the app needs from the pair is not when the session
    /// dies but when to replace it: late enough that replacements are rare, early enough
    /// that a request in flight is never the one that finds out.
    private struct Session {
        let token: String
        let issuedAt: Date
        let expiresAt: Date

        /// When to exchange a new one: 80% of the way through its life.
        ///
        /// Only ever reached with a session whose expiry is in the future — one the service
        /// already said was past is refused at the point it is stored — so this is a moment
        /// between now and the session's death, which is the whole of what the app needs.
        var refreshAt: Date {
            issuedAt.addingTimeInterval(expiresAt.timeIntervalSince(issuedAt) * 0.8)
        }
    }
}

/// Why an enrollment was refused, in words a person can act on.
///
/// The codes are the service's; the sentences are this app's. `ENROLLMENT_USED` is not
/// something to show someone holding a phone, and every one of these has a different next
/// step — wait, ask for a new code, ask for a new code because the last was cancelled,
/// forget the device and start again.
enum DeviceAuthError: Error, LocalizedError {
    case codeInvalid
    case noKey
    case unsupportedServer
    case malformed(String)
    case transport(String)
    case refused(status: Int, code: String, message: String)

    init(status: Int, shape: [String: Any]) {
        let error = shape["error"] as? [String: Any]
        let code = error?["code"] as? String
        let message = error?["message"] as? String
        self = status == 404
            ? .unsupportedServer
            : .refused(status: status, code: code ?? "UNKNOWN", message: message ?? "")
    }

    /// What to show when enrollment fails.
    var failureMessage: String {
        switch self {
        case .codeInvalid:
            "That does not look like an enrollment code. Paste the whole line, or the payload a QR code carries."
        case .noKey:
            "This device could not create a signing key, so it cannot be enrolled."
        case .unsupportedServer:
            "This service does not use device enrollment, so there is nothing to enroll."
        case .malformed(let reason):
            reason
        case .transport(let reason):
            "Could not reach the service. \(reason)"
        case .refused(let status, let code, let message):
            switch code {
            case "ENROLLMENT_EXPIRED":
                "That code has expired. Ask for a new one."
            case "ENROLLMENT_USED":
                "That code has already been used. Each code works once, so ask for a new one."
            case "ENROLLMENT_REVOKED":
                "That code was cancelled. Ask for a new one."
            case "ENROLLMENT_INVALID":
                "That code is not valid for this service. Check it was meant for this one."
            case "DEVICE_KEY_INVALID":
                "The service would not accept this device's key. Forget this device and enroll again."
            case "RATE_LIMITED":
                "Too many attempts. Wait a minute and try again."
            default:
                message.isEmpty ? "The service refused the enrollment (HTTP \(status))." : message
            }
        }
    }

    var errorDescription: String? { failureMessage }
}

/// What someone pastes into the enrollment field, or what a QR code carries.
struct EnrollmentCode {
    let token: String
    /// The service's address when the code names one, which is how this app is pointed at its
    /// own backend without anybody typing a hostname.
    let server: String?
    /// Which kind of deployment the code is for — the one thing the app cannot work out for
    /// itself, because the same address is a tailnet name in one kind and a server on the
    /// internet in the other. Absent from a code made before the service sent it, in which
    /// case the app asks rather than guessing.
    let mode: ConnectionMode?

    /// Accepts the service's JSON payload (`{"version":1,"server":…,"enrollment_token":…}`)
    /// or a bare token.
    ///
    /// A payload that does not parse falls back to being read as a bare token rather than
    /// being rejected: a paste field is not a parser, and the service is the authority on
    /// whether a token is real. `version` is deliberately not enforced — a client that
    /// refuses a payload it does not yet understand turns a forward-compatible field into
    /// a fault.
    init?(_ text: String) {
        guard let trimmed = text.nonBlank else { return nil }

        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let shape = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = (shape["enrollment_token"] as? String ?? shape["token"] as? String)?.nonBlank {
            self.token = token
            self.server = (shape["server"] as? String)?.nonBlank
            self.mode = ConnectionMode.named(by: shape["mode"] as? String)
            return
        }

        self.token = trimmed
        self.server = nil
        self.mode = nil
    }
}

private extension String {
    /// The value with the whitespace around it removed, or nil when nothing is left.
    ///
    /// Pasted codes arrive with newlines and spaces attached often enough that trimming is
    /// the difference between a working enrollment and an unexplained one.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
