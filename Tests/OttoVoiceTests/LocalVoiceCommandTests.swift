import Foundation
import OttoApplicationTools
import OttoCore
import OttoDocuments
import OttoModels
import OttoRuntime
import OttoTools
import OttoVoice
import Testing

@Suite("Local voice commands")
struct LocalVoiceCommandTests {
  @Test("Sleep grammar is strict and local")
  func sleepGrammar() async throws {
    let router = LocalVoiceCommandRouter(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "local-command-test", scopes: [], source: .voice)
    )

    #expect(try await router.execute("Otto, go to sleep please") == .sleeping)
    #expect(
      try await router.execute("Tell Chase to go to sleep")
        == .unrecognized(
          "Command not recognized. Try opening a URL, starting a terminal, opening a session, or prompting an exact agent name."
        )
    )
  }

  @Test("Canvas commands execute through the real registry")
  @MainActor
  func canvasCommands() async throws {
    let fixture = try await Fixture()
    let first = fixture.store.dispatch(
      .createNode(kind: .markdown, at: WorldPoint(x: 900, y: 700)))
    let second = fixture.store.dispatch(
      .createNode(kind: .markdown, at: WorldPoint(x: 100, y: 100)))
    let firstID = try #require(first.affectedNodeIDs.first)
    _ = try #require(second.affectedNodeIDs.first)
    fixture.store.dispatch(.renameNode(id: firstID, name: "Release Notes"))
    await fixture.refreshContext()

    let focused = try await fixture.router.execute("focus Release Notes")
    #expect(focused == .completed(toolName: "node.focus", confirmation: "Focused Release Notes"))
    #expect(fixture.store.activeCanvas.selectedNodeID == firstID)
  }

  @Test("Exact agent prompts preserve punctuation and casing")
  @MainActor
  func exactPrompt() async throws {
    let fixture = try await Fixture()
    let agentID = try await fixture.spawnMockAgent()
    fixture.store.dispatch(.renameNode(id: agentID, name: "Chase"))
    await fixture.refreshContext()

    let outcome = try await fixture.router.execute("Prompt Chase with Fix build/API_v2 now.")
    #expect(outcome == .completed(toolName: "agent.send_prompt", confirmation: "Prompted Chase"))
    try await waitUntil {
      (try? await fixture.supervisor.snapshot(agentID: agentID))?.lastPrompt
        == "Fix build/API_v2 now."
    }

    fixture.store.dispatch(.renameNode(id: agentID, name: "Finished Chase"))
    let secondAgentID = try await fixture.spawnMockAgent()
    fixture.store.dispatch(.renameNode(id: secondAgentID, name: "Chase"))
    await fixture.refreshContext()
    let told = try await fixture.router.execute("Tell Chase to go to sleep.")
    // "Tell <agent> …" is now intercepted by the verbatim relay before the direct-prompt matcher;
    // the payload and tool are identical, only the confirmation wording differs.
    #expect(
      told == .completed(toolName: "agent.send_prompt", confirmation: "Sent verbatim to Chase"))
    try await waitUntil {
      (try? await fixture.supervisor.snapshot(agentID: secondAgentID))?.lastPrompt == "go to sleep."
    }
  }

  @Test("Common local canvas commands execute through typed tools")
  @MainActor
  func commonCommands() async throws {
    let fixture = try await Fixture()

    let created = try await fixture.router.execute("Create a terminal")
    #expect(created == .completed(toolName: "node.create", confirmation: "Created terminal"))
    let terminal = try #require(fixture.store.activeCanvas.nodes.first { $0.kind == .terminal })
    fixture.store.dispatch(.renameNode(id: terminal.id, name: "Build Log"))
    await fixture.refreshContext()

    let focused = try await fixture.router.execute("Focus Build Log")
    #expect(focused == .completed(toolName: "node.focus", confirmation: "Focused Build Log"))

    let openedNode = try await fixture.router.execute("Open Build Log")
    #expect(openedNode == .completed(toolName: "node.focus", confirmation: "Opened Build Log"))

    let opened = try await fixture.router.execute("Open example.com")
    #expect(
      opened == .completed(toolName: "browser.open", confirmation: "Opened https://example.com"))
    #expect(
      fixture.store.activeCanvas.nodes.contains {
        guard case .browser(let url) = $0.content else { return false }
        return url == "https://example.com"
      })

    let closed = try await fixture.router.execute("Close Build Log")
    #expect(closed == .completed(toolName: "node.close", confirmation: "Closed Build Log"))
    #expect(!fixture.store.activeCanvas.nodes.contains { $0.id == terminal.id })
  }

  @Test("Ambiguous and destructive phrases never guess a target")
  @MainActor
  func ambiguityAndAdversarialCommands() async throws {
    let fixture = try await Fixture()
    let first = fixture.store.dispatch(.createNode(kind: .markdown, at: WorldPoint(x: 0, y: 0)))
    let second = fixture.store.dispatch(.createNode(kind: .markdown, at: WorldPoint(x: 50, y: 50)))
    for id in first.affectedNodeIDs + second.affectedNodeIDs {
      fixture.store.dispatch(.renameNode(id: id, name: "Notes"))
    }
    await fixture.refreshContext()

    let ambiguous = try await fixture.router.execute("Close Notes")
    guard case .clarification(let question) = ambiguous else {
      Issue.record("Expected a clarification for duplicate node names")
      return
    }
    #expect(question.hasPrefix("Which node did you mean:"))
    #expect(fixture.store.activeCanvas.nodes.count == 2)

    let plural = try await fixture.router.execute("Close everything")
    #expect(plural == .clarification("I cannot find a node named everything."))
    #expect(fixture.store.activeCanvas.nodes.count == 2)
    let names = await fixture.registry.auditLog().map(\.toolName)
    #expect(!names.contains("node.close"))
    #expect(!names.contains("node.close_all"))
  }

  @Test("Spoken dictation to an exact agent remains verbatim")
  @MainActor
  func spokenPrompt() async throws {
    let fixture = try await Fixture()
    let agentID = try await fixture.spawnMockAgent()
    fixture.store.dispatch(.renameNode(id: agentID, name: "Chase"))
    await fixture.refreshContext()

    let outcome = try await fixture.router.execute(
      "Dictate to Chase: Keep API_v3; café 東京 — do not normalize."
    )
    #expect(outcome == .completed(toolName: "agent.send_prompt", confirmation: "Prompted Chase"))
    try await waitUntil {
      (try? await fixture.supervisor.snapshot(agentID: agentID))?.lastPrompt
        == "Keep API_v3; café 東京 — do not normalize."
    }
  }

  @Test("Duplicate agent names require clarification before prompting")
  @MainActor
  func ambiguousPrompt() async throws {
    let fixture = try await Fixture()
    let first = try await fixture.spawnMockAgent()
    let second = try await fixture.spawnMockAgent()
    fixture.store.dispatch(.renameNode(id: first, name: "Chase"))
    fixture.store.dispatch(.renameNode(id: second, name: "Chase"))
    await fixture.refreshContext()

    let result = try await fixture.router.execute("Prompt Chase with ship it")
    guard case .clarification(let question) = result else {
      Issue.record("Expected duplicate agent names to require clarification")
      return
    }
    #expect(question.hasPrefix("Which agent did you mean:"))
    #expect((try await fixture.supervisor.snapshot(agentID: first)).lastPrompt == nil)
    #expect((try await fixture.supervisor.snapshot(agentID: second)).lastPrompt == nil)
  }

  @Test("Chat surface voice routes saved bots, teams, channel mentions, and fresh sessions")
  func botsModeCommands() async throws {
    let registry = ToolRegistry()
    let capture = VoiceBotControlCapture()
    try await registry.register(VoiceBotOpenProbe(capture: capture))
    try await registry.register(VoiceBotPromptProbe(capture: capture))
    try await registry.register(VoiceTeamMessageProbe(capture: capture))
    try await registry.register(VoiceTeamNewSessionProbe(capture: capture))
    try await registry.register(VoiceSurfaceProbe(capture: capture))
    try await registry.register(VoiceChatOpenProbe(capture: capture))
    try await registry.register(VoiceSessionOpenProbe(capture: capture))
    try await registry.register(VoiceSessionPromptProbe(capture: capture))
    let router = LocalVoiceCommandRouter(
      registry: registry,
      context: ToolContext(
        actorID: "bots-voice-test", scopes: Set(ToolScope.allCases), source: .voice)
    )
    let canvasID = UUID()
    await router.updateContext(
      VoiceContext(
        activeCanvas: VoiceCanvasContext(
          id: canvasID, name: "Work", workspace: "/tmp/work", layout: .freeform),
        nodes: [
          VoiceNodeContext(
            id: UUID(), name: "Beck", kind: .agent, provider: .codex, status: .idle
          )
        ],
        sessions: [
          VoiceSessionContext(
            id: UUID(),
            name: "Beck",
            canvasID: UUID(),
            provider: .codex,
            status: .idle
          )
        ],
        bots: [
          VoiceBotContext(
            id: UUID(), name: "Taz", handle: "taz", jobTitle: "Planner", nodeID: nil)
        ],
        teams: [
          VoiceTeamContext(
            id: UUID(), name: "Staff", memberHandles: ["taz", "reviewer"],
            orchestratorHandle: "taz")
        ]
      ))

    #expect(
      try await router.execute("Tell Taz to Preserve API_v3; do not rewrite it.")
        == .completed(toolName: "bot.send_prompt", confirmation: "Prompted Taz"))
    #expect(
      await capture.last(tool: "bot.send_prompt")?["prompt"]
        == "Preserve API_v3; do not rewrite it.")
    #expect(
      try await router.execute("Switch to Taz")
        == .completed(toolName: "bot.open", confirmation: "Opened Taz"))
    #expect(await capture.last(tool: "bot.open")?["bot"] == "Taz")

    #expect(
      try await router.execute("Go tell Beck in Sessions to Review API_v4; keep it verbatim.")
        == .completed(
          toolName: "session.send_prompt",
          confirmation: "Prompted Beck in Sessions"
        ))
    #expect(
      await capture.last(tool: "session.send_prompt")?["prompt"]
        == "Review API_v4; keep it verbatim."
    )
    #expect(
      try await router.execute("Switch to Beck session")
        == .completed(toolName: "session.open", confirmation: "Opened Beck"))
    #expect(await capture.last(tool: "session.open")?["session"] != nil)
    #expect(
      try await router.execute("Show my sessions")
        == .completed(toolName: "chat.open", confirmation: "Opened Sessions"))
    #expect(await capture.last(tool: "chat.open")?["section"] == "sessions")

    #expect(
      try await router.execute("Tell team Staff: at channel create a launch plan")
        == .completed(toolName: "team.send_message", confirmation: "Messaged Staff"))
    #expect(
      await capture.last(tool: "team.send_message")?["message"]
        == "@channel create a launch plan")

    #expect(
      try await router.execute("Start a new session for team Staff")
        == .completed(
          toolName: "team.new_session", confirmation: "Started a new Staff session"))
    #expect(
      try await router.execute("Switch to Chat mode")
        == .completed(toolName: "surface.set", confirmation: "Opened Chat"))
    #expect(
      try await router.execute("Switch to Bots mode")
        == .completed(toolName: "chat.open", confirmation: "Opened Bots"))
    #expect(await capture.last(tool: "chat.open")?["section"] == "bots")
    #expect(await capture.last(tool: "surface.set")?["surface"] == "chat")
  }

  @Test("Spoken relay continues an agent whose transport had just closed")
  func relayContinuesExitedAgent() async throws {
    // A waiting agent whose one-shot CLI closed its PTY a beat before the exit event lands:
    // send_input fails with a closed transport, then the status settles to DONE and the text
    // continues the conversation as a prompt instead of surfacing a transport error.
    let script = ExitingAgentScript(states: ["WAITING_USER", "DONE"])
    let registry = ToolRegistry()
    try await registry.register(ExitingAgentStatusProbe(script: script))
    try await registry.register(ClosedTransportInputProbe(script: script))
    try await registry.register(ExitingAgentPromptProbe(script: script))
    let router = LocalVoiceCommandRouter(
      registry: registry,
      context: ToolContext(
        actorID: "relay-voice-test", scopes: Set(ToolScope.allCases), source: .voice)
    )
    await router.updateContext(
      VoiceContext(
        activeCanvas: VoiceCanvasContext(
          id: UUID(), name: "Work", workspace: "/tmp/work", layout: .freeform),
        nodes: [
          VoiceNodeContext(id: UUID(), name: "Chase", kind: .agent, provider: .codex, status: .idle)
        ]))

    let outcome = try await router.execute("Tell Chase to review the auth flow.")

    #expect(
      outcome == .completed(toolName: "agent.send_prompt", confirmation: "Sent verbatim to Chase"))
    #expect(await script.inputs == ["review the auth flow."])
    #expect(await script.prompts == ["review the auth flow."])
  }

  @Test("A failed command shows short wording and keeps the raw error for logs")
  func failedCommandWording() async throws {
    let script = ExitingAgentScript(states: ["IDLE"], promptFails: true)
    let registry = ToolRegistry()
    try await registry.register(ExitingAgentStatusProbe(script: script))
    try await registry.register(ClosedTransportInputProbe(script: script))
    try await registry.register(ExitingAgentPromptProbe(script: script))
    let router = LocalVoiceCommandRouter(
      registry: registry,
      context: ToolContext(
        actorID: "relay-voice-test", scopes: Set(ToolScope.allCases), source: .voice)
    )
    await router.updateContext(
      VoiceContext(
        activeCanvas: VoiceCanvasContext(
          id: UUID(), name: "Work", workspace: "/tmp/work", layout: .freeform),
        nodes: [
          VoiceNodeContext(id: UUID(), name: "Chase", kind: .agent, provider: .codex, status: .idle)
        ]))
    let session = LocalCommandSession(
      transcriber: SingleUtteranceTranscriber(utterance: "Tell Chase to review the auth flow."),
      router: router
    )
    let collector = CommandUpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(update) }
    }

    await session.start()
    try await waitUntil {
      await collector.updates.contains { $0.transcript == "Tell Chase to review the auth flow." }
    }
    await session.stopAndExecute()
    try await waitUntil {
      await collector.updates.contains { $0.state == .failed }
    }
    let failed = try #require(await collector.updates.first { $0.state == .failed })
    #expect(failed.detail == VoiceFailureText.transportClosedMessage)
    #expect(!failed.detail.contains("transport is closed"))
    #expect(failed.technicalDetail?.contains("transportClosed") == true)
    collectTask.cancel()
  }
}

private actor CommandUpdateCollector {
  private(set) var updates: [LocalCommandUpdate] = []
  func record(_ update: LocalCommandUpdate) { updates.append(update) }
}

/// Yields one transcript as soon as capture starts and finishes the stream on stop.
private final class SingleUtteranceTranscriber: SpeechTranscriber, @unchecked Sendable {
  let inputDiagnostics = AsyncStream<LocalSpeechInputDiagnostic> { $0.finish() }
  private let utterance: String
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<String, Error>.Continuation?

  init(utterance: String) { self.utterance = utterance }

  func requestAuthorization() async -> Bool { true }

  func startTranscribing() async throws -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      lock.withLock { self.continuation = continuation }
      continuation.yield(utterance)
    }
  }

  func stopTranscribing() async {
    lock.withLock {
      continuation?.finish()
      continuation = nil
    }
  }
}

/// Scripts an agent through the agent tools without a real process: `states` feed
/// agent.get_status in order (the last repeats), send_input always reports a closed transport,
/// and send_prompt records what reached it.
private actor ExitingAgentScript {
  private var states: [String]
  private let promptFails: Bool
  private(set) var inputs: [String] = []
  private(set) var prompts: [String] = []

  init(states: [String], promptFails: Bool = false) {
    self.states = states
    self.promptFails = promptFails
  }

  func nextState() -> String {
    states.count > 1 ? states.removeFirst() : states[0]
  }

  func recordInput(_ text: String) { inputs.append(text) }

  func recordPrompt(_ prompt: String) throws {
    prompts.append(prompt)
    if promptFails { throw RuntimeError.transportClosed }
  }
}

private struct ExitingAgentStatusProbe: OttoTool {
  struct Input: Codable, Sendable { var agentID: UUID }
  struct Output: Codable, Sendable { var state: String }

  static let definition = ToolDefinition(
    name: "agent.get_status",
    description: "Scripted status probe",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  let script: ExitingAgentScript

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    Output(state: await script.nextState())
  }
}

private struct ClosedTransportInputProbe: OttoTool {
  struct Input: Codable, Sendable {
    var agentID: UUID
    var text: String
  }
  struct Output: Codable, Sendable { var agentID: UUID }

  static let definition = ToolDefinition(
    name: "agent.send_input",
    description: "Input probe whose PTY has closed",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  let script: ExitingAgentScript

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    await script.recordInput(input.text)
    throw RuntimeError.transportClosed
  }
}

private struct ExitingAgentPromptProbe: OttoTool {
  struct Input: Codable, Sendable {
    var agentID: UUID
    var prompt: String
  }
  struct Output: Codable, Sendable {
    var agentID: UUID
    var state: String
  }

  static let definition = ToolDefinition(
    name: "agent.send_prompt",
    description: "Prompt probe standing in for the resume path",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  let script: ExitingAgentScript

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    try await script.recordPrompt(input.prompt)
    return Output(agentID: input.agentID, state: "WORKING")
  }
}

private actor VoiceBotControlCapture {
  private var calls: [(String, [String: String])] = []
  func append(_ tool: String, _ values: [String: String]) { calls.append((tool, values)) }
  func last(tool: String) -> [String: String]? { calls.last { $0.0 == tool }?.1 }
}

private struct VoiceBotOpenProbe: OttoTool {
  static let definition = ToolDefinition(
    name: "bot.open", description: "probe",
    inputSchema: .objectSchema(
      properties: ["bot": .stringSchema()], required: ["bot"]),
    outputSchema: .objectSchema(), requiredScopes: [], riskLevel: .reversible)
  let capture: VoiceBotControlCapture
  struct Input: Codable, Sendable { let bot: String }
  func call(_ input: Input, context: ToolContext) async throws -> Bool {
    await capture.append(Self.definition.name, ["bot": input.bot])
    return true
  }
}

private struct VoiceBotPromptProbe: OttoTool {
  static let definition = ToolDefinition(
    name: "bot.send_prompt", description: "probe",
    inputSchema: .objectSchema(
      properties: ["bot": .stringSchema(), "prompt": .stringSchema()],
      required: ["bot", "prompt"]),
    outputSchema: .objectSchema(), requiredScopes: [], riskLevel: .reversible)
  let capture: VoiceBotControlCapture
  struct Input: Codable, Sendable {
    let bot: String
    let prompt: String
  }
  func call(_ input: Input, context: ToolContext) async throws -> Bool {
    await capture.append(Self.definition.name, ["bot": input.bot, "prompt": input.prompt])
    return true
  }
}

private struct VoiceTeamMessageProbe: OttoTool {
  static let definition = ToolDefinition(
    name: "team.send_message", description: "probe",
    inputSchema: .objectSchema(
      properties: ["team": .stringSchema(), "message": .stringSchema()],
      required: ["team", "message"]),
    outputSchema: .objectSchema(), requiredScopes: [], riskLevel: .reversible)
  let capture: VoiceBotControlCapture
  struct Input: Codable, Sendable {
    let team: String
    let message: String
  }
  func call(_ input: Input, context: ToolContext) async throws -> Bool {
    await capture.append(Self.definition.name, ["team": input.team, "message": input.message])
    return true
  }
}

private struct VoiceTeamNewSessionProbe: OttoTool {
  static let definition = ToolDefinition(
    name: "team.new_session", description: "probe",
    inputSchema: .objectSchema(
      properties: ["team": .stringSchema()], required: ["team"]),
    outputSchema: .objectSchema(), requiredScopes: [], riskLevel: .reversible)
  let capture: VoiceBotControlCapture
  struct Input: Codable, Sendable { let team: String }
  func call(_ input: Input, context: ToolContext) async throws -> Bool {
    await capture.append(Self.definition.name, ["team": input.team])
    return true
  }
}

private struct VoiceSurfaceProbe: OttoTool {
  static let definition = ToolDefinition(
    name: "surface.set", description: "probe",
    inputSchema: .objectSchema(
      properties: ["surface": .stringSchema()], required: ["surface"]),
    outputSchema: .objectSchema(), requiredScopes: [], riskLevel: .reversible)
  let capture: VoiceBotControlCapture
  struct Input: Codable, Sendable { let surface: String }
  func call(_ input: Input, context: ToolContext) async throws -> Bool {
    await capture.append(Self.definition.name, ["surface": input.surface])
    return true
  }
}

private struct VoiceChatOpenProbe: OttoTool {
  static let definition = ToolDefinition(
    name: "chat.open", description: "probe",
    inputSchema: .objectSchema(
      properties: ["section": .stringSchema()], required: ["section"]),
    outputSchema: .objectSchema(), requiredScopes: [], riskLevel: .reversible)
  let capture: VoiceBotControlCapture
  struct Input: Codable, Sendable { let section: String }
  func call(_ input: Input, context: ToolContext) async throws -> Bool {
    await capture.append(Self.definition.name, ["section": input.section])
    return true
  }
}

private struct VoiceSessionOpenProbe: OttoTool {
  static let definition = ToolDefinition(
    name: "session.open", description: "probe",
    inputSchema: .objectSchema(
      properties: ["session": .stringSchema()], required: ["session"]),
    outputSchema: .objectSchema(), requiredScopes: [], riskLevel: .reversible)
  let capture: VoiceBotControlCapture
  struct Input: Codable, Sendable { let session: String }
  func call(_ input: Input, context: ToolContext) async throws -> Bool {
    await capture.append(Self.definition.name, ["session": input.session])
    return true
  }
}

private struct VoiceSessionPromptProbe: OttoTool {
  static let definition = ToolDefinition(
    name: "session.send_prompt", description: "probe",
    inputSchema: .objectSchema(
      properties: ["sessionID": .stringSchema(), "prompt": .stringSchema()],
      required: ["sessionID", "prompt"]),
    outputSchema: .objectSchema(), requiredScopes: [], riskLevel: .consequential)
  let capture: VoiceBotControlCapture
  struct Input: Codable, Sendable {
    let sessionID: UUID
    let prompt: String
  }
  func call(_ input: Input, context: ToolContext) async throws -> Bool {
    await capture.append(
      Self.definition.name,
      ["sessionID": input.sessionID.uuidString, "prompt": input.prompt]
    )
    return true
  }
}

@MainActor
private struct Fixture {
  let store: CanvasStore
  let registry: ToolRegistry
  let supervisor: AgentSupervisor
  let router: LocalVoiceCommandRouter
  let context: ToolContext
  let root: String
  let documents: WorkspaceDocumentStore

  init(canvasName: String = "Local Commands") async throws {
    root = NSTemporaryDirectory() + "otto-local-voice-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    documents = WorkspaceDocumentStore(rootPath: root)
    let canvas = OttoCanvas(name: canvasName)
    store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    registry = ToolRegistry()
    supervisor = AgentSupervisor()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: supervisor,
      documents: documents,
      workspacePath: root
    )
    context = ToolContext(
      actorID: "local-command-test",
      scopes: Set(ToolScope.allCases),
      source: .voice
    )
    router = LocalVoiceCommandRouter(registry: registry, context: context)
    await refreshContext()
  }

  func refreshContext() async {
    await router.updateContext(
      VoiceContext(
        canvas: store.activeCanvas,
        workspace: "/tmp/local-command-test",
        canvases: store.snapshot.canvases
      ))
  }

  func spawnMockAgent() async throws -> UUID {
    let output = try await registry.call(
      name: "agent.spawn_mock",
      input: .object(["x": .number(0), "y": .number(0)]),
      context: context
    )
    let agentID = try #require(output["agentID"]?.stringValue.flatMap(UUID.init(uuidString:)))
    try await waitUntil {
      (try? await supervisor.snapshot(agentID: agentID))?.state == .idle
    }
    return agentID
  }
}

private func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for local command condition")
}
