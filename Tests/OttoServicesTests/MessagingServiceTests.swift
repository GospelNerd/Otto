import Foundation
import OttoCore
import OttoModels
import OttoSecurity
import Testing

@testable import OttoServices

actor MessagingTestSecrets: SecretStore {
  var values: [String: String] = [:]
  var refusesDeletion = false
  func refuseDeletion(_ value: Bool) { refusesDeletion = value }
  func set(_ value: String, for key: String) { values[key] = value }
  func value(for key: String) -> String? { values[key] }
  func delete(_ key: String) throws {
    if refusesDeletion { throw MessagingError.providerUnavailable }
    values[key] = nil
  }
  var count: Int { values.count }
}

@MainActor
final class MessagingTestAdapter: MessagingProviderAdapter {
  var onEvent: ((Data) -> Void)?
  var sent: [MessagingJob] = []
  var signals: [String] = []
  func signal(_ action: String, binding: MessagingBinding, eventID: String?) {
    signals.append(action)
  }
  var connected = false
  func connect(accountID: String, secret: String) { connected = true }
  func send(_ job: MessagingJob) { sent.append(job) }
  func disconnect() { connected = false }
  func event(_ object: [String: Any]) throws {
    onEvent?(try JSONSerialization.data(withJSONObject: object))
  }
  func inbound(code: String? = nil, text: String = "Hello", id: String = UUID().uuidString) throws {
    try event([
      "kind": "inbound", "accountID": "test-account", "sender": "+15550001111",
      "destination": "+15550002222", "eventID": id, "conversation": "test-chat", "isDirect": true,
      "unsupported": false, "text": code.map { "PAIR " + $0 } ?? text,
    ])
  }
}

@MainActor
@Suite("Messaging service (simulated provider, in-memory secrets)")
struct MessagingServiceTests {
  @Test func connectionPairingDisconnectAndMissingCoordinator() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "otto-messaging-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    let lead = try services.saveAgentProfile(
      AgentProfile(name: "Lead", instructions: "Coordinate", provider: .codex))
    let worker = try services.saveAgentProfile(
      AgentProfile(name: "Worker", instructions: "Help", provider: .codex))
    let team = try services.botChannels.createGroupChannel(
      memberProfileIDs: [lead.id, worker.id], name: "Test", orchestratorProfileID: lead.id)
    let adapter = MessagingTestAdapter()
    let secrets = MessagingTestSecrets()
    let messaging = MessagingService(
      services: services, adapter: adapter, secrets: secrets,
      url: root.appending(path: "state.json"))
    await messaging.connect(
      accountID: "test-account", secret: "SIMULATED-SECRET", sender: "+15550001111",
      destination: "+15550002222", teamID: team.id)
    #expect(adapter.connected)
    #expect(await secrets.count == 1)
    #expect(!messaging.status.contains("complete"))
    try adapter.event(["kind": "ready"])
    let code = try #require(messaging.pairingCode)
    try adapter.inbound(text: "Not paired yet", id: "ignored")
    #expect(adapter.signals.isEmpty)
    try adapter.inbound(code: code, id: "pair")
    #expect(adapter.signals == ["read"])
    try adapter.inbound(code: code, id: "pair")
    #expect(adapter.signals == ["read"])
    #expect(messaging.binding?.sender == "+15550001111")
    #expect(messaging.pairingCode == nil)
    let raw = try String(contentsOf: root.appending(path: "state.json"), encoding: .utf8)
    #expect(!raw.contains("SIMULATED-SECRET"))
    #expect(!raw.contains(code))
    let roomID = try #require(messaging.binding?.roomID)
    #expect(services.botChannels.channel(id: roomID) == nil)
    // A saved session may outlive its sidebar channel (e.g. an older host rewrote channels).
    let session = try services.botGroups.beginTurn(
      members: [lead.id, worker.id], channelID: roomID, mentioned: [])
    _ = try services.botGroups.recordUserMessage(
      sessionID: session.id, text: "Preserve review history")
    await messaging.reconnect()
    #expect(services.botChannels.channel(id: roomID)?.orchestratorProfileID == lead.id)
    messaging.openTeam()
    #expect(services.botNavigationRequest?.destination == .team(roomID))
    #expect(
      services.botGroups.latestSession(forChannel: roomID)?.messages.first?.text
        == "Preserve review history")
    _ = try services.botChannels.archive(channelID: roomID)
    messaging.openTeam()
    #expect(services.botChannels.channel(id: roomID)?.archived == true)
    #expect(messaging.status.contains("unavailable"))
    _ = try services.botChannels.archive(channelID: team.id)
    await messaging.reconnect()
    #expect(messaging.status.contains("available project"))
    await secrets.refuseDeletion(true)
    await messaging.disconnect()
    #expect(messaging.cleanupRequired)
    #expect(await secrets.count == 1)
    await secrets.refuseDeletion(false)
    await messaging.disconnect()
    #expect(!messaging.cleanupRequired)
    #expect(!adapter.connected)
    #expect(await secrets.count == 0)
    let count = messaging.jobs.count
    try adapter.inbound(text: "Do not run")
    #expect(messaging.jobs.count == count)
    #expect(messaging.binding?.enabled == false)
  }
  @Test func providerFailuresBoundRetriesAndPreserveUncertainDelivery() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-messaging-failure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let lead = try services.saveAgentProfile(
      AgentProfile(name: "Lead", instructions: "Coordinate", provider: .codex))
    let worker = try services.saveAgentProfile(
      AgentProfile(name: "Worker", instructions: "Help", provider: .codex))
    let team = try services.botChannels.createGroupChannel(
      memberProfileIDs: [lead.id, worker.id], name: "Test", orchestratorProfileID: lead.id)
    let adapter = MessagingTestAdapter()
    let messaging = MessagingService(
      services: services, adapter: adapter, secrets: MessagingTestSecrets(),
      url: root.appending(path: "state.json"))
    await messaging.connect(
      accountID: "test-account", secret: "SIMULATED", sender: "+15550001111",
      destination: "+15550002222", teamID: team.id)
    try adapter.event(["kind": "connectionFailed", "reason": "credentialExpired"])
    #expect(messaging.status.contains("credentials"))
    await messaging.reconnect()
    try adapter.event(["kind": "ready"])
    let pairingCode = try #require(messaging.pairingCode)
    try adapter.inbound(code: pairingCode)
    for attempt in 1...4 {
      messaging.tick(now: Date().addingTimeInterval(300))
      let sent = try #require(adapter.sent.last)
      #expect(sent.attempts == attempt)
      try adapter.event(["kind": "retry", "id": sent.id.uuidString, "reason": "throttled"])
    }
    #expect(messaging.jobs.first?.state == .failed)
    let before = adapter.sent.count
    messaging.tick(now: Date().addingTimeInterval(600))
    #expect(adapter.sent.count == before)
    try adapter.event([
      "kind": "inbound", "accountID": "test-account", "sender": "+15550001111",
      "destination": "+15550002222", "eventID": "attachment", "conversation": "test-chat",
      "isDirect": true, "unsupported": true, "text": "",
    ])
    messaging.tick()
    let uncertain = try #require(adapter.sent.last)
    try adapter.event(["kind": "uncertain", "id": uncertain.id.uuidString])
    #expect(messaging.jobs.last?.state == .uncertain)
    #expect(messaging.status.contains("uncertain"))
    await messaging.reconnect()
    try adapter.event(["kind": "ready"])
    messaging.tick(now: Date().addingTimeInterval(600))
    #expect(adapter.sent.count == before + 1)
    await messaging.disconnect()
    await services.shutdown()
  }

  @Test("Restart keeps interrupted A and queued B behind desktop review")
  func interruptedRequestPreservesGate() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "messaging-review-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let (binding, state, sessionID, request) = try fixture(services, root: root)
    let checkpoint = BotTeamCheckpoint(
      queue: [], point: WorldPoint(x: 0, y: 0),
      turnCounts: [:], replyFingerprints: [], activeRuntimeID: UUID(),
      activeAssignment: BotTeamAssignment(profileID: binding.coordinatorID, task: "Interrupted A"))
    try services.botGroups.checkpoint(sessionID: sessionID, state: checkpoint)
    try services.botGroups.recoverInterruptedTeams()
    let queued = MessagingJob(binding: binding, eventKey: "B", text: "Queued B")
    // Persist a second accepted request using the actual inbound acceptance path.
    _ = try state.accept(
      MessagingInbound(
        accountID: binding.accountID, eventID: "B", conversation: "test-chat",
        sender: binding.expectedSender, destination: binding.destination, isDirect: true,
        text: queued.text, unsupported: false))
    let adapter = MessagingTestAdapter()
    let messaging = MessagingService(
      services: services, adapter: adapter, secrets: MessagingTestSecrets(),
      url: root.appending(path: "state.json"))
    try adapter.event(["kind": "ready"])
    for _ in 0..<3 {
      messaging.tick()
      await Task.yield()
    }
    #expect(messaging.jobs.first(where: { $0.id == request.id })?.state == .running)
    #expect(messaging.jobs.first(where: { $0.text == "Queued B" })?.state == .queued)
    #expect(services.botGroups.session(id: sessionID)?.teamCheckpoint == checkpoint)
    #expect(services.botGroups.session(id: sessionID)?.needsUser == true)
    #expect(!services.isTeamRunning(channelID: binding.roomID))
    #expect(adapter.sent.count == 1)
    #expect(adapter.sent.first?.text == "")  // Separate notice, not completion of A.
    await services.shutdown()
  }

  @Test("Phone answer cannot borrow a later desktop turn", arguments: [false, true])
  func replyIsBoundedByNextRequest(hasPhoneAnswer: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "messaging-correlation-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let (binding, _, sessionID, request) = try fixture(services, root: root)
    if hasPhoneAnswer {
      _ = try services.botGroups.recordTurn(
        sessionID: sessionID, profileID: binding.coordinatorID,
        kind: .reply, text: "Answer to phone A")
    }
    _ = try services.botGroups.recordUserMessage(sessionID: sessionID, text: "Private desktop B")
    _ = try services.botGroups.recordTurn(
      sessionID: sessionID, profileID: binding.coordinatorID,
      kind: .reply, text: "Private desktop answer B")
    let adapter = MessagingTestAdapter()
    let messaging = MessagingService(
      services: services, adapter: adapter, secrets: MessagingTestSecrets(),
      url: root.appending(path: "state.json"))
    try adapter.event(["kind": "ready"])
    messaging.tick()
    #expect(
      !adapter.sent.contains {
        $0.reply?.contains("desktop") == true && $0.reply?.contains("answer B") == true
      })
    if hasPhoneAnswer {
      #expect(adapter.sent.first?.id == request.id)
      #expect(adapter.sent.first?.reply == "Answer to phone A")
    } else {
      #expect(messaging.jobs.first(where: { $0.id == request.id })?.state == .uncertain)
      #expect(adapter.sent.first?.text == "")
    }
    await services.shutdown()
  }

  @Test("The phone gets the coordinator's answer as plain text")
  func phoneAnswerIsPlainText() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "messaging-plain-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let (binding, _, sessionID, request) = try fixture(services, root: root)
    _ = try services.botGroups.recordTurn(
      sessionID: sessionID, profileID: binding.coordinatorID, kind: .reply,
      text: """
        **Ship Friday.**
        ```mermaid
        flowchart TD
          A --> B
        ```
        | Step | Owner |
        | --- | --- |
        | QA | Sam |
        <!-- otto:details -->
        Long reasoning.
        """)
    let adapter = MessagingTestAdapter()
    let messaging = MessagingService(
      services: services, adapter: adapter, secrets: MessagingTestSecrets(),
      url: root.appending(path: "state.json"))
    try adapter.event(["kind": "ready"])
    messaging.tick()
    #expect(adapter.sent.first?.id == request.id)
    #expect(
      adapter.sent.first?.reply
        == "Ship Friday.\n(diagram in Otto)\n• QA — Sam\n\n(More detail in Otto on your Mac.)")
    await services.shutdown()
  }

  @Test("Review repro: a request blocked before dispatch remains queued")
  func dispatchGateRaceKeepsQueuedRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "messaging-gate-race-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let (binding, state, sessionID, original) = try fixture(services, root: root)
    var completed = original
    completed.state = .accepted
    try state.update(completed)
    _ = try state.accept(
      MessagingInbound(
        accountID: binding.accountID, eventID: "B", conversation: "test-chat",
        sender: binding.expectedSender, destination: binding.destination, isDirect: true,
        text: "Queued B", unsupported: false))
    let queued = try #require(state.jobs.last)
    let adapter = MessagingTestAdapter()
    let messaging = MessagingService(
      services: services, adapter: adapter, secrets: MessagingTestSecrets(),
      url: root.appending(path: "state.json"))
    try adapter.event(["kind": "ready"])
    messaging.tick()
    // Model a desktop checkpoint appearing before the scheduled dispatch Task executes.
    let checkpoint = BotTeamCheckpoint(
      queue: [], point: WorldPoint(x: 0, y: 0),
      turnCounts: [:], replyFingerprints: [], activeRuntimeID: UUID(),
      activeAssignment: BotTeamAssignment(profileID: binding.coordinatorID, task: "Desktop task"))
    try services.botGroups.checkpoint(sessionID: sessionID, state: checkpoint)
    for _ in 0..<3 { await Task.yield() }
    messaging.tick()
    #expect(!services.isTeamRunning(channelID: binding.roomID))
    #expect(
      !services.botGroups.allSessions.contains { $0.messages.contains { $0.id == queued.id } })
    #expect(messaging.jobs.first(where: { $0.id == queued.id })?.state == .queued)
    await services.shutdown()
  }

  @Test func feedbackIsThrottledDurableAndStops() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "messaging-feedback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    let (_, _, _, request) = try fixture(services, root: root)
    let adapter = MessagingTestAdapter()
    let messaging = MessagingService(
      services: services, adapter: adapter, secrets: MessagingTestSecrets(),
      url: root.appending(path: "state.json"))
    messaging.updateFeedback(active: request, now: request.createdAt)
    messaging.updateFeedback(active: request, now: request.createdAt.addingTimeInterval(7))
    #expect(adapter.signals == ["typingStart"])
    #expect(messaging.jobs.count == 1)
    messaging.updateFeedback(active: request, now: request.createdAt.addingTimeInterval(15))
    messaging.updateFeedback(active: request, now: request.createdAt.addingTimeInterval(16))
    #expect(adapter.signals == ["typingStart", "typingStart"])
    #expect(messaging.jobs.filter { $0.progressParentID == request.id }.count == 1)
    let restored = try MessagingStore(url: root.appending(path: "state.json"))
    try restored.enqueueProgress(for: request)
    #expect(restored.jobs.count == 2)
    messaging.updateFeedback(active: nil)
    messaging.updateFeedback(active: nil)
    #expect(adapter.signals.last == "typingStop")
    #expect(adapter.signals.count == 3)
    // No running team: reconciliation must cancel the unsent acknowledgement.
    messaging.tick()
    #expect(messaging.jobs.first { $0.progressParentID == request.id }?.state == .cancelled)
  }

  private func fixture(_ services: ApplicationServices, root: URL) throws -> (
    MessagingBinding, MessagingStore, UUID, MessagingJob
  ) {
    let lead = try services.saveAgentProfile(
      AgentProfile(name: "Lead", instructions: "Coordinate", provider: .codex))
    let worker = try services.saveAgentProfile(
      AgentProfile(name: "Worker", instructions: "Help", provider: .codex))
    let team = try services.botChannels.createGroupChannel(
      memberProfileIDs: [lead.id, worker.id], name: "Test", orchestratorProfileID: lead.id)
    var binding = MessagingBinding(
      accountID: "test-account", projectPath: root.path, teamID: team.id,
      coordinatorID: lead.id, expectedSender: "+15550001111", destination: "+15550002222")
    binding.sender = binding.expectedSender
    binding.conversation = "test-chat"
    let state = try MessagingStore(url: root.appending(path: "state.json"))
    try state.configure(binding)
    _ = try state.accept(
      MessagingInbound(
        accountID: binding.accountID, eventID: "A", conversation: "test-chat",
        sender: binding.expectedSender, destination: binding.destination, isDirect: true,
        text: "Phone A", unsupported: false))
    var request = try #require(state.jobs.first)
    request.state = .running
    try state.update(request)
    let session = try services.botGroups.beginTurn(
      members: team.memberProfileIDs, channelID: binding.roomID, mentioned: [])
    _ = try services.botGroups.recordUserMessage(
      sessionID: session.id, text: request.text, messageID: request.id)
    return (binding, state, session.id, request)
  }

}
