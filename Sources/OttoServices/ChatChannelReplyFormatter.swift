import Foundation
import OttoModels

/// A phone chat Otto relays bot conversations through.
public enum ChatChannel: String, Sendable {
  case telegram = "Telegram"
  case iMessage = "iMessage"
}

/// Reply rules for chat channels such as Telegram and iMessage, which show plain text only.
///
/// Inbound, a short header tells the bot where a message came from and how to answer it. Outbound,
/// desktop-only markup (mermaid diagrams, Markdown tables, the details divider, otto-* cards) is
/// turned into plain text before it reaches the phone, because a bot may not follow the header and
/// a raw ```mermaid block or `| --- |` row is unreadable there.
public enum ChatChannelReplyFormatter {
  /// Telegram allows 4,096 characters per message; this leaves room for a prefix.
  public static let telegramChunkLimit = 3_500
  static let detailsNote = "(More detail in Otto on your Mac.)"
  static let diagramNote = "(diagram in Otto)"

  // MARK: Inbound

  /// The header the bot sees before a message that arrived on `channel`. The person's own text
  /// follows it unchanged. `sender` is the name the chat app reports and is cleaned to one short
  /// line, since it is set by the sender, not by Otto.
  public static func inboundHeader(
    channel: ChatChannel, sender: String?, isGroup: Bool = false
  ) -> String {
    let name = cleanedName(sender)
    let origin =
      isGroup
      ? "via a \(channel.rawValue) group\(name.map { " from \($0)" } ?? "") (others in the group can read your reply)"
      : "via \(channel.rawValue)\(name.map { " from \($0)" } ?? "")"
    return
      "[Otto · \(origin) — reply for a phone chat: plain text, short (aim ≤100 words unless asked for more), no mermaid, tables, HTML comments or otto-* cards; put long material in a Document and send the link]"
  }

  /// One line of at most 40 characters with no brackets, so a display name cannot close the
  /// header early or add lines that look like Otto's own.
  static func cleanedName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let flat = raw.unicodeScalars
      .map {
        CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
          ? " " : String($0)
      }
      .joined()
      .replacingOccurrences(of: "[", with: "(")
      .replacingOccurrences(of: "]", with: ")")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !flat.isEmpty else { return nil }
    return flat.count > 40 ? String(flat.prefix(39)) + "…" : flat
  }

  // MARK: Outbound

  /// `markdown` as plain text a phone chat shows well.
  ///
  /// Everything from a standalone details divider on is dropped and replaced by a pointer to the
  /// Mac: Otto's guidance puts every requested deliverable above that line and only optional
  /// supporting explanation below it, so on a phone the takeaway is the answer and the rest would
  /// only add screens of text (and, on Telegram, several messages).
  public static func plainText(_ markdown: String) -> String {
    var output: [String] = []
    var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")[...]
    var droppedDetails = false
    while let line = lines.popFirst() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if OttoTranscriptMarkers.detailsMarkers.contains(trimmed) {
        droppedDetails = !lines.allSatisfy {
          $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        break
      }
      if let fence = fenceInfo(trimmed) {
        var body: [String] = []
        // An unclosed fence runs to the end, as Markdown renders it.
        while let inner = lines.popFirst(),
          !inner.trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker)
        {
          body.append(inner)
        }
        output.append(contentsOf: renderFence(language: fence.language, body: body))
        continue
      }
      if isTableRow(trimmed), let separator = lines.first,
        isTableSeparator(separator.trimmingCharacters(in: .whitespaces))
      {
        lines.removeFirst()
        var rows: [[String]] = []
        while let next = lines.first, isTableRow(next.trimmingCharacters(in: .whitespaces)) {
          rows.append(cells(next))
          lines.removeFirst()
        }
        output.append(contentsOf: renderTable(header: cells(trimmed), rows: rows))
        continue
      }
      output.append(inline(line))
    }
    var text = collapseBlankLines(output).trimmingCharacters(in: .whitespacesAndNewlines)
    if droppedDetails {
      text += text.isEmpty ? detailsNote : "\n\n" + detailsNote
    }
    return text
  }

  /// `text` in pieces of at most `limit` characters, split at a paragraph, then a line, then a
  /// space when one falls in the second half of the piece; otherwise at the limit.
  public static func chunks(_ text: String, limit: Int = telegramChunkLimit) -> [String] {
    precondition(limit > 0)
    var rest = Substring(text)
    var parts: [String] = []
    while rest.count > limit {
      let window = rest.prefix(limit)
      let floor = window.index(window.startIndex, offsetBy: limit / 2)
      let cut =
        [
          window.range(of: "\n\n", options: .backwards),
          window.range(of: "\n", options: .backwards),
          window.range(of: " ", options: .backwards),
        ]
        .compactMap { $0 }.first { $0.lowerBound >= floor }
      let end = cut?.lowerBound ?? window.endIndex
      let part = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
      if !part.isEmpty { parts.append(part) }
      rest = rest[(cut?.upperBound ?? end)...]
    }
    let last = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    if !last.isEmpty || parts.isEmpty { parts.append(last) }
    return parts
  }

  /// Plain text in chunks for Telegram.
  public static func telegramMessages(_ markdown: String) -> [String] {
    chunks(plainText(markdown), limit: telegramChunkLimit)
  }

  // MARK: Blocks

  private static func fenceInfo(_ line: String) -> (marker: String, language: String)? {
    for marker in ["```", "~~~"] where line.hasPrefix(marker) {
      let language = line.drop { $0 == marker.first }.trimmingCharacters(in: .whitespaces)
      return (marker, language.lowercased())
    }
    return nil
  }

  private static func renderFence(language: String, body: [String]) -> [String] {
    if language == "mermaid" { return [diagramNote] }
    if OttoTranscriptMarkers.emailFences.contains(language) { return emailDraft(body) }
    if OttoTranscriptMarkers.inboxFences.contains(language) { return ["(inbox in Otto)"] }
    if language.hasPrefix("otto-") || language.hasPrefix("muse-") {
      return ["(\(language.dropFirst(5)) card in Otto)"]
    }
    // Ordinary code reads fine without its fence lines.
    return body
  }

  /// An email card as the email itself: the draft is usually the deliverable.
  private static func emailDraft(_ body: [String]) -> [String] {
    struct Draft: Decodable {
      let to: String?
      let subject: String?
      let body: String?
    }
    guard let data = body.joined(separator: "\n").data(using: .utf8),
      let draft = try? JSONDecoder().decode(Draft.self, from: data)
    else { return ["(email draft in Otto)"] }
    var lines: [String] = []
    if let to = draft.to, !to.isEmpty { lines.append("To: \(to)") }
    if let subject = draft.subject, !subject.isEmpty { lines.append("Subject: \(subject)") }
    if let text = draft.body, !text.isEmpty {
      if !lines.isEmpty { lines.append("") }
      lines.append(contentsOf: text.components(separatedBy: "\n"))
    }
    return lines.isEmpty ? ["(email draft in Otto)"] : lines
  }

  private static func isTableRow(_ line: String) -> Bool {
    line.hasPrefix("|") && line.dropFirst().contains("|")
  }

  private static func isTableSeparator(_ line: String) -> Bool {
    guard line.contains("-"), line.contains("|") else { return false }
    return line.allSatisfy { "|-: ".contains($0) }
  }

  private static func cells(_ line: String) -> [String] {
    var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
    if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
    if trimmed.hasSuffix("|") { trimmed = trimmed.dropLast() }
    return trimmed.split(separator: "|", omittingEmptySubsequences: false)
      .map { inline(String($0)).trimmingCharacters(in: .whitespaces) }
  }

  /// Two columns read as "• left — right"; wider tables keep their header line so each row's
  /// values can be matched to it.
  private static func renderTable(header: [String], rows: [[String]]) -> [String] {
    func line(_ cells: [String]) -> String {
      cells.filter { !$0.isEmpty }.joined(separator: " — ")
    }
    var lines: [String] = []
    if header.count > 2 { lines.append(line(header)) }
    for row in rows {
      let text = line(row)
      if !text.isEmpty { lines.append("• " + text) }
    }
    if lines.isEmpty { lines.append(line(header)) }
    return lines
  }

  // MARK: Inline

  /// Drops HTML comments, heading marks and bold markers, and rewrites images and links so
  /// they make sense away from the Mac.
  private static func inline(_ line: String) -> String {
    var text = line
    text = replace(#"<!--.*?-->"#, in: text, with: "")
    text = replace(#"^(\s*)#{1,6}\s+"#, in: text, with: "$1")
    // Images are local files on the Mac.
    text = replace(#"!\[([^\]]*)\]\([^)]*\)"#, in: text) { groups in
      groups[1].isEmpty ? "(image in Otto)" : "(image in Otto: \(groups[1]))"
    }
    // A target in angle brackets may hold spaces and parentheses — Otto's own tools say
    // "return [Open document](<path>)", and Mac paths have both. A title after the target is
    // dropped: a phone chat has nowhere to show it. The alternation stays non-capturing;
    // NSRegularExpression refuses a capturing one right after the escaped "(".
    text = replace(
      #"\[([^\]]+)\]\((?:<([^<>\n]*)>|([^)>\s]+))(?:[ \t]+("[^"]*"|'[^']*'))?[ \t]*\)"#, in: text
    ) { groups in
      let title = groups[1]
      let target = groups[2].isEmpty ? groups[3] : groups[2]
      if target.hasPrefix("http://") || target.hasPrefix("https://") {
        return title == target ? target : "\(title) (\(target))"
      }
      return "\(title) (in Otto)"
    }
    text = replace(#"\*\*(.+?)\*\*"#, in: text, with: "$1")
    return text
  }

  private static func replace(_ pattern: String, in text: String, with template: String)
    -> String
  {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    else { return text }
    return regex.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
  }

  private static func replace(
    _ pattern: String, in text: String, _ transform: ([String]) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    var result = ""
    var cursor = text.startIndex
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let whole = Range(match.range, in: text) else { continue }
      let groups = (0..<match.numberOfRanges).map { index -> String in
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
      }
      result += text[cursor..<whole.lowerBound]
      result += transform(groups)
      cursor = whole.upperBound
    }
    return result + text[cursor...]
  }

  private static func collapseBlankLines(_ lines: [String]) -> String {
    var result: [String] = []
    for line in lines {
      let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
      if blank, result.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
      result.append(blank ? "" : line)
    }
    return result.joined(separator: "\n")
  }
}
