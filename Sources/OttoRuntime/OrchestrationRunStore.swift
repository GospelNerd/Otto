import Foundation
import OttoModels

public enum OrchestrationRunError: Error, Equatable {
  case invalidContract(String)
  case invalidTransition(from: OrchestrationPhase, to: OrchestrationPhase)
  case assignmentNotFound(UUID)
  case reviewRoundMismatch(expected: Int, received: Int)
  case assignmentClaimed(UUID)
  case permissionExpansion(
    granted: OrchestrationPermissionGrant, requested: OrchestrationPermissionGrant)
  case costCeilingRequired
  case invalidCost(Decimal)
  case mergeOwnerConflict(owner: UUID, requested: UUID)
  case invalidReview(String)
}

/// The deliberately small orchestration pipe: one typed JSON record, updated only by explicit
/// calls. Nothing supervises a run or invents follow-up prompts in the background. (The app-wide
/// `AgentWatchdog` may flag an assignment's agent as stuck on Home, but it never touches this
/// record or acts on the agent.)
public actor OrchestrationRunStore {
  private let fileURL: URL
  private var run: OrchestrationRun?
  private var didLoad = false
  private var updateContinuations: [UUID: AsyncStream<OrchestrationRun?>.Continuation] = [:]

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func live(workspacePath: String) -> OrchestrationRunStore {
    let fingerprint = workspacePath.utf8.reduce(UInt64(5_381)) { value, byte in
      ((value << 5) &+ value) ^ UInt64(byte)
    }
    let root =
      FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    return OrchestrationRunStore(
      fileURL: root.appending(
        path: "Otto/Orchestration/\(String(fingerprint, radix: 16))/active-run.json"))
  }

  public func current() throws -> OrchestrationRun? {
    try loadIfNeeded()
    return run
  }

  public func updates() -> AsyncStream<OrchestrationRun?> {
    let id = UUID()
    return AsyncStream { continuation in
      updateContinuations[id] = continuation
      continuation.yield(try? current())
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeUpdateContinuation(id) }
      }
    }
  }

  @discardableResult
  public func create(_ contract: OrchestrationRun) throws -> OrchestrationRun {
    guard !contract.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OrchestrationRunError.invalidContract("Objective is required")
    }
    guard !contract.acceptanceCriteria.isEmpty else {
      throw OrchestrationRunError.invalidContract("Acceptance criteria are required")
    }
    guard !contract.assignments.isEmpty else {
      throw OrchestrationRunError.invalidContract("At least one assignment is required")
    }
    guard contract.assignments.count <= contract.spendPolicy.maximumWorkers else {
      throw OrchestrationRunError.invalidContract("Assignments exceed the worker limit")
    }
    guard
      contract.spendPolicy.effectiveBillingMode != .metered
        || contract.spendPolicy.maximumEstimatedCost != nil
    else {
      throw OrchestrationRunError.costCeilingRequired
    }
    if let deadline = contract.deadline, deadline <= .now {
      throw OrchestrationRunError.invalidContract("Deadline must be in the future")
    }
    run = contract
    didLoad = true
    try persist()
    return contract
  }

  @discardableResult
  public func beginWorkers() throws -> OrchestrationRun {
    var run = try requiredRun()
    guard run.phase == .planning || run.phase == .corrections else {
      throw OrchestrationRunError.invalidTransition(from: run.phase, to: .workers)
    }
    if try stopIfDeadlineExpired(&run) { return run }
    if try stopIfBudgetExhausted(&run) { return run }
    run.phase = .workers
    for index in run.assignments.indices where run.assignments[index].status == .pending {
      run.assignments[index].status = .running
    }
    try save(run)
    return run
  }

  /// Durably claims one assignment before its worker performs any external effect. Replaying the
  /// same execution ID after a crash is safe; a different claim is rejected.
  @discardableResult
  public func claimAssignment(assignmentID: UUID, executionID: UUID) throws -> OrchestrationRun {
    var run = try requiredRun()
    guard run.phase == .workers else {
      throw OrchestrationRunError.invalidTransition(from: run.phase, to: .workers)
    }
    guard let index = run.assignments.firstIndex(where: { $0.id == assignmentID }) else {
      throw OrchestrationRunError.assignmentNotFound(assignmentID)
    }
    if run.assignments[index].executionID == executionID { return run }
    if run.assignments[index].executionID != nil {
      throw OrchestrationRunError.assignmentClaimed(assignmentID)
    }
    run.assignments[index].executionID = executionID
    run.assignments[index].status = .running
    try save(run)
    return run
  }

  @discardableResult
  public func recordWorkerResult(
    assignmentID: UUID,
    result: String,
    succeeded: Bool,
    executionID: UUID? = nil,
    evidence: [String] = [],
    completedRevision: String? = nil
  ) throws -> OrchestrationRun {
    var run = try requiredRun()
    guard run.phase == .workers else {
      throw OrchestrationRunError.invalidTransition(from: run.phase, to: .review)
    }
    guard let index = run.assignments.firstIndex(where: { $0.id == assignmentID }) else {
      throw OrchestrationRunError.assignmentNotFound(assignmentID)
    }
    if let executionID {
      if run.assignments[index].executionID == executionID,
        run.assignments[index].status == .completed || run.assignments[index].status == .failed
      {
        return run
      }
      guard run.assignments[index].executionID == executionID else {
        throw OrchestrationRunError.assignmentClaimed(assignmentID)
      }
    }
    run.assignments[index].result = result
    run.assignments[index].status = succeeded ? .completed : .failed
    run.assignments[index].resultRound = run.currentRound
    run.assignments[index].evidence = evidence
    run.assignments[index].completedRevision = completedRevision
    if run.assignments.allSatisfy({ $0.status == .completed || $0.status == .failed }) {
      if run.assignments.contains(where: { $0.status == .failed }) {
        run.phase = .failed
        run.failureReason = "One or more worker assignments failed"
      } else {
        run.phase = .review
      }
    }
    try save(run)
    return run
  }

  @discardableResult
  public func submitReview(_ review: OrchestrationReview) throws -> OrchestrationRun {
    var run = try requiredRun()
    guard run.phase == .review else {
      throw OrchestrationRunError.invalidTransition(from: run.phase, to: .passed)
    }
    guard review.round == run.currentRound else {
      throw OrchestrationRunError.reviewRoundMismatch(
        expected: run.currentRound, received: review.round)
    }
    if review.verdict == .pass {
      guard !review.evidence.isEmpty else {
        throw OrchestrationRunError.invalidReview("A passing review requires fresh evidence")
      }
      guard
        run.assignments.allSatisfy({
          $0.status == .completed && !($0.evidence ?? []).isEmpty
        })
      else {
        throw OrchestrationRunError.invalidReview(
          "Every assignment requires acceptance evidence before passing")
      }
      if let previous = run.reviews.last, previous.verdict == .correctionsRequired {
        let corrected = Set(previous.correctionAssignmentIDs)
        guard
          run.assignments.filter({ corrected.contains($0.id) })
            .allSatisfy({ $0.resultRound == run.currentRound })
        else {
          throw OrchestrationRunError.invalidReview(
            "Correction evidence must come from the current round")
        }
      }
    }
    run.reviews.append(review)
    switch review.verdict {
    case .pass:
      run.phase = .passed
    case .correctionsRequired where run.currentRound >= run.maximumRounds:
      run.phase = .escalated
      run.escalationReason = "Maximum correction rounds reached"
    case .correctionsRequired:
      run.currentRound += 1
      run.phase = .corrections
      let requested = Set(review.correctionAssignmentIDs)
      for index in run.assignments.indices
      where requested.isEmpty || requested.contains(run.assignments[index].id) {
        run.assignments[index].status = .pending
        run.assignments[index].result = nil
        run.assignments[index].executionID = nil
        run.assignments[index].resultRound = nil
        run.assignments[index].evidence = nil
        run.assignments[index].completedRevision = nil
      }
    }
    try save(run)
    return run
  }

  @discardableResult
  public func cancel(reason: String) throws -> OrchestrationRun {
    var run = try requiredRun()
    guard !run.phase.isTerminal else { return run }
    for index in run.assignments.indices
    where run.assignments[index].status == .pending || run.assignments[index].status == .running {
      run.assignments[index].status = .cancelled
    }
    run.phase = .cancelled
    run.failureReason = reason
    try save(run)
    return run
  }

  @discardableResult
  public func timeout(reason: String = "Orchestration deadline elapsed") throws -> OrchestrationRun
  {
    var run = try requiredRun()
    guard !run.phase.isTerminal else { return run }
    for index in run.assignments.indices
    where run.assignments[index].status == .pending || run.assignments[index].status == .running {
      run.assignments[index].status = .timedOut
    }
    run.phase = .failed
    run.failureReason = reason
    try save(run)
    return run
  }

  @discardableResult
  public func reportQuotaHandoff(details: [String]) throws -> OrchestrationRun {
    var run = try requiredRun()
    guard !run.phase.isTerminal else { return run }
    for index in run.assignments.indices where run.assignments[index].status == .running {
      run.assignments[index].status = .quotaExceeded
    }
    run.phase = .needsUser
    run.handoff = handoff(
      for: run, reason: "Provider quota or usage threshold reached", details: details)
    try save(run)
    return run
  }

  @discardableResult
  public func reportNeedsUser(reason: String, details: [String]) throws -> OrchestrationRun {
    var run = try requiredRun()
    guard !run.phase.isTerminal else { return run }
    run.phase = .needsUser
    run.handoff = handoff(for: run, reason: reason, details: details)
    try save(run)
    return run
  }

  @discardableResult
  public func recordSpend(_ amount: Decimal) throws -> OrchestrationRun {
    guard amount >= 0 else { throw OrchestrationRunError.invalidCost(amount) }
    var run = try requiredRun()
    run.spendPolicy.knownSpend = run.spendPolicy.effectiveKnownSpend + amount
    _ = try stopIfBudgetExhausted(&run)
    try save(run)
    return run
  }

  public func authorize(_ requested: OrchestrationPermissionGrant) throws {
    let run = try requiredRun()
    guard permissionRank(requested) <= permissionRank(run.permissionGrant) else {
      throw OrchestrationRunError.permissionExpansion(
        granted: run.permissionGrant, requested: requested)
    }
  }

  @discardableResult
  public func bindWorktree(
    assignmentID: UUID,
    path: String,
    baseRevision: String
  ) throws -> OrchestrationRun {
    var run = try requiredRun()
    guard let index = run.assignments.firstIndex(where: { $0.id == assignmentID }) else {
      throw OrchestrationRunError.assignmentNotFound(assignmentID)
    }
    run.assignments[index].worktreePath = path
    run.assignments[index].baseRevision = baseRevision
    try save(run)
    return run
  }

  @discardableResult
  public func claimMergeOwnership(assignmentID: UUID) throws -> OrchestrationRun {
    var run = try requiredRun()
    guard run.assignments.contains(where: { $0.id == assignmentID }) else {
      throw OrchestrationRunError.assignmentNotFound(assignmentID)
    }
    if let owner = run.mergeOwnerAssignmentID, owner != assignmentID {
      throw OrchestrationRunError.mergeOwnerConflict(owner: owner, requested: assignmentID)
    }
    run.mergeOwnerAssignmentID = assignmentID
    try save(run)
    return run
  }

  /// Reloads the latest checkpoint without resetting running claims or repeating transitions.
  public func resume() throws -> OrchestrationRun? {
    try current()
  }

  public func clear() throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
    run = nil
    didLoad = true
    for continuation in updateContinuations.values { continuation.yield(nil) }
  }

  private func requiredRun() throws -> OrchestrationRun {
    guard let run = try current() else {
      throw OrchestrationRunError.invalidContract("No orchestration run exists")
    }
    return run
  }

  private func save(_ run: OrchestrationRun) throws {
    var run = run
    run.updatedAt = .now
    run.checkpointSequence = (run.checkpointSequence ?? 0) + 1
    self.run = run
    try persist()
  }

  private func stopIfDeadlineExpired(_ run: inout OrchestrationRun) throws -> Bool {
    guard let deadline = run.deadline, deadline <= .now else { return false }
    for index in run.assignments.indices
    where run.assignments[index].status == .pending || run.assignments[index].status == .running {
      run.assignments[index].status = .timedOut
    }
    run.phase = .failed
    run.failureReason = "Orchestration deadline elapsed"
    try save(run)
    return true
  }

  private func stopIfBudgetExhausted(_ run: inout OrchestrationRun) throws -> Bool {
    guard let ceiling = run.spendPolicy.maximumEstimatedCost,
      run.spendPolicy.effectiveKnownSpend >= ceiling
    else { return false }
    run.phase = .budgetExhausted
    run.handoff = handoff(
      for: run,
      reason: "Configured spend ceiling reached",
      details: ["Known spend: \(run.spendPolicy.effectiveKnownSpend)", "Ceiling: \(ceiling)"])
    return true
  }

  private func handoff(
    for run: OrchestrationRun,
    reason: String,
    details: [String]
  ) -> OrchestrationHandoff {
    OrchestrationHandoff(
      reason: reason,
      round: run.currentRound,
      pendingAssignmentIDs: run.assignments.compactMap {
        switch $0.status {
        case .completed, .failed, .cancelled: nil
        case .pending, .running, .timedOut, .quotaExceeded: $0.id
        }
      },
      details: details)
  }

  private func permissionRank(_ grant: OrchestrationPermissionGrant) -> Int {
    switch grant {
    case .readOnly: 0
    case .workspaceWrite: 1
    case .unrestricted: 2
    }
  }

  private func loadIfNeeded() throws {
    guard !didLoad else { return }
    didLoad = true
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    run = try decoder.decode(OrchestrationRun.self, from: Data(contentsOf: fileURL))
  }

  private func persist() throws {
    guard let run else { return }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(run).write(to: fileURL, options: .atomic)
    for continuation in updateContinuations.values { continuation.yield(run) }
  }

  private func removeUpdateContinuation(_ id: UUID) {
    updateContinuations[id] = nil
  }
}
