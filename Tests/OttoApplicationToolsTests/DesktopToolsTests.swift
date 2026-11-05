import Foundation
import OttoApplicationTools
import OttoCore
import OttoRuntime
import OttoTools
import Testing

/// Records every agent-desktop call and answers with a canned envelope.
actor FakeDesktopRunner: DesktopCommandRunning {
  var calls: [[String]] = []
  var installed: Bool
  var envelope: JSONValue

  init(installed: Bool = true, envelope: JSONValue = FakeDesktopRunner.ok) {
    self.installed = installed
    self.envelope = envelope
  }

  static let ok: JSONValue = .object([
    "version": .string("2.6"), "ok": .bool(true), "command": .string("click"),
    "data": .object([
      "action": .string("click"),
      "disposition": .object([
        "delivery": .string("delivered_unverified"), "retry": .string("unsafe"),
      ]),
    ]),
  ])

  static func error(_ code: String) -> JSONValue {
    .object([
      "version": .string("2.6"), "ok": .bool(false), "command": .string("click"),
      "error": .object([
        "code": .string(code), "message": .string("\(code) happened"),
        "disposition": .object(["delivery": .string("not_delivered"), "retry": .string("safe")]),
      ]),
    ])
  }

  func executablePath() async -> String? { installed ? "/opt/homebrew/bin/agent-desktop" : nil }

  func run(_ arguments: [String], timeout: Duration) async throws -> DesktopCommandResult {
    guard installed else { throw DesktopControlError.notInstalled }
    calls.append(arguments)
    return DesktopCommandResult(exitCode: 0, envelope: envelope)
  }

  func lastCall() -> [String]? { calls.last }
}

@Suite("Desktop tools")
struct DesktopToolsTests {
  private var agent: ToolContext {
    ToolContext(actorID: "otto-agent-1", scopes: Set(ToolScope.allCases), source: .agent)
  }
  private var confirmed: ToolContext {
    ToolContext(
      actorID: "otto-agent-1", scopes: Set(ToolScope.allCases), confirmed: true, source: .agent)
  }

  @Test("Snapshot reads interactive elements compactly by default and scopes to the app")
  func snapshotArguments() async throws {
    let runner = FakeDesktopRunner()
    let output = try await DesktopSnapshotTool(runner: runner).call(
      DesktopSnapshotInput(app: "Mail", skeleton: true), context: agent)
    #expect(output.ok)
    let call = await runner.lastCall()
    #expect(call == ["snapshot", "--app", "Mail", "--skeleton", "-i", "--compact"])

    _ = try await DesktopSnapshotTool(runner: runner).call(
      DesktopSnapshotInput(root: "@s8f3k2p9:e3", interactiveOnly: false, compact: false),
      context: agent)
    #expect(await runner.lastCall() == ["snapshot", "--root", "@s8f3k2p9:e3"])
  }

  @Test("A bare ref is refused before anything runs")
  func bareRef() async throws {
    let runner = FakeDesktopRunner()
    await #expect(throws: ToolRegistryError.self) {
      try await DesktopClickTool(runner: runner).call(
        DesktopClickInput(ref: "@e8", label: "Archive"), context: agent)
    }
    #expect(await runner.calls.isEmpty)
  }

  @Test("Headless click runs without confirmation; headed click asks first, then runs")
  func clickConfirmation() async throws {
    let runner = FakeDesktopRunner()
    let tool = DesktopClickTool(runner: runner)
    _ = try await tool.call(DesktopClickInput(ref: "@s1:e8", label: "Archive"), context: agent)
    #expect(await runner.lastCall() == ["click", "@s1:e8"])

    await #expect(throws: ToolRegistryError.confirmationRequired("desktop.click")) {
      try await tool.call(
        DesktopClickInput(ref: "@s1:e8", label: "Archive", headed: true), context: agent)
    }
    #expect(await runner.calls.count == 1)

    _ = try await tool.call(
      DesktopClickInput(ref: "@s1:e8", label: "Archive", headed: true), context: confirmed)
    #expect(await runner.lastCall() == ["click", "@s1:e8", "--headed"])
  }

  @Test("Double-click is physical input, so it needs the person's approval")
  func doubleClickIsHeaded() async throws {
    let runner = FakeDesktopRunner()
    let tool = DesktopClickTool(runner: runner)
    await #expect(throws: ToolRegistryError.confirmationRequired("desktop.click")) {
      try await tool.call(
        DesktopClickInput(ref: "@s1:e8", label: "a file", kind: "double_click"), context: agent)
    }
    _ = try await tool.call(
      DesktopClickInput(ref: "@s1:e8", label: "a file", kind: "double_click"), context: confirmed)
    #expect(await runner.lastCall() == ["double-click", "@s1:e8", "--headed"])
  }

  @Test("Type keeps the text after the option terminator and replace uses set-value")
  func typeArguments() async throws {
    let runner = FakeDesktopRunner()
    let tool = DesktopTypeTool(runner: runner)
    _ = try await tool.call(
      DesktopTypeInput(ref: "@s1:e2", text: "-not a flag", label: "the subject"), context: agent)
    #expect(await runner.lastCall() == ["type", "@s1:e2", "--", "-not a flag"])

    _ = try await tool.call(
      DesktopTypeInput(ref: "@s1:e2", text: "Hello", label: "the subject", replace: true),
      context: agent)
    #expect(await runner.lastCall() == ["set-value", "@s1:e2", "--", "Hello"])

    await #expect(throws: ToolRegistryError.confirmationRequired("desktop.type")) {
      try await tool.call(
        DesktopTypeInput(ref: "@s1:e2", text: "Hi", label: "the subject", headed: true),
        context: agent)
    }
  }

  @Test("Press goes to a named app headlessly; without an app it asks first and never forces")
  func pressArguments() async throws {
    let runner = FakeDesktopRunner()
    let tool = DesktopPressTool(runner: runner)
    _ = try await tool.call(
      DesktopPressInput(keys: "cmd+s", app: "Notes", label: "save the note"), context: agent)
    #expect(await runner.lastCall() == ["press", "cmd+s", "--app", "Notes"])

    await #expect(throws: ToolRegistryError.confirmationRequired("desktop.press")) {
      try await tool.call(DesktopPressInput(keys: "return", label: "confirm"), context: agent)
    }
    _ = try await tool.call(DesktopPressInput(keys: "cmd+q", label: "quit"), context: confirmed)
    let call = await runner.lastCall() ?? []
    #expect(call == ["press", "cmd+q"])
    #expect(!call.contains("--force"))
  }

  @Test("Semantic actions map to their commands and select carries its value")
  func actArguments() async throws {
    let runner = FakeDesktopRunner()
    let tool = DesktopActTool(runner: runner)
    _ = try await tool.call(
      DesktopActInput(ref: "@s1:e4", action: "select", label: "the folder menu", value: "Inbox"),
      context: agent)
    #expect(await runner.lastCall() == ["select", "@s1:e4", "--", "Inbox"])
    _ = try await tool.call(
      DesktopActInput(ref: "@s1:e4", action: "scroll_to", label: "the row"), context: agent)
    #expect(await runner.lastCall() == ["scroll-to", "@s1:e4"])
    await #expect(throws: ToolRegistryError.self) {
      try await tool.call(
        DesktopActInput(ref: "@s1:e4", action: "select", label: "menu"), context: agent)
    }
  }

  @Test("Wait takes exactly one condition and passes the app and timeout")
  func waitArguments() async throws {
    let runner = FakeDesktopRunner()
    let tool = DesktopWaitTool(runner: runner)
    _ = try await tool.call(
      DesktopWaitInput(app: "Mail", text: "Sent", timeoutMs: 5_000), context: agent)
    #expect(await runner.lastCall() == ["wait", "--text", "Sent", "--app", "Mail", "--timeout", "5000"])
    await #expect(throws: ToolRegistryError.self) {
      try await tool.call(DesktopWaitInput(text: "a", windowTitle: "b"), context: agent)
    }
    await #expect(throws: ToolRegistryError.self) {
      try await tool.call(DesktopWaitInput(), context: agent)
    }
  }

  @Test("When agent-desktop is missing the agent gets the setup instructions, not a crash")
  func notInstalled() async throws {
    let runner = FakeDesktopRunner(installed: false)
    do {
      _ = try await DesktopSnapshotTool(runner: runner).call(DesktopSnapshotInput(), context: agent)
      Issue.record("expected a setup error")
    } catch let error as ToolRegistryError {
      #expect(error.localizedDescription.contains("Desktop control"))
      #expect(error.localizedDescription.contains("brew install agent-desktop"))
    }
    let status = try await DesktopStatusTool(runner: runner).call(
      DesktopStatusInput(), context: agent)
    #expect(status.status.installed == false)
    #expect(status.status.setup?.contains("brew install") == true)
    #expect(!status.guide.isEmpty)
  }

  @Test("A permission refusal from the CLI carries a note that points at Settings")
  func permissionNote() async throws {
    let runner = FakeDesktopRunner(envelope: FakeDesktopRunner.error("PERM_DENIED"))
    let output = try await DesktopClickTool(runner: runner).call(
      DesktopClickInput(ref: "@s1:e8", label: "Archive"), context: agent)
    #expect(output.ok == false)
    #expect(output.error?["code"]?.stringValue == "PERM_DENIED")
    #expect(output.note?.contains("Grant access") == true)

    let stale = FakeDesktopRunner(envelope: FakeDesktopRunner.error("STALE_REF"))
    let staleOutput = try await DesktopClickTool(runner: stale).call(
      DesktopClickInput(ref: "@s1:e8", label: "Archive"), context: agent)
    #expect(staleOutput.note?.contains("fresh desktop.snapshot") == true)
  }

  @Test("Status parses the CLI's permission block")
  func statusParsing() throws {
    let json = """
      {"version":"2.6","ok":true,"command":"status","data":{"permissions":{"accessibility":{"state":"denied"},"automation":{"state":"unknown"},"screen_recording":{"state":"granted"}},"platform":"macos","version":"1.1.0"}}
      """
    let envelope = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    let status = DesktopControlStatus.parse(envelope, executable: "/opt/homebrew/bin/agent-desktop")
    #expect(status.installed)
    #expect(status.version == "1.1.0")
    #expect(status.accessibility == .denied)
    #expect(status.screenRecording == .granted)
    #expect(status.isReady == false)
    #expect(status.setup?.contains("Accessibility") == true)

    let granted = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(json.replacingOccurrences(of: "\"accessibility\":{\"state\":\"denied\"}",
        with: "\"accessibility\":{\"state\":\"granted\"}").utf8))
    let ready = DesktopControlStatus.parse(granted, executable: nil)
    #expect(ready.isReady)
    #expect(ready.setup == nil)
  }

  @Test("Screenshots always go through the Allow / Deny card")
  func screenshotNeedsConfirmation() async throws {
    #expect(DesktopScreenshotTool.definition.requiresConfirmation)
    let registry = ToolRegistry()
    let runner = FakeDesktopRunner()
    try await registry.register(
      DesktopScreenshotTool(runner: runner, workspacePath: FileManager.default.temporaryDirectory.path))
    await #expect(throws: ToolRegistryError.confirmationRequired("desktop.screenshot")) {
      try await registry.call(name: "desktop.screenshot", input: .object([:]), context: agent)
    }
    #expect(await runner.calls.isEmpty)
  }

  @Test("Approval cards describe the physical action in the person's words")
  func approvalSummaries() {
    #expect(
      DesktopApprovalSummary.text(
        toolName: "desktop.click",
        input: ["ref": .string("@s1:e8"), "label": .string("the Archive button in Mail"), "headed": .bool(true)])
        == "Click the Archive button in Mail with real mouse input (takes focus)")
    #expect(
      DesktopApprovalSummary.text(
        toolName: "desktop.press", input: ["keys": .string("return"), "label": .string("send it")])
        == "Press return in whichever app is in front to send it")
    #expect(
      DesktopApprovalSummary.text(
        toolName: "desktop.screenshot", input: ["app": .string("Mail")])
        == "Take a screenshot of Mail and save it in the workspace")
    #expect(DesktopApprovalSummary.text(toolName: "browser.click", input: [:]) == nil)
  }

  @Test("Bootstrap registers every desktop tool")
  func bootstrapRegistration() async throws {
    let registry = ToolRegistry()
    let store = await MainActor.run { CanvasStore() }
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor(),
      workspacePath: FileManager.default.temporaryDirectory.path,
      desktopControl: FakeDesktopRunner())
    let names = Set(await registry.definitions().map(\.name))
    for name in [
      "desktop.status", "desktop.apps", "desktop.launch", "desktop.snapshot", "desktop.find",
      "desktop.get", "desktop.click", "desktop.type", "desktop.act", "desktop.scroll",
      "desktop.press", "desktop.wait", "desktop.screenshot",
    ] {
      #expect(names.contains(name), "missing \(name)")
    }
  }
}
