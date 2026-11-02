import Foundation
import OttoModels

/// How a Telegram chat names an Otto bot. People type what they see: `@instagram100kcompany`
/// from the /bots list, `instagram`, or the bot's name "Instagram (100k company)". A handle, a
/// name or a unique start of either resolves, with or without the `@`. Ambiguity never guesses.
public enum TelegramBotRouting {
  public enum Match: Equatable, Sendable {
    case bot(AgentProfile)
    case ambiguous([AgentProfile])
    case none
  }

  /// `query` folded the way `AgentProfile.handle` folds a name, so a typed name and its handle
  /// compare equal: `@Instagram (100k company)` → `instagram100kcompany`. Empty for no letters.
  public static func key(_ query: String) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let bare = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    let folded = bare.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    return folded.filter { $0.isLetter || $0.isNumber }
  }

  public static func match(_ query: String, in bots: [AgentProfile]) -> Match {
    let wanted = key(query)
    guard !wanted.isEmpty else { return .none }
    let exact = bots.filter { $0.handle.lowercased() == wanted }
    if exact.count == 1 { return .bot(exact[0]) }
    if exact.count > 1 { return .ambiguous(exact) }
    let prefixed = bots.filter { $0.handle.lowercased().hasPrefix(wanted) }
    switch prefixed.count {
    case 0: return .none
    case 1: return .bot(prefixed[0])
    default: return .ambiguous(prefixed)
    }
  }

  /// The bot whose folded handle or name is exactly `query`, for bare `@mentions` in ordinary
  /// text where a start-of-name match would hijack "@max said we ship Friday". Nil when none or
  /// several match.
  public static func exactMatch(_ query: String, in bots: [AgentProfile]) -> AgentProfile? {
    let wanted = key(query)
    guard !wanted.isEmpty else { return nil }
    let exact = bots.filter { $0.handle.lowercased() == wanted }
    return exact.count == 1 ? exact[0] : nil
  }

  /// The /bots reply: the bots this chat can reach with the one it talks to marked, and the
  /// saved bots the Mac owner has not allowed yet, by name only, so a missing bot is explained
  /// rather than invisible.
  public static func botsReply(
    allowed: [AgentProfile], notAllowed: [AgentProfile], current: UUID?
  ) -> String {
    var text: String
    if allowed.isEmpty {
      text =
        "No Otto bot is allowed on Telegram yet. Allow one in Otto → Settings → Connectors → Telegram."
      if !notAllowed.isEmpty {
        text += " Saved bots: \(notAllowed.map(\.name).joined(separator: ", "))."
      }
      return text
    }
    let lines = allowed.map { bot in
      "\(bot.id == current ? "•" : " ") @\(bot.handle) — \(bot.name)"
    }
    text =
      "Otto bots you can reach:\n" + lines.joined(separator: "\n")
      + "\nSend /use with a handle, a name or the start of one to switch. @handle message asks one bot once."
    if !notAllowed.isEmpty {
      let names = notAllowed.map(\.name).joined(separator: ", ")
      let one = notAllowed.count == 1
      text +=
        "\n\n\(one ? "1 more bot is" : "\(notAllowed.count) more bots are") not allowed for Telegram yet: \(names). Allow \(one ? "it" : "them") in Otto → Settings → Connectors → Telegram."
    }
    return text
  }

  /// What to tell the chat when `query` named no single allowed bot; nil when it did.
  public static func unmatchedReply(
    _ query: String, match: Match, allowed: [AgentProfile], notAllowed: [AgentProfile],
    current: UUID?
  ) -> String? {
    let shown = query.trimmingCharacters(in: .whitespacesAndNewlines)
    switch match {
    case .bot: return nil
    case .ambiguous(let bots):
      let options = bots.map { "@\($0.handle) (\($0.name))" }.joined(separator: ", ")
      return "“\(shown)” could be \(options). Type more of the name."
    case .none:
      return "No allowed Otto bot matches “\(shown)”.\n\n"
        + botsReply(allowed: allowed, notAllowed: notAllowed, current: current)
    }
  }

  public static func switchedReply(to bot: AgentProfile) -> String {
    "This chat now talks to @\(bot.handle) (\(bot.name))."
  }
}
