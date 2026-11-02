import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoTools
import Testing

@testable import OttoServices

/// Approve, comment or reject on Home: an automation's answer waits there, and nothing after
/// it runs until the person approves.
@Suite(.serialized)
struct HomeReviewTests {
  @MainActor private final class Harness {
    let root: URL
    let store: RoutineStore
    let bus = OttoEventBus()
    var prompts: [(routine: String, prompt: String, node: UUID)] = []
    var answers: [UUID: String] = [:]
    var held: [(routine: String, answer: String, depth: Int)] = []
    var engine: RoutineEngine!

    init() {
      root = FileManager.default.temporaryDirectory
        .appending(path: "otto-review-\(UUID().uuidString)")
      store = RoutineStore(workspacePath: root.path)
      engine = RoutineEngine(
        store: store, eventBus: bus, tickSeconds: 3_600,
        executor: { [unowned self] routine, prompt in
          let node = UUID()
          self.prompts.append((routine.name, prompt, node))
          return node
        },
        resultProvider: { [unowned self] node in self.answers[node] },
        deliveryHandler: { _, _, _ in },
        reviewHandler: { [unowned self] routine, _, _, answer, depth in
          self.held.append((routine.name, answer, depth))
        })
      engine.start()
    }

    func step(_ name: String, after parent: Routine? = nil, review: Bool = false) throws
      -> Routine
    {
      var routine = Routine(
        name: name, instruction: "Do \(name)",
        trigger: .schedule(cron: "0 8 * * *", intervalSeconds: nil),
        target: .spawnProvider(provider: "Claude Code"), enabled: true)
      if let parent { routine.chain(after: parent.id, when: .succeeded) }
      if review { routine.reviewOnHome = true }
      return try store.save(routine)
    }

    func finish(_ name: String, answer: String) async throws {
      let node = try #require(prompts.last { $0.routine == name }?.node)
      answers[node] = answer
      bus.publish(OttoEvent(type: .agentRunCompleted, nodeID: node))
      for _ in 0..<50 {
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    deinit { try? FileManager.default.removeItem(at: root) }
  }

  @MainActor @Test func reviewedAnswerHoldsTheFlowUntilApproved() async throws {
    let harness = Harness()
    defer { harness.engine.stop() }
    let tip = try harness.step("Tip of the day", review: true)
    _ = try harness.step("Post to Discord", after: tip)

    try await Task.sleep(for: .milliseconds(30))
    _ = try await harness.engine.fire(tip)
    let tipPrompt = try #require(harness.prompts.first?.prompt)
    #expect(tipPrompt.contains("approve, comment on or"))
    try await harness.finish("Tip of the day", answer: "Name your branches after tickets.")

    #expect(harness.held.map(\.routine) == ["Tip of the day"])
    #expect(harness.prompts.map(\.routine) == ["Tip of the day"])
    let run = try #require(harness.store.recentRuns(routineID: tip.id).first)
    #expect(run.outcome == .completed)

    await harness.engine.continueAfterApproval(
      routineID: tip.id, approvedText: "Name branches after tickets.", depth: 0)
    #expect(harness.prompts.map(\.routine) == ["Tip of the day", "Post to Discord"])
    let post = try #require(harness.prompts.last?.prompt)
    #expect(post.contains("Name branches after tickets."))
    #expect(post.contains("was approved"))
    #expect(post.contains("approved it (they may have edited it)"))
  }

  @MainActor @Test func silentAnswersAreNotSentForReview() async throws {
    let harness = Harness()
    defer { harness.engine.stop() }
    let tip = try harness.step("Tip of the day", review: true)
    try await Task.sleep(for: .milliseconds(30))
    _ = try await harness.engine.fire(tip)
    try await harness.finish("Tip of the day", answer: "[SILENT]")
    #expect(harness.held.isEmpty)
  }

  @Test func routinesWrittenBeforeReviewsStillDecode() throws {
    let routine = Routine(
      name: "Old", instruction: "x", trigger: .schedule(cron: "0 8 * * *", intervalSeconds: nil),
      target: .spawnProvider(provider: "Claude Code"))
    var object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(routine)) as? [String: Any])
    object["reviewOnHome"] = nil
    object["afterApproval"] = nil
    let decoded = try JSONDecoder().decode(
      Routine.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(!decoded.needsReview)
    #expect(decoded.afterApproval == nil)
  }

  @MainActor @Test func storeKeepsOpenReviewsAndReopensInterruptedRevisions() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-review-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = HomeReviewStore(workspacePath: root.path)
    #expect(throws: HomeReviewStore.ReviewError.emptyDraft) {
      try store.add(HomeReview(title: "Empty", requester: "Bot", draft: "   "))
    }
    let first = try store.add(HomeReview(title: "", requester: "Tipster", draft: " A tip "))
    #expect(first.title == "Tipster")
    #expect(first.draft == "A tip")
    try store.update(id: first.id) { $0.state = .revising }

    let reloaded = HomeReviewStore(workspacePath: root.path)
    #expect(reloaded.open.map(\.state) == [.pending])
  }

  @Test func noteRepliesAreToldApartFromRevisedDrafts() {
    #expect(
      ApplicationServices.reviewNote(in: "NOTE: It's from the Git docs.")
        == "It's from the Git docs.")
    #expect(ApplicationServices.reviewNote(in: "note:  ok") == "ok")
    #expect(ApplicationServices.reviewNote(in: "Use short branch names.") == nil)
  }

  @MainActor @Test func agentsRequestApprovalAndThePersonDecides() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-review-tool-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Reviews")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let services = ApplicationServices(
      store: store, registry: registry, secrets: InMemorySecretStore(), workspacePath: root.path)
    try await services.registerHomeReviewTools()
    let context = ToolContext(
      actorID: "test-agent", scopes: [.canvasWrite, .agentRead], source: .agent,
      sourceCanvasID: canvas.id)

    // Without a calling session there's nobody to hand the approved text back to.
    await #expect(throws: (any Error).self) {
      _ = try await registry.call(
        name: "home.request_approval",
        input: .object([
          "title": .string("Tip"), "draft": .string("A tip"),
          "afterApproval": .string("Post it"),
        ]),
        context: context)
    }
    _ = try await registry.call(
      name: "home.request_approval",
      input: .object(["title": .string("Tip of the day"), "draft": .string("Commit small.")]),
      context: context)
    let review = try #require(services.homeReviews.open.first)
    #expect(review.title == "Tip of the day")

    try await services.approveReview(id: review.id, editedDraft: "Commit small and often.")
    let approved = try #require(services.homeReviews.review(id: review.id))
    #expect(approved.state == .approved)
    #expect(approved.draft == "Commit small and often.")
    #expect(services.homeReviews.open.isEmpty)
    await #expect(throws: HomeReviewStore.ReviewError.alreadyDecided) {
      try await services.approveReview(id: review.id)
    }

    _ = try await registry.call(
      name: "home.request_approval",
      input: .object(["title": .string("Second"), "draft": .string("Another")]),
      context: context)
    let second = try #require(services.homeReviews.open.first)
    try services.rejectReview(id: second.id, reason: "Too generic")
    let rejected = try #require(services.homeReviews.review(id: second.id))
    #expect(rejected.state == .rejected)
    #expect(rejected.notes.map(\.text) == ["Too generic"])

    let listed = try await registry.call(
      name: "home.list_approvals", input: .object([:]), context: context
    ).decode(HomeApprovalOutput.self)
    #expect(listed.reviews.map(\.state) == ["rejected", "approved"])
  }

  // MARK: Only when approval is asked for

  @MainActor @Test func automationsWithoutReviewCarryOnAsBefore() async throws {
    let harness = Harness()
    defer { harness.engine.stop() }
    let tip = try harness.step("Tip of the day")
    _ = try harness.step("Post to Discord", after: tip)
    try await Task.sleep(for: .milliseconds(30))
    _ = try await harness.engine.fire(tip)
    let tipPrompt = try #require(harness.prompts.first?.prompt)
    #expect(!tipPrompt.contains(RoutineEngine.reviewInstruction))
    try await harness.finish("Tip of the day", answer: "Commit small.")

    #expect(harness.held.isEmpty)
    #expect(harness.prompts.map(\.routine) == ["Tip of the day", "Post to Discord"])
    let post = try #require(harness.prompts.last?.prompt)
    #expect(!post.contains("approved it"))
  }

  @MainActor @Test func onlyTheReviewedStepWaitsInAFlow() async throws {
    let harness = Harness()
    defer { harness.engine.stop() }
    let research = try harness.step("Research")
    let tip = try harness.step("Tip of the day", after: research, review: true)
    _ = try harness.step("Post to Discord", after: tip)
    try await Task.sleep(for: .milliseconds(30))
    _ = try await harness.engine.fire(research)
    try await harness.finish("Research", answer: "People miss the voice shortcut.")
    // The step before the reviewed one hands on straight away.
    #expect(harness.prompts.map(\.routine) == ["Research", "Tip of the day"])
    try await harness.finish("Tip of the day", answer: "Press ⌃⌥Space and talk.")
    #expect(harness.held.map(\.routine) == ["Tip of the day"])
    #expect(harness.held.first?.depth == 1)
    #expect(harness.prompts.map(\.routine) == ["Research", "Tip of the day"])
  }

  // MARK: Approve, comment and reject through Otto

  @MainActor private func reviewServices() -> (ApplicationServices, URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-review-flow-\(UUID().uuidString)")
    let canvas = OttoCanvas(name: "Reviews")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    return (ApplicationServices(store: store, workspacePath: root.path), root)
  }

  @MainActor private func tipFlow(_ services: ApplicationServices) throws -> (Routine, Routine) {
    let tip = try services.routines.save(
      Routine(
        name: "Tip of the day", instruction: "Write one Otto tip",
        trigger: .schedule(cron: "0 9 * * *", intervalSeconds: nil),
        target: .spawnProvider(provider: "Claude Code"), enabled: true, reviewOnHome: true,
        afterApproval: "Post it in #tips on Discord"))
    var post = Routine(
      name: "Log the post", instruction: "Note what was posted",
      trigger: .schedule(cron: "0 9 * * *", intervalSeconds: nil),
      target: .existingAgent(nodeID: UUID()), enabled: true)
    post.chain(after: tip.id, when: .succeeded)
    return (tip, try services.routines.save(post))
  }

  @MainActor @Test func approvingSendsTheActionAndStartsTheNextStep() async throws {
    let (services, root) = reviewServices()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tip, post) = try tipFlow(services)
    var sent: [(UUID, String)] = []
    services.reviewAgentOverride = { node, prompt in
      sent.append((node, prompt))
      return "Posted it."
    }
    let agent = UUID()
    try services.holdRoutineResultForReview(
      tip, runID: UUID(), nodeID: agent, result: "Press ⌃⌥Space and talk.", depth: 0)
    let review = try #require(services.homeReviews.open.first)
    #expect(review.afterApproval == "Post it in #tips on Discord")
    #expect(services.routines.recentRuns(routineID: post.id).isEmpty)

    try await services.approveReview(id: review.id, editedDraft: "Press ⌃⌥Space, then talk.")
    await services.reviewActionTasks[review.id]?.value

    // The agent that wrote it is told to do the action with exactly the approved text.
    #expect(sent.count == 1)
    let prompt = try #require(sent.first)
    #expect(prompt.0 == agent)
    #expect(prompt.1.contains("Now do this with exactly the approved text: Post it in #tips"))
    #expect(prompt.1.contains("<<<approved>>>\nPress ⌃⌥Space, then talk.\n<<<end>>>"))
    #expect(prompt.1.contains("after editing it"))
    // And the next step in the flow fired.
    #expect(!services.routines.recentRuns(routineID: post.id).isEmpty)
    #expect(services.homeReviews.review(id: review.id)?.state == .approved)
  }

  // MARK: The approved action stays on Home

  @MainActor @Test func approvedActionStaysOnHomeUntilDismissed() async throws {
    let (services, root) = reviewServices()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tip, _) = try tipFlow(services)
    var release: CheckedContinuation<Void, Never>?
    services.reviewAgentOverride = { _, _ in
      await withCheckedContinuation { release = $0 }
      return "Posted it in #tips."
    }
    try services.holdRoutineResultForReview(
      tip, runID: UUID(), nodeID: UUID(), result: "Press ⌃⌥Space.", depth: 0)
    let id = try #require(services.homeReviews.open.first).id

    try await services.approveReview(id: id)
    // While the agent works the card is still on Home, no longer waiting on a decision.
    for _ in 0..<20 where release == nil { await Task.yield() }
    var review = try #require(services.homeReviews.review(id: id))
    #expect(review.actionStatus == .running)
    #expect(services.homeReviews.open.isEmpty)
    #expect(services.homeReviews.onHome.map(\.id) == [id])
    #expect(!review.needsPerson)

    release?.resume()
    await services.reviewActionTasks[id]?.value
    review = try #require(services.homeReviews.review(id: id))
    #expect(review.actionStatus == .done)
    #expect(review.actionResult == "Posted it in #tips.")
    #expect(services.homeReviews.onHome.map(\.id) == [id])

    services.dismissReview(id: id)
    #expect(services.homeReviews.onHome.isEmpty)
  }

  @MainActor @Test func permissionPromptsAreAnsweredFromTheCard() async throws {
    let (services, root) = reviewServices()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tip, _) = try tipFlow(services)
    let agent = UUID()
    var answers: [(UUID, Bool)] = []
    services.reviewPermissionOverride = { node, allow in answers.append((node, allow)) }
    try services.holdRoutineResultForReview(
      tip, runID: UUID(), nodeID: agent, result: "Press ⌃⌥Space.", depth: 0)
    let id = try #require(services.homeReviews.open.first).id
    try services.homeReviews.update(id: id) {
      $0.state = .approved
      $0.actionStatus = .running
      $0.actionPermission = "Bash: mkdir -p output && printf … >> tips.md"
    }
    #expect(try #require(services.homeReviews.review(id: id)).needsPerson)

    await services.answerReviewPermission(id: id, allow: true)
    #expect(answers.count == 1)
    #expect(answers.first?.0 == agent)
    #expect(answers.first?.1 == true)
    #expect(services.homeReviews.review(id: id)?.actionPermission == nil)
  }

  @MainActor @Test func aFailedActionSaysSoAndCanBeDismissed() async throws {
    let (services, root) = reviewServices()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tip, _) = try tipFlow(services)
    services.reviewAgentOverride = { _, _ in
      throw ToolRegistryError.invalidInput("Discord is not connected")
    }
    try services.holdRoutineResultForReview(
      tip, runID: UUID(), nodeID: UUID(), result: "Press ⌃⌥Space.", depth: 0)
    let id = try #require(services.homeReviews.open.first).id
    try await services.approveReview(id: id)
    await services.reviewActionTasks[id]?.value
    let review = try #require(services.homeReviews.review(id: id))
    #expect(review.actionStatus == .failed)
    #expect(review.problem?.contains("Discord is not connected") == true)
    #expect(review.isActing)
    services.dismissReview(id: id)
    #expect(services.homeReviews.onHome.isEmpty)
  }

  @MainActor @Test func approvingWithoutAnActionLeavesNothingOnHome() async throws {
    let (services, root) = reviewServices()
    defer { try? FileManager.default.removeItem(at: root) }
    var tip = try tipFlow(services).0
    tip.afterApproval = nil
    tip = try services.routines.save(tip)
    try services.holdRoutineResultForReview(
      tip, runID: UUID(), nodeID: UUID(), result: "Press ⌃⌥Space.", depth: 0)
    let id = try #require(services.homeReviews.open.first).id
    try await services.approveReview(id: id)
    #expect(services.homeReviews.review(id: id)?.actionStatus == nil)
    #expect(services.homeReviews.onHome.isEmpty)
  }

  @MainActor @Test func anActionRunningWhenOttoQuitShowsAsInterrupted() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-review-restart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = HomeReviewStore(workspacePath: root.path)
    let review = try store.add(HomeReview(title: "Tip", requester: "Bot", draft: "A tip"))
    try store.update(id: review.id) {
      $0.state = .approved
      $0.actionStatus = .running
      $0.actionPermission = "Bash: echo hi"
    }
    let reloaded = HomeReviewStore(workspacePath: root.path)
    let after = try #require(reloaded.review(id: review.id))
    #expect(after.actionStatus == .interrupted)
    #expect(after.actionPermission == nil)
    #expect(reloaded.onHome.map(\.id) == [review.id])
  }

  @Test func reviewFilesFromBeforeActionTrackingStillDecode() throws {
    let json = """
      {"id":"\(UUID().uuidString)","title":"T","requester":"R","draft":"D","state":"approved",
       "notes":[],"chainDepth":0,"createdAt":"2026-10-30T09:00:00Z",
       "updatedAt":"2026-10-30T09:00:00Z"}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let review = try decoder.decode(HomeReview.self, from: Data(json.utf8))
    #expect(review.actionStatus == nil)
    #expect(!review.isActing)
  }

  @MainActor @Test func rejectingSendsNothingAndStopsTheFlow() async throws {
    let (services, root) = reviewServices()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tip, post) = try tipFlow(services)
    var sent = 0
    services.reviewAgentOverride = { _, _ in
      sent += 1
      return nil
    }
    try services.holdRoutineResultForReview(
      tip, runID: UUID(), nodeID: UUID(), result: "A weak tip.", depth: 0)
    let review = try #require(services.homeReviews.open.first)
    try services.rejectReview(id: review.id)
    #expect(sent == 0)
    #expect(services.routines.recentRuns(routineID: post.id).isEmpty)
    await #expect(throws: HomeReviewStore.ReviewError.alreadyDecided) {
      try await services.approveReview(id: review.id)
    }
  }

  @MainActor @Test func commentsReviseTheDraftOrAnswerWithoutActing() async throws {
    let (services, root) = reviewServices()
    defer { try? FileManager.default.removeItem(at: root) }
    let (tip, post) = try tipFlow(services)
    var replies = ["Press ⌃⌥Space.", "NOTE: It works in any app."]
    var prompts: [String] = []
    services.reviewAgentOverride = { _, prompt in
      prompts.append(prompt)
      return replies.removeFirst()
    }
    try services.holdRoutineResultForReview(
      tip, runID: UUID(), nodeID: UUID(), result: "Press ⌃⌥Space and just talk to Otto.",
      depth: 0)
    let id = try #require(services.homeReviews.open.first).id

    try await services.commentOnReview(id: id, text: "Shorter please")
    #expect(prompts.last?.contains("Shorter please") == true)
    #expect(prompts.last?.contains("Do not post, send or publish anything.") == true)
    #expect(services.homeReviews.review(id: id)?.draft == "Press ⌃⌥Space.")

    try await services.commentOnReview(id: id, text: "Does it work everywhere?")
    let review = try #require(services.homeReviews.review(id: id))
    #expect(review.draft == "Press ⌃⌥Space.")
    #expect(review.state == .pending)
    #expect(review.notes.map(\.text).last == "It works in any app.")
    // Commenting never approves: nothing posted, next step still waiting.
    #expect(prompts.allSatisfy { !$0.contains("Now do this") })
    #expect(services.routines.recentRuns(routineID: post.id).isEmpty)
  }
}
