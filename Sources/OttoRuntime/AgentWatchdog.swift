import Foundation

/// Thresholds for `AgentWatchdog`, kept together so they are tuned in one place.
public struct AgentWatchdogConfiguration: Sendable, Equatable {
  /// A working agent with no new transcript entries, output or child activity for this long is
  /// reported as stalled.
  public var stallAfter: TimeInterval
  /// How many identical tool calls in a row (same name and arguments, with no reply in between)
  /// count as a loop.
  public var loopRepeatThreshold: Int
  /// An agent waiting on the person for longer than this gets one reminder. It must stay under
  /// 30 min: Claude Code gives up on an unanswered Otto permission request or question after
  /// 1800 s, so a later reminder would point at a request that is already gone.
  public var waitingReminderAfter: TimeInterval
  /// The same finding for the same run is reported again only after this long.
  public var reReportAfter: TimeInterval
  /// How often the app runs the evaluator.
  public var evaluationInterval: TimeInterval

  public init(
    stallAfter: TimeInterval = 15 * 60,
    loopRepeatThreshold: Int = 6,
    waitingReminderAfter: TimeInterval = 20 * 60,
    reReportAfter: TimeInterval = 2 * 60 * 60,
    evaluationInterval: TimeInterval = 60
  ) {
    self.stallAfter = stallAfter
    self.loopRepeatThreshold = max(2, loopRepeatThreshold)
    self.waitingReminderAfter = waitingReminderAfter
    self.reReportAfter = reReportAfter
    self.evaluationInterval = evaluationInterval
  }

  public static let standard = AgentWatchdogConfiguration()
}

public enum AgentWatchdogFindingKind: String, Sendable, Equatable, Codable {
  /// Working, but nothing has changed for a long time.
  case stalled
  /// Calling the same tool with the same arguments over and over.
  case looping
  /// Waiting on the person (permission or a question) for a long time.
  case waitingOnPerson
}

public struct AgentWatchdogFinding: Identifiable, Sendable, Equatable {
  public var id: UUID { agentID }
  public var agentID: UUID
  public var runID: UUID?
  public var kind: AgentWatchdogFindingKind
  /// When the condition began: last progress, the first repeated call, or the start of a wait.
  public var since: Date
  public var detectedAt: Date
  /// The repeated tool's name, for loops.
  public var toolName: String?
  public var repeatCount: Int?

  public init(
    agentID: UUID, runID: UUID?, kind: AgentWatchdogFindingKind, since: Date, detectedAt: Date,
    toolName: String? = nil, repeatCount: Int? = nil
  ) {
    self.agentID = agentID
    self.runID = runID
    self.kind = kind
    self.since = since
    self.detectedAt = detectedAt
    self.toolName = toolName
    self.repeatCount = repeatCount
  }

  /// A short line for Home, e.g. "No progress for 18 min".
  public var reason: String {
    let duration = Self.durationText(detectedAt.timeIntervalSince(since))
    switch kind {
    case .stalled: return "No progress for \(duration)"
    case .looping:
      let tool = toolName.map { " (\($0)" + (repeatCount.map { " ×\($0))" } ?? ")") } ?? ""
      return "Repeating the same tool call\(tool)"
    case .waitingOnPerson: return "Waiting for you for \(duration)"
    }
  }

  public static func durationText(_ interval: TimeInterval) -> String {
    let minutes = max(1, Int(interval / 60))
    guard minutes >= 60 else { return "\(minutes) min" }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
  }
}

/// What one evaluation found.
public struct AgentWatchdogReport: Sendable, Equatable {
  /// Every condition that holds right now, one per agent. Surfaces show these while they last.
  public var findings: [AgentWatchdogFinding]
  /// The subset worth an alert this time: new, of a new kind, or persisting long enough to repeat.
  public var newlyReported: [AgentWatchdogFinding]

  public init(findings: [AgentWatchdogFinding] = [], newlyReported: [AgentWatchdogFinding] = []) {
    self.findings = findings
    self.newlyReported = newlyReported
  }
}

/// A cheap, deterministic check for agents that look stuck. It never stops or restarts anything;
/// it only reports. Call `evaluate` periodically with fresh snapshots and the current time. It
/// remembers when each agent last made visible progress, so the first sighting of an agent never
/// reports a stall: it must be observed unchanged for the whole stall window.
public struct AgentWatchdog: Sendable {
  public var configuration: AgentWatchdogConfiguration

  private struct Observation: Sendable {
    var runID: UUID?
    var fingerprint: Fingerprint
    var lastProgressAt: Date
    var state: AgentLifecycleState
    var stateSince: Date
  }

  private struct Fingerprint: Sendable, Equatable {
    var transcriptCount: Int
    var lastEntryID: UUID?
    var outputEndOffset: Int
    var childActivity: [String]
  }

  private struct ReportKey: Hashable, Sendable {
    var agentID: UUID
    var runID: UUID?
    var kind: AgentWatchdogFindingKind
  }

  private var observations: [UUID: Observation] = [:]
  private var reportedAt: [ReportKey: Date] = [:]

  public init(configuration: AgentWatchdogConfiguration = .standard) {
    self.configuration = configuration
  }

  /// True when no agent is being tracked, so callers can skip work entirely.
  public var isIdle: Bool { observations.isEmpty }

  public mutating func evaluate(_ snapshots: [AgentRuntimeSnapshot], now: Date)
    -> AgentWatchdogReport
  {
    var report = AgentWatchdogReport()
    var seen = Set<UUID>()
    for snapshot in snapshots.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
      // User shells run whatever the person started, for as long as they like.
      guard snapshot.executionMode != .terminal, Self.isLive(snapshot.state) else { continue }
      seen.insert(snapshot.id)
      let observation = observe(snapshot, now: now)
      guard let finding = finding(for: snapshot, observation: observation, now: now) else {
        continue
      }
      report.findings.append(finding)
      let key = ReportKey(agentID: finding.agentID, runID: finding.runID, kind: finding.kind)
      if let last = reportedAt[key], now.timeIntervalSince(last) < configuration.reReportAfter {
        continue
      }
      reportedAt[key] = now
      report.newlyReported.append(finding)
    }
    observations = observations.filter { seen.contains($0.key) }
    reportedAt = reportedAt.filter { key, _ in
      guard let observation = observations[key.agentID] else { return false }
      return observation.runID == key.runID
    }
    return report
  }

  private static func isLive(_ state: AgentLifecycleState) -> Bool {
    switch state {
    case .starting, .working, .waitingPermission, .waitingUser: true
    case .created, .idle, .done, .failed, .interrupted, .stopped: false
    }
  }

  private mutating func observe(_ snapshot: AgentRuntimeSnapshot, now: Date) -> Observation {
    let fingerprint = Fingerprint(
      transcriptCount: snapshot.transcript.count,
      lastEntryID: snapshot.transcript.last?.id,
      // A one-shot provider's raw stream carries keep-alive events (Claude Code sends a
      // tool_progress heartbeat every 30 s while a command runs), so only its transcript counts
      // as progress. Interactive sessions have no structured transcript to go on.
      outputEndOffset: snapshot.executionMode == .oneShotProvider ? 0 : snapshot.outputEndOffset,
      childActivity: snapshot.childRuns.map { "\($0.id)|\($0.state.rawValue)|\($0.toolCount)" })
    guard var observation = observations[snapshot.id], observation.runID == snapshot.runID else {
      let fresh = Observation(
        runID: snapshot.runID, fingerprint: fingerprint, lastProgressAt: now,
        state: snapshot.state, stateSince: now)
      observations[snapshot.id] = fresh
      return fresh
    }
    if observation.fingerprint != fingerprint {
      observation.fingerprint = fingerprint
      observation.lastProgressAt = now
    }
    if observation.state != snapshot.state {
      observation.state = snapshot.state
      observation.stateSince = now
      observation.lastProgressAt = now
    }
    observations[snapshot.id] = observation
    return observation
  }

  private func finding(
    for snapshot: AgentRuntimeSnapshot, observation: Observation, now: Date
  ) -> AgentWatchdogFinding? {
    switch snapshot.state {
    case .waitingPermission, .waitingUser:
      guard now.timeIntervalSince(observation.stateSince) >= configuration.waitingReminderAfter
      else { return nil }
      return AgentWatchdogFinding(
        agentID: snapshot.id, runID: snapshot.runID, kind: .waitingOnPerson,
        since: observation.stateSince, detectedAt: now)
    case .working:
      if let loop = Self.repeatedCall(
        in: snapshot.transcript, threshold: configuration.loopRepeatThreshold)
      {
        return AgentWatchdogFinding(
          agentID: snapshot.id, runID: snapshot.runID, kind: .looping, since: loop.since,
          detectedAt: now, toolName: loop.toolName, repeatCount: loop.count)
      }
      guard now.timeIntervalSince(observation.lastProgressAt) >= configuration.stallAfter,
        !snapshot.childRuns.contains(where: { $0.state.isActive }),
        !Self.isParkedInWait(snapshot.transcript)
      else { return nil }
      return AgentWatchdogFinding(
        agentID: snapshot.id, runID: snapshot.runID, kind: .stalled,
        since: observation.lastProgressAt, detectedAt: now)
    default:
      return nil
    }
  }

  /// The agent's latest step is a deliberate wait (event.wait, terminal.wait, a status poll),
  /// so silence means it is waiting for something, not stuck.
  static func isParkedInWait(_ transcript: [AgentTranscriptEntry]) -> Bool {
    guard let last = transcript.last, last.kind == .toolCall else { return false }
    return isPollingTool(last.detail ?? last.text)
  }

  /// Tools whose repeated, identical calls are normal: waiting and polling for status.
  static func isPollingTool(_ name: String) -> Bool {
    let normalized = name.lowercased().replacingOccurrences(of: "_", with: ".")
    return ["wait", "status", "read.output", "get.output", "sleep"].contains {
      normalized.contains($0)
    }
  }

  struct RepeatedCall: Equatable {
    var toolName: String
    var count: Int
    var since: Date
  }

  /// The trailing run of identical tool calls in the current turn, when it reaches `threshold`.
  /// Reasoning and notices between the calls are ignored; a user message or an assistant reply
  /// ends the run, because those are progress.
  static func repeatedCall(in transcript: [AgentTranscriptEntry], threshold: Int)
    -> RepeatedCall?
  {
    var key: (name: String, arguments: String)?
    var count = 0
    var since: Date?
    for entry in transcript.reversed() {
      if entry.role == .user { break }
      if entry.kind == .text { break }
      guard entry.kind == .toolCall else { continue }
      let name = entry.detail ?? entry.text
      let current = (name: name, arguments: entry.text)
      if let key {
        guard key == current else { break }
      } else {
        guard !isPollingTool(name) else { return nil }
        key = current
      }
      count += 1
      since = entry.createdAt
    }
    guard let key, let since, count >= threshold else { return nil }
    return RepeatedCall(toolName: key.name, count: count, since: since)
  }
}
