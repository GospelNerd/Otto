import Foundation
import Testing

@testable import OttoServices

@Suite("Skills library")
struct SkillLibraryTests {
  @Test("Frontmatter names and folded descriptions are read; missing names use the folder")
  func parsesFrontmatter() {
    let folded =
      "---\nname: blog-google\ndescription: >\n  Google API integration\n  for blogs.\n---\n\n# Body"
    let meta = SkillParser.metadata(folded, folderName: "x")
    #expect(meta.name == "blog-google")
    #expect(meta.description == "Google API integration for blogs.")
    #expect(SkillParser.body(folded) == "# Body")
    let bare = SkillParser.metadata("---\ndescription: \"Quoted\"\n---\nhi", folderName: "folder")
    #expect(bare == ("folder", "Quoted"))
  }

  @Test("One skill in several harnesses is one entry that lists each place, symlinks followed")
  func mergesAcrossHarnesses() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.skill(".agents/skills/pdf", name: "pdf", description: "Read PDFs")
    try FileManager.default.createDirectory(
      at: home.url.appending(path: ".claude/skills"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.url.appending(path: ".claude/skills/pdf"),
      withDestinationURL: home.url.appending(path: ".agents/skills/pdf"))
    try home.skill(".hermes/skills/creative/poem", name: "poem", description: "Write poems")
    try home.skill(
      ".claude/plugins/cache/market/maker/1.0/skills/watch-video", name: "watch-video",
      description: "Watch a video")

    let entries = SkillScanner(home: home.url).scan(usage: [
      "maker:watch-video": (count: 2, last: Date()),
      "pdf": (count: 1, last: Date()),
    ])
    let pdf = try #require(entries.first { $0.name == "pdf" })
    #expect(Set(pdf.sources) == [.shared, .claudeCode])
    #expect(pdf.uses == 1)
    #expect(entries.first { $0.name == "poem" }?.sources == [.hermes])
    #expect(entries.first?.name == "watch-video")
    #expect(entries.first?.uses == 2)
  }

  @Test("Claude Code transcript skill calls are counted")
  func countsClaudeCodeUsage() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    let project = home.url.appending(path: ".claude/projects/p")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let line = #"{"type":"tool_use","name":"Skill","input":{"skill":"seo-audit"}}"#
    try (line + "\n" + line + "\n").write(
      to: project.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)
    let usage = SkillScanner(home: home.url).claudeCodeUsage()
    #expect(usage["seo-audit"]?.count == 2)
  }

  @Test("Adding to Otto copies the folder and leaves the harness copy untouched")
  @MainActor func addToOttoCopies() async throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.skill(".codex/skills/deploy", name: "deploy", description: "Ship it")
    let scanner = SkillScanner(home: home.url)
    let store = SkillLibraryStore(scanner: scanner)
    let entry = try #require(scanner.scan().first)
    // The store needs the entry loaded to update it in place.
    store.refresh()
    for _ in 0..<100 where store.entries.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    try store.addToOtto(entry)
    let copied = home.url.appending(path: "Library/Application Support/Otto/Skills/deploy/SKILL.md")
    #expect(FileManager.default.fileExists(atPath: copied.path))
    #expect(
      FileManager.default.fileExists(
        atPath: home.url.appending(path: ".codex/skills/deploy/SKILL.md").path))
    #expect(scanner.scan().first?.sources == [.otto, .codex])

    // Switching "All agents" off trashes only Otto's copy; Codex keeps its own.
    let shared = try #require(store.entries.first)
    #expect(store.canStopSharing(shared))
    try store.stopSharing(shared)
    #expect(!FileManager.default.fileExists(atPath: copied.path))
    #expect(
      FileManager.default.fileExists(
        atPath: home.url.appending(path: ".codex/skills/deploy/SKILL.md").path))
    #expect(scanner.scan().first?.sources == [.codex])
    #expect(store.entries.first?.isInOtto == false)
  }

  @Test("A skill written in Otto cannot be switched off, only shared")
  @MainActor func ottoOnlySkillStaysShared() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.skill("Library/Application Support/Otto/Skills/mine", name: "mine", description: "x")
    let store = SkillLibraryStore(scanner: SkillScanner(home: home.url))
    let entry = try #require(SkillScanner(home: home.url).scan().first)
    #expect(!store.canStopSharing(entry))
    try store.stopSharing(entry)
    #expect(
      FileManager.default.fileExists(
        atPath: home.url.appending(path: "Library/Application Support/Otto/Skills/mine/SKILL.md")
          .path))
  }
}

@Suite("Skills delivery")
struct SkillDeliveryTests {
  @Test("Only skills offered to a bot reach it; sessions get the everyone skills")
  @MainActor func audienceFiltering() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    let otto = "Library/Application Support/Otto/Skills"
    try home.skill("\(otto)/shared", name: "shared", description: "For all")
    try home.skill("\(otto)/coder-only", name: "coder-only", description: "Coder")
    let store = SkillLibraryStore(scanner: SkillScanner(home: home.url))
    let coder = UUID()
    let entry = SkillEntry(
      name: "coder-only", description: "", locations: [], uses: 0, lastUsed: nil)
    store.setAudience(.bots([coder]), for: entry)

    #expect(Set(store.ottoSkills(for: coder).map(\.name)) == ["shared", "coder-only"])
    #expect(store.ottoSkills(for: UUID()).map(\.name) == ["shared"])
    #expect(store.ottoSkills(for: nil).map(\.name) == ["shared"])
    // Choices survive a restart.
    let reopened = SkillLibraryStore(scanner: SkillScanner(home: home.url))
    #expect(reopened.ottoSkills(for: nil).map(\.name) == ["shared"])
  }

  @Test("skill.read returns the full instructions, the folder and its other files")
  func readsSkillFolder() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    let folder = "Library/Application Support/Otto/Skills/report"
    try home.skill(folder, name: "report", description: "Weekly report")
    let scripts = home.url.appending(path: "\(folder)/scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try "echo hi".write(to: scripts.appending(path: "run.sh"), atomically: true, encoding: .utf8)
    let entry = try #require(SkillScanner(home: home.url).ottoSkills().first)

    let output = try ApplicationServices.readSkill(entry)
    #expect(output.name == "report")
    #expect(output.instructions.contains("Do the thing."))
    #expect(output.files == ["scripts/run.sh"])
    #expect(output.folder.hasSuffix("Otto/Skills/report"))
  }
}

private struct TemporaryHome {
  let url: URL
  init() throws {
    url = FileManager.default.temporaryDirectory.appending(path: "otto-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
  func skill(_ relative: String, name: String, description: String) throws {
    let folder = url.appending(path: relative)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: \(description)\n---\n\nDo the thing.\n".write(
      to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
  }
  func remove() { try? FileManager.default.removeItem(at: url) }
}
