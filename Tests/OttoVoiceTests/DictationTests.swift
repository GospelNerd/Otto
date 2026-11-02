import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import OttoVoice
import Testing

@Suite("On-device dictation")
struct DictationTests {
  @Test("Dictated transcript prompts an idle agent verbatim")
  func routerPromptsIdleAgent() async throws {
    let fixture = try await DictationFixture()
    let agentID = try await fixture.spawnMockAgent()

    let router = DictationRouter(registry: fixture.registry, context: fixture.context)
    let receipt = try await router.deliver(
      transcript: "  Review the auth flow and list the gaps  ",
      to: agentID
    )
    #expect(receipt.contains("Prompted"))
    let names = await fixture.registry.auditLog().map(\.toolName)
    #expect(names.contains("agent.send_prompt"))
    try await waitUntil {
      (try? await fixture.supervisor.snapshot(agentID: agentID))?.state == .done
    }
    let snapshot = try await fixture.supervisor.snapshot(agentID: agentID)
    #expect(snapshot.lastPrompt == "  Review the auth flow and list the gaps  ")
  }

  @Test("Dictation falls back to raw input when the target is mid-run")
  func routerFallsBackToInput() async throws {
    let fixture = try await DictationFixture()
    let terminal = try await fixture.registry.call(
      name: "terminal.open",
      input: .object(["x": .number(0), "y": .number(0)]),
      context: fixture.context
    )
    let terminalID = try #require(
      terminal["terminalID"]?.stringValue.flatMap(UUID.init(uuidString:)))

    let router = DictationRouter(registry: fixture.registry, context: fixture.context)
    let receipt = try await router.deliver(transcript: "echo dictated-input", to: terminalID)
    #expect(receipt.contains("Sent input"))
    let names = await fixture.registry.auditLog().map(\.toolName)
    #expect(names.contains("agent.send_input"))
    #expect(!names.contains("agent.send_prompt"))
    _ = try await fixture.registry.call(
      name: "node.close",
      input: .object(["nodeID": .string(terminalID.uuidString)]),
      context: fixture.context
    )
  }

  @Test("Empty transcripts are never delivered")
  func emptyTranscript() async throws {
    let fixture = try await DictationFixture()
    let agentID = try await fixture.spawnMockAgent()
    let router = DictationRouter(registry: fixture.registry, context: fixture.context)
    let receipt = try await router.deliver(transcript: "   \n ", to: agentID)
    #expect(receipt == "Nothing to send")
    let names = await fixture.registry.auditLog().map(\.toolName)
    #expect(!names.contains("agent.send_prompt"))
    #expect(!names.contains("agent.send_input"))
  }

  @Test("Push-to-talk session streams partials and delivers on stop")
  func sessionEndToEnd() async throws {
    let fixture = try await DictationFixture()
    let agentID = try await fixture.spawnMockAgent()
    let transcriber = ScriptedTranscriber(
      authorized: true,
      script: ["Open", "Open the", "Open the release notes"]
    )
    let session = DictationSession(
      transcriber: transcriber,
      router: DictationRouter(registry: fixture.registry, context: fixture.context)
    )
    let collector = UpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(update) }
    }

    await session.start()
    try await waitUntil {
      await collector.snapshots.contains {
        $0.state == .listening && $0.transcript == "Open the release notes"
      }
    }
    await session.stopAndDeliver(to: agentID)
    try await waitUntil {
      await collector.snapshots.contains { $0.state == .idle && $0.detail.contains("Prompted") }
    }
    let names = await fixture.registry.auditLog().map(\.toolName)
    #expect(names.contains("agent.send_prompt"))
    let snapshot = try await fixture.supervisor.snapshot(agentID: agentID)
    #expect(snapshot.lastPrompt == "Open the release notes")
    collectTask.cancel()
  }

  @Test("A batch engine's transcript, produced while stopping, is still delivered")
  func batchTranscriptDeliveredOnStop() async throws {
    let fixture = try await DictationFixture()
    let agentID = try await fixture.spawnMockAgent()
    let session = DictationSession(
      transcriber: ScriptedTranscriber(
        authorized: true, script: ["Summarise the open issues"], transcribesOnStop: true),
      router: DictationRouter(registry: fixture.registry, context: fixture.context)
    )
    let collector = UpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(update) }
    }
    await session.start()
    await session.stopAndDeliver(to: agentID)
    try await waitUntil {
      await collector.snapshots.contains { $0.state == .idle && $0.detail.contains("Prompted") }
    }
    let snapshot = try await fixture.supervisor.snapshot(agentID: agentID)
    #expect(snapshot.lastPrompt == "Summarise the open issues")
    collectTask.cancel()
  }

  @Test("Denied speech authorization surfaces remediation instead of starting")
  func deniedAuthorization() async throws {
    let fixture = try await DictationFixture()
    let session = DictationSession(
      transcriber: ScriptedTranscriber(authorized: false, script: []),
      router: DictationRouter(registry: fixture.registry, context: fixture.context)
    )
    let collector = UpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(update) }
    }
    await session.start()
    try await waitUntil {
      await collector.snapshots.contains { $0.state == .denied }
    }
    let denied = try #require(await collector.snapshots.first { $0.state == .denied })
    #expect(denied.detail.contains("System Settings"))
    collectTask.cancel()
  }

  @Test("Stopping without a focused agent keeps the transcript and explains the fix")
  func missingTarget() async throws {
    let fixture = try await DictationFixture()
    let session = DictationSession(
      transcriber: ScriptedTranscriber(authorized: true, script: ["Ship it"]),
      router: DictationRouter(registry: fixture.registry, context: fixture.context)
    )
    let collector = UpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(update) }
    }
    await session.start()
    try await waitUntil {
      await collector.snapshots.contains { $0.transcript == "Ship it" }
    }
    await session.stopAndDeliver(to: nil)
    try await waitUntil {
      await collector.snapshots.contains { $0.state == .failed }
    }
    let failed = try #require(await collector.snapshots.first { $0.state == .failed })
    #expect(failed.transcript == "Ship it")
    #expect(failed.detail.contains("Focus an agent"))
    collectTask.cancel()
  }

  @Test("Live input diagnostics name the microphone and explain weak signal")
  func inputDiagnostics() async throws {
    let fixture = try await DictationFixture()
    let diagnostic = LocalSpeechInputDiagnostic(
      inputName: "Studio Mic",
      sampleRate: 48_000,
      channelCount: 1,
      rootMeanSquare: 0.01
    )
    let transcriber = ScriptedTranscriber(
      authorized: true,
      script: ["Organize"],
      diagnostic: diagnostic
    )
    let session = DictationSession(
      transcriber: transcriber,
      router: DictationRouter(registry: fixture.registry, context: fixture.context)
    )
    let collector = UpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(update) }
    }

    await session.start()
    try await waitUntil {
      await collector.snapshots.contains {
        $0.inputDiagnostic == diagnostic && $0.detail.contains("low signal")
      }
    }
    await session.cancel()
    collectTask.cancel()
  }

  @Test("Local capture can repeatedly start and stop without stale listening state")
  func repeatedLifecycle() async throws {
    let fixture = try await DictationFixture()
    let transcriber = ScriptedTranscriber(authorized: true, script: ["Organize"])
    let session = DictationSession(
      transcriber: transcriber,
      router: DictationRouter(registry: fixture.registry, context: fixture.context)
    )
    let collector = UpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(update) }
    }

    for cycle in 1...20 {
      await session.start()
      try await waitUntil {
        await collector.snapshots.filter { $0.state == .listening }.count >= cycle
      }
      await session.cancel()
      try await waitUntil {
        await collector.snapshots.filter { $0.detail == "Dictation cancelled" }.count >= cycle
      }
    }
    #expect(await transcriber.startCount == 20)
    #expect(await transcriber.stopCount == 20)
    collectTask.cancel()
  }

  @Test("Cancelling capture preserves the latest rolling transcript for recovery")
  func cancellationPreservesTranscript() async throws {
    let fixture = try await DictationFixture()
    let session = DictationSession(
      transcriber: ScriptedTranscriber(
        authorized: true, script: ["Keep", "Keep this unfinished thought"]),
      router: DictationRouter(registry: fixture.registry, context: fixture.context)
    )
    let collector = UpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(update) }
    }

    await session.start()
    try await waitUntil {
      await collector.snapshots.contains { $0.transcript == "Keep this unfinished thought" }
    }
    await session.cancel()
    try await waitUntil {
      await collector.snapshots.contains { $0.detail == "Dictation cancelled" }
    }
    let cancelled = try #require(
      await collector.snapshots.last { $0.detail == "Dictation cancelled" })
    #expect(cancelled.transcript == "Keep this unfinished thought")
    collectTask.cancel()
  }

  @Test("Dictation continues an agent whose transport had just closed")
  func routerContinuesExitedAgent() async throws {
    // A mid-run agent whose one-shot CLI closed its PTY a beat before the exit event lands:
    // send_input fails with a closed transport, then the status settles to DONE.
    let script = ExitingAgentScript(states: ["WORKING", "DONE"])
    let registry = ToolRegistry()
    try await registry.register(ExitingAgentStatusProbe(script: script))
    try await registry.register(ClosedTransportInputProbe(script: script))
    try await registry.register(ExitingAgentPromptProbe(script: script))
    let router = DictationRouter(
      registry: registry,
      context: ToolContext(actorID: "dictation-test", scopes: Set(ToolScope.allCases))
    )

    let receipt = try await router.deliver(transcript: "Ship the release notes", to: UUID())

    #expect(receipt == "Prompted Ship the release notes")
    #expect(await script.inputs == ["Ship the release notes"])
    #expect(await script.prompts == ["Ship the release notes"])
  }

  @Test("A failed delivery shows short wording and keeps the raw error for logs")
  func failedDeliveryWording() async throws {
    let script = ExitingAgentScript(states: ["IDLE"], promptFails: true)
    let registry = ToolRegistry()
    try await registry.register(ExitingAgentStatusProbe(script: script))
    try await registry.register(ClosedTransportInputProbe(script: script))
    try await registry.register(ExitingAgentPromptProbe(script: script))
    let session = DictationSession(
      transcriber: ScriptedTranscriber(authorized: true, script: ["Ship it"]),
      router: DictationRouter(
        registry: registry,
        context: ToolContext(actorID: "dictation-test", scopes: Set(ToolScope.allCases)))
    )
    let collector = UpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(update) }
    }

    await session.start()
    try await waitUntil {
      await collector.snapshots.contains { $0.transcript == "Ship it" }
    }
    await session.stopAndDeliver(to: UUID())
    try await waitUntil {
      await collector.snapshots.contains { $0.state == .failed }
    }
    let failed = try #require(await collector.snapshots.first { $0.state == .failed })
    #expect(failed.detail == VoiceFailureText.transportClosedMessage)
    #expect(!failed.detail.contains("transport is closed"))
    #expect(failed.technicalDetail?.contains("transportClosed") == true)
    #expect(failed.technicalDetail?.contains("The terminal transport is closed") == true)
    collectTask.cancel()
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

private struct DictationFixture {
  let registry: ToolRegistry
  let supervisor: AgentSupervisor
  let store: CanvasStore
  let context: ToolContext

  @MainActor
  init() async throws {
    let canvas = OttoCanvas(name: "Dictation")
    store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    supervisor = AgentSupervisor()
    registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: supervisor)
    context = ToolContext(actorID: "dictation-test", scopes: Set(ToolScope.allCases))
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

private actor UpdateCollector {
  private(set) var snapshots: [DictationUpdate] = []
  func record(_ update: DictationUpdate) { snapshots.append(update) }
}

private final class ScriptedTranscriber: SpeechTranscriber, @unchecked Sendable {
  let inputDiagnostics: AsyncStream<LocalSpeechInputDiagnostic>
  private let authorized: Bool
  private let script: [String]
  private let transcribesOnStop: Bool
  private let diagnostic: LocalSpeechInputDiagnostic?
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<String, Error>.Continuation?
  private let diagnosticContinuation: AsyncStream<LocalSpeechInputDiagnostic>.Continuation
  private var starts = 0
  private var stops = 0

  var startCount: Int { get async { lock.withLock { starts } } }
  var stopCount: Int { get async { lock.withLock { stops } } }

  init(
    authorized: Bool,
    script: [String],
    transcribesOnStop: Bool = false,
    diagnostic: LocalSpeechInputDiagnostic? = nil
  ) {
    self.authorized = authorized
    self.script = script
    self.transcribesOnStop = transcribesOnStop
    self.diagnostic = diagnostic
    var continuation: AsyncStream<LocalSpeechInputDiagnostic>.Continuation!
    inputDiagnostics = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    diagnosticContinuation = continuation
  }

  func requestAuthorization() async -> Bool { authorized }

  func startTranscribing() async throws -> AsyncThrowingStream<String, Error> {
    lock.withLock { starts += 1 }
    if let diagnostic { diagnosticContinuation.yield(diagnostic) }
    return AsyncThrowingStream { continuation in
      lock.withLock { self.continuation = continuation }
      if !transcribesOnStop { for line in script { continuation.yield(line) } }
    }
  }

  func stopTranscribing() async {
    lock.withLock {
      stops += 1
      if transcribesOnStop { for line in script { continuation?.yield(line) } }
      continuation?.finish()
      continuation = nil
    }
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
  Issue.record("Timed out waiting for dictation condition")
}
