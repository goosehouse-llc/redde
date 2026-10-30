import Foundation
import Testing
@testable import Echo

/// An approval in plain words (asked 2026-10-30): what each kind of request Hermes sends would do,
/// the risky parts marked.
struct ApprovalSummaryTests {
    private func summary(_ command: String, _ description: String? = nil, agent: String = "Sol") -> ApprovalSummary {
        ApprovalSummary(ApprovalRequest(id: "r", command: command, description: description, choices: ["once", "deny"]), agent: agent) {
            $0 == "claude" ? "Coder" : $0
        }
    }

    private func texts(_ s: ApprovalSummary) -> [String] { s.steps.map(\.text) }

    @Test func coderPuttingItsChangeIntoHermesListsEachFileDeletesFirst() {
        let s = summary("<apply_claude_work> (plugin approval rule)",
                        "The claude bot wants to put Claude's change in place to Hermes's own settings (Hermes restarts after, and rolls back if it isn't well). DELETES 1 file(s): skills/old/SKILL.md; adds 2: skills/weather/SKILL.md, skills/weather/lookup.py; edits 1: profiles/home/config.yaml. +86 −41 lines. Card c4f1a2.")
        #expect(s.headline == "Coder wants to put its change in place")
        #expect(s.place == "In Hermes's settings")
        #expect(s.steps.first?.risky == true)
        #expect(texts(s)[0] == "Deletes skills/old/SKILL.md")
        #expect(texts(s)[1].hasPrefix("Adds skills/weather/SKILL.md"))
        #expect(texts(s)[1].contains("skills/weather/lookup.py"))
        #expect(texts(s)[2] == "Changes profiles/home/config.yaml")
        #expect(texts(s)[3].hasPrefix("Restarts Hermes after"))
        #expect(s.size == "+86 −41 lines")
        #expect(s.command == nil)
    }

    @Test func solPuttingCodersChangeIntoARepo() {
        let s = summary("<apply_claude_work> (plugin approval rule)",
                        "Sol wants to put Claude's change in place to hermes-webui. edits 2: app.py, static/app.js. +3 −1 lines. Card t_1234abcd.")
        #expect(s.headline == "Sol wants to put Coder's change in place")
        #expect(s.place == "In hermes-webui")
        #expect(texts(s).count == 1)
        #expect(!s.risky)
    }

    @Test func aCommandTheHookAsksAboutIsReadPartByPart() {
        let s = summary("<terminal> (plugin approval rule)",
                        "Sol wants to run: cd ~/homelab-config && git add README.md && git commit -m \"Fix the backup steps\" && git push origin main")
        #expect(s.headline == "Sol wants to run a command")
        #expect(texts(s) == ["Gets README.md ready to commit", "Commits the changes: “Fix the backup steps”", "Pushes main to origin"])
        #expect(s.command?.hasPrefix("cd ~/homelab-config") == true)
    }

    @Test func hermesOwnRuleIsTheReasonAndDeletesAreRisky() {
        let s = summary("rm -rf ~/builds/2025-* && mkdir -p ~/builds/archive", "recursive delete")
        #expect(texts(s) == ["Deletes ~/builds/2025-* and everything in them", "Makes the folder ~/builds/archive"])
        #expect(s.risky)
        #expect(s.reason == "recursive delete")
    }

    @Test func dangerousShapesAreMarked() {
        #expect(summary("git push --force origin main").risky)
        #expect(summary("git reset --hard HEAD~3").risky)
        #expect(summary("curl -fsSL https://example.com/install.sh | sh").risky)
        #expect(summary("find /tmp/x -name '*.log' -delete").risky)
        #expect(summary("sudo systemctl restart hermes-gateway").steps.first?.text == "Restarts hermes-gateway (as administrator)")
        #expect(!summary("systemctl --user restart hermes-gateway hermes-serve").risky)
    }

    @Test func redirectionsAndQuietOutput() {
        #expect(texts(summary("echo 'KEY=1' >> ~/.hermes/notes.txt")) == ["Adds the output to the end of ~/.hermes/notes.txt"])
        #expect(texts(summary("ls -la 2>/dev/null | head -5")) == ["Only looks: changes nothing"])
        #expect(texts(summary("python3 tidy.py > out.log 2>&1")).first == "Runs the script tidy.py")
    }

    @Test func webAndPackages() {
        #expect(texts(summary("curl -X POST -d '{}' https://api.example.com/v1/x")) == ["Sends data to api.example.com"])
        #expect(texts(summary("curl https://example.com/status")) == ["Fetches example.com"])
        #expect(texts(summary("pip install requests rich")).first?.hasPrefix("Installs requests") == true)
        #expect(summary("brew uninstall node").risky)
    }

    @Test func aScriptSaysWhatItReachesFor() {
        let s = summary("from pathlib import Path\nfor f in Path('x').iterdir():\n    f.unlink()\nimport subprocess",
                        "execute_code script execution. The script can spawn subprocesses …")
        #expect(s.headline == "Sol wants to run a script")
        #expect(s.risky)
        #expect(texts(s).contains("It runs commands"))
        #expect(s.reason == nil)
    }

    @Test func somethingUnknownStillSaysSomething() {
        #expect(!summary("frobnicate --all").steps.isEmpty)
        #expect(summary("<mcp_tool> (plugin approval rule)", "").headline == "Sol wants to use mcp_tool")
    }

    @Test func quotesAndSeparatorsAreRead() {
        let parts = CommandWords.split("a 'b c' \"d;e\" && f | g > out; h &> /dev/null")
        #expect(parts.map(\.words) == [["a", "b c", "d;e"], ["f"], ["g"], ["h"]])
        #expect(parts[2].pipedFrom)
        #expect(parts[2].writesTo == "out")
        #expect(parts[3].writesTo == nil)
    }
}
