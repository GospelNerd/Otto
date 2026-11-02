import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import OttoVoice
import Testing

/// Issue #46 against the real stack: a real registry over a real supervisor, real shell
/// processes whose PTYs have genuinely closed, and the same `DictationSession` /
/// `LocalCommandSession` paths the Chat sidebar's Voice row renders. No scripted tools.
///
/// The one-shot CLI race from the bug report cannot be forced deterministically, so the two
/// dead-agent shapes a shell provider can reach are used instead: a mock agent that finished its
/// turn and exited (status DONE; voice reaches it through agent.send_prompt), and a terminal
/// whose shell was told to `exit` (status STOPPED; voice reaches it through agent.send_input).
@Suite("Voice to a dead agent (live stack)", .serialized)
struct VoiceDeadAgentRelayLiveTests {
  static let rawTransportError = "The terminal transport is closed"

  @Test("The real supervisor throws transportClosed through the registry, unwrapped")
  func realStackThrowsTransportClosed() async throws {
    let fixture = try await LiveVoiceFixture()
    let agentID = try await fixture.spawnFinishedMockAgent()

    await #expect(throws: RuntimeError.transportClosed) {
      try await fixture.registry.call(
        name: "agent.send_input",
        input: .object(["agentID": .string(agentID.uuidString), "text": .string("hello")]),
        context: fixture.context
      )
    }
    await #expect(throws: RuntimeError.transportClosed) {
      try await fixture.registry.call(
        name: "agent.send_prompt",
        input: .object(["agentID": .string(agentID.uuidString), "prompt": .string("hello")]),
        context: fixture.context
      )
    }
    let message = VoiceFailureText.message(for: RuntimeError.transportClosed)
    #expect(message == VoiceFailureText.transportClosedMessage)
  }

  @Test("Dictating a sentence to a finished mock agent shows human wording, never raw text")
  func dictationToFinishedAgent() async throws {
    let fixture = try await LiveVoiceFixture()
    let agentID = try await fixture.spawnFinishedMockAgent()
    let before = try await fixture.supervisor.snapshot(agentID: agentID)

    let failed = try await fixture.dictate(
      "Use the staging database for the migration", to: agentID)

    #expect(failed.state == .failed)
    #expect(failed.detail == VoiceFailureText.transportClosedMessage)
    #expect(!failed.detail.contains(Self.rawTransportError))
    #expect(failed.technicalDetail?.contains(Self.rawTransportError) == true)
    #expect(failed.technicalDetail?.contains("transportClosed") == true)
    // A finished shell agent cannot be resumed: nothing new reached it.
    let after = try await fixture.supervisor.snapshot(agentID: agentID)
    #expect(after.lastPrompt == before.lastPrompt)
    #expect(after.runID == before.runID)
    #expect(after.exitCode != nil)
    let names = await fixture.registry.auditLog().map(\.toolName)
    #expect(names.contains("agent.send_prompt"))
  }

  @Test("A spoken command relayed to a finished mock agent shows human wording")
  func localCommandToFinishedAgent() async throws {
    let fixture = try await LiveVoiceFixture()
    let agentID = try await fixture.spawnFinishedMockAgent()
    await fixture.rename(agentID, to: "Chase")
    let before = try await fixture.supervisor.snapshot(agentID: agentID)

    let failed = try await fixture.command("Tell Chase to review the auth flow.")

    #expect(failed.state == .failed)
    #expect(failed.detail == VoiceFailureText.transportClosedMessage)
    #expect(!failed.detail.contains(Self.rawTransportError))
    #expect(failed.technicalDetail?.contains(Self.rawTransportError) == true)
    let after = try await fixture.supervisor.snapshot(agentID: agentID)
    #expect(after.lastPrompt == before.lastPrompt)
    #expect(after.runID == before.runID)
  }

  @Test("An approval spoken to a finished mock agent is never replayed as a prompt")
  func approvalToFinishedAgent() async throws {
    let fixture = try await LiveVoiceFixture()
    let agentID = try await fixture.spawnFinishedMockAgent()
    let before = try await fixture.supervisor.snapshot(agentID: agentID)

    let failed = try await fixture.dictate("yes", to: agentID)

    #expect(failed.state == .failed)
    #expect(failed.detail == VoiceFailureText.transportClosedMessage)
    #expect(!failed.detail.contains(Self.rawTransportError))
    let after = try await fixture.supervisor.snapshot(agentID: agentID)
    #expect(after.lastPrompt == before.lastPrompt)
    #expect(after.runID == before.runID)
    #expect(after.transcript.filter { $0.role == .user }.map(\.text) == ["warm up"])
  }

  @Test("A spoken command to a killed shell agent is worded as stopped, not busy")
  func localCommandToKilledAgent() async throws {
    // The process died mid-run (SIGKILL), so the supervisor records FAILED. Voice reaches it
    // through agent.send_prompt, which the supervisor refuses as an invalid transition; that
    // refusal must read as "stopped", not "busy".
    let fixture = try await LiveVoiceFixture()
    let agentID = try await fixture.spawnKilledMockAgent()
    await fixture.rename(agentID, to: "Chase")
    let before = try await fixture.supervisor.snapshot(agentID: agentID)
    #expect(before.state == .failed)

    let failed = try await fixture.command("Tell Chase to review the auth flow.")

    #expect(failed.state == .failed)
    #expect(failed.detail == VoiceFailureText.transportClosedMessage)
    #expect(!failed.detail.contains(Self.rawTransportError))
    #expect(!failed.detail.contains("busy"))
    #expect(failed.technicalDetail?.contains("invalidTransition") == true)
    let after = try await fixture.supervisor.snapshot(agentID: agentID)
    #expect(after.lastPrompt == before.lastPrompt)
    #expect(after.runID == before.runID)
  }

  @Test("Dictating to an exited terminal goes through send_input and shows human wording")
  func dictationToExitedTerminal() async throws {
    let fixture = try await LiveVoiceFixture()
    let terminalID = try await fixture.openExitedTerminal()
    let before = try await fixture.supervisor.snapshot(agentID: terminalID)
    // `exit` from a login shell records a non-zero code on some setups; either way the process
    // is gone and the state is terminal.
    #expect([.stopped, .failed].contains(before.state))

    let failed = try await fixture.dictate("Use the staging database", to: terminalID)

    let names = await fixture.registry.auditLog().map(\.toolName)
    #expect(names.contains("agent.send_input"))
    #expect(failed.state == .failed)
    #expect(failed.detail == VoiceFailureText.transportClosedMessage)
    #expect(!failed.detail.contains(Self.rawTransportError))
    #expect(failed.technicalDetail?.contains(Self.rawTransportError) == true)
    let after = try await fixture.supervisor.snapshot(agentID: terminalID)
    #expect(after.runID == before.runID)
  }

  @Test("An approval spoken to an exited terminal is never sent as a prompt")
  func approvalToExitedTerminal() async throws {
    let fixture = try await LiveVoiceFixture()
    let terminalID = try await fixture.openExitedTerminal()
    let before = try await fixture.supervisor.snapshot(agentID: terminalID)

    let failed = try await fixture.dictate("yes, go ahead", to: terminalID)

    let names = await fixture.registry.auditLog().map(\.toolName)
    #expect(names.contains("agent.send_input"))
    #expect(!names.contains("agent.send_prompt"))
    #expect(failed.state == .failed)
    #expect(failed.detail == VoiceFailureText.transportClosedMessage)
    let after = try await fixture.supervisor.snapshot(agentID: terminalID)
    #expect(after.runID == before.runID)
    #expect(after.lastPrompt == before.lastPrompt)
  }
}

@MainActor
private struct LiveVoiceFixture {
  let store: CanvasStore
  let registry: ToolRegistry
  let supervisor: AgentSupervisor
  let context: ToolContext
  let root: String

  init() async throws {
    root = NSTemporaryDirectory() + "otto-voice-dead-agent-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let canvas = OttoCanvas(name: "Dead agents")
    store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    supervisor = AgentSupervisor()
    registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: supervisor, workspacePath: root)
    // The same actor shape VoiceController gives DictationRouter and LocalVoiceCommandRouter.
    context = ToolContext(
      actorID: "otto-dictation", scopes: Set(ToolScope.allCases), source: .voice)
  }

  /// A real shell mock agent, prompted once so it prints DONE and exits: its PTY is closed and
  /// the supervisor reports DONE with an exit code.
  func spawnFinishedMockAgent() async throws -> UUID {
    let output = try await registry.call(
      name: "agent.spawn_mock",
      input: .object(["x": .number(0), "y": .number(0)]),
      context: context
    )
    let agentID = try #require(output["agentID"]?.stringValue.flatMap(UUID.init(uuidString:)))
    try await waitUntil("mock agent idle") {
      (try? await supervisor.snapshot(agentID: agentID))?.state == .idle
    }
    _ = try await registry.call(
      name: "agent.send_prompt",
      input: .object(["agentID": .string(agentID.uuidString), "prompt": .string("warm up")]),
      context: context
    )
    try await waitUntil("mock agent exited") {
      let snapshot = try? await supervisor.snapshot(agentID: agentID)
      return snapshot?.state == .done && snapshot?.exitCode != nil
    }
    return agentID
  }

  /// A real shell mock agent killed while idle: the PTY closes and the supervisor records
  /// FAILED with an exit code.
  func spawnKilledMockAgent() async throws -> UUID {
    let output = try await registry.call(
      name: "agent.spawn_mock",
      input: .object(["x": .number(0), "y": .number(0)]),
      context: context
    )
    let agentID = try #require(output["agentID"]?.stringValue.flatMap(UUID.init(uuidString:)))
    try await waitUntil("mock agent idle") {
      (try? await supervisor.snapshot(agentID: agentID))?.state == .idle
    }
    let processID = try #require(try await supervisor.snapshot(agentID: agentID).processID)
    kill(processID, SIGKILL)
    try await waitUntil("killed mock agent exited") {
      (try? await supervisor.snapshot(agentID: agentID))?.exitCode != nil
    }
    return agentID
  }

  /// A real terminal shell told to `exit`: the PTY closes and the supervisor records STOPPED.
  func openExitedTerminal() async throws -> UUID {
    let output = try await registry.call(
      name: "terminal.open",
      input: .object(["x": .number(0), "y": .number(0)]),
      context: context
    )
    let terminalID = try #require(
      output["terminalID"]?.stringValue.flatMap(UUID.init(uuidString:)))
    try await waitUntil("terminal running") {
      (try? await supervisor.snapshot(agentID: terminalID))?.processID != nil
    }
    _ = try await registry.call(
      name: "agent.send_input",
      input: .object(["agentID": .string(terminalID.uuidString), "text": .string("exit\n")]),
      context: context
    )
    try await waitUntil("terminal exited") {
      (try? await supervisor.snapshot(agentID: terminalID))?.exitCode != nil
    }
    return terminalID
  }

  func rename(_ nodeID: UUID, to name: String) {
    store.dispatch(.renameNode(id: nodeID, name: name))
  }

  /// Runs a dictation through the real session: capture, stop, deliver to `nodeID`.
  func dictate(_ utterance: String, to nodeID: UUID) async throws -> DictationUpdate {
    let session = DictationSession(
      transcriber: SingleUtteranceTranscriber(utterance: utterance),
      router: DictationRouter(registry: registry, context: context)
    )
    let collector = LiveUpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(dictation: update) }
    }
    defer { collectTask.cancel() }
    await session.start()
    try await waitUntil("dictation heard") {
      await collector.dictation.contains { $0.transcript == utterance }
    }
    await session.stopAndDeliver(to: nodeID)
    try await waitUntil("dictation finished") {
      await collector.dictation.contains { $0.state == .failed || $0.delivered }
    }
    return try #require(await collector.dictation.last { $0.state == .failed || $0.delivered })
  }

  /// Runs a local command through the real session with the store's current canvas as context.
  func command(_ utterance: String) async throws -> LocalCommandUpdate {
    let router = LocalVoiceCommandRouter(registry: registry, context: context)
    await router.updateContext(
      VoiceContext(canvas: store.activeCanvas, workspace: root, canvases: store.snapshot.canvases))
    let session = LocalCommandSession(
      transcriber: SingleUtteranceTranscriber(utterance: utterance),
      router: router
    )
    let collector = LiveUpdateCollector()
    let collectTask = Task {
      for await update in session.updates { await collector.record(command: update) }
    }
    defer { collectTask.cancel() }
    await session.start()
    try await waitUntil("command heard") {
      await collector.command.contains { $0.transcript == utterance }
    }
    await session.stopAndExecute()
    try await waitUntil("command finished") {
      await collector.command.contains { $0.state == .failed || $0.outcome != nil }
    }
    return try #require(
      await collector.command.last { $0.state == .failed || $0.outcome != nil })
  }
}

private actor LiveUpdateCollector {
  private(set) var dictation: [DictationUpdate] = []
  private(set) var command: [LocalCommandUpdate] = []
  func record(dictation update: DictationUpdate) { dictation.append(update) }
  func record(command update: LocalCommandUpdate) { command.append(update) }
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

private func waitUntil(
  _ description: String,
  timeout: Duration = .seconds(10),
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  Issue.record("Timed out waiting for \(description)")
}
