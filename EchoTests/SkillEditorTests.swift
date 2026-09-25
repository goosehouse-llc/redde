import Testing
@testable import Echo

struct SkillEditorTests {
    @Test func extractsFencedMarkdown() {
        let reply = "Here you go:\n```markdown\n---\nname: vet-calls\ndescription: x\n---\n# Vet\n```\nLet me know!"
        #expect(SkillEditorView.extractMarkdown(reply) == "---\nname: vet-calls\ndescription: x\n---\n# Vet")
        #expect(SkillEditorView.extractMarkdown("no fence here") == "no fence here")
    }

    @Test func readsFrontMatter() {
        let md = SkillEditorView.template(name: "deploy-runbook")
        #expect(SkillEditorView.frontMatterValue("name", in: md) == "deploy-runbook")
        #expect(SkillEditorView.frontMatterValue("version", in: md) == "1.0.0")
        #expect(SkillEditorView.frontMatterValue("missing", in: md) == nil)
    }
}
