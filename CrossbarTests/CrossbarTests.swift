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
