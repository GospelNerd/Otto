import Foundation
import OttoModels

public struct AgentResult: Codable, Sendable, Equatable {
  public var status: AgentLifecycleState
  public var summaryCandidate: String
  public var rawText: String
  public var filesChanged: [String]
  public var commandsRun: [String]
  public var durationMilliseconds: Int?
  public var inputTokens: Int?
  public var outputTokens: Int?

  public init(
    status: AgentLifecycleState,
    summaryCandidate: String,
    rawText: String,
    filesChanged: [String] = [],
    commandsRun: [String] = [],
    durationMilliseconds: Int? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil
  ) {
    self.status = status
    self.summaryCandidate = summaryCandidate
    self.rawText = rawText
    self.filesChanged = filesChanged
    self.commandsRun = commandsRun
    self.durationMilliseconds = durationMilliseconds
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

/// Reads a provider's usage object. Claude reports cache reads and writes apart from
/// `input_tokens`, Codex reports `cached_input_tokens` as part of it; both become one input
/// figure. Nil when the object carries no counts.
public enum ProviderTokenUsage {
  public static func parse(_ usage: Any?) -> (input: Int?, output: Int?) {
    guard let usage = usage as? [String: Any] else { return (nil, nil) }
    func int(_ key: String) -> Int? {
      (usage[key] as? Int) ?? (usage[key] as? Double).map { Int($0) }
    }
    let base = int("input_tokens") ?? int("prompt_tokens") ?? int("inputTokens")
    let cache = (int("cache_read_input_tokens") ?? 0) + (int("cache_creation_input_tokens") ?? 0)
    let input = base.map { $0 + cache }
    let output = int("output_tokens") ?? int("completion_tokens") ?? int("outputTokens")
    return (input, output)
  }
}

public enum ParsedAgentEvent: Sendable, Equatable {
  case sessionStarted(String)
  case state(AgentLifecycleState, confidence: Double)
  case permissionRequested(String)
  case waitingForUser(String)
  /// A structured question with selectable choices (Hermes clarify). The supervisor surfaces it
  /// as a pending choice the chat surface renders as buttons.
  case choiceRequested(AgentChoicePrompt)
  /// A completed assistant prose message, emitted as soon as the provider finishes it so
  /// multi-step runs read as a conversation instead of a single final dump.
  case assistantMessage(String)
  /// Extended thinking / reasoning text that precedes a message or tool call.
  case reasoning(String)
  /// Any tool invocation, with a human-readable display name and a compact input summary.
  case toolInvoked(name: String, detail: String)
  case childStarted(AgentChildRun)
  case childUpdated(id: String, activity: String, toolIncrement: Int)
  case childCompleted(id: String, failed: Bool, inputTokens: Int?, outputTokens: Int?)
  case diagnostic(String)
  case result(AgentResult)
}

/// A selectable list a provider TUI is currently showing, lifted out of the repaint so Otto can
/// offer the same options as chat buttons. The TUI reads arrow keys rather than typed text, so
/// answering means moving the highlight from `selectedIndex` to the chosen row and pressing Enter.
public struct InteractiveMenu: Sendable, Equatable {
  public var options: [String]
  public var selectedIndex: Int

  public init(options: [String], selectedIndex: Int) {
    self.options = options
    self.selectedIndex = selectedIndex
  }

  /// Keystrokes that move the highlight to `index` and commit it. Down and up are sent as the
  /// bare CSI cursor sequences every one of these harnesses reads in raw mode.
  public func keystrokes(toSelect index: Int) -> String {
    guard options.indices.contains(index), options.indices.contains(selectedIndex) else {
      return "\r"
    }
    let step = index > selectedIndex ? "\u{1B}[B" : "\u{1B}[A"
    return String(repeating: step, count: abs(index - selectedIndex)) + "\r"
  }
}

public struct InteractivePrompt: Sendable, Equatable {
  public var token: String
  public var state: AgentLifecycleState
  public var reason: String
  public var automaticResponse: String?
  /// The options the prompt is offering, when Otto could read them off the repaint. Prompts that
  /// block on something other than a list (a sign-in that must happen in a browser) carry none.
  public var menu: InteractiveMenu?

  public init(
    token: String,
    state: AgentLifecycleState,
    reason: String,
    automaticResponse: String? = nil,
    menu: InteractiveMenu? = nil
  ) {
    self.token = token
    self.state = state
    self.reason = reason
    self.automaticResponse = automaticResponse
    self.menu = menu
  }
}

/// Reads the option list out of a TUI menu repaint.
///
/// A TUI redraws its whole frame on every keystroke, so the scan buffer holds several stale copies
/// of the same menu; only the last one describes what is on screen now. Within that copy the
/// highlighted row carries a caret marker, and rows are grouped the way the harness spaces them:
/// when options are separated by blank lines each group's first line is the label and the rest is
/// its description, and when they are packed together every line is a label.
public enum InteractiveMenuParser {
  private static let carets: Set<Character> = ["❯", "›", "▶", ">"]

  public static func parse(_ text: String) -> InteractiveMenu? {
    let lines = text.components(separatedBy: .newlines)
    guard let caretLine = lines.lastIndex(where: { isCaretRow($0) }) else { return nil }

    // The menu is the run of lines around the caret, bounded by the separator rules the harnesses
    // share: a horizontal rule, the navigation hint, or two blank lines in a row end the list.
    var start = caretLine
    while start > 0, isMenuBody(lines[start - 1]), !isCaretRow(lines[start - 1]) { start -= 1 }
    var end = caretLine
    while end + 1 < lines.count, isMenuBody(lines[end + 1]) { end += 1 }

    let block = Array(lines[start...end])
    let groups = groupedRows(block)
    guard groups.count >= 2 else { return nil }

    let options = groups.map { stripCaret($0.first ?? "") }
    guard options.allSatisfy({ !$0.isEmpty }) else { return nil }
    let selected = groups.firstIndex { $0.contains(where: isCaretRow) } ?? 0
    return InteractiveMenu(options: options, selectedIndex: selected)
  }

  /// Groups the block into one entry per option. Blank-line-separated menus put the label first
  /// and its help text after; packed menus have one option per line and so form one group each.
  private static func groupedRows(_ block: [String]) -> [[String]] {
    var groups: [[String]] = []
    var current: [String] = []
    for line in block {
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        if !current.isEmpty { groups.append(current) }
        current = []
        continue
      }
      current.append(line)
    }
    if !current.isEmpty { groups.append(current) }
    if groups.count > 1 { return groups }
    return (groups.first ?? []).map { [$0] }
  }

  private static func isCaretRow(_ line: String) -> Bool {
    guard let first = line.trimmingCharacters(in: .whitespaces).first else { return false }
    return carets.contains(first)
  }

  /// Menu rows are indented option or description lines. A rule, a hint, or an unindented line
  /// belongs to the surrounding frame rather than the list.
  private static func isMenuBody(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return true }
    if trimmed.allSatisfy({ $0 == "─" || $0 == "-" || $0 == "=" || $0 == "│" }) { return false }
    let lowered = trimmed.lowercased()
    if lowered.contains("navigate"), lowered.contains("select") { return false }
    if lowered.hasPrefix("esc ") || lowered.hasPrefix("enter ") || lowered.contains("↑↓") {
      return false
    }
    return line.hasPrefix(" ") || isCaretRow(line)
  }

  private static func stripCaret(_ line: String) -> String {
    var trimmed = line.trimmingCharacters(in: .whitespaces)
    if let first = trimmed.first, carets.contains(first) { trimmed.removeFirst() }
    return String(trimmed.trimmingCharacters(in: .whitespaces).prefix(200))
  }
}

/// Recognizes blocking prompts emitted by native provider TUIs. These are not structured JSON, and
/// may arrive split across arbitrary PTY chunks, so the supervisor feeds this a short rolling view.
public enum InteractivePromptDetector {
  public static func detect(in text: String, provider: AgentProvider) -> InteractivePrompt? {
    let normalized = text.lowercased()

    if provider == .claudeCode,
      normalized.contains("yes, i trust this folder"),
      normalized.contains("no, exit")
    {
      return InteractivePrompt(
        token: "claude-workspace-trust",
        state: .waitingPermission,
        reason: "Confirming access to this Otto workspace",
        automaticResponse: "\r"
      )
    }

    // Kimi asks the same workspace question in its own words, and gates project MCP servers on
    // the answer — so declining would strand the Otto bridge the adapter just wrote.
    if provider == .kimi,
      normalized.contains("trust this folder"),
      normalized.contains("don't trust") || normalized.contains("dont trust")
    {
      return InteractivePrompt(
        token: "kimi-workspace-trust",
        state: .waitingPermission,
        reason: "Confirming access to this Otto workspace",
        automaticResponse: "\r"
      )
    }

    // `/login` opens a platform picker. This is the one blocking prompt a fresh Kimi install
    // always hits, so it carries its menu up to chat rather than stranding the user in the TUI.
    if provider == .kimi, normalized.contains("select a platform") {
      return InteractivePrompt(
        token: "kimi-login-platform",
        state: .waitingUser,
        reason: "Kimi sign-in: choose a platform",
        menu: InteractiveMenuParser.parse(text)
      )
    }

    if normalized.contains("new version"),
      normalized.contains("update"),
      normalized.contains("later") || normalized.contains("skip")
    {
      return InteractivePrompt(
        token: "provider-update-choice",
        state: .waitingUser,
        reason: "Agent update choice required"
      )
    }

    // Provider TUIs list their configured MCP servers at startup; "the X MCP server is not
    // logged in" is a warning about an unrelated server, not a blocked harness. Only treat
    // sign-in text as blocking when it is not MCP-scoped — a truly logged-out provider that
    // also mentions MCP degrades to a structured run whose error surfaces as a chat notice.
    if !normalized.contains("mcp"),
      normalized.contains("not logged in") || normalized.contains("authentication required")
        || normalized.contains("sign in to continue")
    {
      return InteractivePrompt(
        token: "provider-authentication",
        state: .waitingUser,
        reason: "Agent sign-in required"
      )
    }

    // Harnesses word their navigation hint differently — "Enter to confirm · Esc to cancel" and
    // "Enter select · Esc cancel" are the same blocking list — so match on the pairing, not the
    // exact phrasing, or a provider's menu silently never reaches chat.
    let confirms =
      normalized.contains("enter to confirm") || normalized.contains("enter select")
      || normalized.contains("enter to submit")
    let cancels =
      normalized.contains("esc to cancel") || normalized.contains("esc cancel")
      || normalized.contains("esc exit")
    if confirms, cancels {
      let isPermission =
        normalized.contains("permission") || normalized.contains("approve")
        || normalized.contains("allow") || normalized.contains("trust")
      let permissionQuestion = text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .last { $0.lowercased().hasPrefix("allow ") && $0.lowercased().contains("mcp server") }
      return InteractivePrompt(
        token: isPermission ? "provider-permission" : "provider-choice",
        state: isPermission ? .waitingPermission : .waitingUser,
        reason: isPermission
          ? permissionQuestion.map { String($0.prefix(400)) } ?? "Agent permission required"
          : "Agent is waiting for your choice",
        menu: InteractiveMenuParser.parse(text)
      )
    }

    return nil
  }
}

/// Incremental control-sequence filtering keeps split OSC title animations out of prompt state.
public struct InteractiveTextFilter: Sendable {
  private enum State: Sendable { case text, escape, csi, osc, oscEscape }
  private var state: State = .text
  public init() {}

  public mutating func ingest(_ chunk: String) -> String {
    var result = ""
    for scalar in chunk.unicodeScalars {
      switch state {
      case .text:
        if scalar.value == 27 {
          state = .escape
        } else if scalar.value == 10 || scalar.value == 13 || scalar.value == 9
          || scalar.value >= 32
        {
          result.unicodeScalars.append(scalar)
        }
      case .escape:
        if scalar == "]" {
          state = .osc
        } else if scalar == "[" {
          state = .csi
        } else {
          state = .text
        }
      case .csi:
        if (0x40...0x7e).contains(scalar.value) { state = .text }
      case .osc:
        if scalar.value == 7 { state = .text } else if scalar.value == 27 { state = .oscEscape }
      case .oscEscape:
        if scalar == "\\" || scalar.value == 7 { state = .text } else { state = .osc }
      }
    }
    return result
  }
}

public enum InteractiveCompletionDetector {
  public static func isReadyForNextPrompt(
    recentText: String,
    rawChunk: String,
    provider: AgentProvider
  ) -> Bool {
    // BEL also terminates OSC window titles, including "Action Required" animations.
    // Neither bells nor selection carets are evidence that a turn has completed.
    guard InteractivePromptDetector.detect(in: recentText, provider: provider) == nil else {
      return false
    }
    let tail = recentText.suffix(900)
    guard !tail.lowercased().contains("esc to interrupt") else { return false }
    let promptLines = tail.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    func hasPrompt(_ marker: String) -> Bool {
      promptLines.contains { $0 == marker }
    }
    switch provider {
    case .claudeCode:
      return hasPrompt("❯")
    case .codex:
      return hasPrompt("›")
    case .openAI:
      return false
    case .hermes:
      return hasPrompt("❯") || hasPrompt("You:")
    case .cursor:
      return hasPrompt("❯") || hasPrompt("›")
    case .kimi:
      return hasPrompt("❯") || hasPrompt("›")
    case .openCode:
      return hasPrompt("❯") || hasPrompt(">_")
    case .pi:
      return hasPrompt("❯") || hasPrompt(">")
    case .grok:
      return hasPrompt("❯") || hasPrompt("›")
    case .shell:
      return false
    }
  }

  public static func completionExcerpt(from output: String) -> String {
    let ignoredFragments = [
      "sessionstart:startup", "sessionstart hook", "warp plugin", "install warp",
      "privacy policy", "esc to cancel", "esc to interrupt", "shift+tab", "context left",
      "/skills to list", "skills context budget", "to interrupt)",
    ]
    // sanitizedExcerpt strips OSC title sequences and control bytes that the CSI-only plainText
    // pass leaves behind as visible "]0;" fragments when a TUI repaints its window title.
    let lines = TerminalOutputSearch.sanitizedExcerpt(String(output.suffix(24_000)), limit: 24_000)
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { line in
        !line.isEmpty && !ignoredFragments.contains(where: line.lowercased().contains)
      }
    let excerpt = lines.suffix(40).joined(separator: "\n")
    return String(excerpt.suffix(2_000))
  }
}

public struct HermesOutputParser: Sendable {
  private var streamedText = ""

  public init() {}

  private var nativeChildren = NativeChildEventParser(provider: .hermes)

  public mutating func ingest(line: String) -> [ParsedAgentEvent] {
    let children = nativeChildren.ingest(line)
    return children.events + (children.nested ? [] : ingestParent(line: line))
  }

  private mutating func ingestParent(line: String) -> [ParsedAgentEvent] {
    guard let object = jsonObject(line), let type = object["type"] as? String else {
      return fallbackEvents(line)
    }
    let payload = object["payload"] as? [String: Any] ?? [:]
    switch type {
    case "session.started":
      guard let sessionID = object["session_id"] as? String, !sessionID.isEmpty else {
        return [.state(.idle, confidence: 0.99)]
      }
      return [.sessionStarted(sessionID), .state(.idle, confidence: 0.99)]
    case "message.start":
      streamedText = ""
      return [.state(.working, confidence: 0.99)]
    case "message.delta":
      streamedText += payload["text"] as? String ?? ""
      return [.state(.working, confidence: 0.99)]
    case "message.interim":
      let text = (payload["text"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? [] : [.assistantMessage(text)]
    case "message.complete":
      let text = (payload["text"] as? String ?? streamedText)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard payload["status"] as? String != "error" else {
        return [
          .diagnostic(text.isEmpty ? "Hermes run failed" : text),
          .state(.failed, confidence: 0.99),
        ]
      }
      guard !text.isEmpty else {
        return [
          .diagnostic("Hermes completed without a response"),
          .state(.failed, confidence: 0.9),
        ]
      }
      return [
        .assistantMessage(text),
        .result(AgentResult(status: .done, summaryCandidate: text, rawText: text)),
        .state(.done, confidence: 0.99),
      ]
    case "thinking.delta", "reasoning.delta", "reasoning.available":
      let text = (payload["text"] as? String ?? payload["reasoning"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? [] : [.reasoning(text)]
    case "tool.start", "tool.generating":
      let name = payload["name"] as? String ?? payload["tool_name"] as? String ?? "Tool"
      let detail = payload["detail"] as? String ?? payload["description"] as? String ?? ""
      return [.toolInvoked(name: name, detail: String(detail.prefix(200)))]
    case "approval.request", "sudo.request":
      let reason =
        payload["reason"] as? String ?? payload["message"] as? String
        ?? "Hermes requests approval"
      return [.permissionRequested(reason), .state(.waitingPermission, confidence: 0.99)]
    case "clarify.request":
      // Hermes' clarify tool blocks the agent on a question, usually with button choices. The
      // bridge tracks the request_id and answers via clarify.respond when the user replies, so
      // the full prompt (not just the question text) must reach the chat surface.
      let question = (payload["question"] as? String ?? "Hermes needs your input")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let choices = (payload["choices"] as? [String] ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      return [
        .choiceRequested(
          AgentChoicePrompt(
            requestID: payload["request_id"] as? String ?? "",
            question: question,
            choices: choices,
            multiSelect: payload["multi_select"] as? Bool ?? false
          ))
      ]
    case "secret.request":
      let reason =
        payload["question"] as? String ?? payload["message"] as? String
        ?? "Hermes needs your input"
      return [.waitingForUser(reason), .state(.waitingUser, confidence: 0.99)]
    case "error":
      let message =
        object["message"] as? String ?? payload["message"] as? String
        ?? "Hermes gateway error"
      return [.diagnostic(message), .state(.failed, confidence: 0.99)]
    default:
      return []
    }
  }
}

public struct TerminalScrollbackRing: Sendable, Equatable {
  public let capacity: Int
  public private(set) var startOffset = 0
  public private(set) var endOffset = 0
  private var bytes = Data()

  public init(capacity: Int = 1_048_576) {
    self.capacity = max(1, capacity)
  }

  public mutating func append(_ data: Data) {
    bytes.append(data)
    endOffset += data.count
    if bytes.count > capacity {
      let overflow = bytes.count - capacity
      bytes.removeFirst(overflow)
      startOffset += overflow
    }
  }

  public var text: String { String(decoding: bytes, as: UTF8.self) }
}

public struct ClaudeOutputParser: Sendable {
  private var assistantText = ""
  private var commands: [String] = []
  private var files: [String] = []

  public init() {}

  private var nativeChildren = NativeChildEventParser(provider: .claudeCode)

  public mutating func ingest(line: String) -> [ParsedAgentEvent] {
    let children = nativeChildren.ingest(line)
    return children.events + (children.nested ? [] : ingestParent(line: line))
  }

  private mutating func ingestParent(line: String) -> [ParsedAgentEvent] {
    guard let object = jsonObject(line) else { return fallbackEvents(line) }
    let type = object["type"] as? String
    switch type {
    case "system":
      // In print/stream-json mode this is the run handshake, not an idle prompt. The Claude
      // process is already handling the submitted turn and may emit additional system records
      // while it works. Downgrading either one to `.idle` makes the chat flash READY and removes
      // its thinking indicator until the next assistant/tool event arrives.
      var events: [ParsedAgentEvent] = [.state(.working, confidence: 0.99)]
      if let sessionID = object["session_id"] as? String, !sessionID.isEmpty {
        events.insert(.sessionStarted(sessionID), at: 0)
      }
      return events
    case "assistant":
      var events: [ParsedAgentEvent] = [.state(.working, confidence: 0.99)]
      guard let message = object["message"] as? [String: Any],
        let content = message["content"] as? [[String: Any]]
      else { return events }
      var messageText = ""
      for item in content {
        switch item["type"] as? String {
        case "text":
          messageText += item["text"] as? String ?? ""
        case "thinking":
          let thinking = (item["thinking"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if !thinking.isEmpty { events.append(.reasoning(thinking)) }
        case "tool_use":
          // ToolSearch only loads deferred tool schemas; it is harness plumbing, not work.
          guard let name = item["name"] as? String, name != "ToolSearch" else { break }
          let input = item["input"] as? [String: Any] ?? [:]
          if name == "Bash", let command = input["command"] as? String {
            commands.append(command)
          }
          if ["Write", "Edit", "NotebookEdit"].contains(name),
            let path = input["file_path"] as? String
          {
            files.append(path)
          }
          events.append(.toolInvoked(name: name, detail: Self.toolDetail(name: name, input: input)))
        default:
          break
        }
      }
      if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        assistantText += messageText
        events.append(.assistantMessage(messageText))
      }
      return events
    case "user":
      return []
    case "result":
      if object["is_error"] as? Bool == true || object["subtype"] as? String == "error" {
        let message = object["result"] as? String ?? "Claude Code run failed"
        return [.diagnostic(message), .state(.failed, confidence: 0.99)]
      }
      // Non-interactive runs cannot prompt for approval; denied tools are reported after the
      // fact, and the conversation must say so instead of silently omitting the work.
      var events: [ParsedAgentEvent] = []
      if let denials = object["permission_denials"] as? [[String: Any]], !denials.isEmpty {
        for denial in denials {
          let name = denial["tool_name"] as? String ?? "a tool"
          let input = denial["tool_input"] as? [String: Any] ?? [:]
          let detail = Self.toolDetail(name: name, input: input)
          events.append(
            .diagnostic(
              "Permission denied for \(name)\(detail.isEmpty ? "" : ": \(detail)"). "
                + "Relaunch with a broader permission mode to allow it."
            ))
        }
      }
      let resultText = object["result"] as? String ?? assistantText
      let duration = object["duration_ms"] as? Int
      let usage = ProviderTokenUsage.parse(object["usage"])
      events.append(
        .result(
          AgentResult(
            status: .done,
            summaryCandidate: resultText,
            rawText: assistantText.isEmpty ? resultText : assistantText,
            filesChanged: unique(files),
            commandsRun: unique(commands),
            durationMilliseconds: duration,
            inputTokens: usage.input,
            outputTokens: usage.output
          )))
      events.append(.state(.done, confidence: 0.99))
      return events
    default:
      return []
    }
  }

  /// Compact, single-line summary of a tool invocation for the conversation surface. Tool inputs
  /// are provider-controlled; bound them so a large edit payload never floods the transcript.
  public static func toolDetail(name: String, input: [String: Any]) -> String {
    let preferred: String? =
      switch name {
      case "Bash": input["command"] as? String
      case "Write", "Edit", "Read", "NotebookEdit": input["file_path"] as? String
      case "Glob", "Grep": input["pattern"] as? String
      case "WebFetch": input["url"] as? String
      case "WebSearch": input["query"] as? String
      case "Task", "Agent": (input["description"] as? String) ?? (input["prompt"] as? String)
      case "TodoWrite": "Updating the task list"
      default: nil
      }
    let fallback = input.values.compactMap { $0 as? String }.max(by: { $0.count < $1.count })
    let detail = (preferred ?? fallback ?? "")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(detail.prefix(200))
  }
}

public struct CodexOutputParser: Sendable {
  private var finalText = ""
  private var diagnostics: [String] = []
  private var commands: [String] = []
  private var files: [String] = []
  private var announcedToolDetails: Set<String> = []

  public init() {}

  private var nativeChildren = NativeChildEventParser(provider: .codex)

  public mutating func ingest(line: String) -> [ParsedAgentEvent] {
    let children = nativeChildren.ingest(line)
    return children.events + (children.nested ? [] : ingestParent(line: line))
  }

  private mutating func ingestParent(line: String) -> [ParsedAgentEvent] {
    guard let object = jsonObject(line) else { return fallbackEvents(line) }
    let type = object["type"] as? String
    switch type {
    case "thread.started":
      var events: [ParsedAgentEvent] = [.state(.idle, confidence: 0.99)]
      if let sessionID = object["thread_id"] as? String, !sessionID.isEmpty {
        events.insert(.sessionStarted(sessionID), at: 0)
      }
      return events
    case "turn.started":
      return [.state(.working, confidence: 0.99)]
    case "item.started", "item.updated", "item.completed":
      guard let item = object["item"] as? [String: Any], let itemType = item["type"] as? String
      else { return [] }
      let isCompleted = type == "item.completed"
      switch itemType {
      case "agent_message":
        let text = item["text"] as? String ?? ""
        if !text.isEmpty { finalText = text }
        // Only a completed item is a finished message; deltas stream through the live projection.
        if isCompleted, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          return [.assistantMessage(text)]
        }
        return []
      case "reasoning":
        guard isCompleted else { return [] }
        let text = (item["text"] as? String ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [.reasoning(text)]
      case "command_execution":
        let command = item["command"] as? String ?? ""
        guard !command.isEmpty else { return [] }
        commands.append(command)
        return announceTool(name: "Shell", detail: command)
      case "file_change":
        let paths = Self.changedPaths(in: item)
        guard !paths.isEmpty else { return [] }
        files.append(contentsOf: paths)
        return announceTool(name: "Edit", detail: paths.joined(separator: ", "))
      case "mcp_tool_call":
        let tool = [item["server"] as? String, item["tool"] as? String]
          .compactMap { $0 }
          .joined(separator: " · ")
        return announceTool(name: "MCP", detail: tool.isEmpty ? "Tool call" : tool)
      case "web_search":
        let query = item["query"] as? String ?? ""
        return announceTool(name: "WebSearch", detail: query)
      case "error":
        let message = item["message"] as? String ?? "Codex diagnostic"
        diagnostics.append(message)
        return [.diagnostic(message)]
      case "approval_request":
        return [
          .permissionRequested(item["message"] as? String ?? "Codex requests permission"),
          .state(.waitingPermission, confidence: 0.99),
        ]
      case "user_question":
        return [
          .waitingForUser(item["message"] as? String ?? "Codex has a question"),
          .state(.waitingUser, confidence: 0.99),
        ]
      default:
        return []
      }
    case "turn.completed":
      guard !finalText.isEmpty else {
        return [
          .diagnostic(diagnostics.last ?? "Codex completed without a final response"),
          .state(.failed, confidence: 0.95),
        ]
      }
      let usage = ProviderTokenUsage.parse(object["usage"])
      return [
        .result(
          AgentResult(
            status: .done,
            summaryCandidate: finalText,
            rawText: finalText,
            filesChanged: unique(files),
            commandsRun: unique(commands),
            inputTokens: usage.input,
            outputTokens: usage.output
          )),
        .state(.done, confidence: 0.99),
      ]
    case "turn.failed":
      return [
        .diagnostic(object["message"] as? String ?? diagnostics.last ?? "Codex run failed"),
        .state(.failed, confidence: 0.99),
      ]
    default:
      return []
    }
  }

  /// Codex repeats the same item across started/updated/completed events; announce each tool
  /// invocation exactly once so the transcript reads as a clean activity log.
  private mutating func announceTool(name: String, detail: String) -> [ParsedAgentEvent] {
    let bounded = String(
      detail.replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(200))
    guard announcedToolDetails.insert("\(name)\u{1F}\(bounded)").inserted else { return [] }
    return [.toolInvoked(name: name, detail: bounded)]
  }

  private static func changedPaths(in item: [String: Any]) -> [String] {
    if let path = item["path"] as? String, !path.isEmpty { return [path] }
    guard let changes = item["changes"] as? [[String: Any]] else { return [] }
    return changes.compactMap { $0["path"] as? String }.filter { !$0.isEmpty }
  }
}

/// Kimi Code CLI's `--output-format stream-json` emits OpenAI-shaped chat messages, one JSON
/// object per line: assistant messages (optionally carrying tool_calls) and tool results. There
/// is no terminal "result" envelope — an assistant message with no tool calls is what ends the
/// agent loop, so that message is the turn's answer.
public struct KimiOutputParser: Sendable {
  private var finalText = ""
  private var diagnostics: [String] = []
  private var commands: [String] = []
  private var files: [String] = []
  private var announcedSession = false

  public init() {}

  private var nativeChildren = NativeChildEventParser(provider: .kimi)

  public mutating func ingest(line: String) -> [ParsedAgentEvent] {
    let children = nativeChildren.ingest(line)
    return children.events + (children.nested ? [] : ingestParent(line: line))
  }

  private mutating func ingestParent(line: String) -> [ParsedAgentEvent] {
    guard let object = jsonObject(line) else { return fallbackEvents(line) }
    var events: [ParsedAgentEvent] = []
    // Print mode announces no session id, so the run reports the continuation token the adapter
    // translates into `--continue`; a real id is preferred if a future build emits one.
    if !announcedSession,
      let sessionID = (object["session_id"] ?? object["sessionId"]) as? String,
      !sessionID.isEmpty
    {
      announcedSession = true
      events.append(.sessionStarted(sessionID))
    }
    switch object["role"] as? String {
    case "assistant":
      if !announcedSession {
        announcedSession = true
        events.append(.sessionStarted(KimiAdapter.continuationSessionToken))
      }
      events.append(.state(.working, confidence: 0.99))
      let reasoning =
        (object["reasoning_content"] as? String ?? object["thinking"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !reasoning.isEmpty { events.append(.reasoning(reasoning)) }
      let text = Self.messageText(object["content"])
      if !text.isEmpty {
        finalText = text
        events.append(.assistantMessage(text))
      }
      let toolCalls = object["tool_calls"] as? [[String: Any]] ?? []
      for call in toolCalls {
        guard let function = call["function"] as? [String: Any],
          let name = function["name"] as? String
        else { continue }
        let input = Self.decodedArguments(function["arguments"])
        if let command = input["command"] as? String { commands.append(command) }
        if let path = (input["file_path"] ?? input["path"]) as? String, !path.isEmpty {
          files.append(path)
        }
        events.append(
          .toolInvoked(name: name, detail: ClaudeOutputParser.toolDetail(name: name, input: input)))
      }
      // No tool calls means the model stopped asking for work: the turn is finished.
      guard toolCalls.isEmpty else { return events }
      guard !finalText.isEmpty else {
        events.append(
          .diagnostic(diagnostics.last ?? "Kimi completed without a response"))
        events.append(.state(.failed, confidence: 0.9))
        return events
      }
      events.append(
        .result(
          AgentResult(
            status: .done,
            summaryCandidate: finalText,
            rawText: finalText,
            filesChanged: unique(files),
            commandsRun: unique(commands)
          )))
      events.append(.state(.done, confidence: 0.99))
      return events
    case "tool":
      // Tool results are already represented by the invocation entry in the transcript.
      return events
    default:
      // Kimi reports a failed turn as an error record rather than a role; a `where` clause on a
      // multi-pattern case would apply to both patterns, so the two shapes are checked here.
      let isError =
        object["role"] as? String == "error" || object["type"] as? String == "error"
        || object["error"] != nil
      guard isError else { return events }
      let message =
        object["message"] as? String
        ?? (object["error"] as? [String: Any])?["message"] as? String
        ?? object["error"] as? String
        ?? Self.messageText(object["content"])
      let text = message.isEmpty ? "Kimi run failed" : message
      diagnostics.append(text)
      events.append(.diagnostic(text))
      events.append(.state(.failed, confidence: 0.99))
      return events
    }
  }

  /// Kimi content is either a plain string or an array of typed blocks.
  static func messageText(_ content: Any?) -> String {
    if let text = content as? String {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let blocks = content as? [[String: Any]] else { return "" }
    return blocks.compactMap { block -> String? in
      guard block["type"] as? String == "text", let text = block["text"] as? String else {
        return nil
      }
      return text
    }
    .joined()
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Tool-call arguments arrive as a JSON string (OpenAI convention); some builds send an object.
  private static func decodedArguments(_ arguments: Any?) -> [String: Any] {
    if let object = arguments as? [String: Any] { return object }
    guard let text = arguments as? String, let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }
}

/// Cursor's `--print --output-format stream-json` is close to Claude's stream, but not the same:
/// the session id arrives on a `system`/`init` record rather than alongside the result, reasoning
/// streams as `thinking` deltas that only a `completed` record closes, and tool calls are typed by
/// key (`shellToolCall`, `readToolCall`, `editToolCall`) instead of carrying a `name` field.
public struct CursorOutputParser: Sendable {
  private var finalText = ""
  private var thinking = ""
  private var diagnostics: [String] = []
  private var commands: [String] = []
  private var files: [String] = []
  private var announcedTools: Set<String> = []

  public init() {}

  private var nativeChildren = NativeChildEventParser(provider: .cursor)

  public mutating func ingest(line: String) -> [ParsedAgentEvent] {
    let children = nativeChildren.ingest(line)
    return children.events + (children.nested ? [] : ingestParent(line: line))
  }

  private mutating func ingestParent(line: String) -> [ParsedAgentEvent] {
    guard let object = jsonObject(line) else { return fallbackEvents(line) }
    var events: [ParsedAgentEvent] = []
    let subtype = object["subtype"] as? String

    switch object["type"] as? String {
    case "system":
      guard subtype == "init" else { break }
      if let sessionID = object["session_id"] as? String, !sessionID.isEmpty {
        events.append(.sessionStarted(sessionID))
      }
      events.append(.state(.working, confidence: 0.99))
    case "thinking":
      // Deltas accumulate; only the closing record is worth showing as one reasoning block.
      if subtype == "delta", let text = object["text"] as? String {
        thinking += text
      } else if subtype == "completed" {
        let text = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        thinking = ""
        if !text.isEmpty { events.append(.reasoning(text)) }
      }
    case "assistant":
      let text = Self.messageText(object["message"])
      if !text.isEmpty {
        finalText = text
        events.append(.assistantMessage(text))
      }
    case "tool_call":
      // Every call is reported twice, started then completed; announce it once.
      let callID = object["call_id"] as? String ?? UUID().uuidString
      guard announcedTools.insert(callID).inserted,
        let call = object["tool_call"] as? [String: Any],
        // The typed call sits alongside bookkeeping siblings (toolCallId, startedAtMs,
        // hookAdditionalContexts). Dictionary order is unspecified, so the entry has to be
        // selected by shape rather than by taking the first one.
        let (kind, arguments) = call.compactMap({ key, value -> (String, [String: Any])? in
          guard key.hasSuffix("ToolCall"),
            let body = value as? [String: Any],
            let args = body["args"] as? [String: Any]
          else { return nil }
          return (key, args)
        }).first
      else { break }
      if let command = arguments["command"] as? String { commands.append(command) }
      // Only an edit changes a file; a read of the same path must not be reported as a change.
      if kind == "editToolCall", let path = arguments["path"] as? String, !path.isEmpty {
        files.append(path)
      }
      events.append(
        .toolInvoked(name: Self.toolName(kind), detail: Self.toolDetail(arguments)))
    case "result":
      let isError = object["is_error"] as? Bool ?? (subtype == "error")
      let text = (object["result"] as? String ?? finalText)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if isError {
        let message = text.isEmpty ? "Cursor run failed" : text
        diagnostics.append(message)
        events.append(.diagnostic(message))
        events.append(.state(.failed, confidence: 0.99))
        break
      }
      guard !text.isEmpty else {
        events.append(.diagnostic(diagnostics.last ?? "Cursor completed without a response"))
        events.append(.state(.failed, confidence: 0.9))
        break
      }
      let usage = ProviderTokenUsage.parse(object["usage"])
      events.append(
        .result(
          AgentResult(
            status: .done,
            summaryCandidate: text,
            rawText: text,
            filesChanged: unique(files),
            commandsRun: unique(commands),
            durationMilliseconds: object["duration_ms"] as? Int,
            inputTokens: usage.input,
            outputTokens: usage.output
          )))
      events.append(.state(.done, confidence: 0.99))
    default:
      break
    }
    return events
  }

  /// "shellToolCall" reads better in a transcript as "Shell".
  static func toolName(_ kind: String) -> String {
    let trimmed =
      kind.hasSuffix("ToolCall") ? String(kind.dropLast("ToolCall".count)) : kind
    guard let first = trimmed.first else { return kind }
    return first.uppercased() + trimmed.dropFirst()
  }

  /// Cursor names a tool's arguments differently from Claude, and an edit call carries the whole
  /// new file body in `streamContent`. Picking fields explicitly keeps that payload out of the
  /// transcript, which a longest-string fallback would drag in.
  static func toolDetail(_ arguments: [String: Any]) -> String {
    let preferred =
      (arguments["command"] as? String)
      ?? (arguments["path"] as? String)
      ?? (arguments["pattern"] as? String)
      ?? (arguments["query"] as? String)
      ?? (arguments["url"] as? String)
      ?? ""
    let detail =
      preferred
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(detail.prefix(200))
  }

  /// Cursor wraps assistant prose in Claude's content-block shape.
  static func messageText(_ message: Any?) -> String {
    guard let message = message as? [String: Any],
      let content = message["content"] as? [[String: Any]]
    else { return "" }
    return content.compactMap { block -> String? in
      guard block["type"] as? String == "text" else { return nil }
      return block["text"] as? String
    }
    .joined()
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// OpenCode's `run --format json` emits one event per line, each an envelope of `type`,
/// `sessionID`, and a `part` describing what happened. Unlike Kimi there is no terminating record
/// that marks the turn complete: `step_finish` closes a step, and a step that ran a tool is
/// followed by another step. The last assistant text before the stream ends is the answer, so the
/// result is emitted at end of output rather than on any single line.
public struct OpenCodeOutputParser: Sendable {
  private var finalText = ""
  private var diagnostics: [String] = []
  private var commands: [String] = []
  private var files: [String] = []
  private var announcedSession = false
  private var failed = false

  public init() {}

  private var nativeChildren = NativeChildEventParser(provider: .openCode)

  public mutating func ingest(line: String) -> [ParsedAgentEvent] {
    let children = nativeChildren.ingest(line)
    return children.events + (children.nested ? [] : ingestParent(line: line))
  }

  private mutating func ingestParent(line: String) -> [ParsedAgentEvent] {
    guard let object = jsonObject(line) else { return fallbackEvents(line) }
    var events: [ParsedAgentEvent] = []

    // Every event carries the session id, so the very first one is enough to make the run
    // resumable by real id through `run --session`.
    if !announcedSession, let sessionID = object["sessionID"] as? String, !sessionID.isEmpty {
      announcedSession = true
      events.append(.sessionStarted(sessionID))
    }

    let part = object["part"] as? [String: Any] ?? [:]
    switch object["type"] as? String {
    case "step_start":
      events.append(.state(.working, confidence: 0.99))
    case "text":
      let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { break }
      finalText = text
      events.append(.assistantMessage(text))
    case "reasoning":
      let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { events.append(.reasoning(text)) }
    case "tool_use":
      guard let name = part["tool"] as? String else { break }
      let state = part["state"] as? [String: Any] ?? [:]
      let input = state["input"] as? [String: Any] ?? [:]
      if let command = input["command"] as? String { commands.append(command) }
      if let path = (input["filePath"] ?? input["file_path"] ?? input["path"]) as? String,
        !path.isEmpty
      {
        files.append(path)
      }
      events.append(
        .toolInvoked(name: name, detail: ClaudeOutputParser.toolDetail(name: name, input: input)))
    case "error":
      let error = object["error"] as? [String: Any] ?? [:]
      let data = error["data"] as? [String: Any] ?? [:]
      let message =
        data["message"] as? String ?? error["name"] as? String ?? "OpenCode run failed"
      failed = true
      diagnostics.append(message)
      events.append(.diagnostic(message))
      events.append(.state(.failed, confidence: 0.99))
    default:
      break
    }
    return events
  }

  /// The stream ending is what marks an OpenCode turn finished, so the supervisor calls this once
  /// output closes rather than expecting a terminating record on any line.
  public mutating func finish() -> [ParsedAgentEvent] {
    guard !failed else { return [] }
    guard !finalText.isEmpty else {
      return [
        .diagnostic(diagnostics.last ?? "OpenCode completed without a response"),
        .state(.failed, confidence: 0.9),
      ]
    }
    return [
      .result(
        AgentResult(
          status: .done,
          summaryCandidate: finalText,
          rawText: finalText,
          filesChanged: unique(files),
          commandsRun: unique(commands)
        )),
      .state(.done, confidence: 0.99),
    ]
  }
}

/// Pi's `--mode json` emits one JSONL event per line: a `session` header, then agent, turn,
/// message and tool-execution events, closing with `agent_settled` once no automatic work
/// (retries, compaction recovery, queued follow-ups) remains. Stdout is reserved for JSON, so a
/// non-JSON line is Pi's stderr arriving through the shared terminal — a sign-in hint or a crash
/// — and is kept as the failure reason when the run ends without an answer.
public struct PiOutputParser: Sendable {
  private var finalText = ""
  private var diagnostics: [String] = []
  private var commands: [String] = []
  private var files: [String] = []
  private var failed = false
  private var settled = false

  public init() {}

  private var nativeChildren = NativeChildEventParser(provider: .pi)

  public mutating func ingest(line: String) -> [ParsedAgentEvent] {
    let children = nativeChildren.ingest(line)
    return children.events + (children.nested ? [] : ingestParent(line: line))
  }

  private mutating func ingestParent(line: String) -> [ParsedAgentEvent] {
    guard let object = jsonObject(line) else {
      let noise = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !noise.isEmpty, !noise.hasPrefix("/") {
        diagnostics.append(String(noise.prefix(500)))
        diagnostics = Array(diagnostics.suffix(10))
      }
      return fallbackEvents(line)
    }
    var events: [ParsedAgentEvent] = []
    switch object["type"] as? String {
    case "session":
      if let sessionID = object["id"] as? String, !sessionID.isEmpty {
        events.append(.sessionStarted(sessionID))
      }
    case "agent_start", "turn_start":
      events.append(.state(.working, confidence: 0.99))
    case "message_end":
      guard let message = object["message"] as? [String: Any],
        message["role"] as? String == "assistant"
      else { break }
      for block in message["content"] as? [[String: Any]] ?? [] {
        guard block["type"] as? String == "thinking",
          let thinking = (block["thinking"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty
        else { continue }
        events.append(.reasoning(thinking))
      }
      let text = Self.messageText(message["content"])
      if !text.isEmpty {
        finalText = text
        events.append(.assistantMessage(text))
      }
      if message["stopReason"] as? String == "error" {
        let reason =
          (message["errorMessage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
          ?? "Pi's model request failed"
        failed = true
        diagnostics.append(reason)
        events.append(.diagnostic(reason))
        events.append(.state(.failed, confidence: 0.99))
      }
    case "tool_execution_start":
      guard let name = object["toolName"] as? String else { break }
      let input = object["args"] as? [String: Any] ?? [:]
      if let command = input["command"] as? String { commands.append(command) }
      if ["edit", "write"].contains(name),
        let path = (input["path"] ?? input["file_path"] ?? input["filePath"]) as? String,
        !path.isEmpty
      {
        files.append(path)
      }
      events.append(
        .toolInvoked(name: name, detail: ClaudeOutputParser.toolDetail(name: name, input: input)))
    case "auto_retry_start":
      if let message = object["errorMessage"] as? String, !message.isEmpty {
        events.append(.diagnostic("Retrying after: \(message)"))
      }
    case "auto_retry_end":
      if object["success"] as? Bool == false {
        let reason = object["finalError"] as? String ?? "Pi gave up retrying the model request"
        failed = true
        diagnostics.append(reason)
        events.append(.diagnostic(reason))
        events.append(.state(.failed, confidence: 0.99))
      }
    case "extension_error":
      if let message = object["error"] as? String, !message.isEmpty {
        events.append(.diagnostic("Pi extension error: \(message)"))
      }
    case "agent_settled":
      guard !settled else { break }
      settled = true
      if object["aborted"] as? Bool == true, !failed {
        events.append(.diagnostic("Pi run was aborted"))
        events.append(.state(.stopped, confidence: 0.99))
        failed = true
      } else {
        events += completion()
      }
    default:
      break
    }
    return events
  }

  /// Joins the text blocks of an assistant message's content array.
  public static func messageText(_ content: Any?) -> String {
    guard let blocks = content as? [[String: Any]] else {
      return ((content as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return blocks.compactMap { block -> String? in
      guard block["type"] as? String == "text" else { return nil }
      return block["text"] as? String
    }
    .joined()
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A run that exits without `agent_settled` (a crash, or a sign-in failure before the first
  /// turn) is closed here when output ends.
  public mutating func finish() -> [ParsedAgentEvent] {
    guard !settled, !failed else { return [] }
    settled = true
    return completion()
  }

  private func completion() -> [ParsedAgentEvent] {
    guard !failed else { return [] }
    guard !finalText.isEmpty else {
      return [
        .diagnostic(diagnostics.last ?? "Pi completed without a response"),
        .state(.failed, confidence: 0.9),
      ]
    }
    return [
      .result(
        AgentResult(
          status: .done,
          summaryCandidate: finalText,
          rawText: finalText,
          filesChanged: unique(files),
          commandsRun: unique(commands)
        )),
      .state(.done, confidence: 0.99),
    ]
  }
}

public enum ProviderParser: Sendable {
  case markers
  case claude(ClaudeOutputParser)
  case codex(CodexOutputParser)
  case hermes(HermesOutputParser)
  case cursor(CursorOutputParser)
  case kimi(KimiOutputParser)
  case openCode(OpenCodeOutputParser)
  case pi(PiOutputParser)

  public static func forProvider(_ provider: AgentProvider) -> ProviderParser {
    switch provider {
    case .claudeCode: .claude(ClaudeOutputParser())
    case .codex: .codex(CodexOutputParser())
    case .openAI: .codex(CodexOutputParser())
    case .hermes: .hermes(HermesOutputParser())
    case .cursor: .cursor(CursorOutputParser())
    case .kimi: .kimi(KimiOutputParser())
    case .openCode: .openCode(OpenCodeOutputParser())
    case .pi: .pi(PiOutputParser())
    case .grok: .claude(ClaudeOutputParser())
    case .shell: .markers
    }
  }

  /// Events a provider can only emit once its output closes. OpenCode marks a finished turn by
  /// ending the stream rather than by a terminating record, so the supervisor asks every parser
  /// for these when output ends; the rest have already reported their result and return nothing.
  public mutating func finish() -> [ParsedAgentEvent] {
    switch self {
    case .openCode(var parser):
      let events = parser.finish()
      self = .openCode(parser)
      return events
    case .pi(var parser):
      // Pi normally settles explicitly; this covers a process that died before it could.
      let events = parser.finish()
      self = .pi(parser)
      return events
    default:
      return []
    }
  }

  public mutating func ingest(line: String) -> [ParsedAgentEvent] {
    switch self {
    case .markers:
      return []
    case .claude(var parser):
      let events = parser.ingest(line: line)
      self = .claude(parser)
      return events
    case .codex(var parser):
      let events = parser.ingest(line: line)
      self = .codex(parser)
      return events
    case .hermes(var parser):
      let events = parser.ingest(line: line)
      self = .hermes(parser)
      return events
    case .cursor(var parser):
      let events = parser.ingest(line: line)
      self = .cursor(parser)
      return events
    case .kimi(var parser):
      let events = parser.ingest(line: line)
      self = .kimi(parser)
      return events
    case .openCode(var parser):
      let events = parser.ingest(line: line)
      self = .openCode(parser)
      return events
    case .pi(var parser):
      let events = parser.ingest(line: line)
      self = .pi(parser)
      return events
    }
  }
}

private func jsonObject(_ line: String) -> [String: Any]? {
  guard let data = line.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return nil }
  return object
}

private func fallbackEvents(_ line: String) -> [ParsedAgentEvent] {
  let normalized = line.lowercased()
  if normalized.contains("permission")
    && (normalized.contains("allow") || normalized.contains("approve"))
  {
    return [.permissionRequested(line), .state(.waitingPermission, confidence: 0.7)]
  }
  if normalized.contains("what would you like") || normalized.contains("need your input") {
    return [.waitingForUser(line), .state(.waitingUser, confidence: 0.7)]
  }
  // A dead provider's auth failure is prose, not a prompt: the sign-in is answered outside Otto.
  // Read it as a failed run needing re-authentication, not the working idle screen behind it.
  if normalized.contains("failed to authenticate") || normalized.contains("oauth session expired") {
    return [.diagnostic(line), .state(.failed, confidence: 0.8)]
  }
  if normalized.contains("context") && normalized.contains("exhaust") {
    return [.diagnostic(line), .state(.failed, confidence: 0.8)]
  }
  return []
}

private func unique(_ values: [String]) -> [String] {
  var seen = Set<String>()
  return values.filter { seen.insert($0).inserted }
}
