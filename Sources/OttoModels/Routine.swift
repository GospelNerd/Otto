import Foundation

public struct Routine: Codable, Identifiable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var id: UUID
  public var name: String
  public var instruction: String
  public var trigger: RoutineTrigger
  public var target: RoutineTarget
  public var enabled: Bool
  public var concurrency: ConcurrencyPolicy
  public var permissionMode: String?
  public var toolAllowlist: [String]?
  public var delivery: RoutineDelivery
  public var quietWhenUnchanged: Bool
  /// Schedule calculations remain anchored even if the Mac's current timezone later changes.
  public var timeZoneIdentifier: String
  public var revision: Int
  public var createdAt: Date
  public var updatedAt: Date
  public var lastFiredAt: Date?
  public var fireCount: Int
  public var lastError: String?
  public var suspendedByProfileArchive: Bool?
  /// The AI account a fresh agent runs on. Nil uses the bot's account or the default.
  public var accountID: UUID?
  /// Set when this automation is a later step in a flow: it runs when another automation
  /// finishes, instead of on its own trigger. Stored as an optional field (not a new trigger
  /// case) so older Otto versions can still decode the file and simply leave the step idle.
  public var runAfter: RoutineChainLink?
  /// The model a fresh agent uses. Nil keeps the harness's (or bot's) default.
  public var model: String?
  /// True when the automation was built in the advanced canvas, so lists can label it.
  public var advanced: Bool? = nil
  /// When true, each answer waits on Home for the person to approve, comment on or reject,
  /// and nothing after it (the next steps, `afterApproval`) runs until they approve.
  public var reviewOnHome: Bool? = nil
  /// What the agent does once the person approves its answer, e.g. "Post it in #tips".
  public var afterApproval: String? = nil

  public init(
    id: UUID = UUID(), name: String, instruction: String, trigger: RoutineTrigger,
    target: RoutineTarget, enabled: Bool = false, concurrency: ConcurrencyPolicy = .skip,
    permissionMode: String? = nil, toolAllowlist: [String]? = nil,
    delivery: RoutineDelivery = .canvas, quietWhenUnchanged: Bool = false,
    timeZoneIdentifier: String = TimeZone.current.identifier, revision: Int = 1,
    createdAt: Date = .now, updatedAt: Date = .now, lastFiredAt: Date? = nil,
    fireCount: Int = 0, lastError: String? = nil,
    suspendedByProfileArchive: Bool? = nil, accountID: UUID? = nil,
    runAfter: RoutineChainLink? = nil, model: String? = nil, reviewOnHome: Bool? = nil,
    afterApproval: String? = nil
  ) {
    self.id = id
    self.name = name
    self.instruction = instruction
    self.trigger = trigger
    self.target = target
    self.enabled = enabled
    self.concurrency = concurrency
    self.permissionMode = permissionMode
    self.toolAllowlist = toolAllowlist
    self.delivery = delivery
    self.quietWhenUnchanged = quietWhenUnchanged
    self.timeZoneIdentifier = timeZoneIdentifier
    self.revision = revision
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastFiredAt = lastFiredAt
    self.fireCount = fireCount
    self.lastError = lastError
    self.suspendedByProfileArchive = suspendedByProfileArchive
    self.accountID = accountID
    self.runAfter = runAfter
    self.model = model
    self.reviewOnHome = reviewOnHome
    self.afterApproval = afterApproval
  }

  /// The trigger every chained step stores. No event bus event has this type, so the step
  /// never fires on its own, including in Otto versions that predate `runAfter`.
  public static let chainedTrigger = RoutineTrigger.agentEvent(
    types: [RoutineChainLink.inertEventType], nodeID: nil)

  /// Makes this automation run after `parent` instead of on its own trigger.
  public mutating func chain(after parentID: UUID, when condition: RoutineChainCondition) {
    runAfter = RoutineChainLink(routineID: parentID, when: condition)
    trigger = Self.chainedTrigger
  }

  public var needsReview: Bool { reviewOnHome == true }

  public var triggerSummary: String {
    runAfter.map { "after the previous automation \($0.when.rawValue)" }
      ?? trigger.summary
  }
}

/// "Run this automation after that one finishes". The finished run's answer becomes the
/// follower's payload, which is passed to the agent as untrusted data.
public struct RoutineChainLink: Codable, Sendable, Equatable, Hashable {
  public static let inertEventType = "routine.chain"
  /// Flows deeper than this stop, so a mistake can never run agents forever.
  public static let maximumDepth = 16

  public var routineID: UUID
  public var when: RoutineChainCondition

  public init(routineID: UUID, when: RoutineChainCondition = .succeeded) {
    self.routineID = routineID
    self.when = when
  }
}

public enum RoutineChainCondition: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
  case succeeded
  case failed
  case finished

  public func matches(_ outcome: RoutineRunOutcome) -> Bool {
    switch self {
    case .succeeded: outcome == .completed
    case .failed: outcome == .failed
    case .finished: outcome == .completed || outcome == .failed || outcome == .noChange
    }
  }
}

public enum RoutineTrigger: Codable, Sendable, Equatable {
  case schedule(cron: String?, intervalSeconds: Int?)
  case webhook(slug: String, filter: PayloadFilter?)
  case agentEvent(types: [String], nodeID: UUID?)
  case slackMessage(channel: String, match: MessageMatch?)
  case discordMessage(channelID: String, match: MessageMatch?)
  case gitEvent(repoPath: String, kinds: [GitEventKind])
}

public enum RoutineTarget: Codable, Sendable, Equatable {
  case existingAgent(nodeID: UUID)
  case spawnProfile(profileID: UUID)
  case spawnProvider(provider: String)
}

public enum RoutineDelivery: Codable, Sendable, Equatable {
  case canvas
  case origin
  case document(relativePath: String)
  case botChannel(profileID: UUID)
  /// Results become items in the Home brief, scoped to a Home profile when one is given.
  case brief(profileID: UUID?)
  /// Results replace the content of a card on Home.
  case homeCard(cardID: UUID)
}

public enum ConcurrencyPolicy: String, Codable, CaseIterable, Sendable, Equatable {
  case skip
  case queueLatest
}

public enum PayloadFilter: Codable, Sendable, Equatable {
  case keyword(String)
  case regex(String)
  case jsonPathEquals(path: String, value: String)
}

public enum MessageMatch: Codable, Sendable, Equatable {
  case keyword(String)
  case regex(String)
}

public enum GitEventKind: String, Codable, CaseIterable, Sendable, Equatable {
  case commit
  case branch
  case tag
}

public enum RoutineRunOutcome: String, Codable, Sendable, Equatable {
  case running
  case completed
  case failed
  case skipped
  case noChange = "no_change"
}

public struct RoutineRunRecord: Codable, Identifiable, Sendable, Equatable {
  public var id: UUID { runID }
  public var runID: UUID
  public var routineID: UUID
  public var triggerSummary: String
  public var payloadDigest: String?
  public var firedAt: Date
  public var agentNodeID: UUID?
  public var outcome: RoutineRunOutcome
  public var durationMs: Double?
  public var error: String?
  public var collapsedMissedRuns: Bool
  /// The agent's answer (trimmed), so a run's output can be read without opening its session.
  public var result: String?
  /// Set on an automatic retry: the failed run it repeats. Absent in older history.
  public var retryOfRunID: UUID?

  public init(
    runID: UUID = UUID(), routineID: UUID, triggerSummary: String,
    payloadDigest: String? = nil, firedAt: Date = .now, agentNodeID: UUID? = nil,
    outcome: RoutineRunOutcome, durationMs: Double? = nil, error: String? = nil,
    collapsedMissedRuns: Bool = false, result: String? = nil, retryOfRunID: UUID? = nil
  ) {
    self.runID = runID
    self.routineID = routineID
    self.triggerSummary = triggerSummary
    self.payloadDigest = payloadDigest
    self.firedAt = firedAt
    self.agentNodeID = agentNodeID
    self.outcome = outcome
    self.durationMs = durationMs
    self.error = error
    self.collapsedMissedRuns = collapsedMissedRuns
    self.result = result
    self.retryOfRunID = retryOfRunID
  }
}

extension RoutineTrigger {
  public var summary: String {
    switch self {
    case .schedule(let cron, let interval):
      if let cron { return "schedule \(cron)" }
      return "every \(interval ?? 60)s"
    case .webhook(let slug, _): return "webhook /hooks/\(slug)"
    case .agentEvent(let types, _): return "agent event \(types.joined(separator: ", "))"
    case .slackMessage(let channel, _): return "Slack #\(channel)"
    case .discordMessage(let channelID, _): return "Discord \(channelID)"
    case .gitEvent(let path, let kinds):
      return "git \(path) [\(kinds.map(\.rawValue).joined(separator: ", "))]"
    }
  }
}
