import CryptoKit
import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import Testing

@testable import OttoServices

/// Messages that arrive while the bot is still on an earlier one must not be lost (issue #41).
/// They queue per bot, the chat is told so, and each goes when the previous run ends. These tests
/// extend the media delivery suite so they run in series with it: both drive the real connector
/// against the globally registered fake Bot API.
extension TelegramMediaDeliveryTests {
  @Test("Messages sent while the bot is busy queue and go in order when each run ends")
  func busyBotQueuesMessages() async throws {
    let harness = try await TelegramQueueHarness.make(
      updates: TelegramQueueHarness.textUpdates(["first message"]))
    defer { harness.tearDown() }
    let bot = harness.bot
    let sent = "Sent to @\(bot.handle). Working…"
    let queued = "Queued behind the current task. I'll send it when @\(bot.handle) is free."

    try await waitUntil(timeout: .seconds(60), describe: harness.describe) {
      await harness.userPrompts() == ["first message"]
        && harness.api.sentMessages.filter { $0 == sent }.count == 1
        && harness.isWorking
    }
    // Two more arrive while the bot is on the first: both are acknowledged as waiting.
    harness.api.serve(
      TelegramQueueHarness.textUpdates(["second message", "third message"], from: 2))
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      harness.api.sentMessages.filter { $0 == queued }.count == 2
    }
    #expect(!harness.api.sentMessages.contains { $0.hasPrefix("Could not") })
    #expect(await harness.userPrompts() == ["first message"])
    #expect(harness.connector.queuedTexts(for: bot.id) == ["second message", "third message"])

    // The first run ends: the answer is relayed, then the second message goes, and only then.
    try harness.finishRun()
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      await harness.userPrompts() == ["first message", "second message"]
        && harness.api.sentMessages.filter { $0 == sent }.count == 2
    }
    let messages = harness.api.sentMessages
    let firstAnswer = try #require(messages.firstIndex(of: "Done"))
    let secondSend = try #require(messages.lastIndex(of: sent))
    #expect(firstAnswer < secondSend)
    #expect(harness.connector.queuedTexts(for: bot.id) == ["third message"])

    try harness.finishRun()
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      await harness.userPrompts() == ["first message", "second message", "third message"]
        && harness.api.sentMessages.filter { $0 == sent }.count == 3
    }
    try harness.finishRun()
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      harness.api.sentMessages.filter { $0 == "Done" }.count == 3
    }
    #expect(!harness.api.sentMessages.contains { $0.hasPrefix("Could not") })
    #expect(harness.api.sentMessages.filter { $0 == queued }.count == 2)
    #expect(harness.connector.queuedTexts(for: bot.id).isEmpty)
    await harness.shutdown()
  }

  @Test("Disconnecting drops what is waiting and sends nothing more to the chat")
  func disconnectDropsQueue() async throws {
    let harness = try await TelegramQueueHarness.make(
      updates: TelegramQueueHarness.textUpdates(["first message"]))
    defer { harness.tearDown() }
    let bot = harness.bot
    try await waitUntil(timeout: .seconds(60), describe: harness.describe) {
      await harness.userPrompts() == ["first message"] && harness.isWorking
    }
    harness.api.serve(TelegramQueueHarness.textUpdates(["second message"], from: 2))
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      harness.connector.queuedTexts(for: bot.id) == ["second message"]
        && harness.api.sentMessages.contains { $0.hasPrefix("Queued behind") }
    }
    await harness.connector.disconnect()
    #expect(harness.connector.queuedTexts(for: bot.id).isEmpty)
    let sentBefore = harness.api.sentMessages.count

    // Freeing the bot afterwards changes nothing: the queue and its pump are gone, and the run's
    // answer is not relayed through the disconnected chat.
    try harness.finishRun()
    try await Task.sleep(for: .seconds(3))
    #expect(await harness.userPrompts() == ["first message"])
    #expect(harness.api.sentMessages.count == sentBefore)
    await harness.shutdown()
  }

  @Test("A message the bot cannot take is bounced on its own; the next one is still tried")
  func failedSendDoesNotBlockTheQueue() async throws {
    // The bot's node asks to resume a shell session, which the shell adapter refuses, so every
    // send fails the way a bot whose provider cannot launch does, without starting anything.
    let harness = try await TelegramQueueHarness.make(
      updates: TelegramQueueHarness.textUpdates(["first message", "second message"]),
      launchable: false)
    defer { harness.tearDown() }
    let bot = harness.bot
    func bounced(_ text: String) -> String {
      "Could not deliver “\(text)” to @\(bot.handle). Open Otto on your Mac to check the bot, then send it again."
    }
    try await waitUntil(timeout: .seconds(60), describe: harness.describe) {
      harness.api.sentMessages.contains(bounced("first message"))
        && harness.api.sentMessages.contains(bounced("second message"))
    }
    #expect(!harness.api.sentMessages.contains { $0.hasPrefix("Queued behind") })
    #expect(!harness.api.sentMessages.contains { $0.hasPrefix("Sent to") })
    #expect(harness.connector.queuedTexts(for: bot.id).isEmpty)

    // A later message is tried on its own too, not refused behind the earlier failures.
    harness.api.serve(TelegramQueueHarness.textUpdates(["third message"], from: 3))
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      harness.api.sentMessages.contains(bounced("third message"))
    }
    #expect(!harness.api.sentMessages.contains { $0.hasPrefix("Queued behind") })
    #expect(harness.connector.queuedTexts(for: bot.id).isEmpty)
    await harness.shutdown()
  }
}

extension TelegramMediaDeliveryTests {
  @Test("The bot's turn carries the Telegram channel header; the Mac chat shows the text")
  func channelHeaderReachesTheBot() async throws {
    let harness = try await TelegramQueueHarness.make(updates: TelegramQueueHarness.textUpdates([]))
    defer { harness.tearDown() }
    // The fixture bot is a shell, whose input is never wrapped in context, so record the one-turn
    // context Otto hands the provider instead of reading it back from the shell.
    let handed = HandedChannelContext()
    await harness.services.supervisor.setTurnContextProvider {
      [weak services = harness.services] id, _ in
      await handed.record(await services?.takeNextTurnContext(nodeID: id))
      return nil
    }
    harness.api.serve(TelegramQueueHarness.textUpdates(["what is on today"]))
    try await waitUntil(timeout: .seconds(60), describe: harness.describe) {
      await harness.userPrompts() == ["what is on today"]
        && harness.providerInput.contains("what is on today")
    }
    let context = await handed.values.compactMap { $0 }.joined(separator: "\n")
    #expect(
      context.contains(
        ChatChannelReplyFormatter.inboundHeader(channel: .telegram, sender: "Max")))
    #expect(!harness.providerInput.contains("[Otto · via Telegram"))
    try harness.finishRun()
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      harness.api.sentMessages.contains("Done")
    }
    await harness.shutdown()
  }

  @Test("A run that outlasts the wait sends its answer later; the next message still goes after")
  func lateAnswerArrivesAndQueueContinues() async throws {
    let harness = try await TelegramQueueHarness.make(
      updates: TelegramQueueHarness.textUpdates(["first message"]), followWindow: 2)
    defer { harness.tearDown() }
    let bot = harness.bot
    let sent = "Sent to @\(bot.handle). Working…"
    let still = TelegramConnector.stillWorkingReply
    func late(_ request: String) -> String {
      TelegramConnector.lateAnswerPrefix(for: request) + "\n\nDone"
    }

    try await waitUntil(timeout: .seconds(60), describe: harness.describe) {
      harness.api.sentMessages.contains(still) && harness.isWorking
    }
    #expect(harness.connector.isFollowingLate(bot.id))
    #expect(!harness.api.sentMessages.contains("Done"))

    // A second message arrives while the late follow is on: it waits behind the run.
    harness.api.serve(TelegramQueueHarness.textUpdates(["second message"], from: 2))
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      harness.connector.queuedTexts(for: bot.id) == ["second message"]
        && harness.api.sentMessages.contains { $0.hasPrefix("Queued behind") }
    }
    try await Task.sleep(for: .seconds(1))
    #expect(await harness.userPrompts() == ["first message"])

    // The first run ends: its answer arrives labelled as the earlier request's, then the second
    // message goes.
    try harness.finishRun()
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      await harness.userPrompts() == ["first message", "second message"]
        && harness.api.sentMessages.filter { $0 == sent }.count == 2
    }
    var messages = harness.api.sentMessages
    let firstLate = try #require(messages.firstIndex(of: late("first message")))
    #expect(firstLate < (try #require(messages.lastIndex(of: sent))))
    #expect(!messages.contains("Done"))

    // The second run also outlasts the wait; its late answer names the second message only.
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      harness.api.sentMessages.filter { $0 == still }.count == 2
    }
    try harness.finishRun()
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      harness.api.sentMessages.contains(late("second message"))
    }
    messages = harness.api.sentMessages
    #expect(messages.filter { $0 == late("first message") }.count == 1)
    #expect(messages.filter { $0.hasPrefix("Here's the answer") }.count == 2)
    try await waitUntil(timeout: .seconds(10), describe: harness.describe) {
      !harness.connector.isFollowingLate(bot.id)
    }
    await harness.shutdown()
  }

  @Test("Stopping the connector ends a late follow without sending anything more")
  func stopEndsLateFollow() async throws {
    let harness = try await TelegramQueueHarness.make(
      updates: TelegramQueueHarness.textUpdates(["first message"]), followWindow: 2)
    defer { harness.tearDown() }
    try await waitUntil(timeout: .seconds(60), describe: harness.describe) {
      harness.api.sentMessages.contains(TelegramConnector.stillWorkingReply)
    }
    harness.connector.stop()
    #expect(!harness.connector.isFollowingLate(harness.bot.id))
    let sentBefore = harness.api.sentMessages.count
    try harness.finishRun()
    try await Task.sleep(for: .seconds(3))
    #expect(harness.api.sentMessages.count == sentBefore)
    await harness.shutdown()
  }
}

/// One allowed bot whose node is a plain shell, so the test runs on Macs without Codex or Claude
/// Code. When launchable, the shell stays busy after each prompt until the test ends the run by
/// creating a file. Otherwise the node has never run and cannot be launched.
@MainActor
struct TelegramQueueHarness {
  let root: URL
  let services: ApplicationServices
  let bot: AgentProfile
  let node: UUID
  let connector: TelegramConnector
  let api: FakeBotAPI
  let defaults: UserDefaults
  let suite: String

  static let chatID: Int64 = 123

  static func make(
    updates: String, launchable: Bool = true, followWindow: TimeInterval? = nil
  ) async throws -> TelegramQueueHarness {
    let root = FileManager.default.temporaryDirectory.appending(path: "tg-queue-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    let bot = try services.createBot(BotCreationRequest(name: "Scout", responsibility: "Help"))
    try services.connectorAccess.setAllowed(true, profileID: bot.id, for: .telegram)
    let node = try await shellNode(for: bot, in: services, root: root, launchable: launchable)

    let suite = "TelegramQueue-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let hash = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }
      .joined().prefix(24)
    defaults.set(NSNumber(value: chatID), forKey: "otto.telegram.\(hash).chat")

    // A token of its own, so a poll left over from another connector is never answered.
    let api = FakeBotAPI(
      token: "\(Int.random(in: 100_000...999_999)):zyxwvutsrqponmlkjihgfedcba", updates: updates)
    FakeBotAPI.current = api
    URLProtocol.registerClass(FakeBotAPIProtocol.self)

    let connector = TelegramConnector(
      services: services, secrets: InMemorySecretStore(), defaults: defaults)
    if let followWindow { connector.followWindow = followWindow }
    await connector.connect(token: api.token)
    #expect(connector.username == "ottotestbot")
    return TelegramQueueHarness(
      root: root, services: services, bot: bot, node: node, connector: connector, api: api,
      defaults: defaults, suite: suite)
  }

  /// The bot's node, tagged with the bot so opening the bot reuses it. A node that is not
  /// launchable asks to resume a shell session: the shell adapter refuses that, so a send to it
  /// fails on restart before any process starts.
  private static func shellNode(
    for bot: AgentProfile, in services: ApplicationServices, root: URL, launchable: Bool
  ) async throws -> UUID {
    let node = try #require(
      services.store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
        .affectedNodeIDs.first)
    services.store.dispatch(
      .setAgentDefinition(
        id: node,
        definition: AgentDefinition(
          provider: .shell, workingDirectory: root.path, launchCommand: "/bin/sh",
          permissionMode: "workspaceWrite", resumeSessionID: launchable ? nil : "stale",
          profileID: bot.id)))
    _ = try services.botChannels.bindNode(profileID: bot.id, nodeID: node)
    guard launchable else { return node }
    // The shell drains prompts in the foreground (a background job's stdin would be /dev/null and
    // the PTY write would stall); a watcher ends the run when the finish file appears and exits
    // with the shell so no loop outlives the test.
    let finish = root.appending(path: "finish").path
    let script = """
      ( while kill -0 "$$" 2>/dev/null; do
          if [ -f '\(finish)' ]; then
            rm -f '\(finish)'
            printf 'OTTO_RESULT:Done\\r\\n'
            printf 'OTTO_STATUS:DONE\\r\\n'
          fi
          sleep 0.1
        done ) &
      printf 'OTTO_STATUS:IDLE\\r\\n'
      while IFS= read -r line; do printf '%s\n' "$line" >> '\(root.appending(path: "stdin.log").path)'; done
      """
    _ = try await services.supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh", arguments: ["-c", script], environment: ["NO_COLOR": "1"],
        workingDirectory: root.path), id: node)
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline,
      try await services.supervisor.snapshot(agentID: node).state != .idle
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    return node
  }

  /// The paired person's text messages, in one poll, in this order.
  static func textUpdates(_ texts: [String], from firstID: Int = 1) -> String {
    let items = texts.enumerated().map { index, text in
      """
      {"update_id":\(firstID + index),"message":{"message_id":\(firstID + index + 10),
        "chat":{"id":\(chatID),"type":"private"},
        "from":{"id":\(chatID),"is_bot":false,"first_name":"Max"},
        "text":"\(text)"}}
      """
    }
    return #"{"ok":true,"result":["# + items.joined(separator: ",") + "]}"
  }

  /// Ends the bot's current run; the shell reports a result and DONE within a moment.
  func finishRun() throws {
    try Data().write(to: root.appending(path: "finish"))
  }

  /// Everything the bot's process has been sent, as it received it.
  var providerInput: String {
    (try? String(contentsOf: root.appending(path: "stdin.log"), encoding: .utf8)) ?? ""
  }

  /// Whether the connector would see the bot as busy: its fleet snapshot is on a run.
  var isWorking: Bool {
    services.fleetStore.snapshot(for: node)?.state == .working
  }

  /// What the bot has been asked so far, in order.
  func userPrompts() async -> [String] {
    guard let snapshot = try? await services.supervisor.snapshot(agentID: node) else { return [] }
    return snapshot.transcript.filter { $0.role == .user }.map(\.text)
  }

  var describe: String {
    "status: \(connector.status); sent: \(api.sentMessages); polls: \(api.polls)"
  }

  func shutdown() async {
    connector.stop()
    await services.shutdown()
  }

  func tearDown() {
    URLProtocol.unregisterClass(FakeBotAPIProtocol.self)
    FakeBotAPI.current = nil
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
}

private actor HandedChannelContext {
  private(set) var values: [String?] = []
  func record(_ value: String?) { values.append(value) }
}
