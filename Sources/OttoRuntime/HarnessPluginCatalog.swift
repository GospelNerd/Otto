import Foundation
import OttoModels

/// A plugin or built-in capability the hired bot will inherit from its harness or from Otto.
public struct HarnessPlugin: Equatable, Sendable, Identifiable {
  public var id: String { "\(source):\(name)" }
  public var name: String
  public var source: String
  /// One- or two-character mark drawn on the logo tile when no glyph is mapped.
  public var mark: String
  public var colorHex: String

  public init(name: String, source: String, mark: String, colorHex: String) {
    self.name = name
    self.source = source
    self.mark = mark
    self.colorHex = colorHex
  }
}

/// Best-effort inventory of MCP servers declared for a harness. This reads local config
/// files; it does not launch the provider or enumerate live tool schemas.
public enum HarnessPluginCatalog {
  /// Source tag for Otto's own built-in plugins.
  public static let ottoSource = "otto"

  public static let ottoBuiltins: [HarnessPlugin] = [
    branded(name: "Canvas", raw: "canvas", source: ottoSource),
    branded(name: "Memory", raw: "memory", source: ottoSource),
    branded(name: "Browser", raw: "browser", source: ottoSource),
    branded(name: "Terminal", raw: "terminal", source: ottoSource),
  ]

  /// Desktop control (native apps through the accessibility tree) joins the built-ins once the
  /// agent-desktop CLI is installed; before that a bot would only be told to set it up.
  public static let desktopBuiltin = branded(name: "Desktop", raw: "computeruse", source: ottoSource)

  public static func ottoBuiltins(desktopInstalled: Bool) -> [HarnessPlugin] {
    desktopInstalled ? ottoBuiltins + [desktopBuiltin] : ottoBuiltins
  }

  public static func plugins(
    for provider: AgentProvider,
    workspacePath: String,
    homeDirectory: String = NSHomeDirectory(),
    fileManager: FileManager = .default,
    desktopInstalled: Bool = AgentDesktopLocator.isInstalled
  ) -> [HarnessPlugin] {
    var names: [String] = []
    for url in configURLs(
      for: provider, workspacePath: workspacePath, homeDirectory: homeDirectory)
    {
      names.append(
        contentsOf: serverNames(in: url, workspacePath: workspacePath, fileManager: fileManager))
    }
    // Otto's own MCP server (and the `muse` entry from before the rename) is shown through
    // the branded built-ins above, never as a third-party plugin.
    let unique = orderedUnique(
      names.filter { !OttoMCPRegistration.serverNames.contains($0.lowercased()) })
    let harness = unique.map { branded(name: displayName($0), raw: $0, source: provider.rawValue) }
    return ottoBuiltins(desktopInstalled: desktopInstalled) + harness
  }

  /// How a person adds another MCP server or plugin for this harness.
  public static func addMoreHint(for provider: AgentProvider) -> String {
    if provider == .hermes {
      return "Hermes manages its own app connections."
    }
    return "Manage additional apps and MCP servers in your provider’s own settings."
  }

  /// Resolve a display name back to a configured server identity, never a shell command.
  /// Only providers with a documented standalone MCP authentication command are included.
  public static func authenticationServer(
    named name: String, provider: AgentProvider, workspacePath: String,
    homeDirectory: String = NSHomeDirectory()
  ) -> String? {
    guard provider == .cursor || provider == .openCode else { return nil }
    var matches = Set<String>()
    for url in configURLs(for: provider, workspacePath: workspacePath, homeDirectory: homeDirectory)
    where url.pathExtension == "json" || url.pathExtension == "jsonc" {
      guard let data = try? Data(contentsOf: url), data.count <= 1_048_576,
        let root = try? JSONSerialization.jsonObject(
          with: Data(stripJSONC(String(decoding: data, as: UTF8.self)).utf8)) as? [String: Any],
        let servers = root[provider == .cursor ? "mcpServers" : "mcp"] as? [String: Any]
      else { continue }
      for (id, value) in servers {
        guard displayName(id) == name, !OttoMCPRegistration.serverNames.contains(id),
          !id.hasPrefix("-"), id.count <= 200,
          let config = value as? [String: Any],
          config["url"] is String,
          provider != .openCode
            || (config["type"] as? String == "remote" && config["oauth"] as? Bool != false)
        else { continue }
        matches.insert(id)
      }
    }
    return matches.count == 1 ? matches.first : nil
  }

  static func configURLs(
    for provider: AgentProvider, workspacePath: String, homeDirectory: String
  ) -> [URL] {
    let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
    let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
    switch provider {
    case .codex:
      return [
        home.appending(path: ".codex/config.toml"),
        workspace.appending(path: ".codex/config.toml"),
      ]
    case .openAI:
      return []
    case .claudeCode:
      return [
        home.appending(path: ".claude.json"),
        home.appending(path: ".claude/settings.json"),
        workspace.appending(path: ".mcp.json"),
        workspace.appending(path: ".claude/mcp.json"),
        workspace.appending(path: ".claude/settings.json"),
      ]
    case .cursor:
      return [
        home.appending(path: ".cursor/mcp.json"),
        workspace.appending(path: ".cursor/mcp.json"),
      ]
    case .kimi:
      return [
        home.appending(path: ".kimi-code/mcp.json"),
        home.appending(path: ".kimi/mcp.json"),
        workspace.appending(path: ".kimi-code/mcp.json"),
        workspace.appending(path: ".mcp.json"),
      ]
    case .grok:
      return [
        home.appending(path: ".grok/config.toml"),
        workspace.appending(path: ".grok/config.toml"),
        workspace.appending(path: ".mcp.json"),
      ]
    case .openCode:
      return [
        home.appending(path: ".config/opencode/opencode.json"),
        home.appending(path: ".config/opencode/opencode.jsonc"),
        workspace.appending(path: "opencode.json"),
        workspace.appending(path: "opencode.jsonc"),
        workspace.appending(path: ".mcp.json"),
      ]
    case .pi:
      return [
        home.appending(path: ".pi/agent/mcp.json"),
        workspace.appending(path: ".pi/mcp.json"),
      ]
    case .hermes:
      return [
        home.appending(path: ".hermes/config.yaml"),
        home.appending(path: ".hermes/config.yml"),
        workspace.appending(path: ".mcp.json"),
      ]
    case .shell:
      return []
    }
  }

  static func serverNames(in url: URL, workspacePath: String, fileManager: FileManager) -> [String]
  {
    guard fileManager.fileExists(atPath: url.path),
      let data = fileManager.contents(atPath: url.path)
    else { return [] }
    let ext = url.pathExtension.lowercased()
    if ext == "toml" {
      let text = String(decoding: data, as: UTF8.self)
      return tomlPluginNames(text) + tomlServerNames(text)
    }
    if ext == "yaml" || ext == "yml" {
      return yamlServerNames(String(decoding: data, as: UTF8.self))
    }
    return jsonServerNames(data, workspacePath: workspacePath)
  }

  static func jsonServerNames(_ data: Data, workspacePath: String) -> [String] {
    let text = String(decoding: data, as: UTF8.self)
    let payload = Data(stripJSONC(text).utf8)
    guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
      return []
    }
    var names: [String] = []
    names.append(contentsOf: dictionaryKeys(root["mcpServers"]))
    names.append(contentsOf: dictionaryKeys(root["mcp"]))
    if let projects = root["projects"] as? [String: Any],
      let project = projects[workspacePath] as? [String: Any]
    {
      names.append(contentsOf: dictionaryKeys(project["mcpServers"]))
      names.append(contentsOf: dictionaryKeys(project["mcp"]))
    }
    return names
  }

  static func tomlPluginNames(_ text: String) -> [String] {
    var names: [String] = []
    var enabled: [String: Bool] = [:]
    var current: String?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let heading = line.trimmingCharacters(in: .whitespaces)
      if heading.hasPrefix("["), heading.hasSuffix("]") {
        current = nil
        let body = String(heading.dropFirst().dropLast())
        guard body.hasPrefix("plugins.") else { continue }
        var rest = String(body.dropFirst("plugins.".count))
        if rest.hasPrefix("\""), rest.hasSuffix("\"") {
          rest = String(rest.dropFirst().dropLast())
        }
        let plugin =
          rest.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
          .first.map(String.init) ?? rest
        guard !plugin.isEmpty else { continue }
        current = plugin
        if enabled[plugin] == nil {
          names.append(plugin)
          enabled[plugin] = true
        }
        continue
      }
      if let current, heading.hasPrefix("enabled") {
        let value = heading.split(separator: "=", maxSplits: 1).last?
          .trimmingCharacters(in: .whitespaces).lowercased()
        if value == "false" { enabled[current] = false }
      }
    }
    return names.filter { enabled[$0] != false }
  }

  static func tomlServerNames(_ text: String) -> [String] {
    var names: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let heading = line.trimmingCharacters(in: .whitespaces)
      guard heading.hasPrefix("["), heading.hasSuffix("]") else { continue }
      let name = String(heading.dropFirst().dropLast())
      guard name.hasPrefix("mcp_servers.") else { continue }
      let rest = String(name.dropFirst("mcp_servers.".count))
      if !rest.isEmpty, !rest.contains(".") { names.append(rest) }
    }
    return names
  }

  /// Collects first-level keys under a top-level `mcp_servers:` mapping.
  static func yamlServerNames(_ text: String) -> [String] {
    var names: [String] = []
    var collecting = false
    var childIndent: Int?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let raw = String(line)
      if raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
      let indent = raw.prefix(while: { $0 == " " }).count
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      if !collecting {
        if indent == 0, trimmed == "mcp_servers:" || trimmed.hasPrefix("mcp_servers:") {
          collecting = true
          childIndent = nil
        }
        continue
      }
      if trimmed.isEmpty { continue }
      if indent == 0 {
        break
      }
      if childIndent == nil { childIndent = indent }
      guard indent == childIndent, let key = yamlMappingKey(trimmed) else { continue }
      if key != "command", key != "url", key != "args", key != "env", key != "headers",
        key != "enabled", key != "type"
      {
        names.append(key)
      }
    }
    return names
  }

  static func branded(name: String, raw: String, source: String) -> HarnessPlugin {
    let style = PluginBrand.style(for: raw)
    return HarnessPlugin(name: name, source: source, mark: style.mark, colorHex: style.colorHex)
  }

  private static func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
      let key = value.lowercased()
      if seen.insert(key).inserted { result.append(value) }
    }
    return result
  }

  private static func displayName(_ raw: String) -> String {
    let key = PluginBrand.normalize(raw)
    if let override = displayOverrides[key] { return override }
    return raw.replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  private static let displayOverrides: [String: String] = [
    "n8n": "n8n",
    "n8nmcp": "n8n",
    "gtmgrid": "GTM Grid",
    "noderepl": "Node REPL",
    "computeruse": "Computer Use",
    "browsermcp": "Browser MCP",
    "zenrowsdocs": "ZenRows",
    "github": "GitHub",
    "gmail": "Gmail",
    "outlook": "Outlook",
    "googlecalendar": "Calendar",
    "googledrive": "Drive",
    "documents": "Docs",
    "spreadsheets": "Sheets",
    "presentations": "Slides",
    "pdf": "PDF",
    "visualize": "Visualize",
    "sites": "Sites",
    "chrome": "Chrome",
    "templatecreator": "Templates",
    "supabase": "Supabase",
    "stripe": "Stripe",
    "linear": "Linear",
    "slack": "Slack",
  ]

  private static func dictionaryKeys(_ value: Any?) -> [String] {
    (value as? [String: Any])?.keys.sorted() ?? []
  }

  private static func yamlMappingKey(_ trimmed: String) -> String? {
    guard let colon = trimmed.firstIndex(of: ":") else { return nil }
    let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
    return key.isEmpty ? nil : key
  }

  private static func stripJSONC(_ text: String) -> String {
    var result = ""
    var index = text.startIndex
    var inString = false
    var escaped = false
    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)
      if inString {
        result.append(character)
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        index = next
        continue
      }
      if character == "\"" {
        inString = true
        result.append(character)
        index = next
        continue
      }
      if character == "/", next < text.endIndex, text[next] == "/" {
        while index < text.endIndex, text[index] != "\n" {
          index = text.index(after: index)
        }
        continue
      }
      if character == "/", next < text.endIndex, text[next] == "*" {
        index = text.index(after: next)
        while index < text.endIndex {
          if text[index] == "*", text.index(after: index) < text.endIndex,
            text[text.index(after: index)] == "/"
          {
            index = text.index(after: text.index(after: index))
            break
          }
          index = text.index(after: index)
        }
        continue
      }
      result.append(character)
      index = next
    }
    return result
  }
}

public enum PluginLogoKind: String, Sendable, Equatable {
  /// Monochrome glyph, drawn white on the brand color tile.
  case template
  /// Full-color mark on a light plate.
  case mark
  /// App-icon artwork that already includes its own background.
  case original
}

public enum PluginBrand {
  public static func style(for raw: String) -> (mark: String, colorHex: String) {
    let key = normalize(raw)
    if let known = brands[key] { return known }
    let mark = String(raw.trimmingCharacters(in: .whitespaces).prefix(2)).uppercased()
    return (mark.isEmpty ? "?" : mark, fallbackColor(for: key))
  }

  public static func logo(for raw: String) -> (asset: String, kind: PluginLogoKind)? {
    logos[normalize(raw)]
  }

  public static func normalize(_ raw: String) -> String {
    raw.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  private static let brands: [String: (mark: String, colorHex: String)] = [
    "canvas": ("Cv", "#397B69"),
    "memory": ("Me", "#526B8E"),
    "browser": ("Br", "#AD6A66"),
    "terminal": (">_", "#A46E21"),
    "gmail": ("M", "#EA4335"),
    "googlemail": ("M", "#EA4335"),
    "outlook": ("O", "#0078D4"),
    "microsoft365": ("O", "#0078D4"),
    "office365": ("O", "#0078D4"),
    "slack": ("#", "#4A154B"),
    "linear": ("L", "#5E6AD2"),
    "github": ("GH", "#24292F"),
    "gitlab": ("GL", "#FC6D26"),
    "notion": ("N", "#111111"),
    "jira": ("J", "#0052CC"),
    "figma": ("F", "#F24E1E"),
    "drive": ("D", "#4285F4"),
    "googledrive": ("D", "#4285F4"),
    "calendar": ("C", "#0F9D58"),
    "gcal": ("C", "#0F9D58"),
    "googlecalendar": ("C", "#0F9D58"),
    "dropbox": ("Db", "#0061FF"),
    "discord": ("D", "#5865F2"),
    "n8n": ("n8", "#EA4B71"),
    "n8nmcp": ("n8", "#EA4B71"),
    "posthog": ("P", "#1D4AFF"),
    "stripe": ("S", "#635BFF"),
    "hubspot": ("H", "#FF7A59"),
    "salesforce": ("Sf", "#00A1E0"),
    "supabase": ("S", "#3ECF8E"),
    "vercel": ("▲", "#111111"),
    "cloudflare": ("Cf", "#F38020"),
    "openai": ("O", "#10A37F"),
    "anthropic": ("A", "#D97757"),
    "trigify": ("T", "#FF2D8A"),
    "gtmgrid": ("G", "#166534"),
    "exa": ("E", "#0143D9"),
    "heyreach": ("H", "#2563EB"),
    "tella": ("T", "#7C3AED"),
    "silco": ("S", "#334155"),
    "browsermcp": ("B", "#0EA5E9"),
    "zenrows": ("Z", "#0F172A"),
    "zenrowsdocs": ("Z", "#0F172A"),
    "computeruse": ("C", "#111827"),
    "noderepl": ("JS", "#F59E0B"),
    "context7": ("7", "#4F46E5"),
    "filesystem": ("Fs", "#4B5563"),
    "postgres": ("Pg", "#336791"),
    "postgresql": ("Pg", "#336791"),
    "githubmcp": ("GH", "#24292F"),
    "composio": ("Co", "#111827"),
  ]

  private static let logos: [String: (asset: String, kind: PluginLogoKind)] = [
    "canvas": ("canvas", .template),
    "memory": ("memory", .template),
    "browser": ("browser", .template),
    "browsermcp": ("browser", .template),
    "terminal": ("terminal", .template),
    "gmail": ("gmail", .mark),
    "googlemail": ("gmail", .mark),
    "outlook": ("outlook", .original),
    "microsoft365": ("outlook", .original),
    "office365": ("outlook", .original),
    "slack": ("slack", .mark),
    "linear": ("linear", .mark),
    "github": ("github", .mark),
    "githubmcp": ("github", .mark),
    "gitlab": ("gitlab", .template),
    "notion": ("notion", .template),
    "jira": ("jira", .template),
    "figma": ("figma", .template),
    "drive": ("googledrive", .mark),
    "googledrive": ("googledrive", .mark),
    "calendar": ("googlecalendar", .mark),
    "gcal": ("googlecalendar", .mark),
    "googlecalendar": ("googlecalendar", .mark),
    "documents": ("googledocs", .mark),
    "googledocs": ("googledocs", .mark),
    "spreadsheets": ("googlesheets", .mark),
    "googlesheets": ("googlesheets", .mark),
    "presentations": ("googleslides", .mark),
    "googleslides": ("googleslides", .mark),
    "pdf": ("pdf", .mark),
    "chrome": ("googlechrome", .mark),
    "googlechrome": ("googlechrome", .mark),
    "visualize": ("visualize", .mark),
    "sites": ("sites", .mark),
    "dropbox": ("dropbox", .template),
    "discord": ("discord", .template),
    "n8n": ("n8n", .mark),
    "n8nmcp": ("n8n", .mark),
    "posthog": ("posthog", .template),
    "stripe": ("stripe", .mark),
    "hubspot": ("hubspot", .template),
    "salesforce": ("salesforce", .template),
    "supabase": ("supabase", .mark),
    "vercel": ("vercel", .template),
    "cloudflare": ("cloudflare", .template),
    "docker": ("docker", .template),
    "postgres": ("postgresql", .template),
    "postgresql": ("postgresql", .template),
    "noderepl": ("nodedotjs", .mark),
    "node": ("nodedotjs", .mark),
    "javascript": ("javascript", .mark),
    "exa": ("exa-icon", .original),
    "trigify": ("trigify", .mark),
    "gtmgrid": ("gtmgrid", .mark),
    "computeruse": ("computeruse", .template),
  ]

  private static func fallbackColor(for key: String) -> String {
    let palette = [
      "#397B69", "#AD6A66", "#526B8E", "#A46E21", "#087F83", "#6D28D9", "#2563EB", "#DC2626",
    ]
    let hash = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return palette[hash % palette.count]
  }
}
