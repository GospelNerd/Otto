import Foundation
import OttoModels
import OttoRuntime
import OttoTools

// MARK: Approve, comment or reject on Home
//
// An automation set to "check with me first", or any agent through home.request_approval, puts
// its draft on Home. Nothing after it happens until the person approves: Comment goes back to
// the agent that wrote it (it revises or answers), Approve hands on the approved text (the
// automation's next steps and its "after I approve" action), Reject ends it.

extension ApplicationServices {
  /// How long a comment waits for the agent's reply before giving up.
  static let reviewReplyTimeout: Duration = .seconds(15 * 60)
  /// An approved action can wait on the person's permission, so it gets much longer.
  static let reviewActionTimeout: Duration = .seconds(24 * 3600)

  /// The engine's review handler: a finished automation answer waits on Home.
  func holdRoutineResultForReview(
    _ routine: Routine, runID: UUID, nodeID: UUID, result: String, depth: Int
  ) throws {
    guard routineEngine.holdsForApproval(routine) else {
      try postRoutineResultAsUpdate(routine, nodeID: nodeID, result: result)
      return
    }
    try homeReviews.add(
      HomeReview(
        title: routine.name, requester: routine.name, draft: result,
        afterApproval: routine.afterApproval?.trimmingCharacters(in: .whitespacesAndNewlines)
          .nilIfEmpty,
        agentNodeID: nodeID, routineID: routine.id, runID: runID, chainDepth: depth))
  }

  /// "Check with me first" with nothing set to run after approval: there is nothing to decide,
  /// so the answer goes to the brief as an update that opens the run's full report.
  func postRoutineResultAsUpdate(_ routine: Routine, nodeID: UUID, result: String) throws {
    // The automation already delivers to the brief or a card; don't post it twice.
    guard case .canvas = routine.delivery else { return }
    var items = BriefOutputParser.parse(
      result, origin: .routine(routine.id), profileID: dailyBrief.selectedProfile.id,
      sourceName: routine.name)
    guard !items.isEmpty else { return }
    for index in items.indices where items[index].action == nil {
      items[index].action = .openAgent(nodeID)
    }
    try dailyBrief.replace(origin: .routine(routine.id), with: items)
  }

  /// Approves a review, optionally with the person's edits, and starts whatever waits on it.
  public func approveReview(id: UUID, editedDraft: String? = nil) async throws {
    guard let current = homeReviews.review(id: id) else {
      throw HomeReviewStore.ReviewError.unknown
    }
    guard current.isOpen else { throw HomeReviewStore.ReviewError.alreadyDecided }
    guard current.state != .revising else { throw HomeReviewStore.ReviewError.busy }
    let edited = editedDraft?.trimmingCharacters(in: .whitespacesAndNewlines)
    let approvedText = edited?.nilIfEmpty ?? current.draft
    let wasEdited = approvedText != current.draft
    let review = try homeReviews.update(id: id) { review in
      review.draft = approvedText
      review.state = .approved
      review.decidedAt = .now
      review.problem = nil
    }
    if let routineID = review.routineID {
      await routineEngine.continueAfterApproval(
        routineID: routineID, approvedText: approvedText, depth: review.chainDepth)
    }
    guard let action = review.afterApproval else { return }
    let prompt = """
      The person approved your draft on their Otto Home page\(wasEdited ? " after editing it" : ""). \
      Approved text:
      <<<approved>>>
      \(approvedText)
      <<<end>>>
      Now do this with exactly the approved text: \(action)
      Reply with one short line saying what you did.
      """
    try homeReviews.update(id: id) {
      $0.actionStatus = .running
      $0.actionPermission = nil
      $0.actionResult = nil
      $0.actionDenied = nil
    }
    // The card stays on Home while the agent works, so its permission prompts and result show
    // there instead of only in Chat.
    reviewActionTasks[id] = Task { [weak self] in
      await self?.runApprovedAction(reviewID: id, prompt: prompt)
    }
  }

  /// Sends the approved action to the agent and keeps the card up to date until it finishes.
  func runApprovedAction(reviewID id: UUID, prompt: String) async {
    defer { reviewActionTasks[id] = nil }
    guard let review = homeReviews.review(id: id) else { return }
    do {
      let answer = try await promptReviewAgent(
        review, prompt: prompt, awaitAnswer: true, timeout: Self.reviewActionTimeout,
        onStatusChange: { [weak self] nodeID in
          guard let self else { return }
          let pending = await self.supervisor.pendingPermission(agentID: nodeID)
          _ = try? self.homeReviews.update(id: id) { $0.actionPermission = pending?.reason }
        })
      _ = try? homeReviews.update(id: id) { review in
        // The agent's turn ends normally after a Deny too; it just couldn't do the action.
        review.actionStatus = review.actionDenied == true ? .declined : .done
        review.actionPermission = nil
        review.actionResult =
          answer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map {
            String($0.prefix(600))
          } ?? "Done."
      }
    } catch {
      _ = try? homeReviews.update(id: id) { review in
        review.actionStatus = .failed
        review.actionPermission = nil
        review.problem = "Approved, but the action didn’t finish: \(error.localizedDescription)"
      }
    }
  }

  /// Allow or Deny on the card: answers the permission prompt the approved action is stuck on.
  public func answerReviewPermission(id: UUID, allow: Bool) async {
    guard let nodeID = homeReviews.review(id: id)?.agentNodeID else { return }
    if let override = reviewPermissionOverride {
      override(nodeID, allow)
    } else {
      await resolveAgentPermission(agentID: nodeID, approved: allow)
    }
    _ = try? homeReviews.update(id: id) {
      $0.actionPermission = nil
      $0.actionDenied = allow ? nil : true
    }
  }

  /// Clears a finished action's card from Home.
  public func dismissReview(id: UUID) {
    _ = try? homeReviews.update(id: id) { $0.actionDismissed = true }
  }

  public func rejectReview(id: UUID, reason: String? = nil) throws {
    guard let current = homeReviews.review(id: id) else {
      throw HomeReviewStore.ReviewError.unknown
    }
    guard current.isOpen else { throw HomeReviewStore.ReviewError.alreadyDecided }
    try homeReviews.update(id: id) { review in
      review.state = .rejected
      review.decidedAt = .now
      if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        review.notes.append(HomeReview.Note(author: .person, text: reason))
      }
    }
  }

  /// Sends the person's comment to the agent that wrote the draft. It either revises the draft
  /// or answers in the thread; the review stays open either way.
  public func commentOnReview(id: UUID, text: String) async throws {
    let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !comment.isEmpty else { return }
    guard let current = homeReviews.review(id: id) else {
      throw HomeReviewStore.ReviewError.unknown
    }
    guard current.isOpen else { throw HomeReviewStore.ReviewError.alreadyDecided }
    guard current.state != .revising else { throw HomeReviewStore.ReviewError.busy }
    let review = try homeReviews.update(id: id) { review in
      review.notes.append(HomeReview.Note(author: .person, text: comment))
      review.state = .revising
      review.problem = nil
    }
    let prompt = """
      The person commented on your draft on their Otto Home page:
      <<<comment>>>
      \(comment)
      <<<end>>>
      The draft as it stands:
      <<<draft>>>
      \(review.draft)
      <<<end>>>
      If they want changes, reply with only the full revised draft, ready to use as written. \
      If they asked a question or want to talk it over, reply starting with "NOTE:" followed by \
      your answer, and the draft stays as it is. Do not post, send or publish anything.
      """
    do {
      let answer = try await promptReviewAgent(review, prompt: prompt, awaitAnswer: true)
      try homeReviews.update(id: id) { review in
        review.state = .pending
        guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
          review.problem = "The agent finished without replying."
          return
        }
        if let note = Self.reviewNote(in: answer) {
          review.notes.append(HomeReview.Note(author: .agent, text: note))
        } else {
          review.draft = String(answer.prefix(HomeReviewStore.maximumDraftCharacters))
          review.notes.append(HomeReview.Note(author: .agent, text: "Updated the draft."))
        }
      }
    } catch {
      _ = try? homeReviews.update(id: id) { review in
        review.state = .pending
        review.problem = "Your comment didn’t reach the agent: \(error.localizedDescription)"
      }
      throw error
    }
  }

  /// An answer starting with "NOTE:" is a reply in the thread, not a new draft.
  nonisolated static func reviewNote(in answer: String) -> String? {
    guard answer.uppercased().hasPrefix("NOTE:") else { return nil }
    return String(answer.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Prompts the session that wrote the draft, or, when that session has closed, runs the
  /// automation again with the same prompt. Returns the agent's answer when asked to wait.
  private func promptReviewAgent(
    _ review: HomeReview, prompt: String, awaitAnswer: Bool,
    timeout: Duration = reviewReplyTimeout,
    onStatusChange: (@MainActor @Sendable (UUID) async -> Void)? = nil
  ) async throws -> String? {
    if let override = reviewAgentOverride, let node = review.agentNodeID {
      let answer = try await override(node, prompt)
      await onStatusChange?(node)
      return awaitAnswer ? answer : nil
    }
    let bus = supervisor.eventBus
    let cursor = bus.latestSequence
    let nodeID: UUID
    if let existing = review.agentNodeID, (try? await supervisor.snapshot(agentID: existing)) != nil
    {
      try await sendPrompt(agentID: existing, prompt: prompt)
      nodeID = existing
    } else if let routineID = review.routineID, let routine = routines.routine(id: routineID) {
      nodeID = try await executeRoutine(routine, prompt: prompt)
      _ = try? homeReviews.update(id: review.id) { $0.agentNodeID = nodeID }
    } else {
      throw ToolRegistryError.invalidInput(
        "The session that wrote this draft has closed. Ask the agent again from Chat.")
    }
    guard awaitAnswer else { return nil }
    return try await withThrowingTaskGroup(of: String?.self) { group in
      group.addTask { [supervisor] in
        for await event in bus.stream(afterSequence: cursor) where event.nodeID == nodeID {
          if event.type == .agentStatusChanged { await onStatusChange?(nodeID) }
          if event.type == .agentRunCompleted {
            return try? await supervisor.snapshot(agentID: nodeID).result
          }
          if event.type == .agentRunFailed {
            throw ToolRegistryError.invalidInput("The agent's run failed.")
          }
        }
        return nil
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw ToolRegistryError.invalidInput("The agent didn’t reply in time.")
      }
      let answer = try await group.next() ?? nil
      group.cancelAll()
      return answer
    }
  }

  // MARK: Tools

  func registerHomeReviewTools() async throws {
    try await registry.register(
      HomeRequestApprovalTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.requestApproval(input, context: context)
      })
    try await registry.register(
      HomeListApprovalsTool { [weak self] in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return await self.listApprovals()
      })
  }

  @MainActor
  private func requestApproval(_ input: HomeApprovalRequestInput, context: ToolContext) throws
    -> HomeApprovalOutput
  {
    let action = input.afterApproval?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    if action != nil, context.sourceNodeID == nil {
      throw ToolRegistryError.invalidInput(
        "afterApproval needs a calling agent session to hand the approved text back to.")
    }
    let requester =
      context.sourceNodeID.flatMap { id in
        store.snapshot.canvases.lazy.flatMap(\.nodes).first { $0.id == id }?.displayName
      } ?? "An agent"
    let review = try homeReviews.add(
      HomeReview(
        title: input.title, requester: requester, draft: input.draft, afterApproval: action,
        agentNodeID: context.sourceNodeID))
    return HomeApprovalOutput(
      reviews: [Self.approvalSummary(review)],
      note: action == nil
        ? "It's on the person's Home page. Check home.list_approvals for their decision."
        : "It's on the person's Home page. When they approve, Otto sends you the approved text "
          + "and you do: \(action ?? ""). Comments come back to you as a new message; reply "
          + "with a revised draft or start with NOTE: to answer. Don't do it before then.")
  }

  @MainActor
  private func listApprovals() -> HomeApprovalOutput {
    HomeApprovalOutput(
      reviews: homeReviews.all.suffix(30).reversed().map(Self.approvalSummary), note: "")
  }

  nonisolated static func approvalSummary(_ review: HomeReview) -> HomeApprovalSummary {
    HomeApprovalSummary(
      id: review.id, title: review.title, state: review.state.rawValue,
      draft: String(review.draft.prefix(600)), afterApproval: review.afterApproval,
      comments: review.notes.map { "\($0.author == .person ? "Person" : "Agent"): \($0.text)" },
      createdAt: review.createdAt)
  }
}

public struct HomeApprovalRequestInput: Codable, Sendable {
  public var title: String
  public var draft: String
  public var afterApproval: String?
  public init(title: String, draft: String, afterApproval: String? = nil) {
    self.title = title
    self.draft = draft
    self.afterApproval = afterApproval
  }
}

public struct HomeApprovalSummary: Codable, Sendable, Equatable {
  public var id: UUID
  public var title: String
  public var state: String
  public var draft: String
  public var afterApproval: String?
  public var comments: [String]
  public var createdAt: Date
}

public struct HomeApprovalOutput: Codable, Sendable, Equatable {
  public var reviews: [HomeApprovalSummary]
  public var note: String
}

public struct HomeRequestApprovalTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "home.request_approval",
    description: """
      Puts a draft on the user's Otto Home page for them to approve, comment on or reject, \
      e.g. a post, reply or tip you should only publish once they say yes. Use it instead of \
      asking in chat when the user said to check with them first or isn't watching. draft is \
      the exact text to review. afterApproval says what you will do once approved, e.g. \
      "Post it in #tips on Discord"; Otto sends you the approved (possibly edited) text when \
      they approve. Comments arrive as a new message: reply with only the revised draft, or \
      start with NOTE: to answer a question. Never do the action before approval.
      """,
    inputSchema: .objectSchema(
      properties: [
        "title": .stringSchema(description: "Short title, e.g. Tip of the day"),
        "draft": .stringSchema(description: "The exact text to review"),
        "afterApproval": .stringSchema(description: "What you do once it is approved"),
      ], required: ["title", "draft"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler:
    @Sendable (HomeApprovalRequestInput, ToolContext) async throws -> HomeApprovalOutput
  public init(
    handler:
      @escaping @Sendable (HomeApprovalRequestInput, ToolContext) async throws ->
      HomeApprovalOutput
  ) { self.handler = handler }
  public func call(_ input: HomeApprovalRequestInput, context: ToolContext) async throws
    -> HomeApprovalOutput
  { try await handler(input, context) }
}

public struct HomeListApprovalsTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "home.list_approvals",
    description:
      "Lists drafts put on the user's Home for approval, newest first, with each one's state "
      + "(pending, revising, approved, rejected) and comments.",
    inputSchema: .objectSchema(), outputSchema: .objectSchema(), requiredScopes: [.agentRead],
    riskLevel: .read)
  public struct Input: Codable, Sendable { public init() {} }
  private let handler: @Sendable () async throws -> HomeApprovalOutput
  public init(handler: @escaping @Sendable () async throws -> HomeApprovalOutput) {
    self.handler = handler
  }
  public func call(_ input: Input, context: ToolContext) async throws -> HomeApprovalOutput {
    try await handler()
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
