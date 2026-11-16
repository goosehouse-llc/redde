import Foundation
import Testing
@testable import Echo

struct HermesServeWireTests {
    @Test func authorityRequiresAnExplicitAdvertisement() {
        #expect(!HermesServeWire.sessionAuthority(.object([:])))
        #expect(!HermesServeWire.sessionAuthority(.object(["session_authority": .bool(false)])))
        #expect(!HermesServeWire.sessionAuthority(.object(["session_authority": .string("true")])))
        #expect(HermesServeWire.sessionAuthority(.object(["session_authority": .bool(true)])))
    }

    @Test func canonicalCreateUsesTheDeclaredSessionContract() {
        let original: [String: JSONValue] = ["source": .string("desktop"), "close_on_disconnect": .bool(false),
            "reasoning_effort": .string("medium"), "model": .string("example-model"),
            "provider": .string("example-provider"), "cwd": .string("/example/project"),
            "hidden": .bool(true), "profile": .string("example-profile")]
        let params = HermesServeWire.create(original, canonical: true, requestID: "create-1")
        #expect(params["source"] == .string("gui"))
        #expect(params["request_id"] == .string("create-1"))
        #expect(params["reasoning"] == .string("medium"))
        #expect(params["reasoning_effort"] == nil)
        #expect(params["close_on_disconnect"] == nil)
        for key in ["model", "provider", "cwd", "hidden", "profile"] { #expect(params[key] == original[key]) }
    }

    @Test func legacyCreateKeepsItsExistingFields() {
        let params: [String: JSONValue] = ["source": .string("desktop"), "close_on_disconnect": .bool(false),
                                         "reasoning_effort": .string("low")]
        #expect(HermesServeWire.create(params, canonical: false, requestID: "unused") == params)
    }

    @Test func canonicalSubmitKeepsTheOriginalSessionAndMessageIdentity() {
        let original: [String: JSONValue] = ["session_id": .string("existing-session"), "text": .string("Hello"),
            "display_kind": .string("hidden"), "surface": .string("voice-live"), "voice_context": .string("example")]
        let first = HermesServeWire.submit(original, canonical: true, submissionID: "message-1")
        let retry = HermesServeWire.submit(original, canonical: true, submissionID: "message-1")
        #expect(first == retry)
        #expect(first["submission_id"] == .string("message-1"))
        for (key, value) in original { #expect(first[key] == value) }
        #expect(HermesServeWire.submit(original, canonical: true, submissionID: "message-2") != first)
    }

    @Test func legacySubmitDoesNotGainCanonicalFields() {
        let params: [String: JSONValue] = ["session_id": .string("existing-session"), "text": .string("Hello")]
        #expect(HermesServeWire.submit(params, canonical: false, submissionID: "unused") == params)
    }

    @Test func stopCancelsTheAcknowledgedAdmissionInsteadOfAnotherTurn() {
        let stop = HermesServeWire.stop(sessionID: "existing-session", canonical: true, admissionID: "admission-1", generation: 8)
        #expect(stop?.method == "prompt.cancel")
        #expect(stop?.params == ["session_id": .string("existing-session"), "admission_id": .string("admission-1")])
        #expect(HermesServeWire.stop(sessionID: "existing-session", canonical: true, admissionID: nil, generation: nil) == nil)
    }

    @Test func rejoinedStopRetainsTheObservedGenerationFence() {
        let stop = HermesServeWire.stop(sessionID: "existing-session", canonical: true, admissionID: nil, generation: 7)
        #expect(stop?.method == "session.interrupt")
        #expect(stop?.params["execution_generation"] == .number(7))
        // Even if a newer turn is now generation8, this request still names7 and the host refuses it.
        #expect(stop?.params["session_id"] == .string("existing-session"))
    }

    @Test func legacyStopKeepsItsExistingShape() {
        let stop = HermesServeWire.stop(sessionID: "existing-session", canonical: false, admissionID: nil, generation: nil)
        #expect(stop?.method == "session.interrupt")
        #expect(stop?.params == ["session_id": .string("existing-session")])
    }
}
