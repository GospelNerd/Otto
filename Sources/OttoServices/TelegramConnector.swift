import Combine
import CryptoKit
import Foundation
import OttoModels
import OttoRuntime
import OttoSecurity

// Telegram's token is part of its mandated Bot API URL. Never log the full URL,
// any URLSession error (which can contain it), or the raw response body.
public struct TelegramIncomingMessage: Codable, Sendable {
  public struct Peer: Codable, Sendable {
    public let id: Int64
    public let type: String?
  }
  public struct Sender: Codable, Sendable {
    public let id: Int64
    public let isBot: Bool?
    public let firstName: String?
    public let lastName: String?
    public let username: String?
    enum CodingKeys: String, CodingKey {
      case id
      case isBot = "is_bot"
      case firstName = "first_name"
      case lastName = "last_name"
      case username
    }

    public init(
      id: Int64, isBot: Bool?, firstName: String? = nil, lastName: String? = nil,
      username: String? = nil
    ) {
      self.id = id
      self.isBot = isBot
      self.firstName = firstName
      self.lastName = lastName
      self.username = username
    }

    /// The name Telegram shows for this person: first and last name, else @username.
    public var displayName: String? {
      let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { return name }
      return username.map { "@\($0)" }
    }
  }
  /// A voice note or audio file. Only its Bot API handle is kept; Otto downloads the bytes
  /// once the sender is known to be paired.
  public struct Audio: Codable, Sendable, Equatable {
    public let fileID: String
    public let duration: Int?
    public let fileSize: Int?
    enum CodingKeys: String, CodingKey {
      case fileID = "file_id"
      case duration
      case fileSize = "file_size"
    }
  }
  /// One size of a photo. Telegram sends several, smallest first.
  public struct PhotoSize: Codable, Sendable, Equatable {
    public let fileID: String
    public let width: Int
    public let height: Int
    public let fileSize: Int?
    enum CodingKeys: String, CodingKey {
      case fileID = "file_id"
      case width, height
      case fileSize = "file_size"
    }
  }
  /// A video, round video note, GIF-style animation or file. Only its Bot API handle is kept.
  public struct File: Codable, Sendable, Equatable {
    public let fileID: String
    public let duration: Int?
    public let fileSize: Int?
    public let mimeType: String?
    public let fileName: String?
    enum CodingKeys: String, CodingKey {
      case fileID = "file_id"
      case duration
      case fileSize = "file_size"
      case mimeType = "mime_type"
      case fileName = "file_name"
    }
  }
  public let messageID: Int64
  public let chat: Peer
  public let from: Sender?
  public let senderChat: Peer?
  public let text: String?
  public let caption: String?
  public let voice: Audio?
  public let audio: Audio?
  public let photo: [PhotoSize]?
  public let video: File?
  public let videoNote: File?
  public let animation: File?
  public let document: File?
  /// Shared by the photos and videos of one album, which Telegram delivers as separate messages.
  public let mediaGroupID: String?
  enum CodingKeys: String, CodingKey {
    case messageID = "message_id"
    case chat, from, text, caption, voice, audio, photo, video, animation, document
    case senderChat = "sender_chat"
    case videoNote = "video_note"
    case mediaGroupID = "media_group_id"
  }

  /// The recording to transcribe when the message has no text of its own.
  public var recording: Audio? { text == nil ? voice ?? audio : nil }

  /// The photo or video this message carries, if any. A photo uses its largest size that the
  /// Bot API will serve; a file counts only when Telegram labels it as an image or a video.
  public var media: TelegramMedia? {
    if let photo {
      let servable = photo.filter { ($0.fileSize ?? 0) <= TelegramMedia.maxBytes }
      guard let best = servable.max(by: { $0.width * $0.height < $1.width * $1.height })
      else { return nil }
      return TelegramMedia(kind: .image, fileID: best.fileID, fileSize: best.fileSize)
    }
    if let file = video ?? videoNote ?? animation {
      return TelegramMedia(
        kind: .video, fileID: file.fileID, fileSize: file.fileSize, duration: file.duration)
    }
    if let document, let type = document.mimeType?.lowercased() {
      if type.hasPrefix("image/"), let ext = TelegramMedia.imageExtension(forMIMEType: type) {
        return TelegramMedia(
          kind: .image, fileID: document.fileID, fileSize: document.fileSize,
          fileExtension: ext)
      }
      if type.hasPrefix("video/") {
        return TelegramMedia(
          kind: .video, fileID: document.fileID, fileSize: document.fileSize,
          duration: document.duration)
      }
    }
    return nil
  }

  public var isPrivateHuman: Bool {
    chat.type == "private" && from?.id == chat.id && from?.isBot == false
  }

  /// The Otto header for this message's prompt: which chat it came through, from whom, and how to
  /// reply. Only the paired person's messages reach a bot (see `isAuthorized`), so the text after
  /// it stays an ordinary, trusted user message.
  public var channelHeader: String {
    ChatChannelReplyFormatter.inboundHeader(
      channel: .telegram, sender: from?.displayName, isGroup: !isPrivateHuman && isGroupHuman)
  }

  public var isGroupHuman: Bool {
    (chat.type == "group" || chat.type == "supergroup") && chat.id < 0
      && from?.isBot == false && senderChat == nil && from?.id != nil
  }

  public func isAuthorized(
    privateChatID: Int64?, groupChatID: Int64?, groupSenderID: Int64?
  ) -> Bool {
    if isPrivateHuman { return privateChatID != nil && privateChatID == chat.id }
    if isGroupHuman {
      return groupChatID != nil && groupChatID == chat.id
        && groupSenderID != nil && groupSenderID == from?.id
    }
    return false
  }
}

public struct TelegramUpdate: Codable, Sendable {
  public let updateID: Int64
  public let message: TelegramIncomingMessage?
  public let callbackQuery: TelegramCallbackQuery?
  enum CodingKeys: String, CodingKey {
    case updateID = "update_id"
    case message
    case callbackQuery = "callback_query"
  }
}

/// A tap on one of Otto's inline buttons, such as Approve under a tool approval.
public struct TelegramCallbackQuery: Codable, Sendable {
  public struct Origin: Codable, Sendable {
    public let messageID: Int64
    public let chat: TelegramIncomingMessage.Peer
    enum CodingKeys: String, CodingKey {
      case messageID = "message_id"
      case chat
    }
  }
  public let id: String
  public let from: TelegramIncomingMessage.Sender
  public let message: Origin?
  public let data: String?
}

/// Inline-button answers to a tool approval. The callback data names a short random token
/// rather than the request itself; the token maps to one request's ID and nonce on the Mac, is
/// accepted only from the paired person in the chat it was sent to, and works once.
public enum TelegramApprovalAnswer: Equatable, Sendable {
  case approve(String)
  case deny(String)

  public static func parse(_ data: String?) -> Self? {
    guard let data, data.count <= 64 else { return nil }
    let parts = data.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, parts[1].count == 32,
      parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { return nil }
    switch parts[0] {
    case "ok": return .approve(parts[1])
    case "no": return .deny(parts[1])
    default: return nil
    }
  }

  public var token: String {
    switch self {
    case .approve(let token), .deny(let token): token
    }
  }

  /// 16 bytes from the system's cryptographic generator, as 32 lowercase hex digits.
  public static func makeToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<16).map { _ in
      String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
    }.joined()
  }
}

public enum TelegramCommand: Equatable, Sendable {
  case help, bots
  case use(String)
  case send(String, String)
  case message(String)
  case pair(String)

  public static func parse(_ raw: String, addressedTo botUsername: String? = nil)
    -> TelegramCommand?
  {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 4_000 else { return nil }
    let split = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    let address = String(split[0]).split(separator: "@", maxSplits: 1)
    if address.count == 2 {
      guard let botUsername, address[1].caseInsensitiveCompare(botUsername) == .orderedSame
      else { return nil }
    }
    let first = String(address[0]).lowercased()
    let argument =
      split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    switch first {
    case "/start", "/help": return .help
    case "/bots": return .bots
    case "/use": return argument.isEmpty ? nil : .use(argument)
    case "/pair": return argument.isEmpty ? nil : .pair(argument)
    case "/bot":
      let values = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      guard values.count == 2 else { return nil }
      return .send(String(values[0]), String(values[1]))
    default: return text.hasPrefix("/") ? nil : .message(text)
    }
  }

  /// A Telegram-style mention at the start of a message: `@instagram look at this` names a bot
  /// the way `/bot @instagram look at this` does. The text after the mention may be empty.
  /// Whether the mention is an Otto bot is for the caller to decide; `@someone` in the middle of
  /// a sentence is never one.
  public static func leadingMention(in raw: String) -> (handle: String, text: String)? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("@") else { return nil }
    let split = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    let token = String(split[0].dropFirst())
    let handle = token.trimmingCharacters(in: CharacterSet(charactersIn: ",.:;!?"))
    guard !handle.isEmpty else { return nil }
    let rest =
      split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return (handle, rest)
  }
}

public enum TelegramConnectionError: Error, LocalizedError {
  case invalidToken, unavailable, notReady
  public var errorDescription: String? {
    switch self {
    case .invalidToken: "Enter a Telegram BotFather token in the format 123456:secret."
    case .unavailable:
      "Telegram Bot API unavailable. Check the bot token, network and webhook settings."
    case .notReady: "Otto and the selected bot must be running before sending messages."
    }
  }
}

private final class TelegramNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public actor TelegramBotTransport {
  private let token: String
  private let session: URLSession
  private let redirects = TelegramNoRedirects()

  public init(token: String, session: URLSession = .shared) throws {
    let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      candidate.range(
        of: #"^[0-9]{5,20}:[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil
    else { throw TelegramConnectionError.invalidToken }
    self.token = candidate
    self.session = session
  }

  private struct Envelope<Value: Decodable>: Decodable {
    let ok: Bool
    let result: Value?
  }

  private func call<Value: Decodable>(
    _ method: String, arguments: [String: Any]
  ) async throws -> Value {
    // The method is a fixed call site, not a user-supplied path or URL.
    let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)")!
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: arguments)
    // No redirects to other domains with a token-bearing request.
    do {
      let (data, response) = try await session.data(for: request, delegate: redirects)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        data.count < 4_000_000,
        let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data),
        envelope.ok, let result = envelope.result
      else { throw TelegramConnectionError.unavailable }
      return result
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw TelegramConnectionError.unavailable
    }
  }

  public func verify() async throws -> String {
    struct Bot: Decodable { let username: String? }
    let bot: Bot = try await call("getMe", arguments: [:])
    return bot.username ?? "Telegram bot"
  }

  public func updates(after offset: Int64) async throws -> [TelegramUpdate] {
    try await call(
      "getUpdates",
      arguments: [
        "offset": offset, "limit": 15, "timeout": 12,
        "allowed_updates": ["message", "callback_query"],
      ])
  }

  private struct Receipt: Decodable {
    let messageID: Int64
    enum CodingKeys: String, CodingKey { case messageID = "message_id" }
  }

  /// Sends one message with a row of inline buttons, each a title and its callback data.
  @discardableResult
  public func send(
    _ message: String, to chatID: Int64, buttons: [(title: String, data: String)]
  ) async throws -> Int64 {
    let receipt: Receipt = try await call(
      "sendMessage",
      arguments: [
        "chat_id": chatID, "text": String(message.prefix(3_500)),
        "disable_web_page_preview": true,
        "reply_markup": [
          "inline_keyboard": [buttons.map { ["text": $0.title, "callback_data": $0.data] }]
        ],
      ])
    return receipt.messageID
  }

  /// Replaces a message's text and removes its buttons, so an answered approval cannot be
  /// tapped again.
  public func edit(_ messageID: Int64, in chatID: Int64, text: String) async throws {
    let _: Receipt = try await call(
      "editMessageText",
      arguments: [
        "chat_id": chatID, "message_id": messageID, "text": String(text.prefix(3_500)),
        "disable_web_page_preview": true,
      ])
  }

  /// Stops the button's loading spinner and briefly shows `text`.
  public func answerCallback(_ id: String, text: String) async throws {
    let _: Bool = try await call(
      "answerCallbackQuery", arguments: ["callback_query_id": id, "text": text])
  }

  /// Downloads a file the bot received into a private temporary folder. The caller removes it.
  public func download(
    fileID: String, maxBytes: Int, named name: String = "recording",
    defaultExtension: String = "oga"
  ) async throws -> URL {
    struct File: Decodable {
      let filePath: String?
      let fileSize: Int?
      enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case fileSize = "file_size"
      }
    }
    let file: File = try await call("getFile", arguments: ["file_id": fileID])
    guard let path = file.filePath, (file.fileSize ?? 0) <= maxBytes,
      !path.contains(".."), !path.hasPrefix("/"),
      path.allSatisfy({ $0.isLetter || $0.isNumber || "/._-".contains($0) }),
      let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(path)")
    else { throw TelegramConnectionError.unavailable }
    do {
      let (data, response) = try await session.data(
        for: URLRequest(url: url, timeoutInterval: 60), delegate: redirects)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        !data.isEmpty, data.count <= maxBytes
      else { throw TelegramConnectionError.unavailable }
      let directory = FileManager.default.temporaryDirectory
        .appending(path: "otto-telegram-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let ext = (path as NSString).pathExtension
      let destination = directory.appending(
        path: "\(name).\((ext.isEmpty ? defaultExtension : ext).lowercased())")
      try data.write(to: destination, options: .atomic)
      return destination
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // URLSession errors can carry the token-bearing URL; never pass them on.
      throw TelegramConnectionError.unavailable
    }
  }

  /// Sends `message` as is, split into Telegram-sized pieces at paragraph or line breaks.
  public func send(_ message: String, to chatID: Int64) async throws {
    for part in ChatChannelReplyFormatter.chunks(message) where !part.isEmpty {
      let _: Receipt = try await call(
        "sendMessage",
        arguments: [
          "chat_id": chatID, "text": part, "disable_web_page_preview": true,
        ])
    }
  }
}

@MainActor
public final class TelegramConnector: ObservableObject {
  @Published public private(set) var status = "Not connected"
  @Published public private(set) var username: String?
  @Published public private(set) var pairingCode: String?
  @Published public private(set) var pendingChatID: Int64?
  @Published public private(set) var approvedChatID: Int64?
  @Published public private(set) var approvedGroupID: Int64?
  @Published public private(set) var approvedGroupSenderID: Int64?
  @Published public private(set) var pendingGroupID: Int64?
  @Published public private(set) var pendingGroupSenderID: Int64?
  @Published public private(set) var groupPairingCode: String?
  /// Off by default: the Mac owner opts in to answering tool approvals from the paired chat.
  @Published public private(set) var approvalsFromTelegram: Bool
  /// Set by the app: transcribes a voice note on this Mac. Nil leaves voice notes unsupported.
  public var transcribeRecording: (@Sendable (URL) async throws -> String)?

  private weak var services: ApplicationServices?
  private let secrets: any SecretStore
  private let defaults: UserDefaults
  private let prefix: String
  private var transport: TelegramBotTransport?
  private var pollTask: Task<Void, Never>?
  private var offset: Int64
  private var pendingSenderID: Int64?
  private var activeBotByChatID: [Int64: UUID] = [:]
  private var pairingExpiry: Date?
  private var groupPairingExpiry: Date?
  private let credentialKey: String
  private var pendingApprovals: [String: PendingApproval] = [:]
  /// Work for one message that outlives its poll, such as following a run or transcribing a
  /// voice note. Cancelled on stop, disconnect and before a new token connects.
  private var messageTasks: [UUID: Task<Void, Never>] = [:]
  /// Photos and videos of one album, collected until Telegram stops delivering them.
  private var pendingAlbums: [String: PendingAlbum] = [:]
  /// Messages waiting for each bot, oldest first. A bot takes one prompt per run, so what arrives
  /// while it is working waits here instead of being bounced (issue #41).
  private var queuedPrompts: [UUID: [QueuedPrompt]] = [:]
  /// Bots whose queue a task is working through, by that task's id. One per bot keeps order.
  private var queuePumps: [UUID: UUID] = [:]
  /// Bots with a run still being followed after the chat was told "Still working", by that
  /// follower's id. The queue holds the bot's next message until the follower has picked up the
  /// run's answer, so the late answer and the next one cannot be mixed up.
  private var lateFollows: [UUID: UUID] = [:]
  /// How long a run is followed before the chat hears that it is still working.
  var followWindow: TimeInterval = 120
  /// How long a run is then followed in the background for its late answer.
  var lateFollowWindow: TimeInterval = 4 * 3_600

  private struct PendingAlbum {
    var media: [TelegramMedia]
    var caption: String
    var generation: Int
  }

  private struct QueuedPrompt {
    let id = UUID()
    let text: String
    /// The channel header the bot sees with this turn only; the chat on the Mac shows `text`.
    let context: String?
    let chat: Int64
    let client: TelegramBotTransport
  }

  /// How following a run ended.
  enum FollowOutcome: Equatable {
    /// The chat has the answer, a question or approval notice, or nothing more is coming.
    case settled
    /// The wait ran out while the run, if it started, was still going.
    case stillRunning(runID: UUID?)
  }

  /// More than this many waiting messages for one bot are refused, not silently dropped.
  static let maxQueuedPrompts = 20

  /// One approval sent to Telegram, kept until it is answered, expires or the run moves on.
  private struct PendingApproval {
    let agentID: UUID
    let requestID: UUID
    let nonce: String
    let chat: Int64
    let messageID: Int64
    let text: String
    let expires: Date
  }

  static let pollingInterrupted = "Telegram polling interrupted. Retrying connection."
  /// Voice notes longer than this are not transcribed.
  static let maxRecordingSeconds = 300

  /// Account and credential approvals stay in Otto on the Mac: a website-account click may
  /// send, buy, delete or change security settings, and connecting a website grants a bot a
  /// signed-in account. Everything else may be answered here once the owner allows it.
  public nonisolated static func isAnswerableOnTelegram(_ pending: AgentPendingPermission) -> Bool {
    !WebsiteAccountTool.approvals.contains(pending.toolName)
  }

  public init(
    services: ApplicationServices,
    secrets: any SecretStore = makeKeychainSecretStore(service: OttoSecretService.messaging),
    defaults: UserDefaults = .standard
  ) {
    self.services = services
    self.secrets = secrets
    self.defaults = defaults
    let workspaceHash = SHA256.hash(data: Data(services.workspacePath.utf8))
      .map { String(format: "%02x", $0) }.joined().prefix(24)
    self.prefix = "otto.telegram.\(workspaceHash)"
    self.credentialKey = "telegram.bot-token.\(workspaceHash)"
    self.offset = max(0, Int64(defaults.integer(forKey: "\(prefix).offset")))
    let savedChat = defaults.object(forKey: "\(prefix).chat") as? NSNumber
    self.approvedChatID = savedChat?.int64Value
    self.approvedGroupID = (defaults.object(forKey: "\(prefix).group") as? NSNumber)?.int64Value
    self.approvedGroupSenderID =
      (defaults.object(forKey: "\(prefix).group.sender") as? NSNumber)?.int64Value
    self.approvalsFromTelegram = defaults.bool(forKey: "\(prefix).approvals")
    if let legacy = defaults.string(forKey: "\(prefix).bot").flatMap(UUID.init(uuidString:)) {
      // Before multi-select, the Mac owner chose one Otto bot. Carry that choice over once.
      if services.connectorAccess.bots(for: .telegram).isEmpty {
        try? services.connectorAccess.setAllowed(true, profileID: legacy, for: .telegram)
      }
      defaults.removeObject(forKey: "\(prefix).bot")
    }
  }

  public var bots: [AgentProfile] {
    (services?.agentProfiles.activeProfiles ?? []).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private var noBotsMessage: String {
    "No Otto bot is allowed on Telegram. Allow one on the Mac in Connectors → Telegram."
  }

  /// Otto bots this Telegram connection may reach. The Mac owner grants them in
  /// Connectors → Telegram; chat messages can only pick among these.
  public var allowedBots: [AgentProfile] {
    guard let access = services?.connectorAccess else { return [] }
    return bots.filter { access.canUse(.telegram, profileID: $0.id) }
  }

  /// The bot a chat is talking to. Chosen with /use; defaults to the first allowed bot.
  private func activeBot(for chat: Int64) -> AgentProfile? {
    let allowed = allowedBots
    if let id = activeBotByChatID[chat], let bot = allowed.first(where: { $0.id == id }) {
      return bot
    }
    return allowed.first
  }

  /// Saved bots the Mac owner has not allowed for Telegram. Named in /bots so a bot that is
  /// missing from the list is explained, never silently unreachable.
  private var botsNotAllowed: [AgentProfile] {
    let allowed = Set(allowedBots.map(\.id))
    return bots.filter { !allowed.contains($0.id) }
  }

  /// The one allowed bot `query` names by handle, name or a unique start of either.
  private func allowedBot(matching query: String) -> AgentProfile? {
    if case .bot(let bot) = TelegramBotRouting.match(query, in: allowedBots) { return bot }
    return nil
  }

  /// The allowed bot a bare leading `@mention` names, with the rest of the message, or nil when
  /// the text should reach this chat's bot unchanged. Only an exact handle or name counts:
  /// "@max said we ship Friday" is a message about Max, not a prompt for @maxsassistant, and a
  /// mention several bots start with is plain text rather than an ambiguity reply.
  func mentionedBot(in text: String) -> (bot: AgentProfile, text: String)? {
    guard let mention = TelegramCommand.leadingMention(in: text),
      let bot = TelegramBotRouting.exactMatch(mention.handle, in: allowedBots)
    else { return nil }
    return (bot, mention.text)
  }

  func botsReply(for chat: Int64) -> String {
    TelegramBotRouting.botsReply(
      allowed: allowedBots, notAllowed: botsNotAllowed, current: activeBot(for: chat)?.id)
  }

  /// Why `query` reached no single allowed bot, with the /bots list so the chat can pick one.
  func unmatchedReply(_ query: String, for chat: Int64) -> String {
    let allowed = allowedBots
    return TelegramBotRouting.unmatchedReply(
      query, match: TelegramBotRouting.match(query, in: allowed), allowed: allowed,
      notAllowed: botsNotAllowed, current: activeBot(for: chat)?.id)
      ?? "No allowed Otto bot matches “\(query)”. Send /bots to see them."
  }

  public func setApprovalsFromTelegram(_ enabled: Bool) {
    approvalsFromTelegram = enabled
    defaults.set(enabled, forKey: "\(prefix).approvals")
    if !enabled { pendingApprovals = [:] }
  }

  /// The one paired person, in the chat they paired: the private chat, or the approved group's
  /// pairing member. Nobody else's taps or recordings are acted on.
  private func isPairedPerson(_ senderID: Int64?, in chat: Int64) -> Bool {
    guard let senderID else { return false }
    if let approvedChatID, chat == approvedChatID { return senderID == approvedChatID }
    if let approvedGroupID, chat == approvedGroupID { return senderID == approvedGroupSenderID }
    return false
  }

  public func connect(token: String) async {
    guard pollTask == nil else {
      status = "Disconnect before replacing the token."
      return
    }
    do {
      let client = try TelegramBotTransport(token: token)
      let name = try await client.verify()
      try await secrets.set(
        token.trimmingCharacters(in: .whitespacesAndNewlines), for: credentialKey)
      // Nothing begun under the previous token may answer through the new one.
      cancelMessageTasks()
      transport = client
      username = name
      status = "Connected to @\(name)"
      if approvedChatID == nil { issuePairingCode() }
      startPolling()
    } catch {
      status = "Could not connect. Check the Telegram bot token and network."
    }
  }

  public func reconnect() async {
    guard pollTask == nil else { return }
    do {
      guard let token = try await secrets.value(for: credentialKey) else { return }
      let client = try TelegramBotTransport(token: token)
      username = try await client.verify()
      transport = client
      status = "Connected to @\(username ?? "bot")"
      if approvedChatID == nil { issuePairingCode() }
      startPolling()
    } catch {
      status = "Telegram unavailable. Check the token, network or existing webhook."
    }
  }

  public func start() {
    if pollTask == nil { Task { await reconnect() } }
  }

  public func stop() {
    pollTask?.cancel()
    pollTask = nil
    cancelMessageTasks()
    transport = nil
    username = nil
  }

  public func disconnect() async {
    stop()
    do {
      try await secrets.delete(credentialKey)
      defaults.removeObject(forKey: "\(prefix).chat")
      defaults.removeObject(forKey: "\(prefix).group")
      defaults.removeObject(forKey: "\(prefix).group.sender")
      defaults.removeObject(forKey: "\(prefix).bot")
      defaults.removeObject(forKey: "\(prefix).offset")
      defaults.removeObject(forKey: "\(prefix).approvals")
      approvalsFromTelegram = false
      pendingApprovals = [:]
      approvedChatID = nil
      approvedGroupID = nil
      approvedGroupSenderID = nil
      pendingGroupID = nil
      pendingGroupSenderID = nil
      groupPairingCode = nil
      activeBotByChatID = [:]
      pendingChatID = nil
      pendingSenderID = nil
      pairingCode = nil
      offset = 0
      status = "Disconnected. Revoke the token in BotFather if it may be exposed."
    } catch {
      status = "Stopped. Keychain removal failed; retry Disconnect."
    }
  }

  public func issuePairingCode() {
    pairingCode = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    pairingExpiry = Date().addingTimeInterval(600)
    pendingChatID = nil
    pendingSenderID = nil
  }

  public func issueGroupPairingCode() {
    groupPairingCode = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    groupPairingExpiry = Date().addingTimeInterval(600)
    pendingGroupID = nil
    pendingGroupSenderID = nil
  }

  public func approvePendingGroup() {
    guard let group = pendingGroupID, group < 0, let sender = pendingGroupSenderID,
      sender > 0
    else { return }
    defaults.set(NSNumber(value: group), forKey: "\(prefix).group")
    defaults.set(NSNumber(value: sender), forKey: "\(prefix).group.sender")
    approvedGroupID = group
    approvedGroupSenderID = sender
    pendingGroupID = nil
    pendingGroupSenderID = nil
    groupPairingCode = nil
    groupPairingExpiry = nil
    status = "Telegram group approved. Only the pairing member can command Otto."
    Task {
      try? await transport?.send(
        "Group approved. Messages from the pairing member can reach the Otto bot selected on your Mac. Use /bots to check the selection.",
        to: group)
    }
  }

  public func revokeGroup() {
    defaults.removeObject(forKey: "\(prefix).group")
    defaults.removeObject(forKey: "\(prefix).group.sender")
    approvedGroupID = nil
    approvedGroupSenderID = nil
    pendingGroupID = nil
    pendingGroupSenderID = nil
    groupPairingCode = nil
    groupPairingExpiry = nil
  }

  public func approvePendingChat() {
    guard let chat = pendingChatID, pendingSenderID == chat else { return }
    defaults.set(NSNumber(value: chat), forKey: "\(prefix).chat")
    approvedChatID = chat
    pendingChatID = nil
    pendingSenderID = nil
    pairingCode = nil
    pairingExpiry = nil
    status = "Paired to your private Telegram chat."
    Task { try? await transport?.send("Paired with Otto. Send /bots to select a bot.", to: chat) }
  }

  /// Also drops waiting messages: they belong to the connection that received them.
  private func cancelMessageTasks() {
    for task in messageTasks.values { task.cancel() }
    messageTasks = [:]
    queuedPrompts = [:]
    queuePumps = [:]
    lateFollows = [:]
  }

  /// What is waiting for a bot, oldest first.
  func queuedTexts(for botID: UUID) -> [String] {
    (queuedPrompts[botID] ?? []).map(\.text)
  }

  /// Whether a run of this bot is being followed for a late answer.
  func isFollowingLate(_ botID: UUID) -> Bool { lateFollows[botID] != nil }

  /// Runs `work` on its own task so polling continues meanwhile: an Approve tap or the next
  /// message must not wait behind it.
  private func track(_ work: @escaping @MainActor (TelegramConnector) async -> Void) {
    let id = UUID()
    messageTasks[id] = Task { [weak self] in
      guard let self else { return }
      await work(self)
      self.messageTasks[id] = nil
    }
  }

  private func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let client = self.transport else { return }
        do {
          let updates = try await client.updates(after: self.offset)
          // A poll that succeeds after an interruption clears the stale warning.
          if self.status == Self.pollingInterrupted {
            self.status = "Connected to @\(self.username ?? "bot")"
          }
          for update in updates.sorted(by: { $0.updateID < $1.updateID }) {
            guard !Task.isCancelled else { return }
            if update.updateID < self.offset { continue }
            // Save before dispatch: after a crash an update must not run twice.
            self.offset = update.updateID + 1
            self.defaults.set(NSNumber(value: self.offset), forKey: "\(self.prefix).offset")
            if let message = update.message { await self.handle(message, client: client) }
            if let tap = update.callbackQuery { await self.handle(tap, client: client) }
          }
        } catch {
          if !Task.isCancelled {
            self.status = Self.pollingInterrupted
          }
          try? await Task.sleep(for: .seconds(5))
        }
      }
    }
  }

  private func handle(_ message: TelegramIncomingMessage, client: TelegramBotTransport) async {
    if let recording = message.recording {
      await handleRecording(recording, in: message, client: client)
      return
    }
    if message.text == nil, let media = message.media {
      await handleMedia(media, in: message, client: client)
      return
    }
    guard let text = message.text,
      let command = TelegramCommand.parse(text, addressedTo: username),
      message.isPrivateHuman || message.isGroupHuman
    else { return }
    let chat = message.chat.id
    if message.isGroupHuman {
      if message.isAuthorized(
        privateChatID: approvedChatID, groupChatID: approvedGroupID,
        groupSenderID: approvedGroupSenderID)
      {
        // Explicitly approved group and one named Telegram user only.
      } else if approvedGroupID == nil, case .pair(let code) = command,
        let groupPairingCode, code == groupPairingCode,
        (groupPairingExpiry ?? .distantPast) > .now
      {
        pendingGroupID = chat
        pendingGroupSenderID = message.from?.id
        status = "Telegram group requests approval in Otto Connectors."
        try? await client.send(
          "Group pairing requested. Approve the group and sender in Otto on your Mac.", to: chat)
        return
      } else {
        return
      }
    } else if approvedChatID != chat {
      guard case .pair(let code) = command,
        approvedChatID == nil, let pairingCode, code == pairingCode,
        (pairingExpiry ?? .distantPast) > .now
      else { return }
      pendingChatID = chat
      pendingSenderID = message.from?.id
      status = "Pairing request received. Approve this Telegram chat on your Mac."
      try? await client.send(
        "Pairing requested. Approve the chat in Otto → Settings → Connectors.", to: chat)
      return
    }
    switch command {
    case .help:
      try? await client.send(
        "Otto commands:\n/bots — list the Otto bots you can reach\n/use name — talk to that bot in this chat (a handle, a name or the start of one)\n/bot @handle message — ask one bot once; @handle message does the same\nPlain text, voice notes, photos and videos go to this chat's bot. Start a caption with /bot @handle or @handle to send media to one bot. The Mac owner decides which bots are allowed. "
          + (approvalsFromTelegram
            ? "Tool approvals arrive here with Approve and Deny buttons."
            : "Tool approvals stay in Otto on the Mac unless the owner allows them here."),
        to: chat)
    case .bots:
      try? await client.send(botsReply(for: chat), to: chat)
    case .use(let handle):
      guard let bot = allowedBot(matching: handle) else {
        try? await client.send(unmatchedReply(handle, for: chat), to: chat)
        return
      }
      activeBotByChatID[chat] = bot.id
      try? await client.send(TelegramBotRouting.switchedReply(to: bot), to: chat)
    case .send(let handle, let text):
      guard let bot = allowedBot(matching: handle) else {
        try? await client.send(unmatchedReply(handle, for: chat), to: chat)
        return
      }
      await sendPrompt(text, to: bot, client: client, chat: chat, context: message.channelHeader)
    case .message(let prompt):
      // `@instagram100kcompany do this` is how Telegram users address a bot. A mention of
      // anyone else stays an ordinary message for this chat's bot, and the bare handle alone
      // switches to it.
      if let mention = mentionedBot(in: prompt) {
        if mention.text.isEmpty {
          activeBotByChatID[chat] = mention.bot.id
          try? await client.send(TelegramBotRouting.switchedReply(to: mention.bot), to: chat)
        } else {
          await sendPrompt(
            mention.text, to: mention.bot, client: client, chat: chat,
            context: message.channelHeader)
        }
        return
      }
      guard let bot = activeBot(for: chat) else {
        try? await client.send(noBotsMessage, to: chat)
        return
      }
      await sendPrompt(prompt, to: bot, client: client, chat: chat, context: message.channelHeader)
    case .pair:
      try? await client.send("Already paired. Use /bots to choose a bot.", to: chat)
    }
  }

  /// A message joins its bot's queue. It goes at once when the bot is free, otherwise when the
  /// bot's current run ends; the chat is told which. Nothing a person says is dropped because
  /// the bot happened to be busy.
  private func sendPrompt(
    _ prompt: String, to bot: AgentProfile, client: TelegramBotTransport, chat: Int64,
    context: String?
  ) async {
    guard let services, services.isOnline else {
      try? await client.send("Otto is not ready on your Mac.", to: chat)
      return
    }
    // Telegram content is untrusted input. It does not grant permission or approve
    // a pending desktop action; those must still go through Otto's UI. Only the paired person's
    // messages get this far, so their text reaches the bot as their own; `context` adds the
    // channel header with its reply rules for this turn only.
    let waiting = queuedPrompts[bot.id] ?? []
    guard waiting.count < Self.maxQueuedPrompts else {
      try? await client.send(
        "@\(bot.handle) already has \(Self.maxQueuedPrompts) messages waiting. Send this one again once it has caught up.",
        to: chat)
      return
    }
    // Only a run in progress is worth announcing; a queue being worked through is not one.
    let busy = isBusy(bot) || lateFollows[bot.id] != nil
    queuedPrompts[bot.id] =
      waiting + [QueuedPrompt(text: prompt, context: context, chat: chat, client: client)]
    if busy {
      try? await client.send(
        "Queued behind the current task. I'll send it when @\(bot.handle) is free.", to: chat)
    }
    pumpQueue(for: bot)
  }

  /// Whether the bot's live session would refuse a prompt now: it is starting, working, or
  /// waiting on an approval or a question. A stopped or failed session restarts on send.
  private func isBusy(_ bot: AgentProfile) -> Bool {
    guard let services,
      let nodeID = services.botRoster().first(where: { $0.profile.id == bot.id })?.nodeID,
      let state = services.fleetStore.snapshot(for: nodeID)?.state
    else { return false }
    return ![.idle, .done, .interrupted, .stopped, .failed].contains(state)
  }

  /// Works through a bot's queue on one task: waits until the bot is free, sends the oldest
  /// message, follows that run so its answer reaches the chat, then repeats until nothing is
  /// waiting. A run that outlasts `followWindow` is handed to a background follower that sends
  /// its answer when it ends; the queue waits for the bot to be free and that answer to be picked
  /// up, never for longer. A message the bot cannot take is bounced on its own, quoting the text
  /// so the person can send it again, and the rest are still tried. Nothing goes to the chat once
  /// the task is cancelled: the connection it came in on may be gone.
  private func pumpQueue(for bot: AgentProfile) {
    guard queuePumps[bot.id] == nil else { return }
    let pump = UUID()
    queuePumps[bot.id] = pump
    track { connector in
      defer {
        if connector.queuePumps[bot.id] == pump { connector.queuePumps[bot.id] = nil }
      }
      while !Task.isCancelled, let services = connector.services,
        let next = connector.queuedPrompts[bot.id]?.first
      {
        if connector.isBusy(bot) || connector.lateFollows[bot.id] != nil {
          try? await Task.sleep(for: .seconds(2))
          continue
        }
        let previousNodeID = services.botRoster().first { $0.profile.id == bot.id }?.nodeID
        let previousSnapshot = previousNodeID.flatMap { services.fleetStore.snapshot(for: $0) }
        let previousRunID = previousSnapshot?.runID
        let previousAssistantIDs = Set(
          previousSnapshot?.transcript.filter { $0.role == .assistant }.map(\.id) ?? [])
        let opened: BotOpenOutput
        do {
          opened = try await services.controlSendPrompt(
            to: bot.id.uuidString, prompt: next.text, hiddenContext: next.context)
        } catch RuntimeError.invalidTransition {
          // The bot took other work between the check and the send. Wait for that run instead.
          try? await Task.sleep(for: .seconds(2))
          continue
        } catch {
          guard !Task.isCancelled else { return }
          connector.queuedPrompts[bot.id]?.removeAll { $0.id == next.id }
          try? await next.client.send(Self.undeliverable(next.text, bot: bot), to: next.chat)
          continue
        }
        // Off the queue only now; a disconnect meanwhile has already emptied it.
        connector.queuedPrompts[bot.id]?.removeAll { $0.id == next.id }
        guard !Task.isCancelled else { return }
        try? await next.client.send("Sent to @\(bot.handle). Working…", to: next.chat)
        guard !Task.isCancelled else { return }
        let outcome = await connector.follow(
          agentID: opened.agentID, bot: bot, previousRunID: previousRunID,
          previousAssistantIDs: previousAssistantIDs, client: next.client, chat: next.chat,
          window: connector.followWindow)
        guard case .stillRunning(let runID) = outcome, !Task.isCancelled else { continue }
        try? await next.client.send(Self.stillWorkingReply, to: next.chat)
        connector.followLate(
          agentID: opened.agentID, bot: bot, previousRunID: previousRunID, runID: runID,
          previousAssistantIDs: previousAssistantIDs, request: next.text,
          client: next.client, chat: next.chat)
      }
    }
  }

  static let stillWorkingReply = "Still working on it — I'll send the answer here when it's done."

  /// Keeps following a run the chat was told is still working, for up to `lateFollowWindow`, and
  /// sends its answer, labelled as the answer to the earlier request, when it ends. Cancelled with
  /// the connection like any message task.
  private func followLate(
    agentID: UUID, bot: AgentProfile, previousRunID: UUID?, runID: UUID?,
    previousAssistantIDs: Set<UUID>, request: String, client: TelegramBotTransport, chat: Int64
  ) {
    let follower = UUID()
    lateFollows[bot.id] = follower
    track { connector in
      defer {
        if connector.lateFollows[bot.id] == follower { connector.lateFollows[bot.id] = nil }
      }
      _ = await connector.follow(
        agentID: agentID, bot: bot, previousRunID: previousRunID,
        previousAssistantIDs: previousAssistantIDs, client: client, chat: chat,
        window: connector.lateFollowWindow, late: (request: request, runID: runID))
    }
  }

  /// The opening of a late answer, quoting the start of the request it answers.
  nonisolated static func lateAnswerPrefix(for request: String) -> String {
    "Here's the answer to your earlier request “\(excerpt(request))”:"
  }

  /// Quotes enough of the text for the person to find it and send it again.
  private static func undeliverable(_ text: String, bot: AgentProfile) -> String {
    let excerpt = text.count > 80 ? String(text.prefix(80)) + "…" : text
    return
      "Could not deliver “\(excerpt)” to @\(bot.handle). Open Otto on your Mac to check the bot, then send it again."
  }

  /// Relays the opened agent's answer, never another bot's. While it waits for a tool approval,
  /// the approval is offered here when the owner allowed that, and the wait is extended. `late`
  /// marks a follow after the chat heard "Still working": its answer names the request it
  /// answers, and it only relays the answer of the run it was handed (`runID`), so a newer run
  /// started on the Mac is never passed off as this one.
  private func follow(
    agentID: UUID, bot: AgentProfile, previousRunID: UUID?, previousAssistantIDs: Set<UUID>,
    client: TelegramBotTransport, chat: Int64, window: TimeInterval,
    late: (request: String, runID: UUID?)? = nil
  ) async -> FollowOutcome {
    guard let services else { return .settled }
    var deadline = Date.now.addingTimeInterval(window)
    var offeredRequestID: UUID?
    var deferredRequestID: UUID?
    while Date.now < deadline {
      try? await Task.sleep(for: .seconds(1))
      if Task.isCancelled { return .settled }
      guard let snapshot = services.fleetStore.snapshot(for: agentID) else { continue }
      if let late, let runID = late.runID, let current = snapshot.runID, current != runID {
        // Another run began before this one's end was seen; its answer is not this request's.
        try? await client.send(
          "@\(bot.handle) finished your earlier request “\(Self.excerpt(late.request))”. Open Otto on your Mac to see the result.",
          to: chat)
        return .settled
      }
      let newAnswer = snapshot.transcript.reversed().first {
        $0.role == .assistant && $0.kind == .text && !$0.text.isEmpty
          && !previousAssistantIDs.contains($0.id)
      }?.text
      guard snapshot.runID != previousRunID || newAnswer != nil else { continue }
      if snapshot.state == .waitingPermission {
        guard approvalsFromTelegram,
          let pending = await services.supervisor.pendingPermission(agentID: agentID)
        else {
          try? await client.send(
            "@\(bot.handle) needs your approval in the Otto Mac app.", to: chat)
          return .settled
        }
        guard Self.isAnswerableOnTelegram(pending) else {
          // No buttons: keep following so the answer still arrives once it is approved on the Mac.
          if pending.requestID != deferredRequestID {
            deferredRequestID = pending.requestID
            try? await client.send(
              "@\(bot.handle) needs a website account approval. Approve it in Otto on your Mac.",
              to: chat)
          }
          deadline = max(deadline, Date.now.addingTimeInterval(600))
          continue
        }
        if pending.requestID != offeredRequestID {
          offeredRequestID = pending.requestID
          await offerApproval(pending, agentID: agentID, bot: bot, client: client, chat: chat)
        }
        // A person on their phone may take a while to answer.
        deadline = max(deadline, Date.now.addingTimeInterval(600))
        continue
      }
      if snapshot.state == .waitingUser {
        try? await client.send(
          "@\(bot.handle) has a question for you in the Otto Mac app.", to: chat)
        return .settled
      }
      if [.done, .idle, .failed, .interrupted, .stopped].contains(snapshot.state) {
        let answer = (newAnswer ?? snapshot.result).map(ChatChannelReplyFormatter.plainText)
        var reply =
          answer?.isEmpty == false
          ? answer! : "Bot finished. Open Otto on your Mac to review the result."
        if let late { reply = Self.lateAnswerPrefix(for: late.request) + "\n\n" + reply }
        try? await client.send(reply, to: chat)
        return .settled
      }
    }
    if late != nil {
      try? await client.send(
        "@\(bot.handle) is still on your earlier request. Check it in Otto on your Mac.", to: chat)
      return .settled
    }
    // A run that has not begun yet has no ID of its own to hold the late follow to.
    let runID = services.fleetStore.snapshot(for: agentID)?.runID
    return .stillRunning(runID: runID == previousRunID ? nil : runID)
  }

  private nonisolated static func excerpt(_ text: String) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
  }

  private func offerApproval(
    _ pending: AgentPendingPermission, agentID: UUID, bot: AgentProfile,
    client: TelegramBotTransport, chat: Int64
  ) async {
    pendingApprovals = pendingApprovals.filter { $0.value.expires > .now }
    let token = TelegramApprovalAnswer.makeToken()
    let text = "@\(bot.handle) asks for approval:\n\n\(pending.reason)"
    guard
      let messageID = try? await client.send(
        text, to: chat,
        buttons: [("Approve", "ok:\(token)"), ("Deny", "no:\(token)")])
    else { return }
    pendingApprovals[token] = PendingApproval(
      agentID: agentID, requestID: pending.requestID, nonce: pending.nonce, chat: chat,
      messageID: messageID, text: text, expires: Date.now.addingTimeInterval(3_600))
  }

  /// An Approve or Deny tap. Telegram content is untrusted: the tap counts only from the paired
  /// person, in the chat the approval was sent to, for a request that is still the one waiting.
  private func handle(_ tap: TelegramCallbackQuery, client: TelegramBotTransport) async {
    guard let answer = TelegramApprovalAnswer.parse(tap.data),
      let pending = pendingApprovals[answer.token], let origin = tap.message,
      origin.chat.id == pending.chat, origin.messageID == pending.messageID,
      tap.from.isBot != true, isPairedPerson(tap.from.id, in: origin.chat.id)
    else {
      try? await client.answerCallback(tap.id, text: "This approval is no longer available.")
      return
    }
    pendingApprovals[answer.token] = nil
    guard approvalsFromTelegram, pending.expires > .now, let services else {
      try? await client.answerCallback(tap.id, text: "Approve this in Otto on your Mac.")
      try? await client.edit(
        pending.messageID, in: pending.chat, text: pending.text + "\n\nExpired. Answer on the Mac.")
      return
    }
    let approved = answer == .approve(answer.token)
    do {
      try await services.supervisor.resolvePermission(
        agentID: pending.agentID, requestID: pending.requestID, nonce: pending.nonce,
        approved: approved)
      try? await client.answerCallback(tap.id, text: approved ? "Approved" : "Denied")
      try? await client.edit(
        pending.messageID, in: pending.chat,
        text: pending.text + (approved ? "\n\n✅ Approved on Telegram" : "\n\n❌ Denied on Telegram"))
    } catch {
      try? await client.answerCallback(tap.id, text: "Already answered.")
      try? await client.edit(
        pending.messageID, in: pending.chat,
        text: pending.text + "\n\nAlready answered, or the run moved on.")
    }
  }

  /// A voice note or audio file from the paired person becomes a message to this chat's bot.
  /// Nothing is downloaded for anyone else.
  private func handleRecording(
    _ recording: TelegramIncomingMessage.Audio, in message: TelegramIncomingMessage,
    client: TelegramBotTransport
  ) async {
    guard message.isPrivateHuman || message.isGroupHuman,
      message.isAuthorized(
        privateChatID: approvedChatID, groupChatID: approvedGroupID,
        groupSenderID: approvedGroupSenderID)
    else { return }
    let chat = message.chat.id
    guard let transcribeRecording else {
      try? await client.send(
        "Voice notes need on-device speech on the Mac. Send text instead.", to: chat)
      return
    }
    guard let bot = activeBot(for: chat) else {
      try? await client.send(noBotsMessage, to: chat)
      return
    }
    guard (recording.duration ?? 0) <= Self.maxRecordingSeconds,
      (recording.fileSize ?? 0) <= AudioRecordingLimits.maxBytes
    else {
      try? await client.send("Voice notes up to 5 minutes can be transcribed.", to: chat)
      return
    }
    let caption = message.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let header = message.channelHeader
    // Downloading and transcribing can take minutes; polling must not wait for it.
    track { connector in
      let transcript: String
      do {
        let file = try await client.download(
          fileID: recording.fileID, maxBytes: AudioRecordingLimits.maxBytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        transcript = try await transcribeRecording(file)
      } catch {
        guard !Task.isCancelled else { return }
        try? await client.send(Self.voiceNoteFailureReply(for: error), to: chat)
        return
      }
      guard !Task.isCancelled else { return }
      try? await client.send("🎙️ Heard: “\(transcript)”", to: chat)
      await connector.sendPrompt(
        caption.isEmpty ? transcript : "\(caption)\n\n\(transcript)", to: bot, client: client,
        chat: chat, context: header)
    }
  }

  /// One short sentence for a voice note that could not be transcribed. The engine's reason is
  /// kept to a single line of at most 200 characters; the full detail is in the system log.
  nonisolated static func voiceNoteFailureReply(for error: Error) -> String {
    let plain = "Couldn't transcribe that voice note. Send text instead."
    var reason = ((error as? LocalizedError)?.errorDescription ?? "")
      .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }.joined(separator: " ")
    while reason.hasSuffix(".") { reason.removeLast() }
    guard !reason.isEmpty else { return plain }
    if reason.count > 200 { reason = String(reason.prefix(199)) + "…" }
    return "Couldn't transcribe that voice note (\(reason)). Send text instead."
  }

  /// A photo or video from the paired person goes to this chat's bot, or to the bot a
  /// `/bot @handle` caption names. Photos and videos of one album arrive as separate messages and
  /// are sent together once Telegram stops delivering them. Nothing is downloaded for anyone else.
  private func handleMedia(
    _ media: TelegramMedia, in message: TelegramIncomingMessage, client: TelegramBotTransport
  ) async {
    guard message.isPrivateHuman || message.isGroupHuman,
      message.isAuthorized(
        privateChatID: approvedChatID, groupChatID: approvedGroupID,
        groupSenderID: approvedGroupSenderID)
    else { return }
    let chat = message.chat.id
    let caption = message.caption ?? ""
    let header = message.channelHeader
    guard let album = message.mediaGroupID else {
      deliver([media], caption: caption, header: header, client: client, chat: chat)
      return
    }
    let key = "\(chat):\(album)"
    var pending = pendingAlbums[key] ?? PendingAlbum(media: [], caption: "", generation: 0)
    if pending.media.count < TelegramMedia.maxAlbumItems { pending.media.append(media) }
    // Telegram puts an album's caption on one of its items, not always the first.
    if pending.caption.isEmpty { pending.caption = caption }
    pending.generation += 1
    pendingAlbums[key] = pending
    let generation = pending.generation
    track { connector in
      try? await Task.sleep(for: .milliseconds(1_500))
      guard !Task.isCancelled, let album = connector.pendingAlbums[key],
        album.generation == generation
      else { return }
      connector.pendingAlbums[key] = nil
      connector.deliver(
        album.media, caption: album.caption, header: header, client: client, chat: chat)
    }
  }

  /// Downloads the media into the workspace's chat attachments, takes stills (and, when voice
  /// notes are supported, the sound) from videos, and sends one prompt to the chosen bot.
  private func deliver(
    _ media: [TelegramMedia], caption: String, header: String, client: TelegramBotTransport,
    chat: Int64
  ) {
    var bot = activeBot(for: chat)
    let route = TelegramMedia.route(caption: caption, botUsername: username)
    var text = route.text
    if let handle = route.botHandle {
      guard let named = allowedBot(matching: handle) else {
        let reply = unmatchedReply(handle, for: chat)
        Task { try? await client.send(reply, to: chat) }
        return
      }
      bot = named
    } else if let mention = mentionedBot(in: text) {
      // `@instagram100kcompany compare these` on a photo, like `/bot @handle` would.
      bot = mention.bot
      text = mention.text
    }
    guard let bot, let services else {
      Task { try? await client.send(self.noBotsMessage, to: chat) }
      return
    }
    let servable = media.filter(\.isServable)
    let skipped = media.count - servable.count
    guard !servable.isEmpty else {
      Task {
        try? await client.send(
          "Telegram only lets bots download files up to 20 MB. Send a smaller or compressed version.",
          to: chat)
      }
      return
    }
    let directory = TelegramMediaStore.directory(workspacePath: services.defaultWorkspacePath)
    let transcribe = transcribeRecording
    // Downloading and reading videos can take a while; polling must not wait for it.
    track { connector in
      var images: [String] = []
      var videos: [TelegramVideoNote] = []
      var failed = skipped
      for item in servable {
        guard !Task.isCancelled else { return }
        do {
          let file = try await client.download(
            fileID: item.fileID, maxBytes: TelegramMedia.maxBytes, named: "media",
            defaultExtension: item.fileExtension)
          defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
          let kept = try TelegramMediaStore.keep(file, kind: item.kind, in: directory)
          switch item.kind {
          case .image:
            images.append(kept.path)
          case .video:
            let frames = (try? await TelegramVideoFrames.extract(from: kept)) ?? []
            var transcript: String?
            if let transcribe,
              (item.duration ?? 0) <= TelegramMedia.maxTranscribedVideoSeconds
            {
              // Best effort: a silent clip or one with no speech is still worth sending.
              transcript = try? await transcribe(kept)
            }
            videos.append(
              TelegramVideoNote(
                path: kept.path, duration: item.duration, frames: frames.map(\.path),
                transcript: transcript?.trimmingCharacters(in: .whitespacesAndNewlines)))
          }
        } catch {
          if Task.isCancelled { return }
          failed += 1
        }
      }
      guard !Task.isCancelled else { return }
      guard !images.isEmpty || !videos.isEmpty else {
        try? await client.send(
          "Couldn't download that from Telegram. Try sending it again.", to: chat)
        return
      }
      if failed > 0 {
        try? await client.send(
          "\(failed) item\(failed == 1 ? "" : "s") couldn't be downloaded; sending the rest.",
          to: chat)
      }
      await connector.sendPrompt(
        TelegramMediaStore.prompt(caption: text, images: images, videos: videos), to: bot,
        client: client, chat: chat, context: header)
    }
  }
}

/// Telegram's Bot API serves files up to 20 MB.
enum AudioRecordingLimits {
  static let maxBytes = 20_000_000
}
