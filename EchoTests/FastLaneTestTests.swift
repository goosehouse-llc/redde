import Foundation
import Testing
@testable import Echo

/// Answers the OpenAI-compatible connection test's /v1/models call in-process.
nonisolated final class ModelListStub: URLProtocol {
    nonisolated(unsafe) static var reply: (status: Int, contentType: String, body: String) = (200, "application/json", "")
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelListStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": Self.reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Issue #77: a 200 that isn't a model list (a website, a login page, broken JSON) must not pass.
@Suite(.serialized)
struct FastLaneTestTests {
    private let base = URL(string: "https://models.example")!

    private func probe(_ status: Int, _ body: String, contentType: String = "application/json",
                       key: String? = nil, model: String = "") async -> ConnectionTester.Outcome {
        ModelListStub.reply = (status, contentType, body)
        return await ConnectionTester.fastLane(url: base, apiKey: key, model: model, session: ModelListStub.session)
    }

    @Test func aWebPageIsNotAModelList() async {
        let html = """

          <!DOCTYPE html>
          <html><head><title>Welcome</title></head><body>Sign in</body></html>
          """
        let outcome = await probe(200, html, contentType: "text/html")
        #expect(!outcome.isOK)
        #expect(outcome.message.contains("web page"), Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("/v1"))
        #expect(ModelListStub.lastRequest?.url?.path() == "/v1/models")
    }

    @Test func brokenJSONIsNotAModelList() async {
        let outcome = await probe(200, #"{"data": [{"id": "a""#)
        #expect(!outcome.isOK)
        #expect(outcome.message.contains("wasn't a model list"), Comment(rawValue: outcome.message))
    }

    @Test func jsonWithoutADataArrayIsNotAModelList() async {
        for body in [#"{"status": "ok"}"#, #"{"data": "nope"}"#, "[]", "OK"] {
            let outcome = await probe(200, body)
            #expect(!outcome.isOK, "\(body)")
            #expect(outcome.message.contains("wasn't a model list"), "\(body): \(outcome.message)")
        }
    }

    @Test func anEmptyListStillConnects() async {
        let outcome = await probe(200, #"{"object": "list", "data": []}"#, model: "any-model")
        #expect(outcome == .ok("Connected."))
    }

    @Test func aListWithTheModelConnects() async {
        let outcome = await probe(200, #"{"data": [{"id": "small"}, {"id": "large"}]}"#, key: "test-key", model: "large")
        #expect(outcome == .ok("Connected. 2 models available."))
        #expect(ModelListStub.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test func aListWithoutTheModelSaysSo() async {
        let outcome = await probe(200, #"{"data": [{"id": "small"}, {"id": "large"}]}"#, model: "medium")
        #expect(outcome == .failed("Connected, but the endpoint doesn't list a model named medium."))
    }

    @Test func noModelNamedAcceptsAnyList() async {
        let outcome = await probe(200, #"{"data": [{"id": "small"}]}"#)
        #expect(outcome.isOK && outcome.message.hasPrefix("Connected. 1 model"), Comment(rawValue: outcome.message))
    }

    @Test func aRejectedKeySaysSo() async {
        for status in [401, 403] {
            let outcome = await probe(status, #"{"error": "unauthorized"}"#, key: "wrong-key")
            #expect(outcome == .failed("Endpoint reachable, but the key was rejected."), "\(status)")
        }
    }

    @Test func anotherStatusIsNamed() async {
        let outcome = await probe(500, "<html>Server error</html>", contentType: "text/html")
        #expect(outcome == .failed("Endpoint answered HTTP 500."))
    }
}
