import Testing
@testable import Echo

struct CloudflareAccessTests {
    @Test func headersOnlyWhenBothPartsPresent() {
        #expect(Settings.cloudflareAccessHeaders(clientID: "", secret: "s").isEmpty)
        #expect(Settings.cloudflareAccessHeaders(clientID: "id", secret: nil).isEmpty)
        #expect(Settings.cloudflareAccessHeaders(clientID: "id", secret: "").isEmpty)
        let h = Settings.cloudflareAccessHeaders(clientID: "  abc.access  ", secret: "xyz")
        #expect(h == ["CF-Access-Client-Id": "abc.access", "CF-Access-Client-Secret": "xyz"])
    }
}
