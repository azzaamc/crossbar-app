import Foundation

// MARK: - Wire models

/// `GET /api/bootstrap` → `user`, mirroring `store.userById` (`src/db.js:165-171`).
struct FamilyUser: Decodable {
    let id: String
    let displayName: String
    let avatar: String?
}

/// `GET /api/bootstrap` → `contacts[]` (`src/db.js:216-226`).
struct FamilyContact: Decodable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let avatar: String?
    let lastSeen: String?
    /// Added by the route rather than the query: whether the contact currently holds
    /// an open SSE stream (`src/server.js:202-207`). A contact is reachable while
    /// this is true; it says nothing about whether they will answer. Mutable because
    /// presence arrives on the event stream after the list is drawn.
    var online: Bool
}

/// The `callPublic` projection (`src/server.js:145-154`), with the fields the other
/// call shapes add.
///
/// `participants` is present on a `callPublic` call but **absent** from the `calls[]`
/// entries of `/api/bootstrap`, which come from `store.callsForUser` and are a
/// different shape for the same idea (`src/db.js:295-305`). Optional fields here are
/// ones some route omits rather than ones that may be null in principle.
/// One call that has finished, as the history reports it.
///
/// Every field is a fact the service already keeps: which way round it was is worked out from
/// who placed it, and what became of it is this person's own participation row rather than a
/// summary the server invented for the screen.
struct RecentCall: Decodable, Identifiable, Equatable {
    let callId: String
    let kind: String
    let callerId: String
    let callerName: String?
    let startedAt: String
    let answeredAt: String?
    let endedAt: String?
    let myStatus: String?
    let joinedAt: String?
    let leftAt: String?
    /// Everyone else on it, as names joined for reading. Absent when there was nobody else.
    let others: String?

    var id: String { callId }

    /// Whether this call had pictures. Anything that is not explicitly audio counts as video,
    /// which is what a row recorded before the service sent a kind was.
    var isVideo: Bool { kind != "audio" }
}

/// The envelope `GET /api/calls/history` answers with.
private struct CallHistory: Decodable {
    let calls: [RecentCall]
}

struct FamilyCall: Decodable, Identifiable, Equatable {
    struct Participant: Decodable, Equatable {
        let userId: String
        let displayName: String?
        let status: String
    }

    let id: String
    let callerId: String
    let callerName: String?
    let status: String
    /// `video` or `audio`. The service has always sent it; the app only ever asked for video.
    let kind: String?
    /// Whether this call has pictures.
    ///
    /// Anything that is not explicitly audio counts as video, because that is what an older
    /// row with no kind was, and drawing camera controls on a call that has none is a worse
    /// mistake than leaving them off a call that has one.
    var isVideo: Bool { kind != "audio" }
    /// The reader's own participation status, from `callsForUser` only.
    let myStatus: String?
    let createdAt: String
    let answeredAt: String?
    let participants: [Participant]?

    var isActive: Bool { status == "active" }
}

/// A family group and the members the service will name (`src/db.js:228-240`).
///
/// Members are filtered server-side to users who have signed in at least once, so
/// absence from this list means "never authenticated", not "not configured" — a
/// distinction worth keeping, because the two need different fixes.
struct FamilyGroup: Decodable, Identifiable {
    struct Member: Decodable {
        let id: String
        let displayName: String
    }

    let id: String
    let displayName: String
    let members: [Member]?
}

struct FamilyBootstrap: Decodable {
    let user: FamilyUser
    let contacts: [FamilyContact]
    let calls: [FamilyCall]
    let ongoingCalls: [FamilyCall]
    let groups: [FamilyGroup]?
}

/// `POST /api/calls`, `/respond` and `/join` all answer `{call, joinUrl}`; `joinUrl`
/// is absent when a call was declined (`src/server.js:289-291`).
struct JoinEnvelope: Decodable {
    let call: FamilyCall
    let joinUrl: String?
}

/// The service's error shape: `{error: {code, message}}` (`src/server.js:32-34`).
struct FamilyAPIError: Error, LocalizedError {
    let status: Int
    let code: String
    let message: String

    var errorDescription: String? { "HTTP \(status) \(code) — \(message)" }
}

/// `POST /api/devices/enrollment` → what this app made of the answer.
///
/// Not the route's own shape, which is an envelope of `enrollment` and `payload`: this is what the
/// screen that shows an invitation needs from it, assembled where the response is read so that no
/// view has to know how the route spells anything.
struct DeviceInvitation {
    /// When the code stops working, in the service's own spelling of an instant — the one
    /// `Reading` reads.
    let expiresAt: String

    /// The payload as the string a QR code carries.
    ///
    /// The service's fields, in the service's own names, untouched — because the reader of these
    /// bytes is not this device. It is `EnrollmentCode` on the *other* phone, which is deliberately
    /// tolerant of fields it does not know, and a payload rebuilt here from the parts this app
    /// happens to understand would drop exactly those on their way across.
    let code: String

    /// The token alone, for the phone whose camera cannot be pointed at the code.
    let token: String
}

// MARK: - The room, recovered from the join URL

/// Where to point the media engine, recovered from the `joinUrl`.
///
/// This is the decided route to the room. `callPublic` deliberately omits `roomId`
/// while all three routes that return media coordinates return a `joinUrl`
/// (`src/server.js:184`, `290`, `324`), and the backend validates that the URL it
/// builds carries `room === roomId` before handing it over
/// (`src/mirotalk.js:34-42`). Widening `callPublic` instead would expose the room id
/// on every call object the app ever sees, including ones it is not in.
///
/// The origin comes from the same URL rather than a second constant: the backend
/// rebuilds the join URL against `MIROTALK_EMBED_ORIGIN` (`src/config.js:65-68`,
/// `src/mirotalk.js:38-40`), so the host in the URL is the MiroTalk host and the
/// socket needs no separately configured origin.
struct JoinTarget: Equatable {
    let room: String
    let origin: URL
}

extension JoinTarget {
    init?(joinUrl: String) {
        guard
            let url = URL(string: joinUrl),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme,
            let host = components.host,
            let room = components.queryItems?.first(where: { $0.name == "room" })?.value,
            !room.isEmpty
        else { return nil }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = components.port
        guard let built = origin.url else { return nil }

        self.init(room: room, origin: built)
    }
}

// MARK: - Events

/// One server-sent event. The names are the ones the service actually emits
/// (`src/server.js:180`, `286-287`, `304-306`, `333-334`).
enum FamilyEvent: Equatable {
    case ready(userId: String)
    case incomingCall(FamilyCall)
    case callStatus(FamilyCall)
    case ongoingCall(FamilyCall)
    case presence(userId: String, online: Bool)
    case unrecognised(name: String)
    /// The stream ended or could not be established. Carried as an event rather than
    /// thrown because a dropped stream is a normal state to recover from.
    case failed(String)
}

// MARK: - Where the service is

/// The one place the Family Call deployment's address is written down.
///
/// Two clients dial it — the control plane directly, and the embedded node when it checks
/// that its carrier actually carries a request — and a second constant beside the first is
/// how a deployment detail drifts from the one thing that used it. The environment
/// override is the same one every instrument here uses, so a different host needs no edit.
enum FamilyCallService {
    /// The compiled default: this household's deployment. A build nobody has configured
    /// still works, which matters because this app belongs to the person using it rather
    /// than to an administrator.
    static let compiledDefault = URL(string: "https://qatar-vpn.tailea67b0.ts.net:8443")!

    /// Where the service is, in order of authority: the environment (how every measurement
    /// on this branch was taken against another host), then what someone typed in Settings,
    /// then the compiled default.
    ///
    /// Asked afresh on every request rather than captured at launch, so a change in
    /// Settings takes effect without a relaunch.
    static var baseURL: URL {
        if let value = ProcessInfo.processInfo.environment["CROSSBAR_BACKEND_URL"],
           let url = URL(string: value) {
            return url
        }
        if let stored = AppSettings.serviceAddress, let url = URL(string: stored) {
            return url
        }
        return compiledDefault
    }

    /// Whether an address can only ever mean "the machine reading it".
    ///
    /// `localhost`, `127.0.0.1` and `::1` say the same thing wherever they are read, and on
    /// a phone they can only ever name the phone.
    static func isLoopback(_ url: URL) -> Bool {
        switch url.host?.lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]": return true
        default: return false
        }
    }

    /// The origin a signalling socket should dial for this invitation.
    ///
    /// The invitation names the signalling host, which is the whole reason it carries one:
    /// the client and the backend cannot disagree about where to dial. But an invitation
    /// that names *loopback* cannot have meant this device's own loopback — a server that
    /// answered this app a moment ago is not inside this phone — so the address the app is
    /// already talking to is the only reading that makes sense.
    ///
    /// Without that rule the socket dials itself, and it fails in the one way that is
    /// hardest to see: the call still goes active at the server, both ends sit in a call
    /// that looks connected, and no media crosses because no two peers ever met. Measured
    /// on a test rig whose `PUBLIC_ORIGIN` was loopback, 2026-09-21 — 46 seconds of a call
    /// that neither end could hear.
    static func signallingOrigin(for invitation: URL) -> URL {
        guard isLoopback(invitation), !isLoopback(baseURL) else { return invitation }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? baseURL
    }
}

// MARK: - Client

/// The Family Call control plane, as a native client.
///
/// Identity is not a parameter. The service accepts `tailscale-user-login` only when
/// the request arrives from loopback (`src/identity.js`) and its listener refuses to
/// bind anywhere else (`src/config.js:59-62`), so a native client has no identity to
/// present and must traverse Serve, which injects the header. That was measured on the
/// device before this was written: without Serve the client has no identity to present.
///
/// This client sends **no `Origin` header**, deliberately. `checkOrigin`
/// (`src/server.js:97-105`) rejects only a header that is both present and
/// mismatched, so omitting it is what makes the POST routes reachable rather than
/// only the reads. Adding one would be self-inflicted: the app is not the public
/// origin and never will be.
///
/// A service that has turned device auth on wants a second thing beside the injected
/// header, and that is a session this device has earned with its own key. `DeviceAuth`
/// supplies it: the token rides along on every request, and a request is unchanged when
/// this device holds none — which is the private deployment, and the reason none of this
/// is a required parameter.
@MainActor
final class FamilyCallClient {
    /// Set by the owner after construction, because the owner cannot capture itself
    /// before it exists.
    var log: (String) -> Void = { _ in }

    /// The carriage every request leaves by.
    ///
    /// `.direct` until an owner sets it, which is how this client behaved before the
    /// embedded node existed: over whatever the system provides, the Tailscale app's
    /// tunnel included. `CallSession` sets it to the node's carrier before the first
    /// request, so the control plane goes down the loopback with the signalling socket
    /// and neither depends on another app being installed and signed in.
    ///
    /// The session is rebuilt when the transport is replaced rather than being read from
    /// the transport per request: what replaces it is a *new* node after a rebuild, whose
    /// loopback is a different address, and a session holds the proxy it was built with.
    var transport: CallTransport = .direct {
        didSet {
            session = transport.session()
            // The device-auth routes travel by the same carrier as everything else. In the
            // embedded node's case the service is reachable over the node's loopback and
            // nowhere else, so a session minted over the system route would be one the
            // control plane could then not use — and the failure would arrive as a call
            // that could not be placed.
            DeviceAuth.shared.transport = transport
        }
    }

    private var session = URLSession(configuration: .default)

    /// Where the service is. One constant, shared with the node's carrier check.
    private var baseURL: URL { FamilyCallService.baseURL }

    /// Built through `URLComponents` rather than `appendingPathComponent` so that a
    /// caller-supplied override with a path cannot silently change where a request
    /// lands.
    private func url(_ path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/" + path
        return components.url!
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return authorized(request)
    }

    /// Adds the session this device holds, when it holds one.
    ///
    /// Additive by construction: a device that was never enrolled has no token, and this
    /// changes nothing about the request it is handed. That is deliberate rather than
    /// incidental — the private deployment requires no device auth, and neither does any
    /// service without `/api/auth/*` routes, so the requests this app has always made must
    /// go out unchanged.
    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let token = DeviceAuth.shared.sessionToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        return request
    }

    /// One request, re-authenticating once if the service refuses the session.
    ///
    /// Two kinds of staleness meet here. A session past 80% of its life is replaced before
    /// the request goes out, so the request in flight is not the one that finds out. A 401
    /// is the service disagreeing about the token in hand — the app's own opinion of its
    /// age is then beside the point — so one exchange is attempted and the request is sent
    /// again.
    ///
    /// One, not a loop: a service that refuses a freshly minted token is refusing this
    /// device, and repeating would only hide that behind retries. When the session cannot
    /// be renewed the original 401 is returned, which is the answer the caller would have
    /// got before device identity existed.
    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await DeviceAuth.shared.ensureSession()
        let (data, response) = try await session.data(for: authorized(request))
        guard (response as? HTTPURLResponse)?.statusCode == 401,
              await DeviceAuth.shared.ensureSession(forcing: true) else {
            return (data, response)
        }
        return try await session.data(for: authorized(request))
    }

    /// The same once-only re-authentication for the event stream.
    ///
    /// Separate from `data(for:)` because a stream is opened rather than awaited: the bytes
    /// have to come back unconsumed for the reader in `events()` to walk them.
    private func stream(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        await DeviceAuth.shared.ensureSession()
        let (bytes, response) = try await session.bytes(for: authorized(request))
        guard (response as? HTTPURLResponse)?.statusCode == 401,
              await DeviceAuth.shared.ensureSession(forcing: true) else {
            return (bytes, response)
        }
        return try await session.bytes(for: authorized(request))
    }

    @discardableResult
    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        log("\(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")")
        let (data, response) = try await data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard (200..<300).contains(code) else {
            throw refusal(status: code, data: data)
        }

        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            log("  -> HTTP \(code), \(data.count) bytes")
            return decoded
        } catch {
            log("  -> HTTP \(code) but the body did not decode: \(error)")
            throw error
        }
    }

    /// The service's refusal, as the reason the product would show: its own message when it wrote
    /// one, and only what this app could see when it did not.
    ///
    /// One place, because two routes read a body that refused — the typed reads, and the invitation,
    /// which keeps its payload as bytes — and a refusal has to read the same way whichever route met
    /// it. The words belong to the service rather than to either of them.
    private func refusal(status: Int, data: Data) -> FamilyAPIError {
        let shape = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let error = shape["error"] as? [String: Any] else {
            let apiError = FamilyAPIError(status: status, code: "UNKNOWN", message: "\(data.count) bytes")
            log("  -> HTTP \(status)")
            return apiError
        }

        let apiError = FamilyAPIError(
            status: status,
            code: error["code"] as? String ?? "UNKNOWN",
            message: error["message"] as? String ?? "No message"
        )
        log("  -> \(apiError.localizedDescription)")
        return apiError
    }

    // MARK: Reads

    /// `GET /api/session` — the one route reachable without an enrolled identity.
    @discardableResult
    func checkSession() async throws -> (authenticated: Bool, configured: Bool, name: String?) {
        // Logged before the request as well as after. A request that never completes
        // otherwise leaves no trace at all, which is indistinguishable from one that
        // was never attempted — and that ambiguity already cost a run here.
        log("GET api/session (requesting)")
        let (data, response) = try await data(for: request("GET", "api/session"))
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let shape = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let identity = shape["identity"] as? [String: Any]
        let name = identity?["name"] as? String
        log("GET api/session -> HTTP \(code) authenticated=\(shape["authenticated"] as? Bool ?? false) name=\(name ?? "none")")
        return (shape["authenticated"] as? Bool ?? false, shape["configured"] as? Bool ?? false, name)
    }

    /// `GET /api/push/config` — whether the service can ring a phone whose app is
    /// closed at all.
    ///
    /// Worth asking explicitly: ringing is delivered two different ways, and only one
    /// of them survives the app being backgrounded. An open client gets `incoming-call`
    /// over the event stream; a closed one needs W3C Web Push, which needs a VAPID key
    /// on the server (`src/config.js:83-86`) and a subscription per device. If this
    /// reports disabled, a call only ever reaches someone who happens to have the app
    /// open, and that is a product-level fact rather than a detail.
    @discardableResult
    func pushConfig() async throws -> (enabled: Bool, publicKeyLength: Int) {
        let (data, response) = try await data(for: request("GET", "api/push/config"))
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let shape = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let enabled = shape["enabled"] as? Bool ?? false
        let key = shape["publicKey"] as? String ?? ""
        log("GET api/push/config -> HTTP \(code) pushEnabled=\(enabled) publicKeyLength=\(key.count)")
        return (enabled, key.count)
    }

    /// `GET /api/bootstrap` — identity, contacts and any call already in progress.
    ///
    /// Everything the app needs to draw its first screen, and it rings nobody, which
    /// is why it is the read this instrument verifies against production.
    func bootstrap() async throws -> FamilyBootstrap {
        let result = try await send(request("GET", "api/bootstrap"), as: FamilyBootstrap.self)
        log("  bootstrap: \(result.contacts.count) contacts, \(result.ongoingCalls.count) ongoing, \(result.calls.count) open")
        // Named rather than counted: the whole question this instrument exists to
        // answer is who can actually be called, and a count cannot say whether the
        // person you intend to ring is on the list. An asterisk means they currently
        // hold an event stream, so they are reachable now.
        let names = result.contacts.map { $0.online ? "\($0.displayName)*" : $0.displayName }
        log("  contacts: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        for group in result.groups ?? [] {
            let members = (group.members ?? []).map(\.displayName)
            log("  group \(group.displayName): \(members.isEmpty ? "none signed in" : members.joined(separator: ", "))")
        }
        return result
    }

    /// `GET /api/calls/history` — what has finished, newest first.
    ///
    /// The read the Recents screen is built on. `/api/calls` answers only what is ringing or
    /// active, deliberately, because that is what a client needs in order to rejoin one; this
    /// is the other question, asked of the same records.
    func callHistory() async throws -> [RecentCall] {
        try await send(request("GET", "api/calls/history"), as: CallHistory.self).calls
    }

    /// `GET /api/calls/:id` — used to re-read state after an event stream drops,
    /// since the stream has no replay.
    func call(id: String) async throws -> FamilyCall {
        let envelope = try await send(request("GET", "api/calls/\(id)"), as: CallOnlyEnvelope.self)
        return envelope.call
    }

    // MARK: Writes

    /// `POST /api/calls` — **this rings real phones.** Rate-limited to 6 per minute
    /// per user (`src/server.js:170`).
    ///
    /// The service has taken a `kind` since it was written and the app never sent one, so every
    /// call it has placed arrived as a video call. It is sent now.
    func createCall(inviteeIds: [String], video: Bool) async throws -> JoinEnvelope {
        let envelope = try await send(
            request("POST", "api/calls", body: [
                "inviteeIds": inviteeIds,
                "kind": video ? "video" : "audio",
            ]),
            as: JoinEnvelope.self
        )
        log("  created call \(envelope.call.id) status=\(envelope.call.status)")
        return envelope
    }

    /// `POST /api/calls/:id/respond`. Only `invited` participants can answer, once.
    func respond(callId: String, accepted: Bool) async throws -> JoinEnvelope {
        let envelope = try await send(
            request("POST", "api/calls/\(callId)/respond", body: ["response": accepted ? "accepted" : "declined"]),
            as: JoinEnvelope.self
        )
        log("  responded \(accepted ? "accepted" : "declined") to \(callId), status=\(envelope.call.status)")
        return envelope
    }

    /// `POST /api/calls/:id/join` — valid while the call is active, and while ringing
    /// for a participant who has already accepted (`src/server.js:317-320`).
    func join(callId: String) async throws -> JoinEnvelope {
        let envelope = try await send(request("POST", "api/calls/\(callId)/join"), as: JoinEnvelope.self)
        log("  joined \(callId), status=\(envelope.call.status)")
        return envelope
    }

    /// `POST /api/calls/:id/end`. Call-wide: the backend has no per-participant
    /// leave, so this ends it for everyone, which matters for four-person calls.
    func end(callId: String) async throws {
        let envelope = try await send(request("POST", "api/calls/\(callId)/end"), as: CallOnlyEnvelope.self)
        log("  ended \(callId), status=\(envelope.call.status)")
    }

    /// `POST /api/devices/push-token` — where the service should send this device's calls.
    ///
    /// The route that makes a closed app ring. A call reaches an open client over the event
    /// stream; a client with no stream open has nothing watching for one, and this is the only
    /// address the service is given that it can use by itself.
    ///
    /// Device-authenticated like every other route from an enrolled device, and the device id is
    /// in the body beside the token for the reason the session cannot be trusted to imply it:
    /// the token belongs to this **device** rather than to the person, and a person with two
    /// phones has two of them. Which device is asking comes from the signature; which device the
    /// token is for is what the body says.
    ///
    /// `environment` and `kind` are not defaulted here. The service reads an omitted `kind` as
    /// `alert`, which is the right reading of an older client and the wrong one for this: a VoIP
    /// token filed as an alert token is a phone that is never rung for a call. And the
    /// environment is the one whose APNs minted the token — the wrong one is refused at APNs
    /// with no one told, so it is a parameter rather than something guessed at here.
    @discardableResult
    func uploadPushToken(deviceId: String, token: String, environment: String, kind: String) async throws -> Bool {
        let ack = try await send(
            request("POST", "api/devices/push-token", body: [
                "deviceId": deviceId,
                "token": token,
                "environment": environment,
                "kind": kind,
            ]),
            as: PushTokenAck.self
        )
        log("  filed this device's \(kind) push token for the \(environment) environment: saved=\(ack.saved)")
        return ack.saved
    }

    /// `POST /api/devices/enrollment` — an invitation for one more device of this person's.
    ///
    /// The body is empty and the invitee is not a parameter, both deliberately: whose invitation
    /// this is comes from the session, so a device can only ever invite the person it belongs to
    /// and a field naming somebody else would be a field whose only use is refusing it. The
    /// lifetime is the service's as well — it answers the instant the code dies rather than a
    /// duration it lets the client keep — and so is how many of these a person may ask for in a
    /// minute. Nothing on this side decides either, which is what makes the screen honest about the
    /// code it is handed.
    ///
    /// The payload is read out as the string a QR code carries rather than decoded into a type: it
    /// is spent on the other device, by `EnrollmentCode`, which is tolerant of fields it does not
    /// know — see `DeviceInvitation.code`.
    func createDeviceInvitation() async throws -> DeviceInvitation {
        log("POST api/devices/enrollment (requesting)")
        let (data, response) = try await data(for: request("POST", "api/devices/enrollment", body: [:]))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard (200..<300).contains(status) else {
            throw refusal(status: status, data: data)
        }

        let shape = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let enrollment = shape["enrollment"] as? [String: Any],
              let expiresAt = enrollment["expiresAt"] as? String,
              let payload = shape["payload"] as? [String: Any],
              let token = (payload["enrollment_token"] as? String ?? payload["token"] as? String),
              !token.isEmpty,
              let code = Self.jsonText(payload) else {
            log("  -> HTTP \(status) but there was no invitation in the body")
            throw FamilyAPIError(
                status: status,
                code: "NO_PAYLOAD",
                message: "The service answered without an invitation to show."
            )
        }

        log("  -> HTTP \(status), expires \(expiresAt)")
        return DeviceInvitation(expiresAt: expiresAt, code: code, token: token)
    }

    /// A JSON object as the text a QR code carries: the object's own fields, no more and no fewer.
    ///
    /// Sorted, so the same invitation always draws the same code. Nothing reads the order — the
    /// reader is `EnrollmentCode`, which looks fields up by name — but a code that changed shape
    /// between two draws of the same payload would make a comparison of the two meaningless.
    private static func jsonText(_ shape: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: shape, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: The event stream

    /// `GET /api/events`.
    ///
    /// The stream carries no event ids and no replay (`src/server.js:236-255`), and
    /// the server offsets that with a 20-second heartbeat comment. Two consequences
    /// are load-bearing rather than incidental: a reconnect cannot recover what was
    /// missed, so state must be re-read from `/api/bootstrap` or `/api/calls/:id`
    /// after any drop; and the heartbeat is what keeps an idle connection inside
    /// URLSession's own idle timeout.
    nonisolated func events() -> AsyncStream<FamilyEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                do {
                    var request = self.request("GET", "api/events")
                    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
                    // Above the server's 20s heartbeat, so an idle stream is not
                    // mistaken for a dead one.
                    request.timeoutInterval = 120

                    let (bytes, response) = try await self.stream(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    self.log("GET api/events -> HTTP \(code)")
                    guard code == 200 else {
                        continuation.yield(.failed("HTTP \(code)"))
                        continuation.finish()
                        return
                    }

                    // Deliberately not `bytes.lines`: that sequence omits empty lines,
                    // and the empty line is what *dispatches* an event in SSE. Using it
                    // produced a stream that connected, reported HTTP 200, received
                    // bytes promptly, and yielded no event at all — the failure mode
                    // this project has now hit repeatedly, where a healthy-looking
                    // connection is indistinguishable from a working one.
                    var lineBytes: [UInt8] = []
                    var eventName = ""
                    var dataLines: [String] = []

                    for try await byte in bytes {
                        guard byte == 0x0A else {
                            lineBytes.append(byte)
                            continue
                        }

                        var line = String(decoding: lineBytes, as: UTF8.self)
                        lineBytes.removeAll(keepingCapacity: true)
                        if line.hasSuffix("\r") { line.removeLast() }

                        if line.isEmpty {
                            // The dispatch point.
                            if !dataLines.isEmpty,
                               let event = FamilyEvent(name: eventName, data: dataLines.joined(separator: "\n")) {
                                continuation.yield(event)
                            }
                            eventName = ""
                            dataLines = []
                            continue
                        }

                        if line.hasPrefix(":") { continue } // heartbeat comment
                        if let value = line.removingPrefix("event:") {
                            eventName = value.trimmed
                        } else if let value = line.removingPrefix("data:") {
                            // Multi-line data joins with newlines, per the SSE spec.
                            dataLines.append(value.trimmed)
                        }
                        // `id:` and `retry:` are not emitted by this service; the stream
                        // has neither event ids nor replay, so there is nothing to use.
                    }
                    if !dataLines.isEmpty,
                       let event = FamilyEvent(name: eventName, data: dataLines.joined(separator: "\n")) {
                        continuation.yield(event)
                    }
                    continuation.yield(.failed("stream ended"))
                    continuation.finish()
                } catch {
                    // Cancellation is how this stream is meant to end; reporting it
                    // as a failure would make a deliberate stop look like a fault.
                    if !Task.isCancelled {
                        continuation.yield(.failed(error.localizedDescription))
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// `GET /api/calls/:id` and `/end` answer `{call}` with no `joinUrl`.
private struct CallOnlyEnvelope: Decodable {
    let call: FamilyCall
}

/// `POST /api/devices/push-token` answers `{"saved": true}`.
///
/// Decoded rather than assumed from the status. The status is about the request; this field is
/// about the token, and the log line that reports it is the only place on the device that says
/// whether the service kept the address it was given.
private struct PushTokenAck: Decodable {
    let saved: Bool
}

// MARK: - Decoding the event stream

private extension FamilyEvent {
    init?(name: String, data: String) {
        guard let payload = data.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        switch name {
        case "ready":
            guard let shape = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let userId = shape["userId"] as? String
            else { return nil }
            self = .ready(userId: userId)
        case "incoming-call", "call-status", "ongoing-call":
            // These three carry `callPublic` directly, not wrapped in an envelope.
            guard let call = try? decoder.decode(FamilyCall.self, from: payload) else { return nil }
            switch name {
            case "incoming-call": self = .incomingCall(call)
            case "call-status": self = .callStatus(call)
            default: self = .ongoingCall(call)
            }
        case "presence":
            guard let shape = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let userId = shape["userId"] as? String
            else { return nil }
            self = .presence(userId: userId, online: shape["online"] as? Bool ?? false)
        default:
            self = .unrecognised(name: name)
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
