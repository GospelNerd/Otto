import Foundation
import OttoModels

/// Where a skill was found. Every harness Otto runs stores skills as a folder with a `SKILL.md`.
public enum SkillSource: String, Codable, CaseIterable, Identifiable, Sendable {
  case otto
  case claudeCode
  case claudePlugins
  case codex
  case shared
  case hermes
  case openCode

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .otto: "Otto"
    case .claudeCode: "Claude Code"
    case .claudePlugins: "Claude plugins"
    case .codex: "Codex"
    case .shared: "Shared"
    case .hermes: "Hermes"
    case .openCode: "OpenCode"
    }
  }

  /// The folder each harness reads, relative to the home folder.
  var relativeRoot: String {
    switch self {
    case .otto: "Library/Application Support/Otto/Skills"
    case .claudeCode: ".claude/skills"
    case .claudePlugins: ".claude/plugins"
    case .codex: ".codex/skills"
    case .shared: ".agents/skills"
    case .hermes: ".hermes/skills"
    case .openCode: ".config/opencode/skills"
    }
  }

  /// Plugin and Hermes skills sit in nested category or version folders.
  var searchDepth: Int {
    switch self {
    case .claudePlugins: 7
    case .hermes: 4
    default: 3
    }
  }
}

public struct SkillLocation: Codable, Equatable, Hashable, Sendable {
  public var source: SkillSource
  public var path: String
}

/// One skill as the library shows it: the same name found in several harnesses is one entry.
public struct SkillEntry: Identifiable, Equatable, Sendable {
  public var id: String { name }
  public var name: String
  public var description: String
  public var locations: [SkillLocation]
  /// Times a session used the skill in the last 30 days, where Otto can tell.
  public var uses: Int
  public var lastUsed: Date?

  public var sources: [SkillSource] {
    SkillSource.allCases.filter { source in locations.contains { $0.source == source } }
  }
  public var isInOtto: Bool { sources.contains(.otto) }
  /// The copy to read and show: Otto's own first, else the first one found.
  public var primaryPath: String {
    (locations.first { $0.source == .otto } ?? locations[0]).path
  }
}

/// Who an Otto skill is offered to. Delivery into each harness comes from this.
public enum SkillAudience: Codable, Equatable, Hashable, Sendable {
  case everyone
  case bots([UUID])
}

public struct SkillParser {
  /// Reads `name` and `description` from SKILL.md frontmatter, including YAML folded (`>`) and
  /// literal (`|`) blocks. Missing names fall back to the folder name.
  public static func metadata(_ text: String, folderName: String) -> (
    name: String, description: String
  ) {
    var lines = text.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
      return (folderName, firstParagraph(text))
    }
    lines.removeFirst()
    var fields: [String: String] = [:]
    var index = 0
    while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "---" {
      let line = lines[index]
      index += 1
      guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { continue }
      let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
      var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      if value.hasPrefix(">") || value.hasPrefix("|") || value.isEmpty {
        var parts: [String] = []
        while index < lines.count, lines[index].hasPrefix(" ") || lines[index].isEmpty,
          lines[index].trimmingCharacters(in: .whitespaces) != "---"
        {
          let part = lines[index].trimmingCharacters(in: .whitespaces)
          if !part.isEmpty { parts.append(part) }
          index += 1
        }
        value = parts.joined(separator: " ")
      }
      fields[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folderName
    return (name, fields["description"] ?? "")
  }

  private static func firstParagraph(_ text: String) -> String {
    text.components(separatedBy: "\n\n").first { !$0.hasPrefix("#") && !$0.isEmpty }?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// The instructions after the frontmatter.
  public static func body(_ text: String) -> String {
    guard text.hasPrefix("---") else { return text }
    let parts = text.components(separatedBy: "\n---")
    guard parts.count > 1 else { return text }
    return parts.dropFirst().joined(separator: "\n---")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public struct SkillScanner: Sendable {
  public let home: URL

  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.home = home
  }

  public func root(_ source: SkillSource) -> URL {
    home.appending(path: source.relativeRoot, directoryHint: .isDirectory)
  }

  /// Every skill in every known folder, merged by name.
  public func scan(
    usage: [String: (count: Int, last: Date)] = [:],
    sources: [SkillSource] = SkillSource.allCases
  ) -> [SkillEntry] {
    var byName: [String: SkillEntry] = [:]
    for source in sources {
      for file in skillFiles(under: root(source), depth: source.searchDepth) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let folder = file.deletingLastPathComponent().lastPathComponent
        let meta = SkillParser.metadata(text, folderName: folder)
        let location = SkillLocation(source: source, path: file.path)
        if var existing = byName[meta.name] {
          if !existing.locations.contains(location) { existing.locations.append(location) }
          if existing.description.isEmpty { existing.description = meta.description }
          byName[meta.name] = existing
        } else {
          byName[meta.name] = SkillEntry(
            name: meta.name, description: meta.description, locations: [location], uses: 0,
            lastUsed: nil)
        }
      }
    }
    for name in byName.keys {
      // Claude Code names plugin skills "plugin:skill"; match either spelling.
      let hits = usage.filter { key, _ in key == name || key.hasSuffix(":" + name) }.values
      byName[name]?.uses = hits.reduce(0) { $0 + $1.count }
      byName[name]?.lastUsed = hits.map(\.last).max()
    }
    return byName.values.sorted {
      $0.uses != $1.uses
        ? $0.uses > $1.uses
        : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Walks `root` up to `depth` levels, following symlinked folders (people often link one
  /// skills folder into another) without visiting the same real folder twice.
  /// Only Otto's own library: cheap enough to read on every launch and tool call.
  public func ottoSkills() -> [SkillEntry] { scan(sources: [.otto]) }

  private func skillFiles(under root: URL, depth: Int) -> [URL] {
    var files: [URL] = []
    var visited = Set<String>()
    func walk(_ folder: URL, level: Int) {
      let real = folder.resolvingSymlinksInPath()
      guard level <= depth, visited.insert(real.path).inserted,
        let children = try? FileManager.default.contentsOfDirectory(
          at: real, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      else { return }
      for child in children {
        let name = child.lastPathComponent
        if name == "SKILL.md" {
          files.append(child)
        } else if name != "node_modules",
          (try? child.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory == true
        {
          walk(child, level: level + 1)
        }
      }
    }
    walk(root, level: 0)
    return files
  }

  /// Skill uses Claude Code logged in the last `days` days. Codex and Hermes logs list every
  /// available skill at session start, so they cannot tell "available" from "used" and are not
  /// counted.
  public func claudeCodeUsage(days: Int = 30, now: Date = Date()) -> [String: (
    count: Int, last: Date
  )] {
    let projects = home.appending(path: ".claude/projects", directoryHint: .isDirectory)
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    guard
      let enumerator = FileManager.default.enumerator(
        at: projects, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return [:] }
    let marker = Data(#""name":"Skill","input":{"skill":""#.utf8)
    var usage: [String: (count: Int, last: Date)] = [:]
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate, modified >= cutoff,
        let data = try? Data(contentsOf: url, options: .mappedIfSafe)
      else { continue }
      var start = data.startIndex
      while let range = data.range(of: marker, in: start..<data.endIndex) {
        let nameStart = range.upperBound
        guard let quote = data[nameStart...].firstIndex(of: UInt8(ascii: "\"")) else { break }
        let name = String(decoding: data[nameStart..<quote], as: UTF8.self)
        let previous = usage[name]
        usage[name] = ((previous?.count ?? 0) + 1, max(previous?.last ?? .distantPast, modified))
        start = quote
      }
    }
    return usage
  }
}

/// Otto's own skills: the shared library every bot, team and session can be given.
@MainActor
public final class SkillLibraryStore: ObservableObject {
  @Published public private(set) var entries: [SkillEntry] = []
  @Published public private(set) var audiences: [String: SkillAudience] = [:]
  @Published public private(set) var isScanning = false
  @Published public private(set) var lastScan: Date?

  private let scanner: SkillScanner
  private var audiencesURL: URL {
    scanner.root(.otto).appending(path: ".audiences.json")
  }

  public init(scanner: SkillScanner = SkillScanner()) {
    self.scanner = scanner
    loadAudiences()
  }

  public func refresh() {
    guard !isScanning else { return }
    isScanning = true
    let scanner = scanner
    // The scan reads files off the main actor; only its Sendable result comes back.
    Task {
      let entries = await Task.detached(priority: .utility) {
        scanner.scan(usage: scanner.claudeCodeUsage())
      }.value
      self.entries = entries
      isScanning = false
      lastScan = Date()
    }
  }

  public func text(of entry: SkillEntry) -> String {
    (try? String(contentsOfFile: entry.primaryPath, encoding: .utf8)) ?? ""
  }

  public func audience(of entry: SkillEntry) -> SkillAudience {
    audience(named: entry.name)
  }

  public func audience(named name: String) -> SkillAudience {
    audiences[name] ?? .everyone
  }

  /// Otto skills offered to a bot (`profileID`) or, with nil, to sessions that are not a bot.
  public func ottoSkills(for profileID: UUID?) -> [SkillEntry] {
    scanner.ottoSkills().filter { entry in
      switch audience(named: entry.name) {
      case .everyone: true
      case .bots(let ids): profileID.map(ids.contains) ?? false
      }
    }
  }

  /// Copies a harness's skill folder into Otto's library. The original stays untouched, so an
  /// edit in Otto never changes what that harness reads.
  public func addToOtto(_ entry: SkillEntry) throws {
    guard !entry.isInOtto, let location = entry.locations.first else { return }
    let sourceFolder = URL(fileURLWithPath: location.path).deletingLastPathComponent()
    let destination = scanner.root(.otto).appending(
      path: Self.folderName(entry.name), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: scanner.root(.otto), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: sourceFolder.resolvingSymlinksInPath(), to: destination)
    updateEntry(entry.name) {
      $0.locations.insert(
        SkillLocation(source: .otto, path: destination.appending(path: "SKILL.md").path), at: 0)
    }
  }

  /// True when the skill also lives in a harness, so sharing it can be switched off without
  /// losing it. Skills written in Otto have nowhere else to fall back to.
  public func canStopSharing(_ entry: SkillEntry) -> Bool {
    entry.isInOtto && entry.sources.contains { $0 != .otto }
  }

  /// Undoes `addToOtto`: Otto's copy goes to the Trash (recoverable) and the harness copy it was
  /// made from is untouched.
  public func stopSharing(_ entry: SkillEntry) throws {
    guard canStopSharing(entry),
      let otto = entry.locations.first(where: { $0.source == .otto })
    else { return }
    let folder = URL(fileURLWithPath: otto.path).deletingLastPathComponent()
    // Only ever remove a folder inside Otto's own library.
    guard
      folder.standardizedFileURL.path.hasPrefix(scanner.root(.otto).standardizedFileURL.path + "/")
    else { return }
    try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    updateEntry(entry.name) { $0.locations.removeAll { $0.source == .otto } }
    audiences[entry.name] = nil
    saveAudiences()
  }

  public func create(name: String, description: String, instructions: String) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let folder = scanner.root(.otto).appending(
      path: Self.folderName(trimmed), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let oneLine = description.replacingOccurrences(of: "\n", with: " ")
    let text = "---\nname: \(trimmed)\ndescription: \(oneLine)\n---\n\n\(instructions)\n"
    try text.write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    refresh()
  }

  public func setAudience(_ audience: SkillAudience, for entry: SkillEntry) {
    audiences[entry.name] = audience
    saveAudiences()
  }

  private func updateEntry(_ name: String, _ change: (inout SkillEntry) -> Void) {
    guard let index = entries.firstIndex(where: { $0.name == name }) else { return }
    change(&entries[index])
  }

  static func folderName(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let cleaned = name.lowercased().unicodeScalars.map {
      allowed.contains($0) ? Character($0) : "-"
    }
    return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private func loadAudiences() {
    guard let data = try? Data(contentsOf: audiencesURL),
      let decoded = try? JSONDecoder().decode([String: SkillAudience].self, from: data)
    else { return }
    audiences = decoded
  }

  private func saveAudiences() {
    try? FileManager.default.createDirectory(
      at: scanner.root(.otto), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(audiences) {
      try? data.write(to: audiencesURL, options: .atomic)
    }
  }
}
