import Foundation
import OttoModels
import OttoTools

public enum LocalVoiceCommandOutcome: Sendable, Equatable {
  case sleeping
  case completed(toolName: String, confirmation: String)
  case clarification(String)
  case unrecognized(String)
}

public struct LocalCommandUpdate: Sendable, Equatable {
  public var state: DictationState
  public var transcript: String
  /// Short wording for the Voice row; never a raw runtime or transport error.
  public var detail: String
  public var outcome: LocalVoiceCommandOutcome?
  public var inputDiagnostic: LocalSpeechInputDiagnostic?
  /// The underlying error for logs when `state` is `.failed`.
  public var technicalDetail: String?

  public init(
    state: DictationState,
    transcript: String = "",
    detail: String = "",
    outcome: LocalVoiceCommandOutcome? = nil,
    inputDiagnostic: LocalSpeechInputDiagnostic? = nil,
    technicalDetail: String? = nil
  ) {
    self.state = state
    self.transcript = transcript
    self.detail = detail
    self.outcome = outcome
    self.inputDiagnostic = inputDiagnostic
    self.technicalDetail = technicalDetail
  }
}

/// Executes a deliberately small, high-confidence command grammar without involving a cloud
/// model. Unsupported speech is rejected instead of being guessed at or sent to the wrong agent.
public actor LocalVoiceCommandRouter {
  private let registry: ToolRegistry
  private let toolContext: ToolContext
  private var voiceContext: VoiceContext?

  public init(registry: ToolRegistry, context: ToolContext) {
    self.registry = registry
    toolContext = context
  }

  public func updateContext(_ context: VoiceContext) {
    voiceContext = context
  }

  public func execute(_ transcript: String) async throws -> LocalVoiceCommandOutcome {
    guard let command = PromptSubmission.verbatimText(from: transcript) else {
      return .unrecognized("Heard nothing")
    }
    if SpokenVoiceLifecycle.isSleepCommand(command) { return .sleeping }

    if let action = simpleNavigationAction(command) {
      _ = try await registry.call(
        name: action.toolName,
        input: action.input,
        context: toolContext
      )
      return .completed(toolName: action.toolName, confirmation: action.confirmation)
    }

    if let create = createNodeAction(command) {
      _ = try await registry.call(name: "node.create", input: create.input, context: toolContext)
      return .completed(toolName: "node.create", confirmation: create.confirmation)
    }

    if let browser = browserOpenAction(command) {
      _ = try await registry.call(name: "browser.open", input: browser.input, context: toolContext)
      return .completed(toolName: "browser.open", confirmation: browser.confirmation)
    }

    switch sessionOpenAction(command) {
    case .match(let session):
      _ = try await registry.call(
        name: "session.open",
        input: .object(["session": .string(session.id.uuidString)]),
        context: toolContext
      )
      return .completed(toolName: "session.open", confirmation: "Opened \(session.name)")
    case .ambiguous(let names):
      return .clarification("Which session did you mean: \(names.joined(separator: ", "))?")
    case .missing(let requested):
      return .clarification("I cannot find a session named \(requested).")
    case .noMatch:
      break
    }

    if let action = botVoiceAction(command) {
      _ = try await registry.call(name: action.toolName, input: action.input, context: toolContext)
      return .completed(toolName: action.toolName, confirmation: action.confirmation)
    }

    switch sessionPromptAction(command) {
    case .match(let intent):
      _ = try await registry.call(
        name: "session.send_prompt",
        input: .object([
          "sessionID": .string(intent.targetID.uuidString),
          "prompt": .string(intent.prompt),
        ]),
        context: toolContext
      )
      return .completed(
        toolName: "session.send_prompt",
        confirmation: "Prompted \(intent.targetName) in Sessions"
      )
    case .ambiguous(let names):
      return .clarification("Which session did you mean: \(names.joined(separator: ", "))?")
    case .missing(let requested):
      return .clarification("I cannot find a session named \(requested).")
    case .noMatch:
      break
    }

    if let action = teamVoiceAction(command) {
      _ = try await registry.call(name: action.toolName, input: action.input, context: toolContext)
      return .completed(toolName: action.toolName, confirmation: action.confirmation)
    }

    switch namedNodeAction(command, verb: "focus") {
    case .match(let target):
      _ = try await registry.call(
        name: "node.focus",
        input: .object(["nodeID": .string(target.id.uuidString)]),
        context: toolContext
      )
      return .completed(toolName: "node.focus", confirmation: "Focused \(target.name)")
    case .ambiguous(let names):
      return .clarification("Which node did you mean: \(names.joined(separator: ", "))?")
    case .missing(let requested):
      return .clarification("I cannot find a node named \(requested).")
    case .noMatch:
      break
    }

    switch namedNodeAction(command, verb: "open") {
    case .match(let target):
      _ = try await registry.call(
        name: "node.focus",
        input: .object(["nodeID": .string(target.id.uuidString)]),
        context: toolContext
      )
      return .completed(toolName: "node.focus", confirmation: "Opened \(target.name)")
    case .ambiguous(let names):
      return .clarification("Which node did you mean: \(names.joined(separator: ", "))?")
    case .missing(let requested):
      return .clarification("I cannot find a node named \(requested).")
    case .noMatch:
      break
    }

    switch namedNodeAction(command, verb: "close") {
    case .match(let target):
      _ = try await registry.call(
        name: "node.close",
        input: .object(["nodeID": .string(target.id.uuidString)]),
        context: toolContext
      )
      return .completed(toolName: "node.close", confirmation: "Closed \(target.name)")
    case .ambiguous(let names):
      return .clarification("Which node did you mean: \(names.joined(separator: ", "))?")
    case .missing(let requested):
      return .clarification("I cannot find a node named \(requested).")
    case .noMatch:
      break
    }

    switch VerbatimRelayParser.parse(command, context: voiceContext, previousUtterance: nil) {
    case .relay(let intent):
      let toolName = try await relay(intent)
      return .completed(toolName: toolName, confirmation: "Sent verbatim to \(intent.targetName)")
    case .rejected(let reason):
      return .unrecognized(reason)
    case .noMatch:
      break
    }

    switch directPrompt(command) {
    case .match(let intent):
      let toolName = try await relay(intent)
      return .completed(toolName: toolName, confirmation: "Prompted \(intent.targetName)")
    case .ambiguous(let names):
      return .clarification("Which agent did you mean: \(names.joined(separator: ", "))?")
    case .missing(let requested):
      return .clarification("I cannot find an agent named \(requested).")
    case .noMatch:
      break
    }

    return .unrecognized(
      "Command not recognized. Try opening a URL, starting a terminal, opening a session, or prompting an exact agent name."
    )
  }

  private enum NamedMatch<T> {
    case noMatch
    case match(T)
    case ambiguous([String])
    case missing(String)
  }

  private func simpleNavigationAction(_ transcript: String) -> (
    toolName: String, input: JSONValue, confirmation: String
  )? {
    switch normalizedWords(transcript) {
    case ["open", "chat"], ["show", "chat"], ["chat", "mode"],
      ["open", "chat", "mode"], ["switch", "to", "chat"],
      ["switch", "to", "chat", "mode"]:
      return (
        "surface.set", .object(["surface": .string(WorkspaceSurface.chat.rawValue)]),
        "Opened Chat"
      )
    case ["open", "bots"], ["show", "bots"], ["bots", "mode"],
      ["open", "bots", "mode"], ["switch", "to", "bots"],
      ["switch", "to", "bots", "mode"], ["show", "my", "bots"], ["list", "bots"],
      ["list", "my", "bots"], ["go", "to", "bots"], ["take", "me", "to", "bots"],
      ["can", "i", "see", "my", "bots"], ["what", "bots", "do", "i", "have"]:
      return ("chat.open", .object(["section": .string("bots")]), "Opened Bots")
    case ["open", "sessions"], ["show", "sessions"], ["sessions", "mode"],
      ["open", "sessions", "mode"], ["switch", "to", "sessions"],
      ["switch", "to", "sessions", "mode"], ["show", "my", "sessions"],
      ["list", "sessions"], ["list", "my", "sessions"], ["go", "to", "sessions"],
      ["take", "me", "to", "sessions"], ["can", "i", "see", "my", "sessions"],
      ["what", "sessions", "do", "i", "have"]:
      return ("chat.open", .object(["section": .string("sessions")]), "Opened Sessions")
    default:
      return nil
    }
  }

  private func botVoiceAction(_ transcript: String) -> (
    toolName: String, input: JSONValue, confirmation: String
  )? {
    guard let context = voiceContext else { return nil }
    for bot in context.bots {
      let escaped = NSRegularExpression.escapedPattern(for: bot.name)
      let handle = NSRegularExpression.escapedPattern(for: bot.handle)
      let target = "(?:@?\(handle)|\(escaped))"
      let promptPatterns = [
        #"(?i)^\s*(?:please\s+)?(?:tell|prompt|ask)\s+(?:bot\s+)?"# + target
          + #"\s*(?:(?:[:,]\s*)|(?:to\s+))?(.+?)\s*$"#
      ]
      if let prompt = firstCapture(in: transcript, patterns: promptPatterns) {
        return (
          "bot.send_prompt",
          .object(["bot": .string(bot.name), "prompt": .string(prompt)]),
          "Prompted \(bot.name)"
        )
      }
      let openPatterns = [
        #"(?i)^\s*(?:open|show|focus|switch\s+to)\s+(?:bot\s+)?"# + target
          + #"(?:\s+bot)?\s*$"#
      ]
      if matchesAny(transcript, patterns: openPatterns) {
        return (
          "bot.open", .object(["bot": .string(bot.name)]), "Opened \(bot.name)"
        )
      }
    }
    return nil
  }

  private func sessionPromptAction(_ transcript: String) -> NamedMatch<VerbatimRelayIntent> {
    guard let context = voiceContext else { return .noMatch }
    var matches: [VerbatimRelayIntent] = []
    let sessions = availableSessions(in: context)
    for session in sessions {
      let escaped = NSRegularExpression.escapedPattern(for: session.name)
      let action = #"(?:tell|prompt|ask|message|instruct)"#
      let sessionLocation = #"(?:in|from)\s+(?:the\s+)?sessions?(?:\s+(?:tab|view))?"#
      let promptSeparator = #"(?:(?:[:,]\s*)|(?:to\s+))?"#
      let patterns = [
        #"(?i)^\s*(?:please\s+)?(?:go\s+)?"# + action + #"\s+(?:session\s+)?"#
          + escaped
          + #"\s+"# + sessionLocation + #"\s*"# + promptSeparator + #"(.+?)\s*$"#,
        #"(?i)^\s*(?:please\s+)?(?:go\s+)?"# + action + #"\s+session\s+"#
          + escaped + #"\s*"# + promptSeparator + #"(.+?)\s*$"#,
      ]
      guard let prompt = firstCapture(in: transcript, patterns: patterns) else { continue }
      matches.append(
        VerbatimRelayIntent(
          targetID: session.id,
          targetName: session.name,
          prompt: prompt,
          source: .inline
        ))
    }
    if matches.count == 1 { return .match(matches[0]) }
    if matches.count > 1 { return .ambiguous(matches.map(\.targetName)) }

    let words = normalizedWords(transcript)
    guard words.contains("session") || words.contains("sessions") else { return .noMatch }
    let actionWords: Set<String> = ["tell", "prompt", "ask", "message", "instruct"]
    guard let actionIndex = words.firstIndex(where: { actionWords.contains($0) }) else {
      return .noMatch
    }
    let targetIndex = words.index(after: actionIndex)
    guard targetIndex < words.endIndex else { return .missing("that session") }
    let requested =
      words[targetIndex] == "session"
      ? words.dropFirst(targetIndex + 1).first ?? "that session"
      : words[targetIndex]
    return .missing(requested)
  }

  private func sessionOpenAction(_ transcript: String) -> NamedMatch<VoiceSessionContext> {
    guard let context = voiceContext else { return .noMatch }
    var matches: [VoiceSessionContext] = []
    for session in availableSessions(in: context) {
      let escaped = NSRegularExpression.escapedPattern(for: session.name)
      let patterns = [
        #"(?i)^\s*(?:open|show|focus|switch\s+to)\s+(?:the\s+)?(?:session\s+)?"#
          + escaped + #"(?:\s+session)?\s*$"#
      ]
      if matchesAny(transcript, patterns: patterns) { matches.append(session) }
    }
    if matches.count == 1 { return .match(matches[0]) }
    if matches.count > 1 { return .ambiguous(matches.map(\.name)) }

    let words = normalizedWords(transcript)
    guard words.contains("session"),
      words.contains(where: { ["open", "show", "focus", "switch"].contains($0) })
    else { return .noMatch }
    let ignored: Set<String> = [
      "open", "show", "focus", "switch", "to", "the", "session", "sessions",
    ]
    let requested = words.filter { !ignored.contains($0) }.joined(separator: " ")
    return requested.isEmpty ? .noMatch : .missing(requested)
  }

  private func availableSessions(in context: VoiceContext) -> [VoiceSessionContext] {
    guard context.sessions.isEmpty else { return context.sessions }
    let botNodeIDs = Set(context.bots.compactMap(\.nodeID))
    return context.nodes.filter { $0.kind == .agent && !botNodeIDs.contains($0.id) }.map {
      VoiceSessionContext(
        id: $0.id,
        name: $0.name,
        canvasID: context.activeCanvas.id,
        provider: $0.provider,
        status: $0.status
      )
    }
  }

  private func teamVoiceAction(_ transcript: String) -> (
    toolName: String, input: JSONValue, confirmation: String
  )? {
    guard let context = voiceContext else { return nil }
    for team in context.teams {
      let escaped = NSRegularExpression.escapedPattern(for: team.name)
      let target = "(?:team\\s+\(escaped)|\(escaped)\\s+team|\(escaped))"
      let newPatterns = [
        #"(?i)^\s*(?:start\s+)?(?:a\s+)?new\s+(?:chat\s+)?session\s+(?:for\s+)?(?:the\s+)?"#
          + target + #"\s*$"#,
        #"(?i)^\s*(?:start\s+)?(?:a\s+)?new\s+"# + target + #"\s+session\s*$"#,
      ]
      if matchesAny(transcript, patterns: newPatterns) {
        return (
          "team.new_session", .object(["team": .string(team.name)]),
          "Started a new \(team.name) session"
        )
      }
      let compactPatterns = [
        #"(?i)^\s*(?:compact|compress)\s+(?:the\s+)?"# + target
          + #"(?:\s+(?:chat|session|history))?\s*$"#
      ]
      if matchesAny(transcript, patterns: compactPatterns) {
        return (
          "team.compact_session", .object(["team": .string(team.name)]),
          "Compacted \(team.name)"
        )
      }
      let messagePatterns = [
        #"(?i)^\s*(?:please\s+)?(?:tell|message|ask|instruct)\s+(?:the\s+)?"# + target
          + #"\s*(?:(?:[:,]\s*)|(?:to\s+))?(.+?)\s*$"#
      ]
      if let message = firstCapture(in: transcript, patterns: messagePatterns) {
        return (
          "team.send_message",
          .object([
            "team": .string(team.name),
            "message": .string(normalizeSpokenTeamMentions(message)),
          ]),
          "Messaged \(team.name)"
        )
      }
      let openPatterns = [
        #"(?i)^\s*(?:open|show|focus)\s+(?:the\s+)?"# + target + #"\s*$"#
      ]
      if matchesAny(transcript, patterns: openPatterns) {
        return (
          "team.open", .object(["team": .string(team.name)]), "Opened \(team.name)"
        )
      }
    }
    return nil
  }

  private func firstCapture(in transcript: String, patterns: [String]) -> String? {
    for pattern in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern),
        let match = expression.firstMatch(
          in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
        match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: transcript)
      else { continue }
      let value = String(transcript[range]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }
    return nil
  }

  private func matchesAny(_ transcript: String, patterns: [String]) -> Bool {
    patterns.contains { pattern in
      guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
      return expression.firstMatch(
        in: transcript, range: NSRange(transcript.startIndex..., in: transcript)) != nil
    }
  }

  private func normalizeSpokenTeamMentions(_ text: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: #"(?i)\bat\s+channel\b"#) else {
      return text
    }
    return expression.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "@channel")
  }

  private func createNodeAction(_ transcript: String) -> (input: JSONValue, confirmation: String)? {
    let words = normalizedWords(transcript)
    guard words.count >= 2, ["create", "add", "open"].contains(words[0]) else { return nil }
    let ignored: Set<String> = ["a", "an", "new", "node", "window", "please"]
    let candidates = words.dropFirst().filter { !ignored.contains($0) }
    guard candidates.count == 1 else { return nil }
    let spokenKind = candidates[0]
    let kind: NodeKind
    switch spokenKind {
    case "agent": kind = .agent
    case "terminal": kind = .terminal
    case "browser": kind = .browser
    case "document", "markdown", "note": kind = .markdown
    default: return nil
    }
    return (
      .object(["kind": .string(kind.rawValue), "x": .number(0), "y": .number(0)]),
      "Created \(spokenKind)"
    )
  }

  private func browserOpenAction(_ transcript: String) -> (input: JSONValue, confirmation: String)?
  {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?i)^\s*(?:please\s+)?open\s+((?:https?://)?[^\s]+\.[^\s]+)\s*$"#
      ),
      let match = expression.firstMatch(
        in: trimmed,
        range: NSRange(trimmed.startIndex..., in: trimmed)
      ),
      let range = Range(match.range(at: 1), in: trimmed)
    else { return nil }
    var url = String(trimmed[range])
    if URL(string: url)?.scheme == nil { url = "https://\(url)" }
    guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased())
    else { return nil }
    return (
      .object(["url": .string(url), "x": .number(0), "y": .number(0)]),
      "Opened \(url)"
    )
  }

  private func namedNodeAction(_ transcript: String, verb: String) -> NamedMatch<VoiceNodeContext> {
    guard let requested = namedTarget(in: transcript, verbs: [verb]) else { return .noMatch }
    let matches = exactMatches(requested, in: voiceContext?.nodes ?? [], name: \.name)
    if matches.count == 1 { return .match(matches[0]) }
    if matches.count > 1 { return .ambiguous(matches.map(\.name)) }
    return .missing(requested)
  }

  private func namedTarget(in transcript: String, verbs: [String]) -> String? {
    let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    for verb in verbs.sorted(by: { $0.count > $1.count }) {
      let prefix = "\(verb) "
      guard normalized.lowercased().hasPrefix(prefix) else { continue }
      let requested = String(normalized.dropFirst(prefix.count))
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
      return requested.isEmpty ? nil : requested
    }
    return nil
  }

  private func exactMatches<T>(_ requested: String, in values: [T], name: KeyPath<T, String>) -> [T]
  {
    values.filter {
      $0[keyPath: name].compare(
        requested,
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
      ) == .orderedSame
    }
  }

  private func directPrompt(_ transcript: String) -> NamedMatch<VerbatimRelayIntent> {
    guard let context = voiceContext else { return .noMatch }
    var matches: [VerbatimRelayIntent] = []
    for agent in context.nodes where agent.kind == .agent {
      let escaped = NSRegularExpression.escapedPattern(for: agent.name)
      let patterns = [
        #"^\s*(?:please\s+)?prompt\s+"# + escaped + #"\s+(?:with\s+)?(.+?)\s*$"#,
        #"^\s*(?:please\s+)?dictate\s+to\s+"# + escaped + #"\s*[:,]?\s*(.+?)\s*$"#,
        #"^\s*(?:please\s+)?tell\s+"# + escaped
          + #"\s*(?:(?:[:,]\s*)|(?:to\s+))?(.+?)\s*$"#,
      ]
      for pattern in patterns {
        guard
          let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
          ),
          let match = expression.firstMatch(
            in: transcript,
            range: NSRange(transcript.startIndex..., in: transcript)
          ),
          let range = Range(match.range(at: 1), in: transcript)
        else { continue }
        let prompt = String(transcript[range])
        guard PromptSubmission.verbatimText(from: prompt) != nil else { continue }
        matches.append(
          VerbatimRelayIntent(
            targetID: agent.id,
            targetName: agent.name,
            prompt: prompt,
            source: .inline
          ))
        break
      }
    }
    if matches.count == 1 { return .match(matches[0]) }
    if matches.count > 1 { return .ambiguous(matches.map(\.targetName)) }
    let words = normalizedWords(transcript)
    if words.first == "prompt" || words.first == "tell" || words.starts(with: ["dictate", "to"]) {
      return .missing(words.dropFirst(words.first == "dictate" ? 2 : 1).first ?? "that agent")
    }
    return .noMatch
  }

  private func relay(_ intent: VerbatimRelayIntent) async throws -> String {
    let status = try await registry.call(
      name: "agent.get_status",
      input: .object(["agentID": .string(intent.targetID.uuidString)]),
      context: toolContext
    )
    let waitingStates = ["WAITING_PERMISSION", "WAITING_USER"]
    let toolName =
      waitingStates.contains(status["state"]?.stringValue ?? "")
      ? VoiceAgentRelay.inputToolName
      : VoiceAgentRelay.promptToolName
    let delivery = try await VoiceAgentRelay.send(
      toolName: toolName,
      agentID: intent.targetID,
      text: intent.prompt,
      lastKnownState: status["state"]?.stringValue,
      registry: registry,
      context: toolContext
    )
    return delivery.toolName
  }

  private func normalizedWords(_ transcript: String) -> [String] {
    transcript.lowercased()
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }
}

public actor LocalCommandSession {
  public nonisolated let updates: AsyncStream<LocalCommandUpdate>
  private let continuation: AsyncStream<LocalCommandUpdate>.Continuation
  private let transcriber: any SpeechTranscriber
  private let router: LocalVoiceCommandRouter
  private var transcript = ""
  private var listenTask: Task<Void, Never>?
  private var diagnosticsTask: Task<Void, Never>?
  private var isListening = false
  /// Set while stopping: batch engines (Whistle, Parakeet) only produce text once capture ends.
  private var isFinishing = false
  private var finishError: String?
  private var latestInputDiagnostic: LocalSpeechInputDiagnostic?

  public init(transcriber: any SpeechTranscriber, router: LocalVoiceCommandRouter) {
    self.transcriber = transcriber
    self.router = router
    var continuation: AsyncStream<LocalCommandUpdate>.Continuation!
    updates = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  deinit {
    listenTask?.cancel()
    diagnosticsTask?.cancel()
  }

  public func start() async {
    guard !isListening else { return }
    guard await transcriber.requestAuthorization() else {
      continuation.yield(
        LocalCommandUpdate(
          state: .denied,
          detail: "Enable Speech Recognition for Otto in System Settings › Privacy"
        ))
      return
    }
    do {
      let stream = try await transcriber.startTranscribing()
      isListening = true
      transcript = ""
      latestInputDiagnostic = nil
      startDiagnostics()
      continuation.yield(LocalCommandUpdate(state: .listening))
      listenTask = Task { [weak self] in
        do {
          for try await text in stream { await self?.record(text) }
        } catch {
          await self?.failed(
            VoiceFailureText.message(for: error),
            technicalDetail: VoiceFailureText.technicalDetail(for: error)
          )
        }
      }
    } catch {
      continuation.yield(
        LocalCommandUpdate(
          state: .failed,
          detail: VoiceFailureText.message(for: error),
          technicalDetail: VoiceFailureText.technicalDetail(for: error)
        ))
    }
  }

  public func stopAndExecute() async {
    guard isListening else { return }
    isListening = false
    isFinishing = true
    finishError = nil
    await transcriber.stopTranscribing()
    await finishTranscription(listenTask)
    isFinishing = false
    listenTask = nil
    diagnosticsTask?.cancel()
    diagnosticsTask = nil
    let final = transcript
    if final.isEmpty, let finishError {
      continuation.yield(LocalCommandUpdate(state: .failed, detail: finishError))
      return
    }
    continuation.yield(
      LocalCommandUpdate(
        state: .delivering,
        transcript: final,
        inputDiagnostic: latestInputDiagnostic
      ))
    do {
      let outcome = try await router.execute(final)
      let detail: String
      switch outcome {
      case .sleeping: detail = "Command mode sleeping"
      case .completed(_, let confirmation): detail = confirmation
      case .clarification(let question): detail = question
      case .unrecognized(let reason): detail = reason
      }
      continuation.yield(
        LocalCommandUpdate(
          state: .idle,
          transcript: final,
          detail: detail,
          outcome: outcome,
          inputDiagnostic: latestInputDiagnostic
        ))
    } catch {
      continuation.yield(
        LocalCommandUpdate(
          state: .failed,
          transcript: final,
          detail: VoiceFailureText.message(for: error),
          technicalDetail: VoiceFailureText.technicalDetail(for: error)
        ))
    }
  }

  public func updateContext(_ context: VoiceContext) async {
    await router.updateContext(context)
  }

  public func cancel() async {
    guard isListening else { return }
    isListening = false
    await transcriber.stopTranscribing()
    listenTask?.cancel()
    listenTask = nil
    diagnosticsTask?.cancel()
    diagnosticsTask = nil
    continuation.yield(LocalCommandUpdate(state: .idle, detail: "Command cancelled"))
  }

  private func record(_ text: String) {
    guard isListening || isFinishing else { return }
    transcript = text
    guard isListening else { return }
    continuation.yield(
      LocalCommandUpdate(
        state: .listening,
        transcript: text,
        inputDiagnostic: latestInputDiagnostic
      ))
  }

  private func startDiagnostics() {
    diagnosticsTask?.cancel()
    let stream = transcriber.inputDiagnostics
    diagnosticsTask = Task { [weak self] in
      for await diagnostic in stream { await self?.record(diagnostic) }
    }
  }

  private func record(_ diagnostic: LocalSpeechInputDiagnostic) {
    guard isListening else { return }
    latestInputDiagnostic = diagnostic
    continuation.yield(
      LocalCommandUpdate(
        state: .listening,
        transcript: transcript,
        detail: diagnostic.actionableDetail,
        inputDiagnostic: diagnostic
      ))
  }

  private func failed(_ message: String, technicalDetail: String? = nil) {
    if isFinishing { finishError = message }
    guard isListening else { return }
    isListening = false
    continuation.yield(
      LocalCommandUpdate(state: .failed, detail: message, technicalDetail: technicalDetail))
  }
}

/// Waits for a listening task to take the transcriber's last result, which batch engines yield
/// while stopping, then cancels it. Streaming engines that never finish are cut off after
/// `timeout`.
func finishTranscription(_ task: Task<Void, Never>?, timeout: Duration = .seconds(1)) async {
  guard let task else { return }
  await withTaskGroup(of: Void.self) { group in
    group.addTask { await task.value }
    group.addTask { try? await Task.sleep(for: timeout) }
    await group.next()
    task.cancel()
    group.cancelAll()
  }
}

public enum SpokenVoiceLifecycle {
  public static func isSleepCommand(_ transcript: String) -> Bool {
    var words = transcript.lowercased()
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)

    let leadingFillers: Set<String> = ["hey", "okay", "ok", "please"]
    while let first = words.first, leadingFillers.contains(first) { words.removeFirst() }
    if let first = words.first, ["otto", "muse", "voice"].contains(first) { words.removeFirst() }
    while let first = words.first, leadingFillers.contains(first) { words.removeFirst() }
    let requestPrefixes = [
      ["can", "you"],
      ["could", "you"],
      ["would", "you"],
      ["will", "you"],
      ["i", "want", "you", "to"],
      ["i", "need", "you", "to"],
    ]
    if let prefix = requestPrefixes.first(where: { words.starts(with: $0) }) {
      words.removeFirst(prefix.count)
    }
    while let first = words.first, leadingFillers.contains(first) { words.removeFirst() }
    while let last = words.last, ["now", "please", "thanks"].contains(last) {
      words.removeLast()
    }
    if words.suffix(2) == ["thank", "you"] { words.removeLast(2) }

    return [
      ["sleep"],
      ["go", "to", "sleep"],
      ["you", "can", "go", "to", "sleep"],
      ["put", "yourself", "to", "sleep"],
      ["stop", "listening"],
    ].contains(words)
  }
}
