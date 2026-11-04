import Foundation
import OttoModels
import OttoRuntime
import Testing

@testable import OttoServices

/// A failed automation run is retried once, after a short wait, only when the failure looks
/// transient. Denied, approval-bound and invalid runs are never retried, nor is a retry.
@Suite(.serialized)
struct RoutineRetryTests {
  @Test func failureReasonComesFromTheAgentNotTheProviderStream() {
    // A Claude Code run killed mid-command: no result event, but its last message says why, and
    // the stream ends in a rate-limit status event whose "rejected" field must not decide.
    let stream =
      #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","#
      + #""overageStatus":"rejected"}}"#
    var snapshot = AgentRuntimeSnapshot(
      id: UUID(), provider: .claudeCode, executionMode: .oneShotProvider, state: .failed,
      confidence: 1, output: stream + "\n",
      transcript: [
        AgentTranscriptEntry(
          role: .assistant, text: "Error: 503 Service Unavailable - try again later.")
      ])
    var detail = ApplicationServices.routineFailureDetail(snapshot)
    #expect(detail == "Error: 503 Service Unavailable - try again later.")
    #expect(RoutineFailureClassifier.classify(detail) == .transient)

    // With no message, only plain (non-JSON) lines from the stream are used.
    snapshot.transcript = []
    snapshot.output = stream + "\nerror: socket hang up\n" + stream + "\n"
    detail = ApplicationServices.routineFailureDetail(snapshot)
    #expect(detail == "error: socket hang up")
    snapshot.output = stream + "\n"
    #expect(ApplicationServices.routineFailureDetail(snapshot) == nil)
  }

  @Test func classifierSeparatesPassingTroubleFromRealFailures() {
    let transient = [
      "The request timed out.", "Network connection was lost", "429 Too Many Requests",
      "rate limit reached for requests", "Overloaded: provider is overloaded (529)",
      "503 Service Unavailable", "The terminal transport is closed", "read ECONNRESET",
    ]
    for message in transient {
      #expect(RoutineFailureClassifier.classify(message) == .transient, "\(message)")
    }
    let permanent = [
      "Permission denied by the person", "This action needs approval",
      "Invalid routine: missing instruction", "Validation failed", "401 Unauthorized",
      "Authentication required: not signed in", "Agent run failed", "", "Model not found",
      // Denial wins even when a timeout is mentioned.
      "Approval timed out and was denied",
    ]
    for message in permanent {
      #expect(RoutineFailureClassifier.classify(message) == .permanent, "\(message)")
    }
    #expect(RoutineFailureClassifier.classify(nil as String?) == .permanent)
    #expect(RoutineFailureClassifier.classify(URLError(.timedOut)) == .transient)
    #expect(RoutineFailureClassifier.classify(URLError(.badURL)) == .permanent)
    #expect(RoutineFailureClassifier.classify(RuntimeError.transportClosed) == .transient)
    #expect(
      RoutineFailureClassifier.classify(RoutineStoreError.invalid("network timeout")) == .permanent)
  }

  @Test func oldRunHistoryDecodesWithoutRetryLink() throws {
    let json = """
      {"runID":"\(UUID())","routineID":"\(UUID())","triggerSummary":"every 60s",
      "firedAt":0,"outcome":"failed","collapsedMissedRuns":false}
      """
    let record = try JSONDecoder().decode(RoutineRunRecord.self, from: Data(json.utf8))
    #expect(record.retryOfRunID == nil)
  }

  @MainActor private final class Harness {
    let root: URL
    let store: RoutineStore
    let bus = OttoEventBus()
    var nodes: [(routine: String, node: UUID)] = []
    var failureDetails: [UUID: String] = [:]
    var executorErrors: [any Error] = []
    var gateOpen = true
    var engine: RoutineEngine!

    init() {
      root = FileManager.default.temporaryDirectory
        .appending(path: "otto-retry-\(UUID().uuidString)")
      store = RoutineStore(workspacePath: root.path)
      engine = RoutineEngine(
        store: store, eventBus: bus, tickSeconds: 3_600,
        executor: { [unowned self] routine, _ in
          if !self.executorErrors.isEmpty { throw self.executorErrors.removeFirst() }
          let node = UUID()
          self.nodes.append((routine.name, node))
          return node
        },
        resultProvider: { _ in nil },
        deliveryHandler: { _, _, _ in },
        failureDetailProvider: { [unowned self] node in self.failureDetails[node] },
        retryDelaySeconds: 0.05,
        retryGate: { [unowned self] _ in self.gateOpen })
      engine.start()
    }

    func routine(_ name: String, after parent: Routine? = nil) throws -> Routine {
      var routine = Routine(
        name: name, instruction: "Do \(name)",
        trigger: .schedule(cron: "0 8 * * 1-5", intervalSeconds: nil),
        target: .spawnProvider(provider: "Claude Code"), enabled: true)
      if let parent { routine.chain(after: parent.id, when: .failed) }
      return try store.save(routine)
    }

    /// Fails the latest run of `name` with `detail` and lets the engine react.
    func fail(_ name: String, detail: String) async throws {
      let node = try #require(nodes.last { $0.routine == name }?.node)
      failureDetails[node] = detail
      bus.publish(OttoEvent(type: .agentRunFailed, nodeID: node))
      try await settle()
    }

    func settle(_ milliseconds: Int = 300) async throws {
      for _ in 0..<(milliseconds / 10) {
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    func runs(_ routine: Routine) -> [RoutineRunRecord] {
      store.recentRuns(routineID: routine.id).filter { $0.outcome != .running }.reversed()
    }

    deinit { try? FileManager.default.removeItem(at: root) }
  }

  @MainActor @Test func transientAgentFailureIsRetriedOnceAndLinked() async throws {
    let harness = Harness()
    defer { harness.engine.stop() }
    let routine = try harness.routine("Inbox triage")
    try await Task.sleep(for: .milliseconds(30))
    _ = try await harness.engine.fire(routine)
    try await harness.fail("Inbox triage", detail: "API error: 529 overloaded")

    #expect(harness.nodes.count == 2)
    let runs = harness.runs(routine)
    let failed = try #require(runs.first)
    #expect(failed.error == "Agent run failed: API error: 529 overloaded")
    #expect(failed.retryOfRunID == nil)
    let retry = try #require(
      harness.store.recentRuns(routineID: routine.id).first { $0.retryOfRunID != nil })
    #expect(retry.retryOfRunID == failed.runID)

    // The retry fails the same way: no second retry.
    try await harness.fail("Inbox triage", detail: "API error: 529 overloaded")
    #expect(harness.nodes.count == 2)
    #expect(harness.engine.pendingRetryRunIDs.isEmpty)
  }

  @MainActor @Test func deniedOrInvalidRunsAreNeverRetried() async throws {
    let harness = Harness()
    defer { harness.engine.stop() }
    let routine = try harness.routine("Poster")
    try await Task.sleep(for: .milliseconds(30))
    _ = try await harness.engine.fire(routine)
    try await harness.fail("Poster", detail: "Permission denied: posting needs your approval")
    _ = try await harness.engine.fire(routine)
    try await harness.fail("Poster", detail: "Invalid input: validation failed (timeout too long)")
    #expect(harness.nodes.count == 2)
    #expect(harness.engine.pendingRetryRunIDs.isEmpty)
  }

  @MainActor @Test func spawnFailuresRetryAndTestRunsDoNot() async throws {
    let harness = Harness()
    defer { harness.engine.stop() }
    let routine = try harness.routine("Digest")
    harness.executorErrors = [URLError(.notConnectedToInternet)]
    await #expect(throws: URLError.self) { try await harness.engine.fire(routine) }
    #expect(harness.engine.pendingRetryRunIDs[routine.id] != nil)
    try await harness.settle()
    #expect(harness.nodes.count == 1)
    #expect(harness.store.recentRuns(routineID: routine.id).contains { $0.retryOfRunID != nil })

    // A test run started by hand is the person's to repeat.
    harness.engine.abandonRuns(agentNodeID: try #require(harness.nodes.last?.node))
    harness.executorErrors = [URLError(.timedOut)]
    await #expect(throws: URLError.self) { try await harness.engine.testRun(routineID: routine.id) }
    #expect(harness.engine.pendingRetryRunIDs.isEmpty)
  }

  @MainActor @Test func retryIsDroppedWhenDisabledOrAsleepAndFailureStepsStillRun() async throws {
    let harness = Harness()
    defer { harness.engine.stop() }
    let routine = try harness.routine("Sync")
    _ = try harness.routine("Alert me", after: routine)
    try await Task.sleep(for: .milliseconds(30))

    _ = try await harness.engine.fire(routine)
    // Turned off while its run is still going: the failure is transient, but by the time the
    // retry comes due the routine is disabled, so the retry is dropped…
    var disabled = try #require(harness.store.routine(id: routine.id))
    disabled.enabled = false
    _ = try harness.store.save(disabled)
    try await harness.fail("Sync", detail: "network connection lost")
    // …and the on-failure step, held for the retry, runs instead.
    #expect(harness.nodes.map(\.routine) == ["Sync", "Alert me"])
    #expect(!harness.store.recentRuns(routineID: routine.id).contains { $0.retryOfRunID != nil })

    var enabled = try #require(harness.store.routine(id: routine.id))
    enabled.enabled = true
    let reenabled = try harness.store.save(enabled)
    harness.gateOpen = false
    _ = try await harness.engine.fire(reenabled)
    try await harness.fail("Sync", detail: "request timed out")
    #expect(harness.nodes.filter { $0.routine == "Sync" }.count == 2)
  }
}
