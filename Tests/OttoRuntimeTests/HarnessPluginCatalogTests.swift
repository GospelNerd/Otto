import Foundation
import OttoModels
import OttoRuntime
import Testing

@Suite("Harness plugin catalog")
struct HarnessPluginCatalogTests {
  @Test("Reads JSON mcpServers and TOML mcp_servers, skipping the Otto bridge")
  func readsDeclaredServers() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "muse-plugins-\(UUID().uuidString)", directoryHint: .isDirectory)
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let workspace = root.appending(path: "work", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: home.appending(path: ".codex"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try Data(
      """
      [plugins."gmail@openai-curated"]
      enabled = true
      [plugins."slack@openai-curated"]
      enabled = false
      [mcp_servers.outlook]
      command = "uvx"
      [mcp_servers.otto]
      command = "/opt/otto/otto-mcp"
      [mcp_servers.muse]
      command = "/Applications/Muse.app/Contents/MacOS/muse-mcp"
      """.utf8
    ).write(to: home.appending(path: ".codex/config.toml"))

    let plugins = HarnessPluginCatalog.plugins(
      for: .codex, workspacePath: workspace.path, homeDirectory: home.path)
    #expect(
      plugins.contains { $0.name == "Gmail" && $0.source == "Codex" && $0.colorHex == "#EA4335" })
    #expect(
      plugins.contains { $0.name == "Outlook" && $0.source == "Codex" && $0.colorHex == "#0078D4" })
    #expect(!plugins.contains { $0.name == "Slack" && $0.source == "Codex" })
    #expect(plugins.contains { $0.name == "Canvas" && $0.source == "otto" })
    // Neither Otto's bridge nor the `muse` entry left from before the rename is a plugin.
    #expect(!plugins.contains { $0.name.lowercased() == "otto" && $0.source == "Codex" })
    #expect(!plugins.contains { $0.name.lowercased() == "muse" && $0.source == "Codex" })
    try? FileManager.default.removeItem(at: root)
  }

  @Test("Cursor JSON mcp.json names appear as harness plugins")
  func readsCursorJSON() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "muse-cursor-plugins-\(UUID().uuidString)", directoryHint: .isDirectory)
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: home.appending(path: ".cursor"), withIntermediateDirectories: true)
    try Data(#"{ "mcpServers": { "slack": {}, "linear": {} } }"#.utf8)
      .write(to: home.appending(path: ".cursor/mcp.json"))
    let plugins = HarnessPluginCatalog.plugins(
      for: .cursor, workspacePath: root.path, homeDirectory: home.path)
    #expect(Set(plugins.filter { $0.source == "Cursor" }.map(\.name)) == ["Slack", "Linear"])
    try? FileManager.default.removeItem(at: root)
  }

  @Test("OpenCode mcp key and Hermes mcp_servers yaml are discovered")
  func readsOpenCodeAndHermes() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "muse-oc-hermes-\(UUID().uuidString)", directoryHint: .isDirectory)
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let workspace = root.appending(path: "work", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: home.appending(path: ".config/opencode"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: home.appending(path: ".hermes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try Data(
      """
      {
        // project github
        "mcp": { "github": { "type": "remote" }, "n8n-mcp": {} }
      }
      """.utf8
    ).write(to: home.appending(path: ".config/opencode/opencode.jsonc"))
    try Data(
      """
      model: auto
      mcp_servers:
        slack:
          command: npx
        linear:
          url: https://mcp.linear.app/mcp
      display:
        compact: false
      """.utf8
    ).write(to: home.appending(path: ".hermes/config.yaml"))

    let openCode = HarnessPluginCatalog.plugins(
      for: .openCode, workspacePath: workspace.path, homeDirectory: home.path)
    #expect(Set(openCode.filter { $0.source == "OpenCode" }.map(\.name)) == ["GitHub", "n8n"])

    let hermes = HarnessPluginCatalog.plugins(
      for: .hermes, workspacePath: workspace.path, homeDirectory: home.path)
    #expect(Set(hermes.filter { $0.source == "Hermes" }.map(\.name)) == ["Slack", "Linear"])
    try? FileManager.default.removeItem(at: root)
  }

  @Test("Claude project-scoped servers for this workspace are included")
  func readsClaudeProjectServers() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "muse-claude-plugins-\(UUID().uuidString)", directoryHint: .isDirectory)
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let workspace = root.appending(path: "work", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let payload = """
      {
        "mcpServers": { "gtmgrid": {} },
        "projects": {
          "\(workspace.path)": { "mcpServers": { "trigify": {} } },
          "/other": { "mcpServers": { "ignored": {} } }
        }
      }
      """
    try Data(payload.utf8).write(to: home.appending(path: ".claude.json"))
    let plugins = HarnessPluginCatalog.plugins(
      for: .claudeCode, workspacePath: workspace.path, homeDirectory: home.path)
    let names = Set(plugins.filter { $0.source == "Claude Code" }.map(\.name))
    #expect(names == ["GTM Grid", "Trigify"])
    try? FileManager.default.removeItem(at: root)
  }

  @Test("App hints route people to provider settings and preserve Hermes independence")
  func addMoreHints() {
    for provider in [AgentProvider.codex, .claudeCode, .cursor, .grok, .kimi, .openCode] {
      #expect(HarnessPluginCatalog.addMoreHint(for: provider).contains("provider’s own settings"))
    }
    #expect(HarnessPluginCatalog.addMoreHint(for: .hermes).contains("own app connections"))
  }

  @Test("Known plugin names keep their brand color")
  func brandsKnownPlugins() {
    #expect(PluginBrand.style(for: "gmail").colorHex == "#EA4335")
    #expect(PluginBrand.style(for: "n8n-mcp").mark == "n8")
    #expect(PluginBrand.style(for: "Outlook").colorHex == "#0078D4")
  }

  @Test("Known plugins map to bundled logo assets")
  func mapsLogoAssets() {
    #expect(PluginBrand.logo(for: "gmail")?.asset == "gmail")
    #expect(PluginBrand.logo(for: "GTM Grid")?.asset == "gtmgrid")
    #expect(PluginBrand.logo(for: "exa")?.kind == .original)
    #expect(PluginBrand.logo(for: "trigify")?.kind == .mark)
    #expect(PluginBrand.logo(for: "Node REPL")?.asset == "nodedotjs")
    #expect(PluginBrand.logo(for: "documents")?.asset == "googledocs")
    #expect(PluginBrand.logo(for: "spreadsheets")?.asset == "googlesheets")
    #expect(PluginBrand.logo(for: "unknown-tool") == nil)
  }
}

@Suite("Desktop built-in plugin")
struct DesktopBuiltinPluginTests {
  @Test("Desktop joins Otto's built-ins only once agent-desktop is installed")
  func desktopFollowsInstallState() throws {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "otto-desktop-plugin-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let installed = HarnessPluginCatalog.plugins(
      for: .claudeCode, workspacePath: home.path, homeDirectory: home.path, desktopInstalled: true)
    #expect(installed.contains { $0.name == "Desktop" && $0.source == HarnessPluginCatalog.ottoSource })
    #expect(installed.last?.name == "Desktop")
    let missing = HarnessPluginCatalog.plugins(
      for: .claudeCode, workspacePath: home.path, homeDirectory: home.path, desktopInstalled: false)
    #expect(!missing.contains { $0.name == "Desktop" })
    #expect(missing.count == HarnessPluginCatalog.ottoBuiltins.count)
  }
}
