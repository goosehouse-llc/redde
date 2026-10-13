import CoreGraphics
import Foundation
import Vision

/// Looking at a picture on the phone, with Apple's Vision: what is in it, and the text in it.
/// Nothing leaves the phone for this.
nonisolated enum PhotoLook {
    /// How large a picture is looked at for what is in it, and how large for its text, in
    /// pixels along the longer side. The small one is always on the phone, also for a picture
    /// whose original is in iCloud; text needs the larger one to be legible.
    static let glance = 360
    static let reading = 1536

    /// What is in the picture: up to twelve things, the least sure dropped.
    static func labels(in picture: CGImage) async throws -> [String: Double] {
        let seen = try await ClassifyImageRequest().perform(on: picture)
        let kept = seen.filter { $0.confidence >= 0.1 }.sorted { $0.confidence > $1.confidence }.prefix(12)
        return Dictionary(kept.map { ($0.identifier, (Double($0.confidence) * 100).rounded() / 100) }) { first, _ in first }
    }

    /// The kinds of picture that have something to read in them. Reading takes ten times as
    /// long as looking, so only these are read.
    static let written: Set<String> = [
        "banner", "billboards", "book", "calendar", "chalkboard", "chart", "checkbook", "computer_monitor", "credit_card",
        "dashboard", "diagram", "document", "envelope", "flipchart", "gift_card", "handwriting", "license_plate", "magazine",
        "map", "newspaper", "printed_page", "receipt", "scoreboard", "screenshot", "sign", "sticky_note", "street_sign",
        "television", "ticket", "whiteboard",
    ]

    static func hasSomethingToRead(_ labels: [String: Double]) -> Bool {
        labels.contains { written.contains($0.key) && $0.value >= 0.2 }
    }

    /// The text in the picture, as far as it could be read with some confidence.
    static func text(in picture: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        let lines = try await request.perform(on: picture).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.5 }
        return String(lines.map(\.string).joined(separator: " ").prefix(600))
    }
}
