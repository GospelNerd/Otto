import Foundation
import OttoModels

public enum AgentLifecycleState: String, Codable, CaseIterable, Sendable {
  case created = "CREATED"
  case starting = "STARTING"
  case idle = "IDLE"
  case working = "WORKING"
  case waitingPermission = "WAITING_PERMISSION"
  case waitingUser = "WAITING_USER"
  case done = "DONE"
  case failed = "FAILED"
  case interrupted = "INTERRUPTED"
  case stopped = "STOPPED"
}

public enum AgentExecutionMode: String, Sendable, Equatable {
  case terminal
  case interactiveProvider
  case oneShotProvider
}

public enum AgentTranscriptRole: String, Sendable, Equatable {
  case user
  case assistant
  case activity
}

/// Distinguishes what a transcript entry represents so the conversation surface can render each
/// with the right visual treatment: prose, collapsed reasoning, a tool-call chip, or a notice.
public enum AgentTranscriptKind: String, Sendable, Equatable {
  case text
  case reasoning
  case toolCall
  case notice
}

/// A clean conversational projection of a provider session. The PTY scrollback remains the
/// source of truth for diagnostics and unusual interactive prompts; these entries are the human
/// reading layer presented by the canvas.
public struct AgentTranscriptEntry: Identifiable, Sendable, Equatable {
  public let id: UUID
  public var role: AgentTranscriptRole
  public var kind: AgentTranscriptKind
  public var text: String
  /// Kind-specific companion value; for `.toolCall` this is the tool's display name.
  public var detail: String?
  public var createdAt: Date
  /// On the last reply of a turn: how long the turn took and the tokens the provider reported.
  public var turnStats: AgentTurnStats?

  public init(
    id: UUID = UUID(),
    role: AgentTranscriptRole,
    kind: AgentTranscriptKind = .text,
    text: String,
    detail: String? = nil,
    createdAt: Date = .now,
    turnStats: AgentTurnStats? = nil
  ) {
    self.id = id
    self.role = role
    self.kind = kind
    self.text = text
    self.detail = detail
    self.createdAt = createdAt
    self.turnStats = turnStats
  }
}

/// Time and token use of one turn, shown under its reply. Tokens are nil when the provider does
/// not report them; input counts include cached input.
public struct AgentTurnStats: Codable, Sendable, Equatable {
  public var durationSeconds: Double
  public var inputTokens: Int?
  public var outputTokens: Int?

  public init(durationSeconds: Double, inputTokens: Int? = nil, outputTokens: Int? = nil) {
    self.durationSeconds = durationSeconds
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

public struct ProcessLaunchSpec: Sendable, Equatable {
  public var executable: String
  public var arguments: [String]
  public var environment: [String: String]
  /// Prefixes removed from Otto's inherited environment before explicit launch values are
  /// applied. Provider CLIs use parent-only variables (for example `CODEX_THREAD_ID`) to bind a
  /// child invocation to the caller's conversation, which must never leak between workspace sessions.
  public var inheritedEnvironmentPrefixesToRemove: [String]
  public var workingDirectory: String
  public var columns: UInt16
  public var rows: UInt16

  public init(
    executable: String,
    arguments: [String] = [],
    environment: [String: String] = [:],
    inheritedEnvironmentPrefixesToRemove: [String] = [],
    workingDirectory: String,
    columns: UInt16 = 120,
    rows: UInt16 = 36
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.inheritedEnvironmentPrefixesToRemove = inheritedEnvironmentPrefixesToRemove
    self.workingDirectory = workingDirectory
    self.columns = columns
    self.rows = rows
  }

  public func resolvedEnvironment(inheriting parent: [String: String]) -> [String: String] {
    var resolved = parent.filter { key, _ in
      !inheritedEnvironmentPrefixesToRemove.contains { key.hasPrefix($0) }
    }
    // Explicit values are applied after scrubbing so a launch can deliberately restore a key.
    resolved.merge(environment) { _, requested in requested }
    resolved["TERM"] = environment["TERM"] ?? "xterm-256color"
    return resolved
  }
}

/// A structured question an agent asked mid-run — either a provider-native prompt (Hermes'
/// clarify tool) or the universal `agent.ask_user` tool served over otto-mcp. The chat surface
/// renders the choices as buttons; free-typed text answers it just as well.
public struct AgentChoicePrompt: Codable, Sendable, Equatable {
  /// Provider-side identifier for the pending request; empty for tool-served prompts, where the
  /// blocked tool call itself is the return channel.
  public var requestID: String
  public var question: String
  public var choices: [String]
  /// When true the user may pick several choices; the answer joins them with ", ".
  public var multiSelect: Bool

  public init(requestID: String, question: String, choices: [String], multiSelect: Bool = false) {
    self.requestID = requestID
    self.question = question
    self.choices = choices
    self.multiSelect = multiSelect
  }
}

public enum AgentChildRunState: String, Codable, Sendable, Equatable {
  case starting
  case working
  case waiting
  case done
  case failed
  case stopped
  case unknown

  public var isActive: Bool { self == .starting || self == .working || self == .waiting }
}

/// Provider-native work nested under one visible Otto agent. Providers expose different amounts
/// of detail, so every field beyond identity and state is optional and the UI degrades honestly.
public struct AgentChildRun: Identifiable, Codable, Sendable, Equatable {
  public var parentID: String?
  public var task: String?
  public var activityLog: [String]?
  public var kind: String?
  public var id: String
  public var name: String
  public var activity: String
  public var model: String?
  public var effort: String?
  public var state: AgentChildRunState
  public var startedAt: Date
  public var completedAt: Date?
  public var toolCount: Int
  public var inputTokens: Int?
  public var outputTokens: Int?

  public init(
    id: String, name: String, activity: String, model: String? = nil,
    effort: String? = nil, state: AgentChildRunState = .starting,
    startedAt: Date = .now, completedAt: Date? = nil, toolCount: Int = 0,
    inputTokens: Int? = nil, outputTokens: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.activity = activity
    self.model = model
    self.effort = effort
    self.state = state
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.toolCount = toolCount
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

public struct AgentRuntimeSnapshot: Identifiable, Sendable, Equatable {
  public let id: UUID
  public var runID: UUID?
  public var provider: AgentProvider
  public var executionMode: AgentExecutionMode
  public var state: AgentLifecycleState
  public var confidence: Double
  public var output: String
  public var outputStartOffset: Int
  public var outputEndOffset: Int
  public var providerSessionID: String?
  public var result: String?
  public var attentionReason: String?
  /// Stable identifier for the kind of attention (e.g. "provider-authentication"), letting the
  /// conversation surface offer a targeted remedy instead of a generic reply box.
  public var attentionToken: String?
  /// A multiple-choice question the agent is blocked on, rendered as buttons in the chat
  /// surface. Present only while the agent waits; answering or run-state changes clear it.
  public var pendingChoice: AgentChoicePrompt?
  /// OS pid of the supervised process for this run, letting surfaces read live process facts
  /// such as a shell's current working directory. Nil once the process has exited.
  public var processID: Int32?
  /// Hash of the memory bootstrap packet this run received at launch; nil when the run predates
  /// bootstrap injection or none was configured. The rendered packet itself is inspectable at
  /// `.otto/bootstrap/<nodeID>.md` in the run's workspace.
  public var bootstrapHash: String?
  public var structuredResult: AgentResult?
  public var exitCode: Int32?
  /// The most recent full prompt submitted to this agent, for at-a-glance context recall.
  public var lastPrompt: String?
  /// Readable user/assistant turns projected from prompts and structured provider results.
  public var transcript: [AgentTranscriptEntry]
  public var childRuns: [AgentChildRun]
  public var startedAt: Date
  public var completedAt: Date?

  public init(
    id: UUID,
    runID: UUID? = nil,
    provider: AgentProvider,
    executionMode: AgentExecutionMode = .oneShotProvider,
    state: AgentLifecycleState,
    confidence: Double,
    output: String = "",
    outputStartOffset: Int = 0,
    outputEndOffset: Int = 0,
    providerSessionID: String? = nil,
    result: String? = nil,
    attentionReason: String? = nil,
    structuredResult: AgentResult? = nil,
    exitCode: Int32? = nil,
    lastPrompt: String? = nil,
    transcript: [AgentTranscriptEntry] = [],
    childRuns: [AgentChildRun] = [],
    startedAt: Date = .now,
    completedAt: Date? = nil
  ) {
    self.id = id
    self.runID = runID
    self.provider = provider
    self.executionMode = executionMode
    self.state = state
    self.confidence = confidence
    self.output = output
    self.outputStartOffset = outputStartOffset
    self.outputEndOffset = outputEndOffset
    self.providerSessionID = providerSessionID
    self.result = result
    self.attentionReason = attentionReason
    self.structuredResult = structuredResult
    self.exitCode = exitCode
    self.lastPrompt = lastPrompt
    self.transcript = transcript
    self.childRuns = childRuns
    self.startedAt = startedAt
    self.completedAt = completedAt
  }
}

public struct AgentRunRecord: Identifiable, Sendable, Equatable {
  public let id: UUID
  public let nodeID: UUID
  public let provider: AgentProvider
  public let state: AgentLifecycleState
  public let exitCode: Int32?
  public let startedAt: Date
  public let completedAt: Date
  public let output: String
  public let outputStartOffset: Int
  public let outputEndOffset: Int

  public init(
    id: UUID,
    nodeID: UUID,
    provider: AgentProvider,
    state: AgentLifecycleState,
    exitCode: Int32?,
    startedAt: Date,
    completedAt: Date,
    output: String,
    outputStartOffset: Int,
    outputEndOffset: Int
  ) {
    self.id = id
    self.nodeID = nodeID
    self.provider = provider
    self.state = state
    self.exitCode = exitCode
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.output = output
    self.outputStartOffset = outputStartOffset
    self.outputEndOffset = outputEndOffset
  }
}

public struct TerminalSearchMatch: Sendable, Equatable {
  public let lineNumber: Int
  public let column: Int
  public let line: String

  public init(lineNumber: Int, column: Int, line: String) {
    self.lineNumber = lineNumber
    self.column = column
    self.line = line
  }
}

public enum TerminalOutputSearch {
  public static func matches(
    query: String,
    in output: String,
    limit: Int = 200
  ) -> [TerminalSearchMatch] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, limit > 0 else { return [] }
    var matches: [TerminalSearchMatch] = []
    for (index, line) in plainText(output).components(separatedBy: .newlines).enumerated() {
      var searchStart = line.startIndex
      while searchStart < line.endIndex,
        let range = line.range(
          of: query,
          options: [.caseInsensitive, .diacriticInsensitive],
          range: searchStart..<line.endIndex
        )
      {
        matches.append(
          TerminalSearchMatch(
            lineNumber: index + 1,
            column: line.distance(from: line.startIndex, to: range.lowerBound) + 1,
            line: line
          ))
        if matches.count == limit { return matches }
        searchStart = range.upperBound
      }
    }
    return matches
  }

  public static func plainText(_ output: String) -> String {
    output.replacingOccurrences(
      of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
      with: "",
      options: .regularExpression
    )
  }

  /// Human- and model-readable excerpt of raw terminal output: strips OSC and CSI escape
  /// sequences, carriage returns, and control characters, then bounds the tail. Raw TUI screens
  /// must never travel through tool results — they bury the useful fields in kilobytes of escape
  /// noise and hand untrusted terminal bytes straight to a language model.
  public static func sanitizedExcerpt(_ output: String, limit: Int = 4_096) -> String {
    var text = output
    // OSC sequences: ESC ] … terminated by BEL or ST (ESC \)
    text = text.replacingOccurrences(
      of: "\u{001B}\\][^\u{0007}\u{001B}]*(\u{0007}|\u{001B}\\\\)",
      with: "",
      options: .regularExpression
    )
    text = plainText(text)
    // Remaining two-character escapes (ESC c reset, ESC 7/8 cursor save, …)
    text = text.replacingOccurrences(
      of: "\u{001B}.",
      with: "",
      options: .regularExpression
    )
    text = text.replacingOccurrences(of: "\r", with: "")
    text = text.replacingOccurrences(
      of: "[\u{0000}-\u{0008}\u{000B}-\u{001F}\u{007F}]",
      with: "",
      options: .regularExpression
    )
    text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    return String(text.suffix(limit))
  }
}

public struct TerminalRenderUpdate: Sendable, Equatable {
  public let resetsTerminal: Bool
  public let bytes: Data
  public let renderedEndOffset: Int

  public init(resetsTerminal: Bool, bytes: Data, renderedEndOffset: Int) {
    self.resetsTerminal = resetsTerminal
    self.bytes = bytes
    self.renderedEndOffset = renderedEndOffset
  }
}

public enum TerminalRenderPlanner {
  public static func update(
    output: String,
    startOffset: Int,
    endOffset: Int,
    sessionKey: String,
    renderedSessionKey: String?,
    renderedEndOffset: Int,
    replayExistingOutput: Bool = true
  ) -> TerminalRenderUpdate {
    // This runs on every SwiftUI update of every visible terminal. utf8.count is O(1) on native
    // strings, so the common no-new-output path must not materialize the scrollback as Data.
    let byteCount = output.utf8.count
    let expectedCount = max(0, endOffset - startOffset)
    let requiresReset =
      renderedSessionKey != sessionKey
      || renderedEndOffset < startOffset
      || renderedEndOffset > endOffset
      || expectedCount != byteCount
    if requiresReset {
      return TerminalRenderUpdate(
        resetsTerminal: true,
        bytes: replayExistingOutput ? Data(output.utf8) : Data(),
        renderedEndOffset: endOffset
      )
    }
    guard renderedEndOffset < endOffset else {
      return TerminalRenderUpdate(
        resetsTerminal: false,
        bytes: Data(),
        renderedEndOffset: endOffset
      )
    }
    return TerminalRenderUpdate(
      resetsTerminal: false,
      bytes: Data(output.utf8.dropFirst(renderedEndOffset - startOffset)),
      renderedEndOffset: endOffset
    )
  }
}

public enum RuntimeEvent: Sendable, Equatable {
  case output(agentID: UUID, text: String)
  case transcriptChanged(agentID: UUID)
  case stateChanged(agentID: UUID, state: AgentLifecycleState, confidence: Double)
  case completed(agentID: UUID, result: String, confidence: Double)
  case exited(agentID: UUID, code: Int32)
}

public enum RuntimeError: Error, LocalizedError, Sendable, Equatable {
  case launchFailed(String)
  case agentNotFound(UUID)
  case staleRun(UUID)
  case invalidTransition(from: AgentLifecycleState, to: AgentLifecycleState)
  case transportClosed
  case noPendingPermission(UUID)
  case permissionExpired

  public var errorDescription: String? {
    switch self {
    case .launchFailed(let message): "Could not launch agent: \(message)"
    case .staleRun: "That run is no longer current. Refresh before controlling it."
    case .agentNotFound(let id): "Agent \(id.uuidString) was not found"
    case .invalidTransition(let from, let to):
      "Invalid agent transition from \(from.rawValue) to \(to.rawValue)"
    case .permissionExpired:
      "Confirmation expired without approval. The action was not performed. Ask the user before retrying."
    case .transportClosed: "The terminal transport is closed"
    case .noPendingPermission(let id):
      "Agent \(id.uuidString) has no pending permission request"
    }
  }
}

extension RuntimeError: OttoFailureClassifying {
  public var failureKind: OttoFailureKind? {
    switch self {
    case .transportClosed: .agentTransportClosed
    case .agentNotFound: .agentNotFound
    // A control refused because the process has already ended is "stopped", not "busy".
    case .invalidTransition(let from, _) where from == .stopped || from == .failed:
      .agentStopped
    case .invalidTransition: .agentBusy
    case .launchFailed: .agentLaunchFailed
    case .staleRun, .noPendingPermission, .permissionExpired: nil
    }
  }
}
