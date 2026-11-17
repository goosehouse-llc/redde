import Foundation
import Testing
@testable import Echo

/// Hermes's skills hub as Redde reads it (`HubSkill`, `HubOverview`, `HubScan`), from the
/// Dashboard's `/api/skills/hub/*` replies on Hermes 0.22–0.23.
struct SkillsHubTests {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    @Test func aSearchHitAndWhatIsInstalled() throws {
        let reply = try json("""
        {"results": [{"name": "pdf-tools", "description": "Read PDFs", "source": "skills-sh", "identifier": "acme/skills/pdf-tools",
                      "trust_level": "community", "repo": "acme/skills", "tags": ["pdf"]},
                     {"name": "weather", "source": "clawhub", "identifier": "weather", "trust_level": "community"},
                     {"description": "no name or id"}],
         "installed": {"clawhub/weather": {"name": "weather-claw", "trust_level": "community", "scan_verdict": "safe"}},
         "timed_out": ["github"]}
        """)
        let skills = (reply["results"]?.array ?? []).compactMap(HubSkill.init)
        #expect(skills.count == 2)
        #expect(skills[0].identifier == "acme/skills/pdf-tools")
        #expect(skills[0].repo == "acme/skills")
        #expect(skills[0].tags == ["pdf"])
        let installed = HubOverview.installed(reply["installed"])
        #expect(skills[0].installedName(in: installed) == nil)
        // ClawHub's search lists a bare slug; Hermes keys its install as the card id.
        #expect(skills[1].installedName(in: installed) == "weather-claw")
    }

    @Test func theSourcesAndFeatured() throws {
        let overview = HubOverview(try json("""
        {"sources": [{"id": "official", "label": "Official"}, {"id": "github", "label": "GitHub", "rate_limited": true}],
         "index_available": true, "featured": [{"name": "x", "identifier": "official/a/x", "trust_level": "builtin"}],
         "installed": {}}
        """))
        #expect(overview.sources.map(\.id) == ["official", "github"])
        #expect(overview.sources[1].rateLimited)
        #expect(overview.featured.first?.trust == "builtin")
        #expect(overview.installed.isEmpty)
    }

    /// The Dashboard installs with `--yes`, which skips the question but not the scan: "ask" is
    /// refused as "block" is.
    @Test func onlyAnAllowedScanInstalls() throws {
        let scan = HubScan(try json("""
        {"verdict": "caution", "summary": "1 finding", "policy": "ask", "policy_reason": "community source",
         "findings": [{"severity": "low", "category": "network", "file": "a.py", "line": 2, "description": "fetches"},
                      {"severity": "critical", "category": "exfil", "file": "b.sh", "line": null, "description": "sends keys"}]}
        """))
        #expect(!scan.installs)
        #expect(scan.findings.map(\.severity) == ["critical", "low"])
        #expect(scan.findings[1].line == 2)
        #expect(HubScan(try json(#"{"policy": "allow", "findings": []}"#)).installs)
        #expect(!HubScan(try json(#"{"policy": "block"}"#)).installs)
    }

    @Test func whyAnInstallStopped() {
        let blocked = GatewayAction(running: false, exitCode: 0, lines: ["Resolving acme/x", "Not installed: high-risk patterns", "Re-run with --force", "x", "y"])
        #expect(HubSkillView.why(blocked) == "Not installed: high-risk patterns\nRe-run with --force\nx\ny")
        #expect(HubSkillView.why(GatewayAction(running: false, lines: [])) == nil)
    }

    @Test func anIdentifierIsOneQueryValue() {
        let path = HermesServeClient.hubQuery("api/skills/hub/preview", "acme/skills/pdf tools&x=1")
        #expect(path == "api/skills/hub/preview?identifier=acme/skills/pdf%20tools%26x%3D1")
        #expect(HermesServeClient.naming(path, profile: "home").hasSuffix("&profile=home"))
    }
}
