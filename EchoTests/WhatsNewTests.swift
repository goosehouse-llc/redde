import Foundation
import Testing
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
        }
    }
}
