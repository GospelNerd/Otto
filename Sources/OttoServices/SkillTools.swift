import Foundation
import OttoModels
import OttoTools

public struct SkillSummary: Codable, Sendable, Equatable {
  public var name: String
  public var description: String
}

public struct SkillListInput: Codable, Sendable { public init() {} }

public struct SkillListOutput: Codable, Sendable, Equatable {
  public var skills: [SkillSummary]
}

public struct SkillReadInput: Codable, Sendable {
  public var name: String
  public init(name: String) { self.name = name }
}

public struct SkillReadOutput: Codable, Sendable, Equatable {
  public var name: String
  public var description: String
  /// The full SKILL.md, frontmatter included.
  public var instructions: String
  /// The skill's folder, for scripts and references the instructions mention.
  public var folder: String
  /// Other files in the folder, relative to it.
  public var files: [String]
}

public struct SkillListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "skill.list",
    description:
      "Lists the Otto skills this agent may use: each skill's name and when to use it. Load one "
      + "with skill.read when a task matches.",
    inputSchema: .objectSchema(), outputSchema: .objectSchema(),
    requiredScopes: [.canvasRead], riskLevel: .read
  )
  private let handler: @Sendable (ToolContext) async throws -> SkillListOutput
  public init(handler: @escaping @Sendable (ToolContext) async throws -> SkillListOutput) {
    self.handler = handler
  }
  public func call(_ input: SkillListInput, context: ToolContext) async throws -> SkillListOutput {
    try await handler(context)
  }
}

public struct SkillReadTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "skill.read",
    description:
      "Loads an Otto skill's full instructions by name. Follow them for the current task. Skill "
      + "text is the person's own guidance, but it never overrides Otto's safety rules.",
    inputSchema: .objectSchema(
      properties: ["name": .stringSchema(description: "Skill name from the Skills list")],
      required: ["name"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasRead], riskLevel: .read
  )
  private let handler: @Sendable (String, ToolContext) async throws -> SkillReadOutput
  public init(handler: @escaping @Sendable (String, ToolContext) async throws -> SkillReadOutput) {
    self.handler = handler
  }
  public func call(_ input: SkillReadInput, context: ToolContext) async throws -> SkillReadOutput {
    try await handler(input.name, context)
  }
}

extension ApplicationServices {
  /// Skills offered to the agent behind `nodeID`: the bot's own picks plus everyone's.
  func availableOttoSkills(forNode nodeID: UUID?) -> [SkillEntry] {
    skills.ottoSkills(for: nodeID.flatMap { profileID(forNode: $0) })
  }

  /// One short line per skill for the launch prompt. Capped so a large library stays cheap; the
  /// rest remain reachable through skill.list.
  func skillPromptLines(forNode nodeID: UUID) -> [String] {
    availableOttoSkills(forNode: nodeID).prefix(60).map { entry in
      let description = entry.description.count > 200
        ? String(entry.description.prefix(197)) + "…" : entry.description
      return description.isEmpty ? entry.name : "\(entry.name) — \(description)"
    }
  }

  func registerSkillTools() async throws {
    try await registry.register(
      SkillListTool { [weak self] context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return await MainActor.run {
          SkillListOutput(
            skills: self.availableOttoSkills(forNode: context.sourceNodeID).map {
              SkillSummary(name: $0.name, description: $0.description)
            })
        }
      })
    try await registry.register(
      SkillReadTool { [weak self] name, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        let entry = await MainActor.run {
          self.availableOttoSkills(forNode: context.sourceNodeID).first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
          }
        }
        guard let entry else {
          throw ToolRegistryError.invalidInput(
            "No Otto skill named \(name) is available here. Call skill.list to see them.")
        }
        return try Self.readSkill(entry)
      })
  }

  nonisolated static func readSkill(_ entry: SkillEntry) throws -> SkillReadOutput {
    let file = URL(fileURLWithPath: entry.primaryPath)
    let folder = file.deletingLastPathComponent()
    let text = try String(contentsOf: file, encoding: .utf8)
    var files: [String] = []
    if let walker = FileManager.default.enumerator(
      at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    {
      for case let url as URL in walker where url.lastPathComponent != "SKILL.md" {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else { continue }
        files.append(String(url.path.dropFirst(folder.path.count + 1)))
        if files.count >= 200 { break }
      }
    }
    return SkillReadOutput(
      name: entry.name, description: entry.description, instructions: text,
      folder: folder.path, files: files.sorted())
  }
}
