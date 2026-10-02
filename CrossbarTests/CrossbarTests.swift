//
//  CrossbarTests.swift
//  CrossbarTests
//
//  Created by Azzaam Chaudhry on 9/16/26.
//

import Foundation
import Testing
@testable import Crossbar

/// The app's whole reading of a VoIP push payload.
///
/// `PushedCall` is a pure function of the dictionary PushKit hands over, and it decides the two
/// things that matter before anything else in the push path happens: which call this app reports
/// to CallKit, and whether a payload it cannot name is refused instead of guessed at. The
/// namespaced shape is the relay's (`docs/PUSH_RELAY_INTEGRATION.md` §3, produced by
/// `src/apns/payload.ts`); the flat one is what a deployment's own APNs path still sends.
struct PushedCallTests {
    /// The relay's payload, field for field.
    ///
    /// Every field can be omitted, which is how a payload missing one is built: the decoder has to
    /// refuse that rather than fall back to a reading the service did not send.
    private static func relayed(
        v: Any = 1,
        type: String = "incoming_call",
        callID: Any? = "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
        callerID: Any? = "per_ayesha",
        callerName: Any? = "Ayesha",
        hasVideo: Any? = true
    ) -> [AnyHashable: Any] {
        var service: [AnyHashable: Any] = [
            "v": v,
            "type": type,
            "installation_id": "ins_1",
        ]
        if let callID { service["call_id"] = callID }
        if let callerID { service["caller_id"] = callerID }
        if let callerName { service["caller_name"] = callerName }
        if let hasVideo { service["has_video"] = hasVideo }
        return ["aps": ["content-available": 1], "crossbar": service]
    }

    private static let relayedCallID = UUID(uuidString: "3f2504e0-4f89-11d3-9a0c-0305e82c3301")!

    /// The payload the relay actually sends becomes a call, with the call's own id.
    @Test func relayPayloadNamesTheCall() throws {
        let pushed = try #require(PushedCall(payload: Self.relayed()))

        #expect(pushed.id == Self.relayedCallID)
        #expect(pushed.callerName == "Ayesha")
        #expect(pushed.video)
    }

    /// `has_video` decides which layout the lock screen draws, so it is read rather than defaulted.
    @Test func relayPayloadWithoutVideoIsAudioOnly() throws {
        let pushed = try #require(PushedCall(payload: Self.relayed(hasVideo: false)))

        #expect(!pushed.video)
    }

    /// The shape that was here before the relay, unchanged: a deployment speaking to APNs itself.
    @Test func flatPayloadNamesTheCall() throws {
        let pushed = try #require(PushedCall(payload: [
            "callId": "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
            "caller": "Ayesha",
            "kind": "audio",
        ]))

        #expect(pushed.id == Self.relayedCallID)
        #expect(pushed.callerName == "Ayesha")
        #expect(!pushed.video)
    }

    /// The payload as it actually arrives: the relay's JSON, parsed by `JSONSerialization`.
    ///
    /// PushKit hands over the APNs body already parsed that way, so `v` and `has_video` reach the
    /// decoder as `NSNumber`s rather than Swift's `Int` and `Bool` — and a decoder that read only
    /// the Swift spellings would refuse every real push while passing every test built from a
    /// Swift literal.
    @Test func relayJSONNamesTheCall() throws {
        let json = """
        {"aps":{"content-available":1},"crossbar":{"v":1,"type":"incoming_call",\
        "installation_id":"ins_1","call_id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301",\
        "caller_id":"per_ayesha","caller_name":"Ayesha","has_video":true}}
        """
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any]
        )
        let pushed = try #require(PushedCall(payload: payload))

        #expect(pushed.id == Self.relayedCallID)
        #expect(pushed.callerName == "Ayesha")
        #expect(pushed.video)
    }

    /// A version this build does not know is the service saying its fields may mean something
    /// else, so the payload is refused rather than read as version 1.
    @Test func payloadOfAnUnknownVersionIsRefused() {
        #expect(PushedCall(payload: Self.relayed(v: 2)) == nil)
    }

    /// The topic carries one kind of message today; the check is what keeps a later one from
    /// arriving as a call.
    @Test func payloadOfAnUnknownTypeIsRefused() {
        #expect(PushedCall(payload: Self.relayed(type: "call_ended")) == nil)
    }

    /// No `call_id` at all — nothing to report a call by.
    @Test func payloadWithoutACallIDIsRefused() {
        #expect(PushedCall(payload: Self.relayed(callID: nil)) == nil)
    }

    /// A `call_id` that is not a UUID cannot become a CallKit call: the answer, the end and the
    /// join all name the call by that identity, and one this app cannot spell is one it cannot
    /// hand over.
    @Test func payloadWithANonUUIDCallIDIsRefused() {
        #expect(PushedCall(payload: Self.relayed(callID: "call-17")) == nil)
    }

    /// Neither shape: a payload with no `crossbar` and no flat `callId`.
    @Test func payloadWithNeitherShapeIsRefused() {
        #expect(PushedCall(payload: ["aps": ["content-available": 1]]) == nil)
    }
}

/// Where the two paths that can ring a phone for the same call meet.
///
/// The backend sends both a VoIP push and a realtime `incoming-call` for a native device
/// (`docs/PUSH_RELAY_INTEGRATION.md` §8) and mints one id for the call with
/// `crypto.randomUUID()`, so both carry the same value and both converge on
/// `CallKitController.reportIncoming` — the push from `AppDelegate`, the event from
/// `CallSession.ring`. These tests hold that convergence to what makes the deduplication exact.
struct CallReportDedupTests {
    /// The push's id and the stream's id are one UUID even when the two spellings differ in case.
    ///
    /// This is the key the report is deduplicated on, so "exact" here means the UUID and not the
    /// string: `UUID(uuidString:)` is what both paths go through, and it is case-insensitive.
    @Test func thePushAndTheEventStreamNameTheSameCallKey() throws {
        let streamed = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
        let pushed = try #require(PushedCall(payload: [
            "crossbar": [
                "v": 1,
                "type": "incoming_call",
                "installation_id": "ins_1",
                "call_id": streamed.uppercased(),
                "caller_id": "per_ayesha",
                "caller_name": "Ayesha",
                "has_video": false,
            ],
        ]))

        #expect(pushed.id == UUID(uuidString: streamed))
    }

    /// Reporting the same call twice reaches CallKit once.
    ///
    /// What the second report produces from the outside is the line the controller writes when it
    /// recognises its own earlier report — `reportIncoming` returns nothing and the system's
    /// answer is a refusal (`callUUIDAlreadyExists`) that the app never wants to see.
    @MainActor
    @Test func aCallReportedByBothPathsReachesTheSystemOnce() {
        let kit = CallKitController()
        var lines: [String] = []
        kit.onLog = { lines.append($0) }
        let callID = UUID()

        kit.reportIncoming(callID: callID, callerName: "Ayesha", video: true)
        #expect(lines.isEmpty)

        kit.reportIncoming(callID: callID, callerName: "Ayesha", video: true)
        #expect(lines.count == 1)
        #expect(lines[0].contains(callID.uuidString.prefix(8)))
    }
}

/// What the app makes of the deployment's answer about a push token.
///
/// A VoIP token is filed in two places — the deployment's own row and the relay that actually
/// rings the phone — and the route answers for both. A client that read `saved` alone cleared a
/// token the relay had refused, leaving a phone that could not be rung with nothing saying so
/// (REL-RELAY-01); these hold the reading of the answered contract, and the one thing that follows
/// from it, which is which verdicts leave the token pending.
///
/// The bodies are literal, and deliberately: they are the contract as the deployment writes it
/// (`POST /api/devices/push-token`, `docs/PUSH_RELAY_INTEGRATION.md` §5), so a renamed field fails
/// here rather than on a phone that has stopped ringing.
@MainActor
struct PushTokenFilingTests {
    private static func answered(_ json: String) throws -> PushTokenAck {
        try JSONDecoder().decode(PushTokenAck.self, from: Data(json.utf8))
    }

    /// A deployment that could not reach its relay leaves the token pending, because it is the
    /// relay that rings the phone and this is the case that actually happens: an installation not
    /// yet configured for the relay answers exactly like this, and so does a relay that is down,
    /// rate-limiting or answering 5xx.
    @Test func aRetryableRelayOutcomeKeepsTheTokenPending() throws {
        let receipt = try Self.answered("""
        {"saved":true,"relay":{"configured":false,"ok":false,"outcome":"retryable","status":0,"error":"not_configured","retryAfterSeconds":null}}
        """)

        #expect(receipt.saved, "the deployment's own row was written — that is not the question")
        #expect(receipt.relay?.configured == false)
        guard case .retry(let reason) = receipt.verdict else {
            Issue.record("a relay that does not hold the token must be retried, got \(receipt.verdict)")
            return
        }
        #expect(reason.contains("not_configured"))

        var pending = PendingPushTokens()
        pending.hold("a1b2c3", kind: "voip")
        let stillPending = pending.resolve(receipt.verdict, kind: "voip")
        #expect(stillPending)
        #expect(pending["voip"] == "a1b2c3", "the token must still be waiting, or the phone never rings")
    }

    /// A relay that will not change its answer ends the attempts and drops the token.
    ///
    /// `409 token_conflict` is the permanent one: another installation owns the relay's token row
    /// and only that owner — or the relay's operator — can release it, so asking again asks a
    /// question whose answer cannot change.
    @Test func aPermanentRelayOutcomeIsNotRetried() throws {
        let receipt = try Self.answered("""
        {"saved":true,"relay":{"configured":true,"ok":false,"outcome":"permanent","status":409,"error":"token_conflict","retryAfterSeconds":null}}
        """)

        #expect(receipt.verdict == .permanent(code: "token_conflict"))

        var pending = PendingPushTokens()
        pending.hold("a1b2c3", kind: "voip")
        let stillPending = pending.resolve(receipt.verdict, kind: "voip")
        #expect(!stillPending)
        #expect(pending.isEmpty, "a token the relay will never take must not be offered again")
    }

    /// The token the relay holds is done with — and so is the alert token, which the relay is
    /// never asked about.
    ///
    /// The alert token's answer carries no `relay` at all, because the relay rings phones and
    /// sends nothing else: that absence is the contract, not a missing field, and it must not be
    /// read as a refusal.
    @Test func aTokenTheRelayHoldsIsFiled() throws {
        let relayed = try Self.answered("""
        {"saved":true,"relay":{"configured":true,"ok":true,"outcome":"saved","status":200,"error":null,"retryAfterSeconds":null}}
        """)
        let alert = try Self.answered(#"{"saved":true}"#)

        #expect(relayed.verdict == .filed)
        #expect(alert.verdict == .filed)

        var pending = PendingPushTokens()
        pending.hold("a1b2c3", kind: "voip")
        pending.resolve(relayed.verdict, kind: "voip")
        #expect(pending.isEmpty)
    }
}

/// What the app does with the call a push named, once the service has been heard from.
///
/// The report to CallKit may not wait for the network — iOS ends an app that takes a VoIP push and
/// reports nothing — so a push can put a call on the lock screen before anything has asked the
/// service whether it has one. The load that follows the report is where that question is
/// answered, and there are four answers: ring the pushed call, rejoin it, end it, or — when no
/// push named anything — ring whatever invitation the service lists.
@MainActor
struct PushedCallReconciliationTests {
    private static let pushed = UUID(uuidString: "3f2504e0-4f89-11d3-9a0c-0305e82c3301")!
    private static let other = UUID(uuidString: "9c858901-8a57-4791-81fe-4c455b099bc9")!

    private static func call(
        _ id: UUID,
        caller: String = "per_ayesha",
        status: String = "ringing",
        myStatus: String? = "invited",
        participants: [Call.Participant]? = nil
    ) -> Call {
        Call(id: id.uuidString, callerId: caller, callerName: "Ayesha", status: status,
             kind: "video", myStatus: myStatus, createdAt: "2026-09-27T15:00:00.000Z",
             answeredAt: nil, participants: participants)
    }

    /// A call the service does not have is ended — not answered, and not replaced by whatever else
    /// happens to be open.
    ///
    /// The replaced-by-another case is the one that used to happen: with nothing matching the
    /// push's id, the app rang the *first* invitation in the list, so an unrelated call appeared on
    /// the system UI while the call the push announced went on ringing with nothing behind it. With
    /// nothing open at all, nothing happened, and that ring had no end until somebody answered or
    /// declined it.
    @Test func aCallTheServiceDoesNotHaveEndsRatherThanRingingAnother() {
        #expect(CallSession.arrival(pushed: Self.pushed, myUserId: "per_me", deviceCallID: nil,
                                    calls: [Self.call(Self.other)], ongoing: []) == .unknown)
        #expect(CallSession.arrival(pushed: Self.pushed, myUserId: "per_me", deviceCallID: nil,
                                    calls: [], ongoing: []) == .unknown)
    }

    /// The call the push named is the one that rings, by its identity rather than by its place in
    /// the list.
    @Test func theCallThePushNamedIsRungByIdentity() {
        let unrelated = Self.call(Self.other)
        let named = Self.call(Self.pushed)

        #expect(CallSession.arrival(pushed: Self.pushed, myUserId: "per_me", deviceCallID: nil,
                                    calls: [unrelated, named], ongoing: []) == .invited(named))
    }

    /// An active call is rejoined only when it is the call **this device** joined.
    ///
    /// Membership is not enough and never was: the service's identity is a person, so a call
    /// answered on another phone reads as active and this person's on all of them, and a device
    /// that rejoined on that basis is how an Xcode preview appeared as a participant in a live call
    /// (2026-09-18). So a pushed call that is active, this person's, and a *different* call from
    /// the one this device joined is ended like any other call the service cannot place here.
    @Test func anActiveCallIsRejoinedOnlyWhenThisDeviceJoinedIt() {
        let active = Self.call(Self.pushed, status: "active", myStatus: "joined",
                               participants: [.init(userId: "per_me", displayName: "Me", status: "joined")])

        #expect(CallSession.arrival(pushed: Self.pushed, myUserId: "per_me",
                                    deviceCallID: Self.pushed.uuidString,
                                    calls: [], ongoing: [active]) == .ongoing(active))
        #expect(CallSession.arrival(pushed: Self.pushed, myUserId: "per_me",
                                    deviceCallID: Self.other.uuidString,
                                    calls: [], ongoing: [active]) == .unknown)
        #expect(CallSession.arrival(pushed: Self.pushed, myUserId: "per_me", deviceCallID: nil,
                                    calls: [], ongoing: [active]) == .unknown)
    }

    /// With no push, an invitation the service lists still rings — the launch-into-a-waiting-call
    /// path, which is not what a push decides and must survive the reconciliation above.
    @Test func withoutAPushTheOpenInvitationStillStands() {
        #expect(CallSession.arrival(pushed: nil, myUserId: "per_me", deviceCallID: nil,
                                    calls: [Self.call(Self.other)], ongoing: []) == .unpushed)
    }
}

/// What a VoIP push does when this app is already carrying a call.
///
/// The report to CallKit cannot be skipped — iOS ends an app that takes a VoIP push and reports
/// nothing, and stops delivering pushes to an app in the habit of it — so a second call arriving
/// during another one was reported and then forgotten: `reportPushedCall` returned as soon as the
/// phase already held a call, and `adopt`'s reconciliation returns on the same condition. The
/// system was left showing a ringing call this app had no media, no screen and no answer path for.
/// These hold what CallKit is told, because that is the observable the defect turned on: the pushed
/// call is reported (iOS requires it) and then ended, `endedCalls` names exactly it and never the
/// call that is on screen, and no load is asked for while a call is being carried. The one thing
/// that must never happen is an end against the call the person is on, from a redelivered wake for
/// that same call.
@MainActor
struct PushedReportWhileBusyTests {
    private static let onScreen = UUID(uuidString: "3f2504e0-4f89-11d3-9a0c-0305e82c3301")!
    private static let second = UUID(uuidString: "9c858901-8a57-4791-81fe-4c455b099bc9")!

    /// A different call while one is on screen ends in exactly one end, and it names the pushed
    /// call: the one on screen is never in the list, which is the whole of what keeps the person's
    /// live call alive.
    @Test func theSecondCallIsTheOneCallKitIsToldToEnd() {
        let plan = CallSession.pushedReportPlan(pushed: Self.second, onScreen: Self.onScreen,
                                               busy: true)

        #expect(plan.endedCalls == [Self.second])
        #expect(!plan.endedCalls.contains(Self.onScreen),
                "ending the call on screen would take down the call the person is on")
        #expect(!plan.reconciles, "and a load would take that call's screen down and put it back")
    }

    /// The same call heard twice is left alone. The relay replays a wake it has already sent within
    /// the day and APNs redelivers, so this is ordinary rather than a fault — CallKit is told to end
    /// nothing, and the live ring stands.
    @Test func aReplayedPushForTheCallOnScreenEndsNothing() {
        let plan = CallSession.pushedReportPlan(pushed: Self.onScreen, onScreen: Self.onScreen,
                                               busy: true)

        #expect(plan.endedCalls.isEmpty)
        #expect(!plan.reconciles)
    }

    /// Nothing on screen: no end, and the load that reconciles the push with the service — the
    /// path this decision must not take away from the ordinary case.
    @Test func aPushWithNothingOnScreenEndsNothingAndStillReconciles() {
        let plan = CallSession.pushedReportPlan(pushed: Self.onScreen, onScreen: nil, busy: false)

        #expect(plan.endedCalls.isEmpty)
        #expect(plan.reconciles)
    }

    /// A call whose id is not a UUID is on screen with no CallKit id of its own, so a push is still
    /// a second call and must not be read as an empty screen.
    @Test func aPushWhileAnUnreportableCallIsOnScreenIsStillEnded() {
        let plan = CallSession.pushedReportPlan(pushed: Self.second, onScreen: nil, busy: true)

        #expect(plan.endedCalls == [Self.second])
    }
}

/// What the person is told about a phone the relay will not ring.
///
/// `409 token_conflict` is permanent: the relay's token row has an owner, the token leaves
/// `PendingPushTokens`, and nothing asks again until this process next launches. The sentence about
/// it used to live in `notice` — which every load and refresh clears — so from the first load after
/// the refusal the phone was unringable with nothing on screen saying so. These hold the durable
/// reading instead: the words are derived from the refusals the session publishes, so they survive
/// the answers a load produces on its way past, and go away at the one moment the condition does.
@MainActor
struct PushTokenRefusalNoticeTests {
    /// The refusal is said, a load that cannot reach the relay does not take it away, and filing
    /// the token does.
    ///
    /// The middle step is a load: `fileHeldPushTokens` asks the deployment again once every load
    /// settles, and a deployment that cannot reach its relay answers `retry` — the case the token
    /// path already treats as "ask again later", and here also the case the sentence must survive.
    @Test func aRefusalSurvivesTheAnswerALoadGetsAndStopsWhenTheTokenIsFiled() {
        var refusals = PushTokenRefusals()
        #expect(refusals.sentence == nil)

        refusals.apply(.permanent(code: "token_conflict"), kind: "voip")
        #expect(refusals.sentence?.contains("voip") == true)
        #expect(refusals.sentence?.contains("token_conflict") == true)

        refusals.apply(.retry("the service did not answer"), kind: "voip")
        #expect(refusals.sentence?.contains("token_conflict") == true,
                "a load that could not reach the relay is not an answer about the token")

        refusals.apply(.filed, kind: "voip")
        #expect(refusals.isEmpty)
        #expect(refusals.sentence == nil, "the phone can be rung again, so there is nothing to say")
    }

    /// The two token kinds are independent, and only the refused one is described: filing the alert
    /// token says nothing about whether the VoIP token — the one the relay rings the phone with —
    /// is still refused.
    @Test func filingOneKindDoesNotSilenceTheOther() throws {
        var refusals = PushTokenRefusals()
        refusals.apply(.permanent(code: "token_conflict"), kind: "voip")
        refusals.apply(.filed, kind: "alert")

        let sentence = try #require(refusals.sentence)
        #expect(sentence.contains("voip (token_conflict)"))
        #expect(!sentence.contains("alert"))
    }
}

/// What the signalling socket does about a drop, which is what a call's media is carried by.
///
/// A network change takes the socket with it, and the event stream already reconnects through one:
/// a failure count that climbs, a wait that doubles up to a cap, and a person-visible state while
/// it is down. The socket copies that curve rather than inventing a second one, and adds the thing
/// the stream deliberately does not have — an end. The stream may retry for the life of the app,
/// because the phone has to be able to ring again; a call with no socket has no peers and no media,
/// and must not sit in `phase=inCall` pretending otherwise.
@MainActor
struct SignalSocketRecoveryTests {
    /// The first failures back off like the event stream's: 2, 4, 8, 16, then the 30-second cap.
    @Test func theWaitDoublesUpToThirtySeconds() {
        #expect(MiroTalkSignalClient.reconnectDelay(failures: 1) == 2)
        #expect(MiroTalkSignalClient.reconnectDelay(failures: 2) == 4)
        #expect(MiroTalkSignalClient.reconnectDelay(failures: 3) == 8)
        #expect(MiroTalkSignalClient.reconnectDelay(failures: 4) == 16)
        #expect(MiroTalkSignalClient.reconnectDelay(failures: 5) == 30)
        // Capped, not unbounded: a person watching "Reconnecting" is owed a bounded wait.
        #expect(MiroTalkSignalClient.reconnectDelay(failures: 9) == 30)
    }

    /// Every failure inside the window earns another dial, at that failure's own wait.
    @Test func theSocketIsRedialledThroughTheRecoveryWindow() {
        #expect(MiroTalkSignalClient.socketRecovery(failures: 1) == .redial(afterSeconds: 2))
        #expect(MiroTalkSignalClient.socketRecovery(failures: 4) == .redial(afterSeconds: 16))
        #expect(MiroTalkSignalClient.socketRecovery(failures: 5) == .redial(afterSeconds: 30))
    }

    /// The sixth failure is the end of it. A handoff is seconds — ICE re-established in ~8 across
    /// the change that found this defect — so a minute without a socket is a call that is not
    /// coming back, and nothing is gained by showing it for longer.
    @Test func theSocketIsGivenUpOnAfterFiveFailedDials() {
        #expect(MiroTalkSignalClient.socketRecovery(failures: 6) == .giveUp)
        #expect(MiroTalkSignalClient.socketRecovery(failures: 12) == .giveUp)
    }

    /// And the whole window is the sum of those waits, so the minute the words claim is the minute
    /// the loop actually spends rather than one that drifts with the attempt count.
    @Test func theRecoveryWindowIsAMinuteOfWaiting() {
        var waited = 0
        for failures in 1...MiroTalkSignalClient.recoveryAttempts {
            waited += MiroTalkSignalClient.reconnectDelay(failures: failures)
        }

        #expect(waited == 60)
    }
}

// MARK: - No compiled default

/// The header that names which recording a request belongs to.
///
/// Every recording session carries its own value, and the protocol files requests under it. That is
/// what makes the store safe to share: Swift Testing runs even serialized suites alongside each
/// other, so a single global list would let one suite's request appear in — or be cleared from —
/// another's assertion.
private let recordingHeader = "X-Crossbar-Recording"

/// A session that records every request started through it, and answers an empty success.
///
/// The observable for "nothing dialled". A request that was never made leaves no log line and no
/// error a test can tell from a slow one, while `URLProtocol` is where `URLSession` says whether a
/// request was started at all. The store is static because `URLSession` instantiates the protocol
/// itself; requests are keyed by the marker header the recording configuration adds, so two
/// recordings never see each other's.
final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started: [String: [URLRequest]] = [:]

    /// The requests that reached the network stack under `recording`, in order.
    static func requests(recording marker: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return started[marker] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let marker = request.value(forHTTPHeaderField: recordingHeader) ?? ""
        Self.lock.lock()
        Self.started[marker, default: []].append(request)
        Self.lock.unlock()

        // A request that *was* made has to complete rather than hang, so the test that fails says
        // which request reached the stack instead of timing out.
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Why the fixture refused to run: an address it could not clear.
private struct ServiceAddressFixtureError: Error, CustomStringConvertible {
    let address: String

    var description: String {
        "the app still resolves a service address (\(address)) after the fixture cleared both of its "
        + "sources — it is coming from a preferences domain the app reads but does not own. Clear it "
        + "on this machine (a stray `defaults write com.abdullahchaudhry.Crossbar "
        + "crossbar.serviceAddress …` on the simulator, for instance) and re-run."
    }
}

/// The state the app is in with no stored address and no runtime override.
///
/// Both sources outlive a test — the app's own defaults, and the seam `ServiceAddress` reads its
/// override from — so the app is put into the state before a test and given back afterwards. The
/// unconfigured state is put into the seam rather than made by removing a process variable, which
/// is what makes these tests independent of the machine they run on: a developer with
/// `CROSSBAR_BACKEND_URL` exported in their shell exercises the same code path as one without.
@MainActor
private struct ServiceAddressFixture {
    private let savedAddress = AppSettings.serviceAddress
    private let savedMode = AppSettings.connectionMode
    private let savedPrevious = AppSettings.previousServiceAddress
    private let savedPreviousMode = AppSettings.previousConnectionMode
    private let savedAbandoned = AppSettings.abandonedServiceAddress
    private let savedEnvironment = ServiceAddress.environment

    /// Fails rather than proceeding on a premise it could not establish.
    ///
    /// `AppSettings.serviceAddress` can only be *removed* from the app's own domain, so a value
    /// living in another domain that the app also reads — a stray
    /// `xcrun simctl spawn <device> defaults write com.abdullahchaudhry.Crossbar
    /// crossbar.serviceAddress …`, which is how one got onto this Mac's simulator on 2026-10-02 —
    /// keeps being read past the removal. A test that then "exercised the unconfigured state" would
    /// be dialling a host a human typed into the simulator, and the failure would read as the app's;
    /// so the premise is checked and named here instead.
    init() throws {
        AppSettings.serviceAddress = nil
        AppSettings.connectionMode = nil
        AppSettings.forgetPreviousAddress()
        AppSettings.abandonedServiceAddress = nil
        ServiceAddress.environment = { [:] }

        if let surviving = ServiceAddress.configuredURL {
            throw ServiceAddressFixtureError(address: surviving.absoluteString)
        }
    }

    /// Puts a runtime override in force, the way an instrument's launch environment does.
    func withEnvironmentOverride(_ value: String) {
        ServiceAddress.environment = { ["CROSSBAR_BACKEND_URL": value] }
    }

    func restore() {
        AppSettings.serviceAddress = savedAddress
        AppSettings.connectionMode = savedMode
        AppSettings.previousServiceAddress = savedPrevious
        AppSettings.previousConnectionMode = savedPreviousMode
        AppSettings.abandonedServiceAddress = savedAbandoned
        ServiceAddress.environment = savedEnvironment
    }
}

/// A client whose requests are recorded rather than sent, and the marker to read them back by.
@MainActor
private func recordingClient() -> (client: ServiceClient, marker: String) {
    let marker = UUID().uuidString
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordingURLProtocol.self]
    configuration.httpAdditionalHeaders = [recordingHeader: marker]
    let client = ServiceClient()
    client.transport = CallTransport(configuration: configuration, label: "recording")
    return (client, marker)
}

/// Where the service address comes from, now that there is no compiled default.
///
/// Three things have to hold together: an app nobody has configured dials nothing and says why; a
/// device is still pointed at its server by an invitation or by the runtime override; and the
/// address it is given is the one it then dials. The recording session is the observable for the
/// dials; the thrown error and its wording are the observable for what a person is told.
///
/// **One suite, serialized.** `ServiceAddress.environment` is process-wide and `.serialized` only
/// orders the tests *inside* a suite, so two sibling suites doing this would still run alongside
/// each other and could see each other's address — which is exactly the flakiness this shape exists
/// to remove. The override is supplied through the seam, so the ambient environment, whatever it
/// is, changes nothing here.
@MainActor
@Suite(.serialized)
struct ServiceAddressTests {
    /// The first read of a load refuses before a request exists.
    @Test func aLoadWithNoAddressMakesNoRequest() async throws {
        let device = try ServiceAddressFixture()
        defer { device.restore() }

        let recording = recordingClient()
        var lines: [String] = []
        recording.client.log = { lines.append($0) }

        await #expect(throws: ServiceAddress.Unconfigured.self) {
            try await recording.client.bootstrap()
        }
        let dialled = RecordingURLProtocol.requests(recording: recording.marker)
        #expect(dialled.isEmpty,
                "an app nobody configured must not dial, but asked for \(dialled.compactMap { $0.url?.absoluteString })")
        #expect(lines.contains { $0.contains("no service address is set") },
                "the log has to name the state, got: \(lines)")
    }

    /// The event stream is a dial as well: with no address it reports the failure and opens no
    /// socket. This is the same guard seen from the connection that would otherwise stay up for
    /// the life of the app.
    @Test func theEventStreamReportsTheFailureInsteadOfDialling() async throws {
        let device = try ServiceAddressFixture()
        defer { device.restore() }

        let recording = recordingClient()
        var events: [ServiceEvent] = []
        for await event in recording.client.events() { events.append(event) }

        #expect(RecordingURLProtocol.requests(recording: recording.marker).isEmpty)
        guard case .failed(let reason)? = events.first else {
            Issue.record("expected the stream to fail, got \(events)")
            return
        }
        #expect(reason.contains("not been told which Crossbar"))
    }

    /// The words the setup and failure paths show say what is missing, and the address cannot be
    /// obtained at all without being handled — which is what makes an accidental dial impossible
    /// rather than merely discouraged.
    @Test func theRefusalSaysWhatIsMissing() throws {
        let device = try ServiceAddressFixture()
        defer { device.restore() }

        #expect(ServiceAddress.configuredURL == nil)
        #expect(!ServiceAddress.isConfigured)
        #expect(throws: ServiceAddress.Unconfigured.self) { try ServiceAddress.requiredURL() }

        let words = ServiceAddress.Unconfigured().localizedDescription
        #expect(words.contains("has not been told which Crossbar"))
        #expect(words.contains("enrollment code"))
    }

    /// The runtime override still configures the app, and is still not stored.
    ///
    /// It is a path that has to keep working rather than a convenience: every measurement on this
    /// branch is taken with `CROSSBAR_BACKEND_URL` in the launch environment, and nothing was
    /// compiled in to fall back to if it stopped being read.
    @Test func theRuntimeOverrideStillConfiguresTheApp() async throws {
        let device = try ServiceAddressFixture()
        defer { device.restore() }
        device.withEnvironmentOverride("https://override.example:8443")

        let recording = recordingClient()
        #expect(ServiceAddress.isConfigured)
        #expect(ServiceAddress.configuredURL == URL(string: "https://override.example:8443"))
        #expect(AppSettings.serviceAddress == nil, "the override is runtime, so nothing is stored")

        _ = try await recording.client.checkSession()
        let dialled = RecordingURLProtocol.requests(recording: recording.marker)
            .compactMap { $0.url?.absoluteString }
        #expect(dialled == ["https://override.example:8443/api/session"], "got \(dialled)")
    }

    /// An invitation that names a server is still how a device is pointed at its own backend.
    ///
    /// The paths that set the address had to keep working when the default went, and this is the one
    /// that matters most: it is now the only way a fresh install — which has no address at all — is
    /// given one. "The app proceeds" is shown by the request that follows: it goes to the host the
    /// invitation named and is answered normally.
    @Test func anInvitationPayloadSetsTheAddressAndTheAppDialsIt() async throws {
        let device = try ServiceAddressFixture()
        defer { device.restore() }

        let recording = recordingClient()
        let payload = """
        {"version":1,"server":"https://crossbar.example:8443","enrollment_token":"tok_123","mode":"private"}
        """

        let parsed = try DeviceAuth.shared.settle(from: payload)

        #expect(parsed.token == "tok_123")
        #expect(parsed.server == "https://crossbar.example:8443")
        #expect(AppSettings.serviceAddress == "https://crossbar.example:8443")
        #expect(AppSettings.connectionMode == .privateNetwork)
        #expect(try ServiceAddress.requiredURL() == URL(string: "https://crossbar.example:8443"))

        _ = try await recording.client.checkSession()
        let dialled = RecordingURLProtocol.requests(recording: recording.marker)
            .compactMap { $0.url?.absoluteString }
        #expect(dialled == ["https://crossbar.example:8443/api/session"], "got \(dialled)")
    }
}
