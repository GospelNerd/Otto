import Foundation

/// Something an agent made that waits on Home for the person to approve, comment on or reject
/// before anything else happens, e.g. a drafted tip that is only posted once approved.
public struct HomeReview: Codable, Identifiable, Sendable, Equatable {
  public enum State: String, Codable, Sendable, Equatable {
    case pending
    /// The person commented and the agent is working on a reply.
    case revising
    case approved
    case rejected
  }

  /// How the "when I approve, do this" action is going once the person approves.
  public enum ActionStatus: String, Codable, Sendable, Equatable {
    case running
    case done
    case failed
    /// The person denied what the agent needed, so the action wasn't done.
    case declined
    /// Otto quit before it finished, so nobody knows whether it happened.
    case interrupted
  }

  public struct Note: Codable, Identifiable, Sendable, Equatable {
    public enum Author: String, Codable, Sendable, Equatable {
      case person
      case agent
    }
    public var id: UUID
    public var author: Author
    public var text: String
    public var at: Date

    public init(id: UUID = UUID(), author: Author, text: String, at: Date = .now) {
      self.id = id
      self.author = author
      self.text = text
      self.at = at
    }
  }

  public var id: UUID
  public var title: String
  /// Who asked: the automation's or agent's name.
  public var requester: String
  /// The text being reviewed. Approving can hand on an edited version.
  public var draft: String
  /// What happens once approved, in plain words, e.g. "Post it in #tips on Discord".
  public var afterApproval: String?
  public var state: State
  public var notes: [Note]
  /// The session that made the draft. Comments and the approved action go back to it.
  public var agentNodeID: UUID?
  /// Set when an automation run made the draft; approving continues its flow.
  public var routineID: UUID?
  public var runID: UUID?
  public var chainDepth: Int
  public var createdAt: Date
  public var updatedAt: Date
  public var decidedAt: Date?
  /// Why the last comment or approval couldn't reach the agent, shown on the card.
  public var problem: String?
  // The approved action's progress. All optional so older Otto versions still read the file.
  public var actionStatus: ActionStatus?
  /// What the agent is asking permission for while doing the action, e.g. a shell command.
  public var actionPermission: String?
  /// The agent's one-line report once the action finished.
  public var actionResult: String?
  /// The person's last answer to the action's permission prompt was Deny.
  public var actionDenied: Bool?
  /// The person cleared the finished card from Home.
  public var actionDismissed: Bool?

  public init(
    id: UUID = UUID(), title: String, requester: String, draft: String,
    afterApproval: String? = nil, state: State = .pending, notes: [Note] = [],
    agentNodeID: UUID? = nil, routineID: UUID? = nil, runID: UUID? = nil, chainDepth: Int = 0,
    createdAt: Date = .now, updatedAt: Date = .now, decidedAt: Date? = nil, problem: String? = nil
  ) {
    self.id = id
    self.title = title
    self.requester = requester
    self.draft = draft
    self.afterApproval = afterApproval
    self.state = state
    self.notes = notes
    self.agentNodeID = agentNodeID
    self.routineID = routineID
    self.runID = runID
    self.chainDepth = chainDepth
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.decidedAt = decidedAt
    self.problem = problem
  }

  public var isOpen: Bool { state == .pending || state == .revising }
  /// Approved, and its action is still on Home: running, waiting for permission, or finished
  /// but not yet dismissed.
  public var isActing: Bool {
    state == .approved && actionStatus != nil && actionDismissed != true
  }
  /// Waiting on the person: a decision, or permission for the approved action.
  public var needsPerson: Bool { isOpen || (isActing && actionPermission != nil) }
}
