import Foundation
import OttoModels
import OttoTools

/// Delivers spoken text to an agent through the agent tools, continuing the conversation when
/// the agent's process had already ended.
///
/// Voice picks `agent.send_input` for an agent that is mid-run or waiting, and `agent.send_prompt`
/// otherwise. One-shot provider CLIs close their PTY just before their exit event arrives, so a
/// send_input that lands in that window fails with a closed transport even though nothing is
/// wrong: the agent simply finished. `agent.send_prompt` already recovers from that state — it
/// waits for the exit to settle and resumes or respawns the provider session — so the relay
/// falls through to it instead of reporting a transport failure to the person.
///
/// The fall-through is deliberately narrow. A closed transport is not proof of an exit: the PTY
/// write also reports it when a live TUI stops reading stdin for a second. So the relay only
/// continues once `agent.get_status` has actually reported a settled terminal state, and never
/// for an approval-shaped answer ("yes", "no", "go ahead") or an agent that was waiting for
/// permission — respawning a provider to run a whole turn on the prompt "yes" costs money and
/// leaves a baffling transcript. Those cases surface the short human error instead.
enum VoiceAgentRelay {
  struct Delivery: Sendable {
    var toolName: String
    var output: JSONValue
    /// True when send_input found the agent already gone and the text went out as a prompt.
    var continuedAfterExit: Bool
  }

  static let inputToolName = "agent.send_input"
  static let promptToolName = "agent.send_prompt"
  static let statusToolName = "agent.get_status"
  static let defaultSettleTimeout: Duration = .seconds(3)
  private static let settledStates: Set<String> = [
    "DONE", "FAILED", "INTERRUPTED", "STOPPED", "EXITED",
  ]
  private static let waitingPermissionState = "WAITING_PERMISSION"

  /// - Parameters:
  ///   - lastKnownState: The agent state the caller read before choosing `toolName`, when it
  ///     has one. An agent that was waiting for permission never gets its answer re-sent as a
  ///     prompt.
  ///   - settleTimeout: How long to wait for the supervisor to record the exit before giving
  ///     up. Tests shorten it; the exit event normally lands well inside the default.
  static func send(
    toolName: String,
    agentID: UUID,
    text: String,
    lastKnownState: String? = nil,
    registry: ToolRegistry,
    context: ToolContext,
    requestID: String = UUID().uuidString,
    settleTimeout: Duration = defaultSettleTimeout
  ) async throws -> Delivery {
    let input = arguments(for: toolName, agentID: agentID, text: text)
    let transportError: any Error
    do {
      let output = try await registry.call(
        name: toolName, input: input, context: context, requestID: requestID)
      return Delivery(toolName: toolName, output: output, continuedAfterExit: false)
    } catch {
      guard toolName == inputToolName, error.ottoFailureKind == .agentTransportClosed else {
        throw error
      }
      guard mayContinueAsPrompt(text: text, lastKnownState: lastKnownState),
        await exitSettled(
          agentID: agentID, registry: registry, context: context, timeout: settleTimeout)
      else {
        throw error
      }
      transportError = error
    }
    do {
      let output = try await registry.call(
        name: promptToolName,
        input: arguments(for: promptToolName, agentID: agentID, text: text),
        context: context,
        // The effect coordinator may answer a repeated request ID with the first call's receipt.
        requestID: "\(requestID)-continue"
      )
      return Delivery(toolName: promptToolName, output: output, continuedAfterExit: true)
    } catch {
      // The agent had stopped and could not be continued — a shell terminal, say, which
      // send_prompt rejects as an invalid transition. The person's truth is still that the
      // agent had stopped; the continuation's own complaint would mislabel it as busy.
      throw transportError
    }
  }

  static func arguments(for toolName: String, agentID: UUID, text: String) -> JSONValue {
    if toolName == inputToolName {
      return .object(["agentID": .string(agentID.uuidString), "text": .string(text)])
    }
    return .object(["agentID": .string(agentID.uuidString), "prompt": .string(text)])
  }

  static func mayContinueAsPrompt(text: String, lastKnownState: String?) -> Bool {
    if lastKnownState?.uppercased() == waitingPermissionState { return false }
    return !isApprovalShaped(text)
  }

  /// A short yes/no style answer to a prompt the agent was showing. Same vocabulary the Hermes
  /// bridge accepts for approvals, plus the spoken forms people actually use.
  static func isApprovalShaped(_ text: String) -> Bool {
    let fillers: Set<String> = ["hey", "okay", "ok", "please", "otto", "thanks", "thank"]
    let words = text.lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
    let meaningful = words.filter { !fillers.contains($0) }
    guard !words.isEmpty, words.count <= 4 else { return false }
    // A bare "ok" or "okay please" is an answer, not a task.
    guard let first = meaningful.first else { return true }
    let answers: Set<String> = [
      "yes", "y", "yep", "yeah", "yup", "sure", "approve", "approved", "allow", "accept",
      "confirm", "go", "proceed", "continue", "do", "no", "n", "nope", "deny", "denied",
      "reject", "cancel", "stop", "skip", "always", "never", "once",
    ]
    // Words that only ever pad an answer: "yes, go ahead", "do it", "no, not that one".
    let padding: Set<String> = [
      "ahead", "it", "that", "this", "one", "all", "and", "then", "fine", "good", "sure",
      "not", "for", "now", "the", "session", "time",
    ]
    guard answers.contains(first) else { return false }
    // "go ahead", "yes do it", "no thanks" — but not "continue the migration plan" or
    // "stop using the old API client", which carry a subject of their own.
    return meaningful.dropFirst().allSatisfy { answers.contains($0) || padding.contains($0) }
  }

  /// The supervisor publishes the agent's final state a moment after the PTY closes. Prompting
  /// before that lands is rejected as a prompt to a working agent, and prompting an agent that
  /// is still alive would start a second turn, so only a recorded exit counts.
  private static func exitSettled(
    agentID: UUID, registry: ToolRegistry, context: ToolContext, timeout: Duration
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    repeat {
      let status = try? await registry.call(
        name: statusToolName,
        input: .object(["agentID": .string(agentID.uuidString)]),
        context: context
      )
      if let state = status?["state"]?.stringValue, settledStates.contains(state.uppercased()) {
        return true
      }
      guard (try? await Task.sleep(for: .milliseconds(40))) != nil else { return false }
    } while ContinuousClock.now < deadline
    return false
  }
}
