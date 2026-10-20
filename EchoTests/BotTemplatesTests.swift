import Foundation
import Testing
@testable import Echo

/// New Bot's templates (`BotTemplate`) and a bot's toolsets as Hermes describes them.
struct BotTemplatesTests {
    @Test func eachTemplateIsWholeAndItsOwn() {
        let all = BotTemplate.all
        #expect(Set(all.map(\.id)).count == all.count && Set(all.map(\.title)).count == all.count)
        #expect(Set(all.map(\.face)).count == all.count, "no two look alike")
        for template in all {
            #expect(!template.about.isEmpty, "\(template.id) says nothing of what it does")
            #expect(template.soul.hasPrefix("# \(template.title)\n") && template.soul.contains("**Mission:**"), "\(template.id)'s personality")
            #expect(template.face.shape != .bubble, "Redde's own bubble is the main agent's alone")
            for toolset in template.toolsets ?? [] {
                #expect(BotToolset.titles[toolset] != nil, "\(template.id) asks for \(toolset), which has no words here")
            }
            #expect(template.toolsets?.contains("clarify") == true, "\(template.id) can't ask the person anything")
        }
        #expect(all.first { $0.id == "writer" }?.toolsets?.contains("terminal") == false, "a writer has no terminal")
        #expect(BotTemplate.blank.toolsets == nil)
    }

    @Test func aTemplateKeepsOnlyTheToolsetsTheServerHas() {
        let offered = ["file", "memory", "clarify", "web"].map { BotToolset(name: $0) }
        let writer = BotTemplate.all.first { $0.id == "writer" }
        #expect(writer?.toolsets(offered: offered) == ["file", "memory", "clarify", "web"], "todo isn't on this server")
        #expect(BotTemplate.blank.toolsets(offered: offered) == nil, "Blank: every one the agent has")
        let home = BotTemplate.all.first { $0.id == "home" }
        #expect(home?.toolsets(offered: offered) == ["memory", "clarify"], "no Home Assistant here")
    }

    @Test func aBotsToolsetsReadFromHermes() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"name": "quill", "soul": "# Quill", "description": "Writes", "toolsets_pinned": true,
         "toolsets": [{"name": "file", "description": "Read and write files", "enabled": true},
                      {"name": "terminal", "description": "Run commands", "enabled": false},
                      {"name": "web", "enabled": true}]}
        """.utf8))
        let details = BotDetails(json)
        #expect(details.toolsets.map(\.name) == ["file", "terminal", "web"])
        #expect(details.enabledToolsets == ["file", "web"])
        // No list of its own and none marked (0.21.5 can say so of every one): all of them.
        let unmarked = BotDetails(toolsets: [BotToolset(name: "file", enabled: false), BotToolset(name: "web", enabled: false)])
        #expect(unmarked.enabledToolsets == ["file", "web"])
        let pinnedNone = BotDetails(toolsets: [BotToolset(name: "file", enabled: false)], toolsetsPinned: true)
        #expect(pinnedNone.enabledToolsets.isEmpty, "a list of its own with nothing in it is that")
        #expect(BotToolset(name: "web").title == "Web search")
        #expect(BotToolset(name: "lab_widgets").title == "Lab Widgets", "one this build has no words for")
    }

    @Test func aChangeToItsToolsIsAChange() {
        #expect(!BotChange(toolsets: ["file"]).isEmpty)
    }
}
