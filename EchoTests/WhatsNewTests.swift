import Foundation
import Testing
import UIKit
@testable import Echo

struct WhatsNewTests {
    private var latest: String { WhatsNew.releases[0].version }

    @Test func freshInstallsSeeNothing() {
        #expect(WhatsNew.pending(lastSeen: nil, current: latest, isNewInstall: true) == nil)
    }

    @Test func firstLaunchAfterAnUpdateShowsTheRelease() {
        // Existing users from before this screen existed have never recorded a version.
        #expect(WhatsNew.pending(lastSeen: nil, current: latest, isNewInstall: false)?.version == latest)
        #expect(WhatsNew.pending(lastSeen: "1.2", current: latest, isNewInstall: false)?.version == latest)
    }

    @Test func onceSeenItStaysAway() {
        #expect(WhatsNew.pending(lastSeen: latest, current: latest, isNewInstall: false) == nil)
        // A downgrade (TestFlight, a reinstall of an older build) never shows it either.
        #expect(WhatsNew.pending(lastSeen: "99.0", current: latest, isNewInstall: false) == nil)
    }

    /// A point release with no entry of its own shows the newest one the person hasn't seen.
    @Test func pointReleasesShowTheUnseenHighlights() {
        #expect(WhatsNew.pending(lastSeen: "1.3", current: "1.4.2", isNewInstall: false)?.version == "1.4")
        #expect(WhatsNew.pending(lastSeen: "1.4", current: "1.5.1", isNewInstall: false)?.version == "1.5")
        #expect(WhatsNew.pending(lastSeen: "1.5", current: "1.5.1", isNewInstall: false) == nil)
    }

    /// A point release with an entry of its own: someone on its version sees only what is new
    /// since, and someone who comes from the version before sees that version's highlights
    /// too, first. Without that, 1.7's would be skipped by everyone who updates past it.
    @Test func aPointReleaseWithItsOwnEntryCarriesItsVersionsHighlights() throws {
        func entry(_ version: String) throws -> WhatsNew.Release { try #require(WhatsNew.releases.first { $0.version == version }) }
        let base = try entry("1.7"), point = try entry("1.7.1")
        #expect(WhatsNew.pending(lastSeen: "1.7", current: "1.7.1", isNewInstall: false) == point)
        let fromBefore = try #require(WhatsNew.pending(lastSeen: "1.6", current: "1.7.1", isNewInstall: false))
        #expect(fromBefore.version == "1.7.1")
        #expect(fromBefore.items == base.items + point.items)
        // The sheet tells its rows apart by title.
        #expect(Set(fromBefore.items.map(\.title)).count == fromBefore.items.count)
        // Not yet on the point release: 1.7 as it was.
        #expect(WhatsNew.pending(lastSeen: "1.6", current: "1.7", isNewInstall: false) == base)
        // And an older version's highlights stay out of it.
        #expect(WhatsNew.pending(lastSeen: "1.5", current: "1.7.1", isNewInstall: false) == fromBefore)
        // Settings → About opens the same full list.
        #expect(WhatsNew.highlights(of: "1.7.1") == fromBefore)
    }

    @Test func versionsWithoutHighlightsShowNothing() {
        #expect(WhatsNew.pending(lastSeen: "1.0", current: "1.0.1", isNewInstall: false) == nil)
    }

    @Test func versionsCompareNumerically() {
        #expect(WhatsNew.compare("1.9", "1.10") == .orderedAscending)
        #expect(WhatsNew.compare("1.4", "1.4.0") == .orderedSame)
        #expect(WhatsNew.compare("2.0", "1.12") == .orderedDescending)
    }

    @Test func everyReleaseHasContent() {
        for release in WhatsNew.releases {
            #expect(!release.items.isEmpty)
            #expect(release.items.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
            // A symbol's name that the system doesn't know leaves the row without a picture.
            for item in release.items { #expect(UIImage(systemName: item.symbol) != nil, "no symbol called \(item.symbol)") }
        }
    }
}
