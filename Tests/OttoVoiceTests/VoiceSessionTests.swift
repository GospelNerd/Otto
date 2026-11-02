import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import OttoVoice
import Testing

private actor VoiceDelegationGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var entered = false

  func wait() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private struct BlockingVoiceTool: OttoTool {
  struct Input: Codable, Sendable {}
  struct Output: Codable, Sendable { var completed: Bool }

  static let definition = ToolDefinition(
    name: "test.blocking_voice_action",
    description: "Waits until the test releases a voice delegation.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  let gate: VoiceDelegationGate

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    await gate.wait()
    return Output(completed: true)
  }
}

private struct DirectVoiceAgentSpawnProbeTool: OttoTool {
  struct Input: Codable, Sendable {
    var provider: String
    var x: Double
    var y: Double
    var permissionMode: String
  }

  struct Output: Codable, Sendable {
    var permissionMode: String
  }

  static let definition = ToolDefinition(
    name: "agent.spawn",
    description: "Captures direct voice agent launch arguments.",
    inputSchema: .objectSchema(
      properties: [
        "provider": .stringSchema(),
        "x": .numberSchema(),
        "y": .numberSchema(),
        "permissionMode": .stringSchema(),
      ],
      required: ["provider", "x", "y", "permissionMode"]
    ),
    outputSchema: .objectSchema(),
    requiredScopes: [],
    riskLevel: .consequential
  )

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    Output(permissionMode: input.permissionMode)
  }
}

@Suite("Voice supervisor")
struct VoiceSessionTests {
  @Test("Direct voice agent launches use the saved provider permission")
  func directAgentLaunchUsesPermissionDefault() async throws {
    let suiteName = "otto.tests.voice-permissions.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
      AgentPermissionMode.unrestricted.rawValue,
      forKey: OttoPreferenceKey.claudePermissionMode
    )

    let registry = ToolRegistry()
    try await registry.register(DirectVoiceAgentSpawnProbeTool())
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: []),
      permissionDefaultsSuiteName: suiteName
    )

    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    await provider.emit(
      .toolCall(
        id: "direct-agent-launch",
        name: "agent.spawn",
        arguments: .object([
          "provider": .string(AgentProvider.claudeCode.rawValue),
          "x": .number(0),
          "y": .number(0),
          // The realtime model's generated value must not override Settings > Agents.
          "permissionMode": .string(AgentPermissionMode.readOnly.rawValue),
        ])
      ))

    let result = try await firstResult(from: provider.results)
    #expect(!result.isError)
    #expect(result.responseInstruction?.contains("Do not speak") == true)
    #expect(
      result.result["permissionMode"]?.stringValue
        == AgentPermissionMode.unrestricted.rawValue)
    await session.sleep()
  }

  @Test("Scripted provider projects schemas and completes a real tool call")
  func toolCallLoop() async throws {
    let canvas = OttoCanvas(name: "Voice")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let supervisor = AgentSupervisor()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: supervisor)
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(
        actorID: "voice",
        scopes: [.canvasRead, .canvasWrite, .agentRead, .agentControl]
      )
    )

    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    #expect(await provider.projectedTools.map(\.name).contains("agent.spawn_mock"))

    await provider.emit(.partialTranscript("Create an agent"))
    await provider.emit(.finalTranscript("Create an agent"))
    await provider.emit(.thinking)
    let actionTask = Task<VoiceActionEvent?, Never> {
      for await action in session.actions { return action }
      return nil
    }
    await provider.emit(
      .toolCall(
        id: "voice-call-1",
        name: "agent.spawn_mock",
        arguments: .object(["x": .number(0), "y": .number(0)])
      ))

    let result = try await firstResult(from: provider.results)
    #expect(!result.isError)
    let spawned = try result.result.decode(AgentSpawnOutput.self)
    let action = try #require(await actionTask.value)
    #expect(action.toolName == "agent.spawn_mock")
    #expect(action.output["agentID"]?.stringValue == spawned.agentID.uuidString)
    #expect(await store.activeCanvas.nodes.first?.id == spawned.agentID)
    #expect(await registry.auditLog().map(\.requestID).contains("voice-call-1"))

    await provider.emit(.speaking("I created "))
    await provider.emit(.speaking("an agent."))
    try await waitUntil { await session.snapshot().lastConfirmation == "I created an agent." }
    #expect(await session.snapshot().lastConfirmation == "I created an agent.")
    await session.interrupt()
    try await waitUntil { await session.snapshot().state == .interrupted }
    await session.sleep()
    #expect(await session.snapshot().state == .sleeping)
  }

  @Test("Slow tool delegation does not block incoming speech or transcript events")
  func asynchronousToolDelegation() async throws {
    let gate = VoiceDelegationGate()
    let registry = ToolRegistry()
    try await registry.register(BlockingVoiceTool(gate: gate))
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )

    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    await provider.emit(.speechStarted)
    await provider.emit(.partialTranscript("Run the slow action"))
    await provider.emit(.finalTranscript("Run the slow action"))
    try await waitUntil {
      await session.conversationRecords().first?.authority == .authoritative
    }

    let initialRecords = await session.conversationRecords()
    #expect(initialRecords.count == 1)
    #expect(initialRecords.first?.authority == .authoritative)
    #expect(initialRecords.first?.text == "Run the slow action")

    await provider.emit(
      .toolCall(
        id: "slow-call",
        name: BlockingVoiceTool.definition.name,
        arguments: .object([:])
      ))
    try await waitUntil { await gate.entered }

    // This event used to sit behind registry.call until the slow tool returned.
    await provider.emit(.speechStarted)
    await provider.emit(.partialTranscript("Actually, keep listening"))
    try await waitUntil {
      await session.snapshot().partialTranscript == "Actually, keep listening"
    }
    #expect(await session.snapshot().state == .userSpeaking)
    let overlappingRecords = await session.conversationRecords()
    #expect(overlappingRecords.last?.authority == .speculative)
    #expect(overlappingRecords.last?.text == "Actually, keep listening")

    let resultTask = Task<VoiceToolResult, any Error> {
      try await firstResult(from: provider.results)
    }
    await gate.release()
    let result = try await resultTask.value
    #expect(!result.isError)
    #expect(result.callID == "slow-call")
    // A late tool completion must not pull the active overlapping turn back into thinking.
    #expect(await session.snapshot().state == .userSpeaking)
    await session.sleep()
  }

  @Test("Full-duplex provider capability keeps playback alive during overlapping speech")
  func fullDuplexCapability() async throws {
    #expect(
      VoicePlaybackPolicy.shouldPlayProviderAudio(
        suppressProviderTurn: false,
        userInputActive: true,
        state: .userSpeaking,
        capabilities: .continuousFullDuplex
      )
    )
    #expect(
      !VoicePlaybackPolicy.shouldPlayProviderAudio(
        suppressProviderTurn: false,
        userInputActive: true,
        state: .userSpeaking,
        capabilities: .turnBased
      )
    )
    let provider = AudioVoiceProviderProbe(capabilities: .continuousFullDuplex)
    let audio = AudioTransportProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: []),
      audioTransport: audio
    )

    await session.connect(provider: provider)
    try await waitUntil("full-duplex audio startup") { await audio.hasStarted }
    await provider.emit(.speaking("I can keep talking"))
    try await waitUntil("full-duplex speaking state") {
      await session.snapshot().state == .speaking
    }
    await provider.emit(.speechStarted)
    try await waitUntil("full-duplex overlapping user state") {
      await session.snapshot().state == .userSpeaking
    }

    #expect(await audio.playbackStopCount == 0)
    #expect(await session.snapshot().state == .userSpeaking)
    await session.sleep()
  }

  @Test("Hiding a space preserves its in-flight voice tool delegation")
  func backgroundSpacePreservesDelegation() async throws {
    let gate = VoiceDelegationGate()
    let registry = ToolRegistry()
    try await registry.register(BlockingVoiceTool(gate: gate))
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: registry, context: ToolContext(actorID: "voice", scopes: []))
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    await provider.emit(
      .toolCall(
        id: "background-call", name: BlockingVoiceTool.definition.name,
        arguments: .object([:])))
    try await waitUntil { await gate.entered }
    await session.setMicrophoneEnabled(false)
    await session.setPresentationEnabled(false)
    let resultTask = Task<VoiceToolResult, any Error> {
      try await firstResult(from: provider.results)
    }
    await gate.release()
    let result = try await resultTask.value
    #expect(!result.isError)
    #expect(result.callID == "background-call")
    #expect(await session.snapshot().state != .sleeping)
    await session.setPresentationEnabled(true)
    await session.sleep()
  }

  @Test("Audio capture, playback, interruption, and sleep share one session lifecycle")
  func audioLifecycle() async throws {
    let registry = ToolRegistry()
    let provider = AudioVoiceProviderProbe()
    let audio = AudioTransportProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: []),
      audioTransport: audio
    )

    await session.connect(provider: provider)
    try await waitUntil { await audio.hasStarted }

    let microphoneBytes = Data([0, 1, 2, 3])
    await audio.capture(microphoneBytes)
    try await waitUntil { await provider.sentAudio == [microphoneBytes] }

    let speakerBytes = Data([4, 5, 6, 7])
    await provider.emitAudio(speakerBytes)
    try await waitUntil { await audio.played == [speakerBytes] }

    await session.interrupt()
    #expect(await audio.playbackStopCount == 1)
    #expect(await provider.interruptCount == 1)

    await session.sleep()
    #expect(await audio.stopCount == 1)
    #expect(await provider.disconnectCount == 1)
  }

  @Test("Push to talk connects for output before opening the microphone gate")
  func pushToTalkMicrophoneGate() async throws {
    let provider = AudioVoiceProviderProbe()
    let audio = AudioTransportProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: []),
      audioTransport: audio
    )

    await session.connect(provider: provider, microphoneEnabled: false)
    try await waitUntil { await session.snapshot().state == .listening }
    #expect(!(await audio.hasStarted))

    let speakerBytes = Data([4, 5, 6, 7])
    await provider.emitAudio(speakerBytes)
    try await waitUntil { await audio.played == [speakerBytes] }

    await session.setMicrophoneEnabled(true)
    #expect(await audio.hasStarted)
    #expect(await audio.inputEnabledChanges == [true])

    await session.setMicrophoneEnabled(false)
    #expect(await audio.inputEnabledChanges == [true, false])
    await session.sleep()
  }

  @Test("Voice can connect, sleep, and reconnect repeatedly without retaining capture")
  func repeatedConnectSleepReconnect() async throws {
    let audio = AudioTransportProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: []),
      audioTransport: audio
    )

    for cycle in 1...20 {
      let provider = AudioVoiceProviderProbe()
      await session.connect(provider: provider)
      try await waitUntil { await session.snapshot().state == .listening }
      await session.sleep()
      #expect(await session.snapshot().state == .sleeping)
      #expect(await provider.disconnectCount == 1)
      #expect(await audio.stopCount == cycle)
    }
  }

  @Test("Cloud capture publishes the selected input and actionable signal level")
  func inputDiagnosticProjection() async throws {
    let provider = AudioVoiceProviderProbe()
    let audio = AudioTransportProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: []),
      audioTransport: audio
    )

    await session.connect(provider: provider)
    try await waitUntil { await audio.hasStarted }
    await audio.reportMetrics(
      VoiceAudioInputMetrics(
        inputFrames: 512,
        outputBytes: 512,
        rootMeanSquare: 0.01,
        inputName: "USB Podcast Mic",
        sampleRate: 48_000,
        channelCount: 1
      ))
    try await waitUntil { await session.snapshot().inputDiagnostic?.inputName == "USB Podcast Mic" }
    let diagnostic = try #require(await session.snapshot().inputDiagnostic)
    #expect(diagnostic.quality == .low)
    #expect(diagnostic.actionableDetail.contains("move closer"))
    await session.sleep()
  }

  @Test(
    "Short spoken sleep commands disconnect locally",
    arguments: [
      "Go to sleep",
      "Otto, go to sleep now.",
      "Okay voice, sleep please",
      "You can go to sleep",
      "Can you go to sleep?",
      "Otto, could you please go to sleep?",
      "I need you to stop listening",
      "Stop listening",
      "Put yourself to sleep, thanks",
    ]
  )
  func spokenSleepCommand(transcript: String) async throws {
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: [])
    )

    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    await provider.emit(.finalTranscript(transcript))
    try await waitUntil { await session.snapshot().state == .sleeping }

    #expect(await provider.disconnectCount == 1)
    #expect(await session.snapshot().lastTranscript == transcript)
    #expect(
      await session.conversationTrace().contains {
        $0.kind == .session && $0.title == "Voice sleeping"
      }
    )
  }

  @Test(
    "Sleep words inside a wider request still reach the provider",
    arguments: [
      "Tell Chase to go to sleep",
      "Implement a go to sleep command",
      "When I say go to sleep, disconnect",
      "Do not go to sleep",
      "Stop listening for errors in that log",
    ]
  )
  func sleepPhraseFalsePositive(transcript: String) async throws {
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: [])
    )

    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    await provider.emit(.finalTranscript(transcript))
    try await waitUntil { await session.snapshot().lastTranscript == transcript }

    #expect(await session.snapshot().state == .endOfTurn)
    #expect(await provider.disconnectCount == 0)
    await session.sleep()
  }

  @Test("Verbatim relay sends only the exact delimited prompt to one named agent")
  func verbatimRelayExactness() async throws {
    let targetID = UUID()
    let target = VoiceNodeContext(
      id: targetID,
      name: "Chase",
      kind: .agent,
      provider: .claudeCode,
      status: .idle
    )
    let context = VoiceContext(
      activeCanvas: VoiceCanvasContext(
        id: UUID(),
        name: "Relay",
        workspace: "/workspace",
        layout: .freeform
      ),
      nodes: [target]
    )
    let capture = VerbatimRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(VerbatimStatusProbe())
    try await registry.register(VerbatimPromptProbe(capture: capture))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(context)
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    let prompt = "Review OAuth, preserve APIName exactly."
    await provider.emit(.finalTranscript("Tell Chase verbatim: \(prompt)"))
    try await waitUntil { await capture.prompts.count == 1 }
    try await waitUntil {
      let snapshot = await session.snapshot()
      return snapshot.lastConfirmation == "Sent verbatim to Chase"
        && snapshot.state == .listening
    }

    #expect(await capture.prompts == [VerbatimPromptProbe.Input(agentID: targetID, prompt: prompt)])
    #expect(await provider.interruptCount == 1)
    #expect(await session.snapshot().lastConfirmation == "Sent verbatim to Chase")
    #expect(await session.snapshot().state == .listening)

    // A late model-selected action from the cancelled provider turn must not duplicate the relay.
    await provider.emit(
      .toolCall(
        id: "late-relay",
        name: "agent.send_prompt",
        arguments: .object([
          "agentID": .string(targetID.uuidString),
          "prompt": .string("contaminated model rewrite"),
        ])
      ))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await capture.prompts.count == 1)
    await session.sleep()
  }

  @Test("Plain tell and ask commands relay word-for-word without a model rewrite")
  func implicitVerbatimRelay() async throws {
    let targetID = UUID()
    let context = relayContext(
      nodes: [
        VoiceNodeContext(
          id: targetID,
          name: "Chase",
          kind: .agent,
          provider: .claudeCode,
          status: .idle
        )
      ])
    let capture = VerbatimRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(VerbatimStatusProbe())
    try await registry.register(VerbatimPromptProbe(capture: capture))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(context)
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    // No "verbatim" keyword: the words still go to the agent directly, with the leading
    // connective stripped so the agent receives an imperative.
    await provider.emit(.finalTranscript("Tell Chase to review the OAuth flow, exactly as-is."))
    try await waitUntil { await capture.prompts.count == 1 }
    #expect(
      await capture.prompts.first
        == VerbatimPromptProbe.Input(
          agentID: targetID, prompt: "review the OAuth flow, exactly as-is."))
    #expect(await provider.interruptCount == 1)
    #expect(await session.snapshot().lastConfirmation == "Sent verbatim to Chase")

    await provider.emit(.speechStarted)
    await provider.emit(.finalTranscript("Ask Chase what broke the release build"))
    try await waitUntil { await capture.prompts.count == 2 }
    #expect(await capture.prompts.last?.prompt == "what broke the release build")
    await session.sleep()
  }

  @Test("Suffix relay without the verbatim keyword still strips the routing clause")
  func implicitSuffixRelay() async throws {
    let targetID = UUID()
    let context = relayContext(
      nodes: [
        VoiceNodeContext(
          id: targetID,
          name: "Rocky",
          kind: .agent,
          provider: .codex,
          status: .idle
        )
      ])
    let capture = VerbatimRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(VerbatimStatusProbe())
    try await registry.register(VerbatimPromptProbe(capture: capture))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(context)
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await provider.emit(.finalTranscript("Fix the flaky login test and send that to Rocky"))
    try await waitUntil { await capture.prompts.count == 1 }
    #expect(await capture.prompts.first?.prompt == "Fix the flaky login test")
    await session.sleep()
  }

  @Test("Cross-turn relay without the verbatim keyword sends the previous utterance")
  func implicitCrossTurnRelay() async throws {
    let targetID = UUID()
    let context = relayContext(
      nodes: [
        VoiceNodeContext(
          id: targetID,
          name: "Chase",
          kind: .agent,
          provider: .claudeCode,
          status: .idle
        )
      ])
    let capture = VerbatimRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(VerbatimStatusProbe())
    try await registry.register(VerbatimPromptProbe(capture: capture))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(context)
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    let source = "The retry queue drops jobs when the worker restarts mid-batch."
    await provider.emit(.finalTranscript(source))
    try await waitUntil { await session.snapshot().state == .endOfTurn }
    await provider.emit(.speechStarted)
    await provider.emit(.finalTranscript("Tell this to Chase"))
    try await waitUntil { await capture.prompts.count == 1 }
    #expect(await capture.prompts.first?.prompt == source)
    await session.sleep()
  }

  @Test(
    "Relay-shaped speech without a matching agent falls through to the model",
    arguments: [
      "Tell me what changed today",
      "Send the report to the whole team",
      "Ask about the deployment status",
    ]
  )
  func implicitRelayFallsBackToModel(transcript: String) async throws {
    let targetID = UUID()
    let capture = VerbatimRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(VerbatimStatusProbe())
    try await registry.register(VerbatimPromptProbe(capture: capture))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(
      relayContext(
        nodes: [
          VoiceNodeContext(
            id: targetID,
            name: "Chase",
            kind: .agent,
            provider: .claudeCode,
            status: .idle
          )
        ]))
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await provider.emit(.finalTranscript(transcript))
    try await waitUntil { await session.snapshot().state == .endOfTurn }

    // Without the "verbatim" keyword an unmatched relay must not produce a spoken error; the
    // realtime model keeps the turn.
    #expect(await capture.prompts.isEmpty)
    #expect(await provider.interruptCount == 0)
    #expect(await session.snapshot().lastError == nil)
    await session.sleep()
  }

  @Test("Suffix relay removes the routing clause but preserves prompt punctuation")
  func verbatimRelaySuffix() async throws {
    let targetID = UUID()
    let context = relayContext(
      nodes: [
        VoiceNodeContext(
          id: targetID,
          name: "Rocky",
          kind: .agent,
          provider: .codex,
          status: .idle
        )
      ])
    let capture = VerbatimRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(VerbatimStatusProbe())
    try await registry.register(VerbatimPromptProbe(capture: capture))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(context)
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    let prompt = "Review OAuth and preserve APIName exactly."
    await provider.emit(.finalTranscript("\(prompt) Send that over to Rocky verbatim."))
    try await waitUntil { await capture.prompts.count == 1 }

    #expect(await capture.prompts.first?.prompt == prompt)
    await session.sleep()
  }

  @Test("Cross-turn relay sends the previous user utterance exactly")
  func crossTurnVerbatimRelay() async throws {
    let targetID = UUID()
    let context = relayContext(
      nodes: [
        VoiceNodeContext(
          id: targetID,
          name: "Chase",
          kind: .agent,
          provider: .claudeCode,
          status: .idle
        )
      ])
    let capture = VerbatimRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(VerbatimStatusProbe())
    try await registry.register(VerbatimPromptProbe(capture: capture))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(context)
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    let source = "Review OAuth, preserve APIName and don't rewrite this sentence."
    await provider.emit(.finalTranscript(source))
    try await waitUntil { await session.snapshot().state == .endOfTurn }
    await provider.emit(.speechStarted)
    await provider.emit(.finalTranscript("Send what I just said to Chase verbatim."))
    try await waitUntil { await capture.prompts.count == 1 }

    #expect(await capture.prompts.first?.prompt == source)
    #expect(await session.snapshot().lastConfirmation == "Sent verbatim to Chase")
    #expect(
      await session.conversationTrace().contains {
        $0.kind == .session
          && $0.title == "Using previous utterance verbatim"
          && $0.detail == source
      }
    )
    await session.sleep()
  }

  @Test("Cross-turn relay refuses when no recent utterance is available")
  func crossTurnVerbatimMissingSource() async throws {
    let targetID = UUID()
    let capture = VerbatimRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(VerbatimStatusProbe())
    try await registry.register(VerbatimPromptProbe(capture: capture))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(
      relayContext(
        nodes: [
          VoiceNodeContext(
            id: targetID,
            name: "Chase",
            kind: .agent,
            provider: .claudeCode,
            status: .idle
          )
        ]))
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await provider.emit(.finalTranscript("Send that to Chase verbatim"))
    try await waitUntil { await session.snapshot().lastError != nil }

    #expect(await capture.prompts.isEmpty)
    #expect(
      await session.snapshot().lastError
        == "There is no recent utterance available to send verbatim")
    #expect(await provider.interruptCount == 1)
    await session.sleep()
  }

  @Test("Oversized utterances are never silently truncated for verbatim relay")
  func crossTurnVerbatimOversizedSource() async throws {
    let targetID = UUID()
    let capture = VerbatimRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(VerbatimStatusProbe())
    try await registry.register(VerbatimPromptProbe(capture: capture))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(
      relayContext(
        nodes: [
          VoiceNodeContext(
            id: targetID,
            name: "Chase",
            kind: .agent,
            provider: .claudeCode,
            status: .idle
          )
        ]))
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await provider.emit(.finalTranscript(String(repeating: "x", count: 8_001)))
    try await waitUntil { await session.snapshot().state == .endOfTurn }
    await provider.emit(.speechStarted)
    await provider.emit(.finalTranscript("Send my last message to Chase verbatim"))
    try await waitUntil { await session.snapshot().lastError != nil }

    #expect(await capture.prompts.isEmpty)
    #expect(
      await session.snapshot().lastError
        == "There is no recent utterance available to send verbatim")
    await session.sleep()
  }

  @Test("Ambiguous or incomplete verbatim relays are cancelled instead of broadcast")
  func verbatimRelayAmbiguity() async throws {
    let duplicateNameNodes = [
      VoiceNodeContext(
        id: UUID(), name: "Chase", kind: .agent, provider: .claudeCode, status: .idle),
      VoiceNodeContext(
        id: UUID(), name: "Chase", kind: .agent, provider: .codex, status: .idle),
    ]
    let capture = VerbatimRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(VerbatimStatusProbe())
    try await registry.register(VerbatimPromptProbe(capture: capture))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(relayContext(nodes: duplicateNameNodes))
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await provider.emit(.finalTranscript("Tell Chase verbatim: review the auth flow"))
    try await waitUntil { await session.snapshot().lastError != nil }

    #expect(await capture.prompts.isEmpty)
    #expect(await provider.interruptCount == 1)
    #expect(await session.snapshot().lastError?.contains("ambiguous") == true)
    await session.sleep()
  }

  @Test("Ordinary uses of verbatim and non-verbatim prompts still reach the model")
  func verbatimRelayFalsePositives() async throws {
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(relayContext(nodes: []))
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await provider.emit(.finalTranscript("Explain what verbatim means"))
    try await waitUntil { await session.snapshot().state == .endOfTurn }
    #expect(await provider.interruptCount == 0)
    await session.sleep()
  }

  @Test(
    "Model-selected close-all authorizes a direct current turn without a synonym list",
    arguments: ["Can you clear them?", "Please tidy this place up"]
  )
  func explicitCloseAll(transcript: String) async throws {
    let first = OttoNode(
      kind: .browser,
      displayName: "Reference",
      subtitle: "BROWSER",
      frame: WorldRect(x: 0, y: 0, width: 400, height: 300),
      zIndex: 0
    )
    let second = OttoNode(
      kind: .terminal,
      displayName: "Shell",
      subtitle: "TERMINAL",
      frame: WorldRect(x: 420, y: 0, width: 400, height: 300),
      zIndex: 1
    )
    let canvas = OttoCanvas(name: "Voice close", nodes: [first, second])
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor())
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: Set(ToolScope.allCases))
    )

    await session.connect(provider: provider)
    await provider.emit(.finalTranscript(transcript))
    await provider.emit(
      .toolCall(id: "close-all", name: "node.close_all", arguments: .object([:])))

    let result = try await firstResult(from: provider.results)
    #expect(!result.isError)
    #expect(await store.activeCanvas.nodes.isEmpty)
    let trace = await session.conversationTrace()
    #expect(trace.contains { $0.kind == .user && $0.detail == transcript })
    #expect(
      trace.contains {
        $0.kind == .toolResult && $0.title == "node.close_all" && $0.succeeded == true
      })
  }

  @Test("Close-all remains denied without explicit positive intent")
  func closeAllDeniesNegativeIntent() async throws {
    let node = OttoNode(
      kind: .browser,
      displayName: "Keep me",
      subtitle: "BROWSER",
      frame: WorldRect(x: 0, y: 0, width: 400, height: 300),
      zIndex: 0
    )
    let canvas = OttoCanvas(name: "Voice close guard", nodes: [node])
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor())
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: Set(ToolScope.allCases))
    )

    await session.connect(provider: provider)
    await provider.emit(.finalTranscript("Don't close all the windows"))
    await provider.emit(
      .toolCall(id: "denied-close-all", name: "node.close_all", arguments: .object([:])))

    let result = try await firstResult(from: provider.results)
    #expect(result.isError)
    #expect(await store.activeCanvas.nodes.count == 1)
    #expect(result.result["error"]?.stringValue?.contains("requires confirmation") == true)

    await provider.emit(
      .toolCall(id: "duplicate-close-all", name: "node.close_all", arguments: .object([:])))
    let duplicate = try await firstResult(from: provider.results)
    #expect(duplicate.isError)
    #expect(
      duplicate.result["error"]?.stringValue?.contains("Repeated failed action suppressed") == true)
    try await waitUntil { await session.snapshot().state == .interrupted }
    #expect(await store.activeCanvas.nodes.count == 1)
  }

  @Test("Speech-start barge-in stops playback and drops late assistant audio")
  func speechStartBargeIn() async throws {
    let provider = AudioVoiceProviderProbe()
    let audio = AudioTransportProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: []),
      audioTransport: audio
    )

    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    await provider.emit(.speaking("This answer is too long"))
    try await waitUntil { await session.snapshot().state == .speaking }
    await provider.emit(.speechStarted)
    try await waitUntil { await session.snapshot().state == .userSpeaking }
    await provider.emit(.speaking(" stale assistant delta"))
    await provider.emitAudio(Data([9, 9, 9]))
    try await Task.sleep(for: .milliseconds(20))

    #expect(await audio.playbackStopCount == 1)
    #expect(await audio.played.isEmpty)
    #expect(await session.snapshot().state == .userSpeaking)
    #expect(await session.conversationTrace().contains { $0.kind == .interruption })
  }

  @Test("Local microphone activity cancels playback before provider VAD")
  func localSpeechBargeIn() async throws {
    let provider = AudioVoiceProviderProbe()
    let audio = AudioTransportProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: []),
      audioTransport: audio
    )

    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    await provider.emit(.speaking("A response that should stop"))
    try await waitUntil { await session.snapshot().state == .speaking }
    await audio.detectSpeech()

    try await waitUntil { await session.snapshot().state == .userSpeaking }
    #expect(await audio.playbackStopCount == 1)
    #expect(await provider.interruptCount == 1)
    #expect(
      await session.conversationTrace().contains {
        $0.kind == .interruption && $0.title == "Local barge-in"
      })
  }

  @Test("Provider events remain responsive while microphone startup is pending")
  func providerEventsBeforeAudioStartupCompletes() async throws {
    let provider = AudioVoiceProviderProbe()
    let audio = BlockingAudioTransportProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: []),
      audioTransport: audio
    )

    let connectTask = Task { await session.connect(provider: provider) }
    try await waitUntil { await audio.hasStarted }
    try await waitUntil { await session.snapshot().state == .listening }
    await audio.releaseStartup()
    await connectTask.value
    await session.sleep()
  }

  @Test("A successful reconnect clears stale voice errors and confirmations")
  func reconnectClearsStaleState() async throws {
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.connect(provider: FailingVoiceProvider())
    #expect(await session.snapshot().state == .error)
    #expect(await session.snapshot().lastError != nil)

    let provider = ScriptedVoiceProvider()
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    let snapshot = await session.snapshot()
    #expect(snapshot.lastError == nil)
    #expect(snapshot.lastConfirmation.isEmpty)
    await session.sleep()
  }

  @Test("A spoken approval to an agent that had exited is reported, not re-run as a prompt")
  func spokenApprovalToExitedAgentIsNotReplayed() async throws {
    // The realtime model answers a permission prompt, but the one-shot CLI already exited.
    // Respawning the provider to run a whole turn on "yes, go ahead" would cost money and leave
    // a baffling transcript, so the person gets the short error instead.
    let script = ExitingAgentScript(states: ["WAITING_PERMISSION", "DONE"])
    let registry = ToolRegistry()
    try await registry.register(ExitingAgentStatusProbe(script: script))
    try await registry.register(ClosedTransportInputProbe(script: script))
    try await registry.register(ExitingAgentPromptProbe(script: script))
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await provider.emit(
      .toolCall(
        id: "spoken-input",
        name: "agent.send_input",
        arguments: .object([
          "agentID": .string(UUID().uuidString),
          "text": .string("yes, go ahead"),
        ])
      ))

    let result = try await firstResult(from: provider.results)
    #expect(result.isError)
    #expect(result.result["error"]?.stringValue == VoiceFailureText.transportClosedMessage)
    #expect(await script.inputs == ["yes, go ahead"])
    #expect(await script.prompts.isEmpty)
    try await waitUntil { await session.snapshot().lastError != nil }
    #expect(await session.snapshot().lastError == VoiceFailureText.transportClosedMessage)
    let trace = await session.conversationTrace()
    #expect(!trace.contains { $0.title == "Agent had exited; continued as a prompt" })
    await session.sleep()
  }

  @Test("Spoken agent input continues an agent whose exit was recorded")
  func spokenInputContinuesExitedAgent() async throws {
    // A real instruction for a waiting agent whose one-shot CLI closed the PTY a beat before
    // its exit event: send_input reports a closed transport, the status settles to DONE, and
    // the text continues the conversation as a prompt.
    let script = ExitingAgentScript(states: ["WAITING_USER", "DONE"])
    let registry = ToolRegistry()
    try await registry.register(ExitingAgentStatusProbe(script: script))
    try await registry.register(ClosedTransportInputProbe(script: script))
    try await registry.register(ExitingAgentPromptProbe(script: script))
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await provider.emit(
      .toolCall(
        id: "spoken-input",
        name: "agent.send_input",
        arguments: .object([
          "agentID": .string(UUID().uuidString),
          "text": .string("Use the staging database for the migration"),
        ])
      ))

    let result = try await firstResult(from: provider.results)
    #expect(!result.isError)
    #expect(await script.inputs == ["Use the staging database for the migration"])
    #expect(await script.prompts == ["Use the staging database for the migration"])
    #expect(await session.snapshot().lastError == nil)
    let trace = await session.conversationTrace()
    #expect(trace.contains { $0.title == "Agent had exited; continued as a prompt" })
    #expect(!trace.contains { $0.succeeded == false })
    await session.sleep()
  }

  @Test("Verbatim relay continues an agent that had just exited")
  func verbatimRelayContinuesExitedAgent() async throws {
    let targetID = UUID()
    let script = ExitingAgentScript(states: ["WAITING_USER", "DONE"])
    let registry = ToolRegistry()
    try await registry.register(ExitingAgentStatusProbe(script: script))
    try await registry.register(ClosedTransportInputProbe(script: script))
    try await registry.register(ExitingAgentPromptProbe(script: script))
    let provider = AudioVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.updateContext(
      relayContext(
        nodes: [
          VoiceNodeContext(
            id: targetID, name: "Chase", kind: .agent, provider: .claudeCode, status: .idle)
        ]))
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await provider.emit(.finalTranscript("Tell Chase verbatim: review the auth flow"))
    try await waitUntil { await session.snapshot().lastConfirmation == "Sent verbatim to Chase" }

    #expect(await script.prompts == ["review the auth flow"])
    #expect(await session.snapshot().lastError == nil)
    await session.sleep()
  }

  @Test("Tool failures use short wording and the next turn clears them")
  func toolFailureWordingClearsOnNextTurn() async throws {
    let script = ExitingAgentScript(states: ["IDLE"], promptFails: true)
    let registry = ToolRegistry()
    try await registry.register(ExitingAgentStatusProbe(script: script))
    try await registry.register(ClosedTransportInputProbe(script: script))
    try await registry.register(ExitingAgentPromptProbe(script: script))
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await provider.emit(
      .toolCall(
        id: "failing-prompt",
        name: "agent.send_prompt",
        arguments: .object([
          "agentID": .string(UUID().uuidString),
          "prompt": .string("summarise the diff"),
        ])
      ))

    let result = try await firstResult(from: provider.results)
    #expect(result.isError)
    #expect(result.result["error"]?.stringValue == VoiceFailureText.transportClosedMessage)
    try await waitUntil { await session.snapshot().lastError != nil }
    let lastError = try #require(await session.snapshot().lastError)
    #expect(lastError == VoiceFailureText.transportClosedMessage)
    #expect(!lastError.contains("transport is closed"))
    // The raw error stays in the trace for diagnosis.
    let trace = await session.conversationTrace()
    #expect(
      trace.contains {
        $0.kind == .toolResult && $0.succeeded == false && $0.detail.contains("transportClosed")
      })

    // Starting to speak again supersedes the old failure.
    await provider.emit(.speechStarted)
    try await waitUntil { await session.snapshot().lastError == nil }
    #expect(await session.snapshot().lastError == nil)
    await session.sleep()
  }

  @Test("Latest compact canvas context is projected when voice connects")
  func contextProjection() async throws {
    let node = OttoNode(
      kind: .agent,
      displayName: "Rowan",
      subtitle: "CODEX",
      frame: WorldRect(x: 10, y: 20, width: 300, height: 200),
      zIndex: 0,
      status: .working,
      detail: "Sensitive terminal output is excluded",
      content: .agent(provider: .codex)
    )
    let canvas = OttoCanvas(
      name: "Payments",
      nodes: [node],
      selectedNodeID: node.id,
      layoutMode: .stage
    )
    let context = VoiceContext(canvas: canvas, workspace: "/workspace/payments")
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: [])
    )

    await session.updateContext(context)
    await session.connect(provider: provider)
    try await waitUntil { await provider.contexts == [context] }

    let projected = try #require(await provider.contexts.first)
    #expect(projected.activeCanvas.name == "Payments")
    #expect(projected.focusedNodeID == node.id)
    #expect(projected.nodes.first?.provider == .codex)
    #expect(!String(describing: projected).contains("Sensitive terminal output"))
  }

  @Test("Sleeping completions flush as a compact digest after reconnect")
  func sleepingCompletionDigest() async throws {
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: []),
      notificationPolicy: CompletionNotificationPolicy(queueWhileSleeping: true)
    )
    await session.notify(
      AgentVoiceNotice(
        agentID: UUID(),
        name: "Rowan",
        status: .done,
        summary: "Authentication review completed"
      ))
    await session.notify(
      AgentVoiceNotice(
        agentID: UUID(),
        name: "Sage",
        status: .waiting,
        summary: "Permission required"
      ))
    #expect(await provider.notifications.isEmpty)

    await session.connect(provider: provider)
    try await waitUntil { await provider.notifications.count == 1 }
    let digest = try #require(await provider.notifications.first)
    #expect(digest.contains("2 agent updates"))
    #expect(digest.contains("Rowan finished"))
    #expect(digest.contains("Sage needs attention"))
  }

  @Test("Sleeping completions are not replayed when voice is first enabled")
  func sleepingCompletionsAreDroppedByDefault() async throws {
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.notify(
      AgentVoiceNotice(
        agentID: UUID(),
        name: "Rowan",
        status: .done,
        summary: "Work completed while voice was off"
      ))

    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    try await Task.sleep(for: .milliseconds(750))
    #expect(await provider.notifications.isEmpty)
  }

  @Test("Simultaneous agent completions are staged into one summarized digest")
  func simultaneousCompletionDigest() async throws {
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    for index in 1...10 {
      await session.notify(
        AgentVoiceNotice(
          agentID: UUID(),
          name: "Agent \(index)",
          status: .done,
          summary: String(repeating: "Long completion detail ", count: 80)
        ))
    }

    try await waitUntil { await provider.notifications.count == 1 }
    let digest = try #require(await provider.notifications.first)
    #expect(digest.contains("10 agent updates arrived together"))
    #expect(digest.contains("one short grouped digest"))
    #expect(await provider.notifications.count == 1)
  }

  @Test("Completion asides start with the outcome and never leak turn-deference instructions")
  func completionAsideOmitsInternalDeferenceInstruction() async throws {
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    await session.notify(
      AgentVoiceNotice(
        agentID: UUID(),
        name: "Aria",
        status: .done,
        summary: "Deployed the docs site"
      ))
    try await waitUntil { await provider.notifications.count == 1 }

    await session.notify(
      AgentVoiceNotice(agentID: UUID(), name: "Rowan", status: .done, summary: "Tests green"))
    await session.notify(
      AgentVoiceNotice(agentID: UUID(), name: "Sage", status: .failed, summary: "Build broke"))
    try await waitUntil { await provider.notifications.count == 2 }

    for prompt in await provider.notifications {
      // The old contract said "if one is open or partially answered, finish it completely
      // before this"; the realtime model paraphrased that aloud ("you've got an open request,
      // finish that first…") before the useful aside. No phrasing about the user's open or
      // pending request may ever reach the provider.
      let lowered = prompt.lowercased()
      #expect(!lowered.contains("open or partially answered"))
      #expect(!lowered.contains("finish it completely"))
      #expect(!lowered.contains("user's own request"))
      #expect(!lowered.contains("comes first"))
      #expect(!lowered.contains("before this"))
      // The contract must open directly with the aside requirement.
      #expect(prompt.hasPrefix("Speak one brief aside that begins with \"By the way\""))
    }
    #expect(await provider.notifications.first?.contains("Aria finished") == true)
    #expect(await provider.notifications.last?.contains("2 agent updates") == true)
    await session.sleep()
  }

  @Test("An abandoned user turn releases playback and queued notices")
  func abandonedTurnReleasesPlaybackAndNotices() async throws {
    let provider = AudioVoiceProviderProbe()
    let audio = AudioTransportProbe()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: []),
      audioTransport: audio
    )
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }

    // A push-to-talk tap with no usable speech: server VAD opens a turn, the microphone gate
    // closes on release, and transcription yields nothing (empty or failed). The session must
    // return to listening instead of latching the user turn open.
    await provider.emit(.speechStarted)
    await provider.emit(.partialTranscript("uh"))
    try await waitUntil { await session.snapshot().state == .userSpeaking }
    await provider.emit(.speechStopped)
    await provider.emit(.finalTranscript("  "))
    try await waitUntil { await session.snapshot().state == .listening }

    // The half-spoken provisional record must not survive as a permanent speculative row.
    #expect(await session.conversationRecords().isEmpty)

    // Assistant audio flows again; a latched turn used to drop every buffer silently.
    let announcement = Data([1, 2, 3])
    await provider.emitAudio(announcement)
    try await waitUntil { await audio.played == [announcement] }

    // Queued completion notices are spoken again as well.
    await session.notify(
      AgentVoiceNotice(
        agentID: UUID(),
        name: "Aria",
        status: .done,
        summary: "Finished the review"
      ))
    try await waitUntil { await provider.notifications.count == 1 }
    await session.sleep()
  }

  @Test("Completion notification never speaks over user speech")
  func notificationDefersForUserSpeech() async throws {
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "voice", scopes: [])
    )
    await session.connect(provider: provider)
    try await waitUntil { await session.snapshot().state == .listening }
    await provider.emit(.speechStarted)
    try await waitUntil { await session.snapshot().state == .userSpeaking }
    await session.notify(
      AgentVoiceNotice(
        agentID: UUID(),
        name: "Marlow",
        status: .failed,
        summary: "Build failed"
      ))
    #expect(await provider.notifications.isEmpty)

    await provider.emit(.speechStopped)
    await provider.emit(.finalTranscript("What finished?"))
    await provider.emit(.speechFinished)
    try await waitUntil { await provider.notifications.count == 1 }
    #expect(await provider.notifications.first?.contains("Marlow failed") == true)
  }

  @Test("Reference resolution handles names, ordinals, ambiguity, and misses")
  func referenceResolution() {
    let first = OttoNode(
      kind: .agent,
      displayName: "Chase",
      subtitle: "CODEX",
      frame: WorldRect(x: 0, y: 0, width: 300, height: 200),
      zIndex: 0
    )
    let second = OttoNode(
      kind: .agent,
      displayName: "Marlow",
      subtitle: "CLAUDE",
      frame: WorldRect(x: 400, y: 0, width: 300, height: 200),
      zIndex: 1,
      createdAt: first.createdAt.addingTimeInterval(1)
    )
    #expect(ReferenceResolver.resolve("Chase", nodes: [first, second]) == .resolved(first.id))
    #expect(
      ReferenceResolver.resolve("the second agent", nodes: [first, second]) == .resolved(second.id))
    #expect(ReferenceResolver.resolve("unknown", nodes: [first, second]) == .notFound)

    var duplicate = second
    duplicate.displayName = "Chase"
    #expect(
      ReferenceResolver.resolve("Chase", nodes: [first, duplicate])
        == .ambiguous([first.id, duplicate.id]))
  }
}

private func relayContext(nodes: [VoiceNodeContext]) -> VoiceContext {
  VoiceContext(
    activeCanvas: VoiceCanvasContext(
      id: UUID(),
      name: "Relay",
      workspace: "/workspace",
      layout: .freeform
    ),
    nodes: nodes
  )
}

private actor VerbatimRelayCapture {
  private(set) var prompts: [VerbatimPromptProbe.Input] = []

  func record(_ input: VerbatimPromptProbe.Input) {
    prompts.append(input)
  }
}

private struct VerbatimStatusProbe: OttoTool {
  struct Input: Codable, Sendable {
    var agentID: UUID
  }

  struct Output: Codable, Sendable {
    var state: String
  }

  static let definition = ToolDefinition(
    name: "agent.get_status",
    description: "Test status probe",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    Output(state: "IDLE")
  }
}

private struct VerbatimPromptProbe: OttoTool {
  struct Input: Codable, Sendable, Equatable {
    var agentID: UUID
    var prompt: String
  }

  struct Output: Codable, Sendable {
    var agentID: UUID
  }

  static let definition = ToolDefinition(
    name: "agent.send_prompt",
    description: "Test prompt probe",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  let capture: VerbatimRelayCapture

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    await capture.record(input)
    return Output(agentID: input.agentID)
  }
}

private actor AudioTransportProbe: VoiceAudioTransport {
  private var inputHandler: (@Sendable (Data) -> Void)?
  private var speechActivityHandler: (@Sendable () -> Void)?
  private var metricsHandler: (@Sendable (VoiceAudioInputMetrics) -> Void)?
  private(set) var played: [Data] = []
  private(set) var playbackStopCount = 0
  private(set) var stopCount = 0
  private(set) var inputEnabledChanges: [Bool] = []

  var hasStarted: Bool { inputHandler != nil }

  func setSpeechActivityHandler(_ handler: (@Sendable () -> Void)?) {
    speechActivityHandler = handler
  }

  func setInputMetricsHandler(_ handler: (@Sendable (VoiceAudioInputMetrics) -> Void)?) {
    metricsHandler = handler
  }

  func startInput(_ handler: @escaping @Sendable (Data) -> Void) async throws {
    inputHandler = handler
  }

  func setInputEnabled(_ enabled: Bool) { inputEnabledChanges.append(enabled) }

  func capture(_ data: Data) { inputHandler?(data) }
  func detectSpeech() { speechActivityHandler?() }
  func reportMetrics(_ metrics: VoiceAudioInputMetrics) { metricsHandler?(metrics) }
  func play(_ data: Data) { played.append(data) }
  func stopPlayback() { playbackStopCount += 1 }
  func stop() { stopCount += 1 }
}

private actor BlockingAudioTransportProbe: VoiceAudioTransport {
  private var startupContinuation: CheckedContinuation<Void, Never>?
  private(set) var hasStarted = false

  func startInput(_ handler: @escaping @Sendable (Data) -> Void) async throws {
    hasStarted = true
    await withCheckedContinuation { continuation in
      startupContinuation = continuation
    }
  }

  func releaseStartup() {
    startupContinuation?.resume()
    startupContinuation = nil
  }

  func play(_ data: Data) {}
  func stopPlayback() {}
  func stop() { releaseStartup() }
}

private actor AudioVoiceProviderProbe: StreamingVoiceProvider {
  nonisolated let events: AsyncStream<VoiceProviderEvent>
  nonisolated let audioOutput: AsyncStream<Data>
  nonisolated let capabilities: VoiceProviderCapabilities
  private let eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation
  private let audioContinuation: AsyncStream<Data>.Continuation
  private(set) var sentAudio: [Data] = []
  private(set) var interruptCount = 0
  private(set) var disconnectCount = 0
  private(set) var notifications: [String] = []

  init(capabilities: VoiceProviderCapabilities = .turnBased) {
    self.capabilities = capabilities
    var eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation!
    events = AsyncStream { eventContinuation = $0 }
    self.eventContinuation = eventContinuation
    var audioContinuation: AsyncStream<Data>.Continuation!
    audioOutput = AsyncStream { audioContinuation = $0 }
    self.audioContinuation = audioContinuation
  }

  func connect(tools: [ToolDefinition]) {
    eventContinuation.yield(.connected)
  }

  func sendAudio(_ data: Data) { sentAudio.append(data) }
  func emitAudio(_ data: Data) { audioContinuation.yield(data) }
  func emit(_ event: VoiceProviderEvent) { eventContinuation.yield(event) }
  func sendToolResult(_ result: VoiceToolResult) {}
  func sendNotification(_ text: String) { notifications.append(text) }

  func interrupt() {
    interruptCount += 1
    eventContinuation.yield(.interrupted)
  }

  func disconnect() {
    disconnectCount += 1
    eventContinuation.yield(.disconnected)
  }
}

private struct FailingVoiceProvider: VoiceProvider {
  let events = AsyncStream<VoiceProviderEvent> { $0.finish() }

  func connect(tools: [ToolDefinition]) async throws {
    throw RuntimeError.launchFailed("Synthetic voice connection failure")
  }

  func sendToolResult(_ result: VoiceToolResult) async {}
  func interrupt() async {}
  func disconnect() async {}
}

private func firstResult(from stream: AsyncStream<VoiceToolResult>) async throws -> VoiceToolResult
{
  try await withThrowingTaskGroup(of: VoiceToolResult.self) { group in
    group.addTask {
      for await result in stream { return result }
      throw RuntimeError.transportClosed
    }
    group.addTask {
      try await Task.sleep(for: .seconds(2))
      throw RuntimeError.launchFailed("Timed out waiting for voice tool result")
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}

private func waitUntil(
  _ timeoutDescription: String = "voice state",
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  // The full package suite runs hundreds of async tests concurrently. Keep polling assertions
  // strict, but allow executor scheduling headroom on busy development machines.
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for \(timeoutDescription)")
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
