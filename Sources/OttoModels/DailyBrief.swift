import Foundation

/// A lens over the workspace's projects. Home shows only the brief, sessions and pins that
/// belong to the selected profile, so Personal and Work stay separate without new workspaces.
public struct HomeProfile: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var symbol: String
  /// Empty means every project, including unassigned work.
  public var projectIDs: [UUID]
  /// Where sessions started from this profile's Home are filed.
  public var defaultProjectID: UUID?
  public var themeID: String?
  /// The Otto-managed routine that reads this profile's connected tools each morning.
  public var briefRoutineID: UUID?
  /// Extra runs of the morning brief, one per other signed-in AI account, keyed by account ID,
  /// so calendars, inboxes and tasks from every account land in this one brief.
  public var briefAccountRoutines: [String: UUID]?
  /// Accounts the person took out of the brief by deleting that account's run.
  public var briefSkippedAccountIDs: [UUID]?

  public init(
    id: UUID = UUID(), name: String, symbol: String = "house", projectIDs: [UUID] = [],
    defaultProjectID: UUID? = nil, themeID: String? = nil, briefRoutineID: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.projectIDs = projectIDs
    self.defaultProjectID = defaultProjectID
    self.themeID = themeID
    self.briefRoutineID = briefRoutineID
  }

  public var includesEverything: Bool { projectIDs.isEmpty }

  /// Unattributed work belongs to the legacy workspace project, so it only appears in profiles
  /// that cover everything or explicitly include that project.
  public func includes(projectID: UUID?, legacyProjectID: UUID?) -> Bool {
    if includesEverything { return true }
    guard let id = projectID ?? legacyProjectID else { return false }
    return projectIDs.contains(id)
  }
}

public enum BriefItemKind: String, Codable, CaseIterable, Sendable {
  case todo
  case update
  case event
}

public enum BriefItemOrigin: Codable, Equatable, Hashable, Sendable {
  /// Derived from Otto's own state each time Home renders. Never persisted as an item.
  case otto
  case user
  case routine(UUID)
  case agent(String)

  // Same JSON shape the synthesized conformance produced, plus the pre-rename `muse` key.
  private enum CodingKeys: String, CodingKey { case otto, muse, user, routine, agent }
  private enum PayloadKeys: String, CodingKey { case _0 }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.otto) || container.contains(.muse) {
      self = .otto
    } else if container.contains(.user) {
      self = .user
    } else if container.contains(.routine) {
      let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .routine)
      self = .routine(try payload.decode(UUID.self, forKey: ._0))
    } else if container.contains(.agent) {
      let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .agent)
      self = .agent(try payload.decode(String.self, forKey: ._0))
    } else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Unknown brief item origin"))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .otto: _ = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .otto)
    case .user: _ = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .user)
    case .routine(let id):
      var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .routine)
      try payload.encode(id, forKey: ._0)
    case .agent(let name):
      var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .agent)
      try payload.encode(name, forKey: ._0)
    }
  }
}

public enum BriefAction: Codable, Equatable, Sendable {
  case openAgent(UUID)
  case openActivity
  case openRoutine(UUID)
  case openURL(String)
  /// Stops a running agent; offered next to "Open" on items about an agent that looks stuck.
  case stopAgent(UUID)
}

/// One line in the brief. Every item states why it is here; an item without a reason is noise.
public struct BriefItem: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var kind: BriefItemKind
  public var title: String
  public var reason: String?
  public var source: String?
  public var people: [String]
  /// Event start, or a to-do's deadline.
  public var time: Date?
  public var endTime: Date?
  public var needsYou: Bool
  public var projectID: UUID?
  public var profileID: UUID?
  public var origin: BriefItemOrigin
  public var action: BriefAction?
  /// A second thing to do from the item's menu, such as stopping an agent that looks stuck.
  public var secondaryAction: BriefAction?
  public var createdAt: Date
  public var completedAt: Date?

  public init(
    id: String = UUID().uuidString, kind: BriefItemKind, title: String, reason: String? = nil,
    source: String? = nil, people: [String] = [], time: Date? = nil, endTime: Date? = nil,
    needsYou: Bool = false, projectID: UUID? = nil, profileID: UUID? = nil,
    origin: BriefItemOrigin, action: BriefAction? = nil, secondaryAction: BriefAction? = nil,
    createdAt: Date = .now, completedAt: Date? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.reason = reason
    self.source = source
    self.people = people
    self.time = time
    self.endTime = endTime
    self.needsYou = needsYou
    self.projectID = projectID
    self.profileID = profileID
    self.origin = origin
    self.action = action
    self.secondaryAction = secondaryAction
    self.createdAt = createdAt
    self.completedAt = completedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, title, reason, source, people, time, endTime, needsYou, projectID, profileID
    case origin, action, secondaryAction, createdAt, completedAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    kind = try values.decode(BriefItemKind.self, forKey: .kind)
    title = try values.decode(String.self, forKey: .title)
    reason = try values.decodeIfPresent(String.self, forKey: .reason)
    source = try values.decodeIfPresent(String.self, forKey: .source)
    people = try values.decodeIfPresent([String].self, forKey: .people) ?? []
    time = try values.decodeIfPresent(Date.self, forKey: .time)
    endTime = try values.decodeIfPresent(Date.self, forKey: .endTime)
    needsYou = try values.decodeIfPresent(Bool.self, forKey: .needsYou) ?? false
    projectID = try values.decodeIfPresent(UUID.self, forKey: .projectID)
    profileID = try values.decodeIfPresent(UUID.self, forKey: .profileID)
    origin = try values.decode(BriefItemOrigin.self, forKey: .origin)
    action = try? values.decodeIfPresent(BriefAction.self, forKey: .action)
    secondaryAction = try? values.decodeIfPresent(BriefAction.self, forKey: .secondaryAction)
    createdAt = try values.decode(Date.self, forKey: .createdAt)
    completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
  }
}

/// What Home shows for one profile on one day. Empty sections are omitted, and an empty brief
/// means Home keeps its ordinary hero: the brief never pads itself with filler.
public struct DailyBrief: Equatable, Sendable {
  public var todos: [BriefItem]
  public var updates: [BriefItem]
  public var events: [BriefItem]
  public var completedTodayCount: Int

  public init(
    todos: [BriefItem] = [], updates: [BriefItem] = [], events: [BriefItem] = [],
    completedTodayCount: Int = 0
  ) {
    self.todos = todos
    self.updates = updates
    self.events = events
    self.completedTodayCount = completedTodayCount
  }

  public var isEmpty: Bool { todos.isEmpty && updates.isEmpty && events.isEmpty }

  /// A one-line summary such as "3 need you · 1 update · 4 on your calendar".
  public var headline: String? {
    var parts: [String] = []
    let needsYou = todos.filter(\.needsYou).count + updates.filter(\.needsYou).count
    if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
    let otherTodos = todos.filter { !$0.needsYou }.count
    if otherTodos > 0 { parts.append("\(otherTodos) to-do\(otherTodos == 1 ? "" : "s")") }
    let otherUpdates = updates.filter { !$0.needsYou }.count
    if otherUpdates > 0 {
      parts.append("\(otherUpdates) update\(otherUpdates == 1 ? "" : "s")")
    }
    if !events.isEmpty { parts.append("\(events.count) on your calendar") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

public enum DailyBriefComposer {
  public static let updateWindow: TimeInterval = 24 * 60 * 60
  public static let maxUpdates = 10

  /// Pure ranking and value gate. `candidates` mixes derived Otto items with stored ones.
  public static func compose(
    candidates: [BriefItem], profile: HomeProfile, legacyProjectID: UUID?,
    dismissedIDs: Set<String>, now: Date = .now, calendar: Calendar = .current
  ) -> DailyBrief {
    let visible = candidates.filter { item in
      guard !dismissedIDs.contains(item.id) else { return false }
      if let owner = item.profileID { return owner == profile.id }
      return profile.includes(projectID: item.projectID, legacyProjectID: legacyProjectID)
    }
    var seen = Set<String>()
    // The same meeting or ask can arrive from more than one account's run; show it once.
    var seenFromRoutines = Set<String>()
    let unique = visible.filter { item in
      guard seen.insert(item.id).inserted else { return false }
      guard case .routine = item.origin, item.kind != .update else { return true }
      let start = item.time.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? ""
      let key = "\(item.kind.rawValue)|\(item.title.lowercased())|\(start)"
      return seenFromRoutines.insert(key).inserted
    }

    let completedToday = unique.filter {
      $0.kind == .todo && $0.completedAt.map { calendar.isDate($0, inSameDayAs: now) } == true
    }.count
    let todos = unique.filter { $0.kind == .todo && $0.completedAt == nil }
      .sorted { lhs, rhs in
        if lhs.needsYou != rhs.needsYou { return lhs.needsYou }
        switch (lhs.time, rhs.time) {
        case (let l?, let r?): return l < r
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.createdAt > rhs.createdAt
        }
      }
    let sortedUpdates = unique.filter {
      $0.kind == .update && now.timeIntervalSince($0.createdAt) <= updateWindow
        && $0.createdAt <= now.addingTimeInterval(60)
    }
    .sorted { lhs, rhs in
      if lhs.needsYou != rhs.needsYou { return lhs.needsYou }
      return lhs.createdAt > rhs.createdAt
    }
    // Repeats read as noise: keep the newest of identical headlines, and only the latest few.
    var seenTitles = Set<String>()
    let updates = Array(
      sortedUpdates.filter { seenTitles.insert($0.title.lowercased()).inserted }
        .prefix(maxUpdates))
    let events = unique.filter { item in
      guard item.kind == .event, let start = item.time else { return false }
      guard calendar.isDate(start, inSameDayAs: now) else { return false }
      // A finished meeting is no longer news.
      return (item.endTime ?? start.addingTimeInterval(30 * 60)) > now
    }
    .sorted { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }

    return DailyBrief(
      todos: todos, updates: updates, events: events, completedTodayCount: completedToday)
  }
}

/// Parses an agent's brief output. Agents are asked for a fenced JSON object
/// `{"items":[...]}`; anything else is kept as one plain update so a run is never lost.
public enum BriefOutputParser {
  public struct WireItem: Decodable {
    var kind: String?
    var title: String
    var reason: String?
    var source: String?
    var people: [String]?
    var time: String?
    var end: String?
    var needsYou: Bool?
    var url: String?
  }
  private struct Envelope: Decodable { var items: [WireItem] }

  public static func parse(
    _ text: String, origin: BriefItemOrigin, profileID: UUID?, projectID: UUID? = nil,
    sourceName: String? = nil, now: Date = .now
  ) -> [BriefItem] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "[SILENT]" else { return [] }
    if let wire = decodeItems(trimmed) {
      return wire.compactMap { item in
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let kind = BriefItemKind(rawValue: (item.kind ?? "update").lowercased()) ?? .update
        return BriefItem(
          kind: kind, title: String(title.prefix(160)),
          reason: item.reason.map { String($0.prefix(600)) },
          source: item.source ?? sourceName, people: item.people ?? [],
          time: item.time.flatMap(date), endTime: item.end.flatMap(date),
          needsYou: item.needsYou ?? false, projectID: projectID, profileID: profileID,
          origin: origin, action: item.url.map(BriefAction.openURL), createdAt: now)
      }
    }
    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let title = lines.first.map(cleanLine) ?? "Routine result"
    let rest = lines.dropFirst().map(cleanLine).joined(separator: " ")
    return [
      BriefItem(
        kind: .update, title: String(title.prefix(160)),
        reason: rest.isEmpty ? nil : String(rest.prefix(600)), source: sourceName,
        projectID: projectID, profileID: profileID, origin: origin, createdAt: now)
    ]
  }

  private static func decodeItems(_ text: String) -> [WireItem]? {
    var candidates: [String] = []
    if let fence = text.range(of: "```json") ?? text.range(of: "```"),
      let close = text.range(of: "```", range: fence.upperBound..<text.endIndex)
    {
      candidates.append(String(text[fence.upperBound..<close.lowerBound]))
    }
    if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
      candidates.append(String(text[open...close]))
    }
    for candidate in candidates {
      guard let data = candidate.data(using: .utf8) else { continue }
      if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
        return envelope.items
      }
    }
    return nil
  }

  static func date(_ value: String) -> Date? {
    let full = ISO8601DateFormatter()
    if let date = full.date(from: value) { return date }
    full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return full.date(from: value)
  }

  public static func cleanLine(_ line: String) -> String {
    line.trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: #"^(#+|[-*•]|\d+\.)\s*"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: "**", with: "")
  }
}
