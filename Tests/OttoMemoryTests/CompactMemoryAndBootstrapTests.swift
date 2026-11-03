import Foundation
import Testing

@testable import OttoMemory

@Suite("Compact memory and agent bootstrap")
struct CompactMemoryAndBootstrapTests {
  @Test("Compact entries round-trip through the human-editable Markdown form")
  func compactRoundTrip() async throws {
    let store = makeStore(budget: .personal)
    let entry = CompactMemoryEntry(
      id: "pref-terse",
      text: "Prefers terse answers without preamble.",
      source: "session:abc123",
      confidence: .confirmed,
      lastConfirmedAt: Date(timeIntervalSince1970: 1_754_300_000)
    )
    try await store.add(entry)
    try await store.add(
      CompactMemoryEntry(
        id: "workspace-swift", text: "Otto is a Swift package; run with swift run Otto.",
        source: "user statement", confidence: .confirmed))

    let reloaded = await store.entries()
    #expect(reloaded.count == 2)
    #expect(reloaded[0].id == "pref-terse")
    #expect(reloaded[0].text == entry.text)
    #expect(reloaded[0].source == "session:abc123")
    #expect(reloaded[1].source == "user statement")

    let usage = await store.usage()
    #expect(usage.entryCount == 2)
    #expect(usage.characterCount > 0)
  }

  @Test("Budget overflow is a visible error, never silent loss")
  func budgetOverflow() async throws {
    let store = makeStore(budget: MemoryBudget(maximumEntries: 2, maximumCharacters: 500))
    try await store.add(CompactMemoryEntry(id: "one", text: "First fact.", source: "s"))
    try await store.add(CompactMemoryEntry(id: "two", text: "Second fact.", source: "s"))
    await #expect(throws: CompactMemoryError.self) {
      try await store.add(CompactMemoryEntry(id: "three", text: "Third fact.", source: "s"))
    }
    // Replacing an existing entry stays within budget.
    try await store.add(CompactMemoryEntry(id: "two", text: "Second fact, revised.", source: "s"))
    let entries = await store.entries()
    #expect(entries.count == 2)
    // Secrets are rejected here too.
    await #expect(throws: CompactMemoryError.self) {
      try await store.add(
        CompactMemoryEntry(id: "one", text: "token xoxb-123456789012-abcdef", source: "s"))
    }
  }

  @Test("Bootstrap packets are deterministic and hash-stable for identical inputs")
  func bootstrapDeterminism() async throws {
    let personal = makeStore(budget: .personal)
    let operating = makeStore(budget: .operating)
    try await personal.add(
      CompactMemoryEntry(id: "pref", text: "Prefers plans before code.", source: "s"))
    try await operating.add(
      CompactMemoryEntry(
        id: "env", text: "Builds are run on an isolated scratch path.", source: "s"))

    let builder = AgentMemoryBootstrapBuilder(project: "muse", brainPath: "/tmp/brain")
    let first = await builder.build(
      personal: personal, operating: operating, permissionSummary: "workspace write")
    let second = await builder.build(
      personal: personal, operating: operating, permissionSummary: "workspace write")

    #expect(first.promptText == second.promptText)
    #expect(first.contentHash == second.contentHash)
    #expect(first.promptText.contains("Otto safety policy"))
    #expect(first.promptText.contains("Prefers plans before code."))
    #expect(first.promptText.contains("Project Brain: /tmp/brain"))
    #expect(first.promptText.contains("memory"))

    // Different compact context produces a different packet identity.
    try await operating.add(
      CompactMemoryEntry(id: "extra", text: "PTY tests are load-flaky.", source: "s"))
    let third = await builder.build(
      personal: personal, operating: operating, permissionSummary: "workspace write")
    #expect(third.contentHash != first.contentHash)
  }

  @Test("Bootstrap content hashes use SHA-256")
  func bootstrapHashIsSHA256() {
    // Known SHA-256 of "abc"; the FNV-1a fallback would not produce this digest.
    #expect(
      AgentMemoryBootstrap.hash("abc")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test("The canvas roster names peers as agents, never contacts")
  func peerRoster() async throws {
    let personal = makeStore(budget: .personal)
    let operating = makeStore(budget: .operating)
    let builder = AgentMemoryBootstrapBuilder(project: "muse", brainPath: "/tmp/brain")
    let bootstrap = await builder.build(
      personal: personal, operating: operating, permissionSummary: "workspace write",
      peerAgents: ["Beck — Claude Code — agentID 2E1B14D0-3898-4D6A-B684-BAF48364A4E7"])
    #expect(bootstrap.promptText.contains("Workspace agents"))
    #expect(bootstrap.promptText.contains("Beck — Claude Code"))
    #expect(bootstrap.promptText.contains("NOT an external contact"))
    #expect(bootstrap.promptText.contains("never search"))

    let solo = await builder.build(
      personal: personal, operating: operating, permissionSummary: "workspace write")
    #expect(!solo.promptText.contains("Workspace agents"))
  }

  @Test("Charter layers resolve in precedence order with the safety layer first")
  func charterPrecedence() {
    let charter = AgentCharter(layers: [
      CharterLayer(kind: .taskContract, source: "run:1", text: "Do the task."),
      AgentCharter.ottoSafetyLayer,
      CharterLayer(kind: .project, source: ".otto/charter.md", text: "Ship calm software."),
    ])
    let resolved = charter.resolvedText()
    let safety = resolved.range(of: "Otto safety policy")!
    let project = resolved.range(of: "Project charter")!
    let task = resolved.range(of: "Task contract")!
    #expect(safety.lowerBound < project.lowerBound)
    #expect(project.lowerBound < task.lowerBound)
  }

  private func makeStore(budget: MemoryBudget) -> CompactMemoryStore {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "otto-compact-\(UUID().uuidString)/store.md").path
    return CompactMemoryStore(filePath: path, title: "Fixture", budget: budget)
  }

  @Test("Every packet tells the agent to rate the records it used")
  func packetCarriesFeedbackGuidance() {
    // Trust only moves when a caller that read a record rates it. Without this instruction the
    // whole ranking mechanism is inert: every record sits at the neutral score forever.
    let packet = AgentMemoryBootstrap(
      charter: AgentCharter(layers: [AgentCharter.ottoSafetyLayer]),
      personalEntries: [],
      operatingEntries: [],
      project: "fixture",
      brainPath: "/tmp/brain",
      permissionSummary: "workspace write; risky actions ask for approval"
    )
    #expect(packet.promptText.contains("memory.feedback"))
    // The guard against reflexive rating matters as much as the instruction itself.
    #expect(packet.promptText.contains("only saw in a result list"))
  }

  @Test("Curation pressure counts only log entries newer than the last promotion")
  func curationPressureMeasurement() throws {
    let brain = FileManager.default.temporaryDirectory
      .appending(path: "otto-brain-\(UUID().uuidString)", directoryHint: .isDirectory).path
    for directory in ["log", "wiki", "decisions"] {
      try FileManager.default.createDirectory(
        atPath: (brain as NSString).appendingPathComponent(directory),
        withIntermediateDirectories: true)
    }
    func write(_ relativePath: String, modified: Date) throws {
      let path = (brain as NSString).appendingPathComponent(relativePath)
      try Data("x".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
      try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }

    let promotion = Date(timeIntervalSince1970: 1_754_400_000)
    try write("decisions/settled.md", modified: promotion)
    // Predates the decision: already accounted for, so it must not count as pressure.
    try write("log/old.md", modified: promotion.addingTimeInterval(-600))
    for index in 0..<4 {
      try write("log/new-\(index).md", modified: promotion.addingTimeInterval(Double(index + 1)))
    }

    let pressure = BrainCurationPressure.measure(brainPath: brain, threshold: 4)
    #expect(pressure.logsSinceLastPromotion == 4)
    #expect(pressure.shouldNudge)
    #expect(pressure.nudgeText?.contains("4 log entries") == true)

    // A fresh wiki entry discharges the pressure without anything being deleted.
    try write("wiki/promoted.md", modified: promotion.addingTimeInterval(60))
    let after = BrainCurationPressure.measure(brainPath: brain, threshold: 4)
    #expect(after.logsSinceLastPromotion == 0)
    #expect(!after.shouldNudge)
    #expect(after.nudgeText == nil)
  }

  @Test("An empty or missing brain applies no curation pressure")
  func curationPressureEmptyBrain() {
    let missing = BrainCurationPressure.measure(
      brainPath: "/nonexistent/muse-brain-\(UUID().uuidString)")
    #expect(missing.logsSinceLastPromotion == 0)
    #expect(!missing.shouldNudge)
  }

  @Test("The nudge reaches the agent only when pressure is present")
  func nudgeRendersIntoPacket() {
    func packet(nudge: String?) -> AgentMemoryBootstrap {
      AgentMemoryBootstrap(
        charter: AgentCharter(layers: [AgentCharter.ottoSafetyLayer]),
        personalEntries: [],
        operatingEntries: [],
        project: "fixture",
        brainPath: "/tmp/brain",
        permissionSummary: "read-only (plan mode)",
        curationNudge: nudge
      )
    }
    #expect(!packet(nudge: nil).promptText.contains("Memory curation"))
    let nudged = packet(nudge: "42 log entries have accumulated")
    #expect(nudged.promptText.contains("## Memory curation"))
    #expect(nudged.promptText.contains("42 log entries have accumulated"))
    // The packet stays deterministic: same inputs, same hash.
    #expect(nudged.contentHash == packet(nudge: "42 log entries have accumulated").contentHash)
    #expect(nudged.contentHash != packet(nudge: nil).contentHash)
  }

  @Test("Skills appear in the launch prompt only when the agent has some")
  func skillsSection() {
    func packet(_ skills: [String]?) -> AgentMemoryBootstrap {
      AgentMemoryBootstrap(
        charter: AgentCharter(layers: [AgentCharter.ottoSafetyLayer]),
        personalEntries: [], operatingEntries: [], project: "fixture", brainPath: "/tmp/brain",
        permissionSummary: "bypass permissions", skills: skills)
    }
    let with = packet(["weekly-report — When asked for the weekly LinkedIn report"])
    #expect(with.promptText.contains("## Skills"))
    #expect(with.promptText.contains("skill.read"))
    #expect(with.promptText.contains("- weekly-report — When asked"))
    #expect(!packet(nil).promptText.contains("## Skills"))
  }
}
