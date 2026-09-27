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
