import Foundation
import OttoRuntime
import OttoTools
import Testing

@testable import OttoVoice

@Suite("Voice agent relay")
struct VoiceAgentRelayTests {
  private let context = ToolContext(actorID: "relay-test", scopes: Set(ToolScope.allCases))

  @Test("A closed transport only continues as a prompt once the exit is recorded")
  func continuesAfterSettledExit() async throws {
    let script = ExitingAgentScript(states: ["WORKING", "WORKING", "DONE"])
    let registry = try await makeRegistry(script)

    let delivery = try await VoiceAgentRelay.send(
      toolName: VoiceAgentRelay.inputToolName,
      agentID: UUID(),
      text: "Use the staging database",
      lastKnownState: "WORKING",
      registry: registry,
      context: context
    )

    #expect(delivery.continuedAfterExit)
    #expect(delivery.toolName == "agent.send_prompt")
    #expect(await script.prompts == ["Use the staging database"])
  }

  @Test("A transport that closes without a recorded exit is an error, not a new turn")
  func deadlineWithoutSettledStateDoesNotPrompt() async throws {
    // PTYProcess also reports a closed transport when a live TUI stops reading stdin for a
    // second; the agent is still running, so prompting it would start a second turn.
    let script = ExitingAgentScript(states: ["WORKING"])
    let registry = try await makeRegistry(script)

    await #expect(throws: RuntimeError.transportClosed) {
      try await VoiceAgentRelay.send(
        toolName: VoiceAgentRelay.inputToolName,
        agentID: UUID(),
        text: "Use the staging database",
        lastKnownState: "WORKING",
        registry: registry,
        context: context,
        settleTimeout: .milliseconds(200)
      )
    }
    #expect(await script.inputs == ["Use the staging database"])
    #expect(await script.prompts.isEmpty)
  }

  @Test("A continuation the agent refuses still reports the closed transport")
  func continuationFailureReportsTransportError() async throws {
    // A shell terminal: its exit is recorded, but agent.send_prompt refuses to prompt a stopped
    // process. The person is told the agent had stopped, not that it is busy.
    let script = ExitingAgentScript(
      states: ["WORKING", "STOPPED"],
      promptError: RuntimeError.invalidTransition(from: .stopped, to: .working)
    )
    let registry = try await makeRegistry(script)

    await #expect(throws: RuntimeError.transportClosed) {
      try await VoiceAgentRelay.send(
        toolName: VoiceAgentRelay.inputToolName,
        agentID: UUID(),
        text: "Use the staging database",
        lastKnownState: "WORKING",
        registry: registry,
        context: context
      )
    }
    #expect(await script.prompts == ["Use the staging database"])
  }

  @Test("Approval answers are never re-sent as prompts")
  func approvalAnswersDoNotPrompt() async throws {
    for text in ["yes", "y", "No thanks", "go ahead", "okay", "approve once"] {
      let script = ExitingAgentScript(states: ["WAITING_USER", "DONE"])
      let registry = try await makeRegistry(script)
      await #expect(throws: RuntimeError.transportClosed, "\(text)") {
        try await VoiceAgentRelay.send(
          toolName: VoiceAgentRelay.inputToolName,
          agentID: UUID(),
          text: text,
          lastKnownState: "WAITING_USER",
          registry: registry,
          context: context
        )
      }
      #expect(await script.prompts.isEmpty, "\(text)")
    }
  }

  @Test("An agent that was waiting for permission is never continued, whatever was said")
  func waitingPermissionDoesNotPrompt() async throws {
    let script = ExitingAgentScript(states: ["WAITING_PERMISSION", "DONE"])
    let registry = try await makeRegistry(script)

    await #expect(throws: RuntimeError.transportClosed) {
      try await VoiceAgentRelay.send(
        toolName: VoiceAgentRelay.inputToolName,
        agentID: UUID(),
        text: "Allow it for the whole session and then rerun the failing tests",
        lastKnownState: "waiting_permission",
        registry: registry,
        context: context
      )
    }
    #expect(await script.prompts.isEmpty)
  }

  @Test("Approval-shaped text is short yes/no vocabulary, not an instruction")
  func approvalShape() {
    for answer in [
      "yes", "y", "Yes.", "yep", "no", "n", "nope", "Okay", "ok please", "go ahead",
      "do it", "yes please", "no thanks", "approve", "deny", "always", "cancel",
      "yes, go ahead", "Yes do it", "no, not that one", "allow for this session",
    ] {
      #expect(VoiceAgentRelay.isApprovalShaped(answer), "\(answer)")
    }
    for instruction in [
      "", "Continue the migration plan from step three", "Use the staging database",
      "Yes but only after you back up the table first", "Stop using the old API client",
      "review the auth flow.",
    ] {
      #expect(!VoiceAgentRelay.isApprovalShaped(instruction), "\(instruction)")
    }
  }

  private func makeRegistry(_ script: ExitingAgentScript) async throws -> ToolRegistry {
    let registry = ToolRegistry()
    try await registry.register(ExitingAgentStatusProbe(script: script))
    try await registry.register(ClosedTransportInputProbe(script: script))
    try await registry.register(ExitingAgentPromptProbe(script: script))
    return registry
  }
}

/// Scripts an agent through the agent tools without a real process: `states` feed
/// agent.get_status in order (the last repeats), send_input always reports a closed transport,
/// and send_prompt records what reached it.
private actor ExitingAgentScript {
  private var states: [String]
  private let promptError: (any Error)?
  private(set) var inputs: [String] = []
  private(set) var prompts: [String] = []

  init(states: [String], promptError: (any Error)? = nil) {
    self.states = states
    self.promptError = promptError
  }

  func nextState() -> String {
    states.count > 1 ? states.removeFirst() : states[0]
  }

  func recordInput(_ text: String) { inputs.append(text) }

  func recordPrompt(_ prompt: String) throws {
    prompts.append(prompt)
    if let promptError { throw promptError }
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
