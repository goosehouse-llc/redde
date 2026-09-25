import Foundation
@testable import Echo

/// Live-test endpoints come from the git-ignored LocalDefaults.json in the app bundle (personal
/// builds) so nothing about a private network lives in the test sources. Absent → tests skip.
nonisolated enum TestEndpoints {
    private static let dict: [String: String] = {
        guard let url = Bundle.main.url(forResource: "LocalDefaults", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return d.compactMapValues { $0 as? String }
    }()
    static var fastLane: URL? { dict["fastLaneURL"].flatMap(URL.init) }
    static var fastLaneModel: String { dict["fastLaneModel"] ?? "" }
    static var gateway: URL? { dict["gatewayURL"].flatMap(URL.init) }
    static var kokoro: URL? { dict["kokoroURL"].flatMap(URL.init) }
    static var kokoroVoice: String { dict["kokoroVoice"] ?? "af_heart" }
}
