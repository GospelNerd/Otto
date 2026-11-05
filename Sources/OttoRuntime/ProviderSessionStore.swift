import Foundation
import OttoModels

/// Reads provider CLIs' own on-disk session records. Interactive TUI sessions never emit
/// stream-JSON for Otto to parse, but both Claude Code and Codex persist every turn to disk —
/// harvesting those files is what lets a TUI stint appear in the chat transcript and lets the
/// next chat message resume the session the TUI actually continued.
public enum ProviderSessionStore {
  public struct Turn: Equatable, Sendable {
    public var role: AgentTranscriptRole
    public var text: String

    public init(role: AgentTranscriptRole, text: String) {
      self.role = role
      self.text = text
    }
  }

  public struct Harvest: Equatable, Sendable {
    /// The confirmed provider identifier for the session these turns belong to.
    public var sessionID: String?
    public var turns: [Turn]

    public init(sessionID: String? = nil, turns: [Turn] = []) {
      self.sessionID = sessionID
      self.turns = turns.compactMap { turn in
        guard turn.role == .user else { return turn }
        guard let text = PromptSubmission.visibleUserText(turn.text) else { return nil }
        return Turn(role: .user, text: text)
      }
    }
  }

  /// Only this much of a session file's tail is parsed; a long-lived session's early history
  /// is already in the transcript from previous harvests or chat runs.
  private static let tailByteLimit = 4 * 1_048_576

  /// Provider homes are relocated per account (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`); pass the
  /// account's home as `providerHome` so sessions are read from where that account wrote them.
  public static func harvest(
    provider: AgentProvider,
    workingDirectory: String,
    since: Date,
    sessionID: String? = nil,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    providerHome: URL? = nil
  ) -> Harvest {
    // A shared working directory is not a session identity. Without a provider-confirmed or
    // explicitly resumed ID, leave the transcript alone rather than adopting a neighbour.
    guard let sessionID, !sessionID.isEmpty else { return Harvest() }
    // Small clock skew guard: the provider stamps lines itself.
    let since = since.addingTimeInterval(-5)
    switch provider {
    case .claudeCode:
      let file = claudeProjectDirectory(
        workingDirectory: workingDirectory, home: home, providerHome: providerHome
      )
      .appending(path: "\(sessionID).jsonl")
      guard FileManager.default.fileExists(atPath: file.path) else { return Harvest() }
      return parseClaudeSession(file, since: since)
    case .codex:
      let root = (providerHome ?? home.appending(path: ".codex")).appending(path: "sessions")
      guard let file = sessionFile(in: root, containing: sessionID) else { return Harvest() }
      return parseCodexRollout(
        file, workingDirectory: workingDirectory, since: since,
        sessionID: sessionID)
    case .openAI, .cursor, .grok, .hermes, .kimi, .openCode, .pi, .shell:
      // Kimi keeps its own history under ~/.kimi-code, but Otto resumes it with `--continue`
      // rather than by id, so there is no session file to attribute turns to yet. OpenCode and
      // Grok do resume by real id, but keep sessions in a database / ACP update log rather than
      // a readable transcript Otto can attribute, so turns come from the live event stream. Pi
      // writes readable JSONL under ~/.pi/agent/sessions, but Otto does not attribute from it yet.
      return Harvest()
    }
  }

  /// Rebuilds the readable conversation for a persisted agent from its exact provider session.
  /// Unlike `harvest`, restoration is not bounded to turns created after the current process
  /// started; it reads the retained tail of the saved session and excludes provider bootstrap,
  /// developer, tool, and reasoning records.
  public static func restore(
    provider: AgentProvider,
    workingDirectory: String,
    sessionID: String,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    providerHome: URL? = nil
  ) -> Harvest {
    guard !sessionID.isEmpty else { return Harvest() }
    switch provider {
    case .claudeCode:
      let file = claudeProjectDirectory(
        workingDirectory: workingDirectory, home: home, providerHome: providerHome
      )
      .appending(path: "\(sessionID).jsonl")
      return parseClaudeSession(file, since: .distantPast)
    case .codex:
      let root = (providerHome ?? home.appending(path: ".codex")).appending(path: "sessions")
      guard let file = sessionFile(in: root, containing: sessionID) else { return Harvest() }
      return parseCodexConversation(
        file,
        workingDirectory: workingDirectory,
        sessionID: sessionID
      )
    case .openAI, .cursor, .grok, .hermes, .kimi, .openCode, .pi, .shell:
      return Harvest()
    }
  }

  // MARK: - Claude Code

  /// Claude Code stores sessions per workspace at ~/.claude/projects/<slug>/<sessionID>.jsonl,
  /// where the slug replaces every non-alphanumeric path character with '-'.
  /// `providerHome` is an account's relocated Claude config directory (`CLAUDE_CONFIG_DIR`).
  static func claudeProjectDirectory(
    workingDirectory: String, home: URL, providerHome: URL? = nil
  ) -> URL {
    let slug = String(
      workingDirectory.map { $0.isLetter || $0.isNumber ? $0 : "-" }
    )
    return (providerHome ?? home.appending(path: ".claude")).appending(path: "projects/\(slug)")
  }

  private static func parseClaudeSession(_ file: URL, since: Date) -> Harvest {
    var turns: [Turn] = []
    for object in jsonLines(of: file) {
      guard let type = object["type"] as? String, type == "user" || type == "assistant",
        object["isMeta"] as? Bool != true,
        timestamp(object["timestamp"]) ?? .distantPast >= since,
        let message = object["message"] as? [String: Any]
      else { continue }
      let text = messageText(message["content"])
      guard !text.isEmpty, !text.hasPrefix("<") else { continue }
      turns.append(Turn(role: type == "user" ? .user : .assistant, text: text))
    }
    return Harvest(
      sessionID: file.deletingPathExtension().lastPathComponent,
      turns: turns
    )
  }

  // MARK: - Codex

  private static func parseCodexRollout(
    _ file: URL, workingDirectory: String, since: Date, sessionID: String
  ) -> Harvest {
    var turns: [Turn] = []
    for object in jsonLines(of: file) {
      let payload = object["payload"] as? [String: Any] ?? [:]
      switch object["type"] as? String {
      case "session_meta":
        guard let cwd = payload["cwd"] as? String,
          URL(fileURLWithPath: cwd).standardizedFileURL.path
            == URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        else {
          // A rollout for some other workspace; skip the whole file.
          return Harvest()
        }
        guard (payload["id"] as? String ?? payload["session_id"] as? String) == sessionID
        else { return Harvest() }
      case "response_item":
        guard payload["type"] as? String == "message",
          let role = payload["role"] as? String, role == "user" || role == "assistant",
          timestamp(object["timestamp"]) ?? .distantPast >= since
        else { continue }
        let text = messageText(payload["content"])
        guard !text.isEmpty, !text.hasPrefix("<") else { continue }
        turns.append(Turn(role: role == "user" ? .user : .assistant, text: text))
      default:
        continue
      }
    }
    return Harvest(sessionID: sessionID, turns: turns)
  }

  /// Prefer clean conversation events where available; current Codex rollouts retain only
  /// response items. Fall back per turn so sessions spanning a provider upgrade keep history
  /// without duplicating messages in versions that write both representations.
  private static func parseCodexConversation(
    _ file: URL,
    workingDirectory: String,
    sessionID: String
  ) -> Harvest {
    var conversation: [Turn] = []
    var turns: [Turn] = []
    var responseTurns: [Turn] = []
    var isHiddenTurn = false
    for object in jsonLines(of: file) {
      let payload = object["payload"] as? [String: Any] ?? [:]
      if object["type"] as? String == "event_msg",
        payload["type"] as? String == "task_started"
      {
        if !isHiddenTurn {
          conversation.append(contentsOf: turns.isEmpty ? responseTurns : turns)
        }
        isHiddenTurn = false
        turns.removeAll(keepingCapacity: true)
        responseTurns.removeAll(keepingCapacity: true)
      }
      if object["type"] as? String == "session_meta",
        let cwd = payload["cwd"] as? String,
        URL(fileURLWithPath: cwd).standardizedFileURL.path
          != URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
      {
        return Harvest()
      }
      // Recent Codex builds persist response items without user_message/agent_message events.
      // Keep these as a fallback, excluding injected environment and bootstrap records.
      if object["type"] as? String == "response_item",
        payload["type"] as? String == "message",
        let role = payload["role"] as? String,
        role == "user" || (role == "assistant" && payload["phase"] as? String == "final_answer")
      {
        let text = messageText(payload["content"])
        if role == "user", PromptSubmission.isHiddenControlPrompt(text) { isHiddenTurn = true }
        if !text.isEmpty, !text.hasPrefix("<"),
          !text.hasPrefix("# Otto agent bootstrap"), !text.hasPrefix("# Muse agent bootstrap"),
          !PromptSubmission.isHiddenControlPrompt(text)
        {
          responseTurns.append(
            Turn(
              role: role == "user" ? .user : .assistant,
              text: role == "user" ? PromptSubmission.originalUserText(text) : text))
        }
      }
      guard object["type"] as? String == "event_msg", let type = payload["type"] as? String
      else { continue }
      switch type {
      case "user_message":
        guard let text = payload["message"] as? String else { continue }
        if PromptSubmission.isHiddenControlPrompt(text) { isHiddenTurn = true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("# Otto agent bootstrap"),
          !trimmed.hasPrefix("# Muse agent bootstrap")
        else { continue }
        turns.append(Turn(role: .user, text: trimmed))
      case "agent_message":
        guard payload["phase"] as? String == "final_answer",
          let text = payload["message"] as? String
        else { continue }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { turns.append(Turn(role: .assistant, text: trimmed)) }
      default:
        continue
      }
    }
    if !isHiddenTurn {
      conversation.append(contentsOf: turns.isEmpty ? responseTurns : turns)
    }
    return Harvest(sessionID: sessionID, turns: conversation)
  }

  // MARK: - Shared parsing

  /// Message content is either a plain string or an array of typed blocks; only prose blocks
  /// count — tool calls, tool results, and thinking stay out of the conversation projection.
  private static func messageText(_ content: Any?) -> String {
    if let text = content as? String {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let blocks = content as? [[String: Any]] else { return "" }
    let texts = blocks.compactMap { block -> String? in
      guard let type = block["type"] as? String,
        ["text", "input_text", "output_text"].contains(type),
        let text = block["text"] as? String
      else { return nil }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    return texts.joined(separator: "\n\n")
  }

  private static func jsonLines(of file: URL) -> [[String: Any]] {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let start = size > UInt64(tailByteLimit) ? size - UInt64(tailByteLimit) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return [] }
    var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    // A tail read can start mid-line; the fragment is never valid JSON, drop it.
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return lines.compactMap { line in
      guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
  }

  private static func sessionFile(in root: URL, containing sessionID: String) -> URL? {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return nil }
    for case let file as URL in enumerator where file.pathExtension == "jsonl" {
      if file.lastPathComponent.hasSuffix("-\(sessionID).jsonl") { return file }
    }
    return nil
  }

  private static func timestamp(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    // ISO8601DateFormatter is not Sendable, so build per call; harvest volume is tiny.
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) { return date }
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    return whole.date(from: string)
  }

}
