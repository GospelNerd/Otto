import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import Testing

@testable import OttoServices

@Suite("Telegram connector command and safety rules")
struct TelegramConnectorTests {
  @Test("Bot commands route to saved Otto bots without granting approval")
  func commands() {
    #expect(TelegramCommand.parse("/start") == .help)
    #expect(TelegramCommand.parse("/help") == .help)
    #expect(TelegramCommand.parse("/bots") == .bots)
    #expect(TelegramCommand.parse("/use @Engineer") == .use("@Engineer"))
    #expect(
      TelegramCommand.parse("/bot @Engineer please review") == .send("@Engineer", "please review"))
    #expect(TelegramCommand.parse("Hi there") == .message("Hi there"))
    #expect(TelegramCommand.parse("/pair code123") == .pair("code123"))
    #expect(TelegramCommand.parse("/bots@OttoDeskBot", addressedTo: "ottodeskbot") == .bots)
    #expect(TelegramCommand.parse("/bots@OtherBot", addressedTo: "ottodeskbot") == nil)
    #expect(TelegramCommand.parse("/approve") == nil)
    #expect(TelegramCommand.parse("/bot") == nil)
    #expect(TelegramCommand.parse("") == nil)
    #expect(TelegramCommand.parse(String(repeating: "X", count: 4_001)) == nil)
  }

  private static func profile(_ name: String) -> AgentProfile {
    AgentProfile(name: name, instructions: "Help", provider: .codex)
  }

  @Test("A bot's handle is the letters and digits of its name, so names with punctuation work")
  func handleDerivation() {
    #expect(AgentProfile.handle(from: "CEO (ALL AUTOMATED WORK)") == "ceoallautomatedwork")
    #expect(AgentProfile.handle(from: "Instagram (100k company)") == "instagram100kcompany")
    #expect(AgentProfile.handle(from: "  Ângela Désk ") == "angeladesk")
    #expect(AgentProfile.handle(from: "🤖") == "bot")
    // Typing the name, the handle, or either with an @ keys to the same handle.
    for typed in ["Instagram (100k company)", "@instagram100kcompany", "INSTAGRAM 100K COMPANY"] {
      #expect(TelegramBotRouting.key(typed) == "instagram100kcompany")
    }
    #expect(TelegramBotRouting.key("@") == "")
  }

  @Test("Addressing forgives the @, the case, and accepts a name or a unique start of one")
  func forgivingAddressing() {
    let ceo = Self.profile("CEO (ALL AUTOMATED WORK)")
    let instagram = Self.profile("Instagram (100k company)")
    let intern = Self.profile("Intern")
    let bots = [ceo, instagram, intern]
    for typed in [
      "@instagram100kcompany", "instagram100kcompany", "Instagram100kCompany", "instagram",
      "Instagram (100k company)", "@Instagram (100k company)", "insta",
    ] {
      #expect(TelegramBotRouting.match(typed, in: bots) == .bot(instagram), "\(typed)")
    }
    #expect(TelegramBotRouting.match("@ceo", in: bots) == .bot(ceo))
    #expect(TelegramBotRouting.match("CEO", in: bots) == .bot(ceo))
    #expect(TelegramBotRouting.match("intern", in: bots) == .bot(intern))
    #expect(TelegramBotRouting.match("in", in: bots) == .ambiguous([instagram, intern]))
    #expect(TelegramBotRouting.match("company", in: bots) == .none)
    #expect(TelegramBotRouting.match("", in: bots) == .none)
    #expect(TelegramBotRouting.match("@", in: bots) == .none)
    #expect(TelegramBotRouting.match("instagram", in: []) == .none)
    // Two names that fold to one handle are never guessed between.
    let twin = Self.profile("Intern!")
    #expect(TelegramBotRouting.match("intern", in: [intern, twin]) == .ambiguous([intern, twin]))

    // Bare @mentions in ordinary text only count when they are a whole handle or name, so a
    // message about Max is never hijacked by Max's assistant, and a start several bots share
    // is plain text, not an ambiguity.
    let assistant = Self.profile("Max's assistant")
    #expect(assistant.handle == "maxsassistant")
    #expect(TelegramBotRouting.exactMatch("@maxsassistant", in: [assistant, intern]) == assistant)
    #expect(TelegramBotRouting.exactMatch("Max's assistant", in: [assistant, intern]) == assistant)
    #expect(TelegramBotRouting.exactMatch("max", in: [assistant, intern]) == nil)
    #expect(TelegramBotRouting.exactMatch("in", in: [instagram, intern]) == nil)
    #expect(TelegramBotRouting.exactMatch("intern", in: [intern, twin]) == nil)
    #expect(TelegramBotRouting.exactMatch("", in: bots) == nil)
  }

  @Test("A leading @mention addresses a bot like /bot does; mentions elsewhere are plain text")
  func leadingMentions() throws {
    let mention = try #require(TelegramCommand.leadingMention(in: "@instagram plan a post"))
    #expect(mention.handle == "instagram")
    #expect(mention.text == "plan a post")
    let punctuated = try #require(TelegramCommand.leadingMention(in: " @Instagram, plan a post "))
    #expect(punctuated.handle == "Instagram")
    #expect(punctuated.text == "plan a post")
    let alone = try #require(TelegramCommand.leadingMention(in: "@ceo"))
    #expect(alone.handle == "ceo")
    #expect(alone.text == "")
    #expect(TelegramCommand.leadingMention(in: "ask @instagram about it") == nil)
    #expect(TelegramCommand.leadingMention(in: "@") == nil)
    #expect(TelegramCommand.leadingMention(in: "@ hello") == nil)
    #expect(TelegramCommand.leadingMention(in: "hello") == nil)
    // Parsing is unchanged: the mention arrives as an ordinary message and the connector
    // decides whether it names an allowed bot.
    #expect(TelegramCommand.parse("@instagram plan a post") == .message("@instagram plan a post"))
    #expect(TelegramCommand.parse("/use instagram") == .use("instagram"))
    #expect(
      TelegramCommand.parse("/use Instagram (100k company)") == .use("Instagram (100k company)"))
  }

  @Test("/bots names saved bots the owner has not allowed, and a miss shows the list")
  func botsReplyExplainsMissingBots() {
    let ceo = Self.profile("CEO (ALL AUTOMATED WORK)")
    let instagram = Self.profile("Instagram (100k company)")
    let intern = Self.profile("Intern")

    let one = TelegramBotRouting.botsReply(allowed: [ceo], notAllowed: [instagram], current: ceo.id)
    #expect(
      one.hasPrefix("Otto bots you can reach:\n• @ceoallautomatedwork — CEO (ALL AUTOMATED WORK)\n")
    )
    #expect(
      one.hasSuffix(
        "1 more bot is not allowed for Telegram yet: Instagram (100k company). Allow it in Otto → Settings → Connectors → Telegram."
      ))
    #expect(!one.contains("@instagram100kcompany"))

    let two = TelegramBotRouting.botsReply(
      allowed: [ceo], notAllowed: [instagram, intern], current: nil)
    #expect(two.contains("  @ceoallautomatedwork — CEO (ALL AUTOMATED WORK)"))
    #expect(
      two.hasSuffix(
        "2 more bots are not allowed for Telegram yet: Instagram (100k company), Intern. Allow them in Otto → Settings → Connectors → Telegram."
      ))

    let all = TelegramBotRouting.botsReply(
      allowed: [ceo, instagram], notAllowed: [], current: instagram.id)
    #expect(
      all.contains(
        "  @ceoallautomatedwork — CEO (ALL AUTOMATED WORK)\n• @instagram100kcompany — Instagram (100k company)"
      ))
    #expect(!all.contains("not allowed"))

    let none = TelegramBotRouting.botsReply(
      allowed: [], notAllowed: [ceo, instagram], current: nil)
    #expect(
      none.hasPrefix(
        "No Otto bot is allowed on Telegram yet. Allow one in Otto → Settings → Connectors → Telegram."
      ))
    #expect(none.hasSuffix("Saved bots: CEO (ALL AUTOMATED WORK), Instagram (100k company)."))

    let miss = TelegramBotRouting.unmatchedReply(
      "@instagram", match: .none, allowed: [ceo], notAllowed: [instagram], current: ceo.id)
    #expect(
      miss?.hasPrefix("No allowed Otto bot matches “@instagram”.\n\nOtto bots you can reach:")
        == true)
    #expect(
      miss?.contains("1 more bot is not allowed for Telegram yet: Instagram (100k company).")
        == true)
    let ambiguous = TelegramBotRouting.unmatchedReply(
      "in", match: .ambiguous([instagram, intern]), allowed: [ceo, instagram, intern],
      notAllowed: [], current: nil)
    #expect(
      ambiguous
        == "“in” could be @instagram100kcompany (Instagram (100k company)), @intern (Intern). Type more of the name."
    )
    #expect(
      TelegramBotRouting.unmatchedReply(
        "ceo", match: .bot(ceo), allowed: [ceo], notAllowed: [], current: nil) == nil)
    #expect(
      TelegramBotRouting.switchedReply(to: instagram)
        == "This chat now talks to @instagram100kcompany (Instagram (100k company)).")
  }

  @Test("Only real human senders in private chats or groups may be considered for pairing")
  func privateAndGroupHumans() throws {
    let privateMessage = """
      {"message_id":1,"chat":{"id":123,"type":"private"},
       "from":{"id":123,"is_bot":false},"text":"/bots"}
      """
    let decoder = JSONDecoder()
    let valid = try decoder.decode(TelegramIncomingMessage.self, from: Data(privateMessage.utf8))
    #expect(valid.isPrivateHuman)
    #expect(!valid.isGroupHuman)
    let groupMessage =
      privateMessage
      .replacingOccurrences(of: "private", with: "supergroup")
      .replacingOccurrences(of: #""id":123,"type""#, with: #""id":-100123,"type""#)
    let groupValid = try decoder.decode(
      TelegramIncomingMessage.self, from: Data(groupMessage.utf8))
    #expect(groupValid.isGroupHuman)
    #expect(groupValid.isAuthorized(privateChatID: nil, groupChatID: -100123, groupSenderID: 123))
    #expect(!groupValid.isAuthorized(privateChatID: 123, groupChatID: -100123, groupSenderID: 999))
    #expect(!groupValid.isAuthorized(privateChatID: 123, groupChatID: -200, groupSenderID: 123))
    #expect(!groupValid.isAuthorized(privateChatID: 123, groupChatID: nil, groupSenderID: nil))
    #expect(valid.isAuthorized(privateChatID: 123, groupChatID: nil, groupSenderID: nil))
    #expect(!valid.isAuthorized(privateChatID: 999, groupChatID: -100123, groupSenderID: 123))
    #expect(
      !groupValid.isPrivateHuman)
    let spoofed = privateMessage.replacingOccurrences(
      of: #""id":123,"is_bot":false"#,
      with: #""id":999,"is_bot":false"#)
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(spoofed.utf8)
      ).isPrivateHuman)
    let automated = privateMessage.replacingOccurrences(of: "false", with: "true")
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(automated.utf8)
      ).isPrivateHuman)
    let botGroup = groupMessage.replacingOccurrences(of: "false", with: "true")
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(botGroup.utf8)
      ).isGroupHuman)
    let anonymousAdmin = groupMessage.replacingOccurrences(
      of: #""from":{"id":123,"is_bot":false}"#,
      with: #""from":{"id":123,"is_bot":false},"sender_chat":{"id":-100123,"type":"supergroup"}"#)
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(anonymousAdmin.utf8)
      ).isGroupHuman)
    let spoofedGroup = groupMessage.replacingOccurrences(
      of: #""type":"supergroup""#, with: #""type":"private""#)
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(spoofedGroup.utf8)
      ).isGroupHuman)
  }

  @Test("Reject malformed BotFather tokens before any network request")
  func tokenValidation() {
    for value in ["", "123", "bot-invalid", "1234:too-short", "abc:token", "12345:bad/path/secret"]
    {
      #expect(throws: TelegramConnectionError.self) {
        _ = try TelegramBotTransport(token: value)
      }
    }
    #expect(throws: Never.self) {
      _ = try TelegramBotTransport(token: "123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567")
    }
  }

  @Test("A voice note is read as a recording only when the message has no text")
  func voiceNotes() throws {
    let voice = """
      {"message_id":7,"chat":{"id":123,"type":"private"},"from":{"id":123,"is_bot":false},
       "voice":{"file_id":"AwACAgQ","file_unique_id":"x","duration":23,"mime_type":"audio/ogg",
       "file_size":41000},"caption":"for the release"}
      """
    let message = try JSONDecoder().decode(TelegramIncomingMessage.self, from: Data(voice.utf8))
    #expect(message.recording?.fileID == "AwACAgQ")
    #expect(message.recording?.duration == 23)
    #expect(message.caption == "for the release")
    let texted = voice.replacingOccurrences(of: #""caption""#, with: #""text""#)
    let withText = try JSONDecoder().decode(
      TelegramIncomingMessage.self, from: Data(texted.utf8))
    #expect(withText.recording == nil)
  }

  @Test("Approval taps carry a one-time token, never the request itself")
  func approvalButtons() throws {
    let token = TelegramApprovalAnswer.makeToken()
    #expect(token.count == 32)
    #expect(TelegramApprovalAnswer.makeToken() != token)
    #expect(TelegramApprovalAnswer.parse("ok:\(token)") == .approve(token))
    #expect(TelegramApprovalAnswer.parse("no:\(token)") == .deny(token))
    #expect(TelegramApprovalAnswer.parse("ok:\(token.uppercased())") == nil)
    #expect(TelegramApprovalAnswer.parse("ok:short") == nil)
    #expect(TelegramApprovalAnswer.parse("yes:\(token)") == nil)
    #expect(TelegramApprovalAnswer.parse(nil) == nil)

    let update = """
      {"update_id":9,"callback_query":{"id":"cb1","from":{"id":123,"is_bot":false},
       "message":{"message_id":44,"chat":{"id":123,"type":"private"}},"data":"ok:\(token)"}}
      """
    let decoded = try JSONDecoder().decode(TelegramUpdate.self, from: Data(update.utf8))
    #expect(decoded.message == nil)
    #expect(decoded.callbackQuery?.from.id == 123)
    #expect(decoded.callbackQuery?.message?.messageID == 44)
    #expect(TelegramApprovalAnswer.parse(decoded.callbackQuery?.data) == .approve(token))
  }

  @Test("Website account approvals stay on the Mac and never get Telegram buttons")
  func accountApprovalsStayOnMac() {
    func pending(_ toolName: String, reason: String) -> AgentPendingPermission {
      AgentPendingPermission(
        requestID: UUID(), runID: UUID(), reason: reason, nonce: "n", requestedAt: .now,
        toolName: toolName)
    }
    #expect(
      !TelegramConnector.isAnswerableOnTelegram(
        pending("Website account click", reason: "Website account click: Buy now")))
    #expect(
      !TelegramConnector.isAnswerableOnTelegram(
        pending("Connect website", reason: "Connect website: Allow Max to use example.com?")))
    // The tool decides, not the text: a look-alike reason from another tool is unaffected, and
    // an account click is held back however its reason reads.
    #expect(
      TelegramConnector.isAnswerableOnTelegram(
        pending("Bash", reason: "Website account click: rm -rf build")))
    #expect(
      !TelegramConnector.isAnswerableOnTelegram(
        pending("Website account click", reason: "Wants to use Read")))
    #expect(TelegramConnector.isAnswerableOnTelegram(pending("Write", reason: "Write: notes.md")))
  }
}

/// The connector reads the bot list and the owner's grants live, so a bot created or allowed
/// in Settings is reachable from Telegram without reconnecting or restarting Otto.
@MainActor
@Suite("Telegram sees new and newly allowed bots", .serialized)
struct TelegramConnectorBotListTests {
  @Test("A bot allowed after the connector started appears in /bots and resolves")
  func newlyAllowedBotAppears() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "tg-bots-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    let suite = "TelegramConnectorBotList-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let connector = TelegramConnector(
      services: services, secrets: InMemorySecretStore(), defaults: defaults)

    #expect(connector.bots.isEmpty)
    #expect(connector.botsReply(for: 1).hasPrefix("No Otto bot is allowed on Telegram yet."))

    let ceo = try services.createBot(
      BotCreationRequest(name: "CEO (ALL AUTOMATED WORK)", responsibility: "Run the company"))
    try services.connectorAccess.setAllowed(true, profileID: ceo.id, for: .telegram)
    let instagram = try services.createBot(
      BotCreationRequest(name: "Instagram (100k company)", responsibility: "Post"))

    // The second bot exists but is not allowed: /bots says so by name, and nothing resolves to it.
    #expect(connector.bots.map(\.id) == [ceo.id, instagram.id])
    #expect(connector.allowedBots.map(\.id) == [ceo.id])
    let before = connector.botsReply(for: 1)
    #expect(before.contains("• @ceoallautomatedwork — CEO (ALL AUTOMATED WORK)"))
    #expect(
      before.contains("1 more bot is not allowed for Telegram yet: Instagram (100k company)."))
    #expect(
      connector.unmatchedReply("instagram", for: 1).hasPrefix(
        "No allowed Otto bot matches “instagram”."))

    try services.connectorAccess.setAllowed(true, profileID: instagram.id, for: .telegram)
    #expect(connector.allowedBots.map(\.id) == [ceo.id, instagram.id])
    let after = connector.botsReply(for: 1)
    #expect(after.contains("  @instagram100kcompany — Instagram (100k company)"))
    #expect(!after.contains("not allowed"))

    // Bare @mentions route only on a whole handle. "@max said we ship Friday" is about Max and
    // goes to the chat's bot unchanged; "@in" alone, which two bots start with, is plain text.
    let assistant = try services.createBot(
      BotCreationRequest(name: "Max's assistant", responsibility: "Assist"))
    try services.connectorAccess.setAllowed(true, profileID: assistant.id, for: .telegram)
    let intern = try services.createBot(BotCreationRequest(name: "Intern", responsibility: "Learn"))
    try services.connectorAccess.setAllowed(true, profileID: intern.id, for: .telegram)
    #expect(connector.allowedBots.map(\.handle).contains("maxsassistant"))
    #expect(connector.mentionedBot(in: "@max said we ship Friday") == nil)
    #expect(connector.mentionedBot(in: "@in") == nil)
    #expect(connector.mentionedBot(in: "@in hello") == nil)
    let routed = try #require(connector.mentionedBot(in: "@maxsassistant what's next"))
    #expect(routed.bot.id == assistant.id)
    #expect(routed.text == "what's next")
    let alone = try #require(connector.mentionedBot(in: "@Intern"))
    #expect(alone.bot.id == intern.id)
    #expect(alone.text == "")
    // The explicit commands still accept a unique start of a name.
    #expect(TelegramBotRouting.match("maxs", in: connector.allowedBots) == .bot(assistant))
    #expect(connector.unmatchedReply("in", for: 1).hasPrefix("“in” could be"))

    try services.connectorAccess.setAllowed(false, profileID: ceo.id, for: .telegram)
    #expect(connector.allowedBots.map(\.id) == [instagram.id, intern.id, assistant.id])
    #expect(
      connector.botsReply(for: 1).contains(
        "1 more bot is not allowed for Telegram yet: CEO (ALL AUTOMATED WORK)."))
    await services.shutdown()
  }
}
