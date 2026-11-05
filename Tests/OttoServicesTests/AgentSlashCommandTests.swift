import Foundation
import OttoCore
import OttoModels
import OttoServices
import Testing

@MainActor
@Suite("Agent slash commands")
struct AgentSlashCommandTests {
  @Test("Parser leaves prompts alone and supports a literal slash escape")
  func promptAndEscape() {
    #expect(AgentSlashCommandParser.parse("explain /goal") == .prompt("explain /goal"))
    #expect(
      AgentSlashCommandParser.parse("//goal is ordinary text")
        == .prompt("/goal is ordinary text"))
  }

  @Test("Parser recognizes goal lifecycle commands and quoted objectives")
  func goals() {
    #expect(AgentSlashCommandParser.parse("/goal") == .goal(.show))
    #expect(
      AgentSlashCommandParser.parse("/goal \"Ship the command router\"")
        == .goal(.set("Ship the command router")))
    #expect(AgentSlashCommandParser.parse("/goal pause") == .goal(.pause))
    #expect(AgentSlashCommandParser.parse("/goal resume") == .goal(.resume))
    #expect(AgentSlashCommandParser.parse("/goal complete") == .goal(.complete))
    #expect(AgentSlashCommandParser.parse("/goal clear") == .goal(.clear))
  }

  @Test("Parser validates loop intervals and supplies a safe default")
  func loops() {
    #expect(
      AgentSlashCommandParser.parse("/loop 5m check CI")
        == .loop(.start(intervalSeconds: 300, prompt: "check CI")))
    #expect(
      AgentSlashCommandParser.parse("/loop check CI")
        == .loop(.start(intervalSeconds: 300, prompt: "check CI")))
    #expect(AgentSlashCommandParser.parse("/loop stop") == .loop(.stop))
    #expect(
      AgentSlashCommandParser.parse("/loop 2s too fast")
        == .invalid("Loop interval must be between 10s and 24h."))
  }

  @Test("Goal and loop state round-trip through workspace persistence")
  func persistence() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-agent-commands-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let agentID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let goal = AgentGoal(
      objective: "Finish the command router", createdAt: createdAt, updatedAt: createdAt)
    let loop = AgentLoop(prompt: "check CI", intervalSeconds: 300, nextRunAt: createdAt)

    let first = AgentCommandStateStore(workspacePath: root.path)
    try first.setGoal(goal, for: agentID)
    try first.setLoop(loop, for: agentID)

    let reloaded = AgentCommandStateStore(workspacePath: root.path)
    #expect(reloaded.goal(for: agentID) == goal)
    #expect(reloaded.loop(for: agentID) == loop)
    #expect(reloaded.enabledLoops().map(\.0) == [agentID])
  }

  @Test("Commands stay local while an active goal reaches the next provider turn")
  func serviceRouting() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-agent-command-service-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Commands")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let services = ApplicationServices(store: store, workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let spawned = try await services.spawnMockAgent(at: WorldPoint(x: 0, y: 0))
    try await waitUntil { services.fleet[spawned.agentID]?.state == .idle }

    try await services.sendPrompt(agentID: spawned.agentID, prompt: "/goal Ship slash commands")
    try await waitUntil {
      services.fleet[spawned.agentID]?.transcript.last?.text.contains("Goal active") == true
    }
    #expect(services.fleet[spawned.agentID]?.state == .idle)

    try await services.sendPrompt(agentID: spawned.agentID, prompt: "take the next step")
    try await waitUntil { services.fleet[spawned.agentID]?.state == .done }
    let providerPrompt = services.fleet[spawned.agentID]?.lastPrompt ?? ""
    #expect(providerPrompt.contains("[Otto active goal]"))
    #expect(providerPrompt.contains("Ship slash commands"))
    #expect(providerPrompt.hasSuffix("take the next step"))
    let background = try await services.spawnMockAgent(at: WorldPoint(x: 0, y: 0))
    try await waitUntil { services.fleet[background.agentID]?.state == .idle }
    try await services.sendPrompt(agentID: background.agentID, prompt: "/goal Ship background work")
    let notice =
      PromptSubmission.backgroundCompletionPrefix + "has finished. "
      + PromptSubmission.backgroundCompletionSuffix
    try await services.sendPrompt(agentID: background.agentID, prompt: notice)
    try await waitUntil { services.fleet[background.agentID]?.state == .done }
    let completed = services.fleet[background.agentID]
    #expect(completed?.lastPrompt?.contains(PromptSubmission.backgroundCompletionPrefix) != true)
    #expect(
      completed?.transcript.filter { $0.role == .user }.contains {
        $0.text.contains(PromptSubmission.backgroundCompletionPrefix)
      } == false)
    #expect(completed?.transcript.last?.role == .assistant)
    await services.shutdown()
  }
}

private func waitUntil(
  timeout: Duration = .seconds(15),
  condition: @escaping @MainActor () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  Issue.record("Timed out waiting for condition")
}
