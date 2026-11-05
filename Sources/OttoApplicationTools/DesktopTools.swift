import Foundation
import OttoRuntime
import OttoTools

// Desktop control: bots see and operate native apps (Mail, Notes, Finder, Slack, System
// Settings, the menu bar) through the accessibility tree, using the agent-desktop CLI. Actions
// are headless by default: no focus change, no pointer movement, so the person keeps working.
// Real mouse or keyboard input and screenshots go through the usual Allow / Deny card first.

/// Every desktop tool returns the CLI's own envelope so the agent can branch on `error.code` and
/// `disposition.retry`, plus a note from Otto when the fix is on the person's side.
public struct DesktopEnvelopeOutput: Codable, Sendable, Equatable {
  public var ok: Bool
  public var command: String
  public var data: JSONValue?
  public var error: JSONValue?
  public var note: String?
}

enum DesktopCommandSupport {
  static let loopGuide = [
    "Observe, act, verify: snapshot an app, act on a ref, then snapshot (or find/get) again to check the result. Never assume an action worked.",
    "Refs look like @s8f3k2p9:e8 and belong to one snapshot. After any UI change take a new snapshot; STALE_REF or AMBIGUOUS_TARGET means do exactly that.",
    "Big apps: snapshot with skeleton=true first, then drill with root=<ref>. Use find when you know the role or name.",
    "Retry or repeat an action only when disposition.retry is \"safe\". Anything else may have landed already; read the live state instead.",
    "Use desktop.wait for async steps (a window, text, or event). A fixed sleep is a race.",
    "Headless actions never take focus. Set headed=true only when the semantic action is refused and the task truly needs real input; the person is asked first.",
  ]

  static func output(_ result: DesktopCommandResult, command: String) -> DesktopEnvelopeOutput {
    let envelope = result.envelope
    let ok = envelope?["ok"] == .bool(true)
    let error = envelope?["error"]
    var note: String?
    switch error?["code"]?.stringValue {
    case "PERM_DENIED":
      note =
        "Otto has no Accessibility permission. Ask the person to open Otto's Settings, choose "
        + "Desktop control and click Grant access; then try again."
    case "POLICY_DENIED":
      note =
        "That action needs physical input or a shortcut Otto does not send. Try a semantic "
        + "action, or set headed=true so the person can allow real input."
    case "STALE_REF", "AMBIGUOUS_TARGET", "SNAPSHOT_NOT_FOUND":
      note = "Take a fresh desktop.snapshot and use its refs."
    default:
      if envelope == nil {
        note = result.standardError.isEmpty ? nil : String(result.standardError.suffix(300))
      }
    }
    return DesktopEnvelopeOutput(
      ok: ok, command: envelope?["command"]?.stringValue ?? command, data: envelope?["data"],
      error: error, note: note)
  }

  static func run(
    _ runner: any DesktopCommandRunning, _ arguments: [String], timeout: Duration = .seconds(60)
  ) async throws -> DesktopEnvelopeOutput {
    do {
      let result = try await runner.run(arguments, timeout: timeout)
      return output(result, command: arguments.first ?? "")
    } catch let error as DesktopControlError {
      throw ToolRegistryError.invalidInput(error.localizedDescription)
    }
  }

  static func validatedRef(_ ref: String) throws -> String {
    let trimmed = ref.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("@"), trimmed.contains(":e"), !trimmed.contains(" ") else {
      throw ToolRegistryError.invalidInput(
        "ref must be a qualified ref from desktop.snapshot or desktop.find, like @s8f3k2p9:e8")
    }
    return trimmed
  }

  static func validatedApp(_ app: String?) throws -> String? {
    guard let app = app?.trimmingCharacters(in: .whitespaces), !app.isEmpty else { return nil }
    guard !app.hasPrefix("-"), app.count <= 200 else {
      throw ToolRegistryError.invalidInput("app must be an application name or bundle ID")
    }
    return app
  }

  static func timeoutArgument(_ milliseconds: Int?) -> [String] {
    guard let milliseconds, milliseconds > 0 else { return [] }
    return ["--timeout-ms", String(min(milliseconds, 120_000))]
  }

  static func processTimeout(_ milliseconds: Int?, floor: Duration = .seconds(60)) -> Duration {
    guard let milliseconds, milliseconds > 0 else { return floor }
    return max(floor, .milliseconds(min(milliseconds, 120_000)) + .seconds(15))
  }

  static let surfaces: Set<String> = [
    "window", "focused", "menu", "menubar", "sheet", "popover", "alert", "dock",
    "menu-bar-extras", "desktop", "taskbar", "system-tray", "quick-settings",
    "notification-center", "toolbar", "spotlight", "system-tray-overflow", "start-menu",
    "action-center",
  ]

  static func validatedSurface(_ surface: String?) throws -> [String] {
    guard let surface = surface?.trimmingCharacters(in: .whitespaces), !surface.isEmpty else {
      return []
    }
    guard surfaces.contains(surface) else {
      throw ToolRegistryError.invalidInput(
        "surface must be one of \(surfaces.sorted().joined(separator: ", "))")
    }
    return ["--surface", surface]
  }

  static let appProperty = JSONValue.stringSchema(
    description:
      "Application name (\"Mail\"), bundle ID or executable name. Defaults to the focused app.")
  static let labelProperty = JSONValue.stringSchema(
    description:
      "What the element is, in the person's words (\"the Archive button in Mail\"). Shown on the "
      + "approval card when real input is needed.")
}

// MARK: - Status

public struct DesktopStatusInput: Codable, Sendable { public init() {} }

public struct DesktopStatusOutput: Codable, Sendable, Equatable {
  public var status: DesktopControlStatus
  /// The rules of the observe, act, verify loop.
  public var guide: [String]
}

public struct DesktopStatusTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.status",
    description:
      "Whether bots can see and operate native desktop apps on this Mac: is the agent-desktop "
      + "CLI installed and has Otto got Accessibility permission. Call it when a desktop tool "
      + "fails, and read its guide before the first desktop task.",
    inputSchema: .objectSchema(), outputSchema: .objectSchema(),
    requiredScopes: [.canvasRead], riskLevel: .read
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopStatusInput, context: ToolContext) async throws
    -> DesktopStatusOutput
  {
    DesktopStatusOutput(status: await runner.status(), guide: DesktopCommandSupport.loopGuide)
  }
}

// MARK: - Apps and windows

public struct DesktopAppsInput: Codable, Sendable {
  public var app: String?
  public var windows: Bool?
  public init(app: String? = nil, windows: Bool? = nil) {
    self.app = app
    self.windows = windows
  }
}

public struct DesktopAppsTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.apps",
    description:
      "Lists the running desktop apps, or with windows=true their windows (titles and window "
      + "IDs). Use it to pick the app name for desktop.snapshot.",
    inputSchema: .objectSchema(
      properties: [
        "app": DesktopCommandSupport.appProperty,
        "windows": .booleanSchema(description: "List windows instead of apps"),
      ]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasRead], riskLevel: .read
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopAppsInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    var arguments = [input.windows == true ? "list-windows" : "list-apps"]
    if let app = try DesktopCommandSupport.validatedApp(input.app) { arguments += ["--app", app] }
    return try await DesktopCommandSupport.run(runner, arguments, timeout: .seconds(30))
  }
}

public struct DesktopLaunchInput: Codable, Sendable {
  public var app: String
  public var activate: Bool?
  public init(app: String, activate: Bool? = nil) {
    self.app = app
    self.activate = activate
  }
}

public struct DesktopLaunchTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.launch",
    description:
      "Launches a desktop app by name or bundle ID and returns once it is running (it attaches "
      + "to an already running app). activate=true brings it forward and waits for a window; "
      + "leave it off so the person keeps what they are doing.",
    inputSchema: .objectSchema(
      properties: [
        "app": .stringSchema(description: "Application name (\"Notes\") or bundle ID"),
        "activate": .booleanSchema(description: "Bring the app to the front and wait for a window"),
      ],
      required: ["app"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopLaunchInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    guard let app = try DesktopCommandSupport.validatedApp(input.app) else {
      throw ToolRegistryError.invalidInput("app is required")
    }
    var arguments = ["launch", app]
    if input.activate == true { arguments.append("--activate") }
    return try await DesktopCommandSupport.run(runner, arguments, timeout: .seconds(60))
  }
}

// MARK: - Observe

public struct DesktopSnapshotInput: Codable, Sendable {
  public var app: String?
  public var skeleton: Bool?
  public var root: String?
  public var surface: String?
  public var interactiveOnly: Bool?
  public var compact: Bool?
  public var maxDepth: Int?
  public var waitFor: String?
  public var timeoutMs: Int?

  public init(
    app: String? = nil, skeleton: Bool? = nil, root: String? = nil, surface: String? = nil,
    interactiveOnly: Bool? = nil, compact: Bool? = nil, maxDepth: Int? = nil,
    waitFor: String? = nil, timeoutMs: Int? = nil
  ) {
    self.app = app
    self.skeleton = skeleton
    self.root = root
    self.surface = surface
    self.interactiveOnly = interactiveOnly
    self.compact = compact
    self.maxDepth = maxDepth
    self.waitFor = waitFor
    self.timeoutMs = timeoutMs
  }
}

public struct DesktopSnapshotTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.snapshot",
    description:
      "Reads a native app's UI as a tree of elements, each actionable one with a ref like "
      + "@s8f3k2p9:e8 for desktop.click, desktop.type and desktop.act. Interactive elements "
      + "only and compact by default. For a dense app pass skeleton=true first, then drill into "
      + "one region with root=<ref>. While a menu, sheet or alert is open, snapshot that surface. "
      + "Refs are valid for one snapshot: after any change, snapshot again. Headless: the app "
      + "stays where it is and the person keeps working.",
    inputSchema: .objectSchema(
      properties: [
        "app": DesktopCommandSupport.appProperty,
        "skeleton": .booleanSchema(
          description: "Shallow map with children_count on cut branches; drill with root next"),
        "root": .stringSchema(description: "Ref to read only that element's subtree"),
        "surface": .stringSchema(
          description:
            "window (default), focused, menu, menubar, sheet, popover, alert, dock or menu-bar-extras"
        ),
        "interactiveOnly": .booleanSchema(
          description: "Only elements a bot can act on (default true). false includes static text"),
        "compact": .booleanSchema(description: "Collapse unnamed wrappers (default true)"),
        "maxDepth": .integerSchema(description: "Tree depth limit (default 10)"),
        "waitFor": .stringSchema(
          description: "role:text selector to wait for before reading, e.g. button:Save"),
        "timeoutMs": .integerSchema(
          description: "Observation deadline in ms (default 3000; raise for slow Electron apps)"),
      ]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasRead], riskLevel: .read
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopSnapshotInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    var arguments = ["snapshot"]
    if let app = try DesktopCommandSupport.validatedApp(input.app) { arguments += ["--app", app] }
    if input.skeleton == true { arguments.append("--skeleton") }
    if let root = input.root { arguments += ["--root", try DesktopCommandSupport.validatedRef(root)] }
    arguments += try DesktopCommandSupport.validatedSurface(input.surface)
    if input.interactiveOnly != false { arguments.append("-i") }
    if input.compact != false { arguments.append("--compact") }
    if let depth = input.maxDepth, depth > 0 { arguments += ["--max-depth", String(min(depth, 50))] }
    if let waitFor = input.waitFor, !waitFor.isEmpty { arguments += ["--wait-for", waitFor] }
    arguments += DesktopCommandSupport.timeoutArgument(input.timeoutMs)
    return try await DesktopCommandSupport.run(
      runner, arguments, timeout: DesktopCommandSupport.processTimeout(input.timeoutMs))
  }
}

public struct DesktopFindInput: Codable, Sendable {
  public var app: String?
  public var role: String?
  public var name: String?
  public var text: String?
  public var value: String?
  public var nativeId: String?
  public var exact: Bool?
  public var root: String?
  public var surface: String?
  public var limit: Int?
  public var timeoutMs: Int?

  public init(
    app: String? = nil, role: String? = nil, name: String? = nil, text: String? = nil,
    value: String? = nil, nativeId: String? = nil, exact: Bool? = nil, root: String? = nil,
    surface: String? = nil, limit: Int? = nil, timeoutMs: Int? = nil
  ) {
    self.app = app
    self.role = role
    self.name = name
    self.text = text
    self.value = value
    self.nativeId = nativeId
    self.exact = exact
    self.root = root
    self.surface = surface
    self.limit = limit
    self.timeoutMs = timeoutMs
  }
}

public struct DesktopFindTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.find",
    description:
      "Finds elements in a native app by role (button, textfield, checkbox, menuitem ...), "
      + "accessible name, visible text or value, and returns them with refs. Faster than a full "
      + "snapshot when you know what you are looking for.",
    inputSchema: .objectSchema(
      properties: [
        "app": DesktopCommandSupport.appProperty,
        "role": .stringSchema(description: "Accessibility role to match"),
        "name": .stringSchema(description: "Accessible name or label"),
        "text": .stringSchema(description: "Text in name, value, title or description"),
        "value": .stringSchema(description: "Current value"),
        "nativeId": .stringSchema(description: "Developer identifier (AXIdentifier)"),
        "exact": .booleanSchema(description: "Exact, case-insensitive matches only"),
        "root": .stringSchema(description: "Search only inside this ref's subtree"),
        "surface": .stringSchema(description: "menubar, menu, sheet ... instead of the window"),
        "limit": .integerSchema(description: "At most this many matches (default 50)"),
        "timeoutMs": .integerSchema(description: "Traversal deadline in ms (default 5000)"),
      ]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasRead], riskLevel: .read
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopFindInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    var arguments = ["find"]
    if let app = try DesktopCommandSupport.validatedApp(input.app) { arguments += ["--app", app] }
    let filters: [(String, String?)] = [
      ("--role", input.role), ("--name", input.name), ("--text", input.text),
      ("--value", input.value), ("--native-id", input.nativeId),
    ]
    var matched = false
    for (flag, value) in filters {
      guard let value, !value.isEmpty else { continue }
      arguments += [flag, value]
      matched = true
    }
    guard matched else {
      throw ToolRegistryError.invalidInput("Give at least one of role, name, text, value or nativeId")
    }
    if input.exact == true { arguments.append("--exact") }
    if let root = input.root { arguments += ["--root", try DesktopCommandSupport.validatedRef(root)] }
    arguments += try DesktopCommandSupport.validatedSurface(input.surface)
    if let limit = input.limit, limit >= 0 { arguments += ["--limit", String(min(limit, 500))] }
    arguments += DesktopCommandSupport.timeoutArgument(input.timeoutMs)
    return try await DesktopCommandSupport.run(
      runner, arguments, timeout: DesktopCommandSupport.processTimeout(input.timeoutMs))
  }
}

public struct DesktopGetInput: Codable, Sendable {
  public var ref: String
  public var property: String?
  public init(ref: String, property: String? = nil) {
    self.ref = ref
    self.property = property
  }
}

public struct DesktopGetTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.get",
    description:
      "Reads one property of an element by ref: text (default, what a person reads), value, "
      + "title, bounds, role or states. Use it to verify an action landed.",
    inputSchema: .objectSchema(
      properties: [
        "ref": .stringSchema(description: "Qualified ref from a snapshot"),
        "property": .stringSchema(description: "text, value, title, bounds, role or states"),
      ],
      required: ["ref"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasRead], riskLevel: .read
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopGetInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    var arguments = ["get", try DesktopCommandSupport.validatedRef(input.ref)]
    if let property = input.property, !property.isEmpty {
      guard ["text", "value", "title", "bounds", "role", "states"].contains(property) else {
        throw ToolRegistryError.invalidInput(
          "property must be text, value, title, bounds, role or states")
      }
      arguments += ["--property", property]
    }
    return try await DesktopCommandSupport.run(runner, arguments, timeout: .seconds(30))
  }
}

// MARK: - Act on a ref

public struct DesktopClickInput: Codable, Sendable {
  public var ref: String
  public var label: String
  public var kind: String?
  public var headed: Bool?
  public var timeoutMs: Int?
  public init(
    ref: String, label: String, kind: String? = nil, headed: Bool? = nil, timeoutMs: Int? = nil
  ) {
    self.ref = ref
    self.label = label
    self.kind = kind
    self.headed = headed
    self.timeoutMs = timeoutMs
  }
}

public struct DesktopClickTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.click",
    description:
      "Clicks an element by ref through its accessibility action, without taking focus or "
      + "moving the pointer. kind: click (default), right_click (opens its menu; snapshot "
      + "surface=menu next) or double_click. The result carries disposition.delivery; snapshot "
      + "again to verify. double_click and headed=true send real mouse input and are shown to "
      + "the person for approval first.",
    inputSchema: .objectSchema(
      properties: [
        "ref": .stringSchema(description: "Qualified ref from a snapshot"),
        "label": DesktopCommandSupport.labelProperty,
        "kind": .stringSchema(description: "click, right_click or double_click"),
        "headed": .booleanSchema(
          description: "Real mouse click that focuses the window; needs the person's approval"),
        "timeoutMs": .integerSchema(description: "Wait for the element to be actionable (default 5000)"),
      ],
      required: ["ref", "label"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopClickInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    let command: String
    switch input.kind ?? "click" {
    case "click": command = "click"
    case "right_click": command = "right-click"
    case "double_click": command = "double-click"
    default:
      throw ToolRegistryError.invalidInput("kind must be click, right_click or double_click")
    }
    let headed = input.headed == true || command == "double-click"
    if headed, !context.confirmed {
      throw ToolRegistryError.confirmationRequired(Self.definition.name)
    }
    var arguments = [command, try DesktopCommandSupport.validatedRef(input.ref)]
    if headed { arguments.append("--headed") }
    arguments += DesktopCommandSupport.timeoutArgument(input.timeoutMs)
    return try await DesktopCommandSupport.run(
      runner, arguments, timeout: DesktopCommandSupport.processTimeout(input.timeoutMs))
  }
}

public struct DesktopTypeInput: Codable, Sendable {
  public var ref: String
  public var text: String
  public var label: String
  public var replace: Bool?
  public var headed: Bool?
  public var timeoutMs: Int?
  public init(
    ref: String, text: String, label: String, replace: Bool? = nil, headed: Bool? = nil,
    timeoutMs: Int? = nil
  ) {
    self.ref = ref
    self.text = text
    self.label = label
    self.replace = replace
    self.headed = headed
    self.timeoutMs = timeoutMs
  }
}

public struct DesktopTypeTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.type",
    description:
      "Inserts text into a text field or editor by ref, without taking focus. replace=true sets "
      + "the field's whole value instead of inserting. Check the field with desktop.get "
      + "afterwards. headed=true types real keystrokes into the focused window and is shown to "
      + "the person for approval first.",
    inputSchema: .objectSchema(
      properties: [
        "ref": .stringSchema(description: "Qualified ref of the text target"),
        "text": .stringSchema(description: "Text to insert"),
        "label": DesktopCommandSupport.labelProperty,
        "replace": .booleanSchema(description: "Set the whole value instead of inserting"),
        "headed": .booleanSchema(
          description: "Real keystrokes that focus the window; needs the person's approval"),
        "timeoutMs": .integerSchema(description: "Wait budget in ms (default 5000 + 30 per character)"),
      ],
      required: ["ref", "text", "label"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopTypeInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    guard input.text.count <= 20_000 else {
      throw ToolRegistryError.invalidInput("text is too long; type at most 20,000 characters")
    }
    let headed = input.headed == true
    if headed, !context.confirmed {
      throw ToolRegistryError.confirmationRequired(Self.definition.name)
    }
    let ref = try DesktopCommandSupport.validatedRef(input.ref)
    var arguments = [input.replace == true ? "set-value" : "type", ref]
    if headed { arguments.append("--headed") }
    arguments += DesktopCommandSupport.timeoutArgument(input.timeoutMs)
    // "--" ends the options, so a text that starts with "-" is never read as a flag.
    arguments += ["--", input.text]
    let budget = (input.timeoutMs ?? 5_000) + 30 * input.text.count
    return try await DesktopCommandSupport.run(
      runner, arguments, timeout: DesktopCommandSupport.processTimeout(budget))
  }
}

public struct DesktopActInput: Codable, Sendable {
  public var ref: String
  public var action: String
  public var label: String
  public var value: String?
  public var timeoutMs: Int?
  public init(ref: String, action: String, label: String, value: String? = nil, timeoutMs: Int? = nil) {
    self.ref = ref
    self.action = action
    self.label = label
    self.value = value
    self.timeoutMs = timeoutMs
  }
}

public struct DesktopActTool: OttoTool {
  static let actions: [String: String] = [
    "select": "select", "toggle": "toggle", "check": "check", "uncheck": "uncheck",
    "expand": "expand", "collapse": "collapse", "focus": "focus", "clear": "clear",
    "scroll_to": "scroll-to",
  ]

  public static let definition = ToolDefinition(
    name: "desktop.act",
    description:
      "Semantic actions on an element by ref, headless: select (pass value, for menus, "
      + "pop-ups and lists), toggle, check, uncheck, expand, collapse, focus, clear (a text "
      + "field) or scroll_to (bring it into view). Stateful actions are verified against the "
      + "element afterwards; toggle can undo itself, so never repeat it blindly.",
    inputSchema: .objectSchema(
      properties: [
        "ref": .stringSchema(description: "Qualified ref from a snapshot"),
        "action": .stringSchema(
          description:
            "select, toggle, check, uncheck, expand, collapse, focus, clear or scroll_to"),
        "label": DesktopCommandSupport.labelProperty,
        "value": .stringSchema(description: "Option to select (select only)"),
        "timeoutMs": .integerSchema(description: "Wait for the element to be actionable (default 5000)"),
      ],
      required: ["ref", "action", "label"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopActInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    guard let command = Self.actions[input.action] else {
      throw ToolRegistryError.invalidInput(
        "action must be one of \(Self.actions.keys.sorted().joined(separator: ", "))")
    }
    var arguments = [command, try DesktopCommandSupport.validatedRef(input.ref)]
    arguments += DesktopCommandSupport.timeoutArgument(input.timeoutMs)
    if command == "select" {
      guard let value = input.value, !value.isEmpty else {
        throw ToolRegistryError.invalidInput("select needs value: the option to choose")
      }
      arguments += ["--", value]
    }
    return try await DesktopCommandSupport.run(
      runner, arguments, timeout: DesktopCommandSupport.processTimeout(input.timeoutMs))
  }
}

public struct DesktopScrollInput: Codable, Sendable {
  public var ref: String
  public var label: String
  public var direction: String?
  public var amount: Int?
  public var headed: Bool?
  public init(
    ref: String, label: String, direction: String? = nil, amount: Int? = nil, headed: Bool? = nil
  ) {
    self.ref = ref
    self.label = label
    self.direction = direction
    self.amount = amount
    self.headed = headed
  }
}

public struct DesktopScrollTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.scroll",
    description:
      "Scrolls a scrollable element by ref: direction up, down (default), left or right, "
      + "amount in scroll units (default 3). Headless; headed=true sends real wheel events and "
      + "is shown to the person for approval first.",
    inputSchema: .objectSchema(
      properties: [
        "ref": .stringSchema(description: "Qualified ref of the scroll area"),
        "label": DesktopCommandSupport.labelProperty,
        "direction": .stringSchema(description: "up, down, left or right"),
        "amount": .integerSchema(description: "Scroll units (default 3)"),
        "headed": .booleanSchema(description: "Real wheel events; needs the person's approval"),
      ],
      required: ["ref", "label"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopScrollInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    let direction = input.direction ?? "down"
    guard ["up", "down", "left", "right"].contains(direction) else {
      throw ToolRegistryError.invalidInput("direction must be up, down, left or right")
    }
    let headed = input.headed == true
    if headed, !context.confirmed {
      throw ToolRegistryError.confirmationRequired(Self.definition.name)
    }
    var arguments = ["scroll", try DesktopCommandSupport.validatedRef(input.ref), "--direction", direction]
    if let amount = input.amount, amount > 0 { arguments += ["--amount", String(min(amount, 100))] }
    if headed { arguments.append("--headed") }
    return try await DesktopCommandSupport.run(runner, arguments, timeout: .seconds(30))
  }
}

// MARK: - Keyboard

public struct DesktopPressInput: Codable, Sendable {
  public var keys: String
  public var app: String?
  public var label: String
  public init(keys: String, app: String? = nil, label: String) {
    self.keys = keys
    self.app = app
    self.label = label
  }
}

public struct DesktopPressTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.press",
    description:
      "Sends a key combo such as return, escape, cmd+s or shift+tab. With app set, the keys go "
      + "to that app's process without focusing it. Without app they land in whatever is in "
      + "front, so the person is asked first. Quit shortcuts (cmd+q and friends) are refused.",
    inputSchema: .objectSchema(
      properties: [
        "keys": .stringSchema(description: "Key combo, e.g. return, escape, cmd+s, shift+tab"),
        "app": DesktopCommandSupport.appProperty,
        "label": .stringSchema(description: "What the keys do (\"save the note\"), for the approval card"),
      ],
      required: ["keys", "label"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopPressInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    let keys = input.keys.trimmingCharacters(in: .whitespaces)
    guard !keys.isEmpty, keys.count <= 40, !keys.hasPrefix("-") else {
      throw ToolRegistryError.invalidInput("keys must be a key combo such as cmd+s")
    }
    let app = try DesktopCommandSupport.validatedApp(input.app)
    if app == nil, !context.confirmed {
      throw ToolRegistryError.confirmationRequired(Self.definition.name)
    }
    var arguments = ["press", keys]
    if let app { arguments += ["--app", app] }
    return try await DesktopCommandSupport.run(runner, arguments, timeout: .seconds(30))
  }
}

// MARK: - Wait

public struct DesktopWaitInput: Codable, Sendable {
  public var app: String?
  public var text: String?
  public var windowTitle: String?
  public var event: String?
  public var ref: String?
  public var predicate: String?
  public var value: String?
  public var ms: Int?
  public var timeoutMs: Int?

  public init(
    app: String? = nil, text: String? = nil, windowTitle: String? = nil, event: String? = nil,
    ref: String? = nil, predicate: String? = nil, value: String? = nil, ms: Int? = nil,
    timeoutMs: Int? = nil
  ) {
    self.app = app
    self.text = text
    self.windowTitle = windowTitle
    self.event = event
    self.ref = ref
    self.predicate = predicate
    self.value = value
    self.ms = ms
    self.timeoutMs = timeoutMs
  }
}

public struct DesktopWaitTool: OttoTool {
  static let events: Set<String> = [
    "window-opened", "window-closed", "app-launched", "app-terminated", "focus-changed",
    "surface-appeared", "surface-dismissed",
  ]

  public static let definition = ToolDefinition(
    name: "desktop.wait",
    description:
      "Waits for something to happen instead of sleeping: text to appear in an app, a window "
      + "with a title, a lifecycle event (window-opened, window-closed, app-launched, "
      + "app-terminated, focus-changed, surface-appeared, surface-dismissed), or an element "
      + "ref to satisfy a predicate (exists, enabled, visible, actionable, value). ms alone "
      + "pauses that long.",
    inputSchema: .objectSchema(
      properties: [
        "app": DesktopCommandSupport.appProperty,
        "text": .stringSchema(description: "Wait until this text appears in the app"),
        "windowTitle": .stringSchema(description: "Wait until a window with this title appears"),
        "event": .stringSchema(description: "Lifecycle event to wait for"),
        "ref": .stringSchema(description: "Element ref to wait on"),
        "predicate": .stringSchema(description: "exists (default), enabled, visible, actionable or value"),
        "value": .stringSchema(description: "Expected value for predicate=value"),
        "ms": .integerSchema(description: "Plain pause in milliseconds (last resort)"),
        "timeoutMs": .integerSchema(description: "Give up after this long (default 30000)"),
      ]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasRead], riskLevel: .read
  )
  private let runner: any DesktopCommandRunning
  public init(runner: any DesktopCommandRunning) { self.runner = runner }

  public func call(_ input: DesktopWaitInput, context: ToolContext) async throws
    -> DesktopEnvelopeOutput
  {
    var arguments = ["wait"]
    var conditions = 0
    if let ms = input.ms, ms > 0 {
      arguments.append(String(min(ms, 60_000)))
      conditions += 1
    }
    if let text = input.text, !text.isEmpty {
      arguments += ["--text", text]
      conditions += 1
    }
    if let title = input.windowTitle, !title.isEmpty {
      arguments += ["--window", title]
      conditions += 1
    }
    if let event = input.event, !event.isEmpty {
      guard Self.events.contains(event) else {
        throw ToolRegistryError.invalidInput(
          "event must be one of \(Self.events.sorted().joined(separator: ", "))")
      }
      arguments += ["--event", event]
      conditions += 1
    }
    if let ref = input.ref {
      arguments += ["--element", try DesktopCommandSupport.validatedRef(ref)]
      if let predicate = input.predicate, !predicate.isEmpty {
        guard ["exists", "enabled", "visible", "actionable", "value"].contains(predicate) else {
          throw ToolRegistryError.invalidInput(
            "predicate must be exists, enabled, visible, actionable or value")
        }
        arguments += ["--predicate", predicate]
        if predicate == "value" {
          guard let value = input.value else {
            throw ToolRegistryError.invalidInput("predicate=value needs value")
          }
          arguments += ["--value", value]
        }
      }
      conditions += 1
    }
    guard conditions == 1 else {
      throw ToolRegistryError.invalidInput(
        "Give exactly one of ms, text, windowTitle, event or ref")
    }
    if let app = try DesktopCommandSupport.validatedApp(input.app) { arguments += ["--app", app] }
    let timeout = min(max(input.timeoutMs ?? 30_000, 1), 120_000)
    if input.ms == nil { arguments += ["--timeout", String(timeout)] }
    return try await DesktopCommandSupport.run(
      runner, arguments,
      timeout: .milliseconds(max(timeout, input.ms ?? 0)) + .seconds(15))
  }
}

// MARK: - Screenshot

public struct DesktopScreenshotInput: Codable, Sendable {
  public var app: String?
  public var windowId: String?
  public var label: String?
  public init(app: String? = nil, windowId: String? = nil, label: String? = nil) {
    self.app = app
    self.windowId = windowId
    self.label = label
  }
}

public struct DesktopScreenshotOutput: Codable, Sendable, Equatable {
  public var relativePath: String
  public var mimeType: String
  public var byteCount: Int
  public var note: String?
}

public struct DesktopScreenshotTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "desktop.screenshot",
    description:
      "Saves a PNG of an app's front window (or the whole screen when app is omitted) under the "
      + "workspace's .otto/captures folder and returns its path. Screenshots can show private "
      + "content, so the person approves each one. Prefer desktop.snapshot: it reads the UI "
      + "without pixels.",
    inputSchema: .objectSchema(
      properties: [
        "app": DesktopCommandSupport.appProperty,
        "windowId": .stringSchema(description: "One window, from desktop.apps windows=true"),
        "label": .stringSchema(description: "Why the picture is needed, for the approval card"),
      ]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasRead, .canvasWrite],
    riskLevel: .consequential, requiresConfirmation: true
  )
  private let runner: any DesktopCommandRunning
  private let workspaceURL: URL

  public init(runner: any DesktopCommandRunning, workspacePath: String) {
    self.runner = runner
    self.workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
  }

  public func call(_ input: DesktopScreenshotInput, context: ToolContext) async throws
    -> DesktopScreenshotOutput
  {
    let stamp = String(Int(Date().timeIntervalSince1970 * 1_000))
    let relativePath = ".otto/captures/desktop-\(stamp).png"
    let destination = workspaceURL.appending(path: relativePath).standardizedFileURL
    let prefix = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
    guard destination.path.hasPrefix(prefix) else {
      throw ToolRegistryError.invalidInput("Screenshot destination escaped the workspace")
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    var arguments = ["screenshot", destination.path]
    if let app = try DesktopCommandSupport.validatedApp(input.app) { arguments += ["--app", app] }
    if let windowId = input.windowId, !windowId.isEmpty, !windowId.hasPrefix("-") {
      arguments += ["--window-id", windowId]
    }
    let envelope = try await DesktopCommandSupport.run(runner, arguments, timeout: .seconds(30))
    guard envelope.ok else {
      let message = envelope.error?["message"]?.stringValue ?? "the screenshot failed"
      let code = envelope.error?["code"]?.stringValue ?? "ERROR"
      let note = envelope.note.map { " \($0)" } ?? ""
      if code == "PERM_DENIED" {
        throw ToolRegistryError.invalidInput(
          "Otto has no Screen Recording permission, so it cannot take desktop screenshots. The "
            + "person grants it in Otto's Settings, Desktop control.")
      }
      throw ToolRegistryError.invalidInput("\(code): \(message).\(note)")
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
    guard size > 0 else {
      throw ToolRegistryError.invalidInput("agent-desktop reported success but wrote no file")
    }
    return DesktopScreenshotOutput(
      relativePath: relativePath, mimeType: "image/png", byteCount: size,
      note: "Treat the image as private: keep it in the workspace and do not upload it.")
  }
}

// MARK: - Approval card text

/// What the Allow / Deny card says for a desktop action that needs the person's go-ahead.
public enum DesktopApprovalSummary {
  public static func text(toolName: String, input: [String: JSONValue]) -> String? {
    guard toolName.hasPrefix("desktop.") else { return nil }
    let label = input["label"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
    let target = label.isEmpty ? "an element" : label
    switch toolName {
    case "desktop.click":
      let kind = input["kind"]?.stringValue == "double_click" ? "Double-click" : "Click"
      return "\(kind) \(target) with real mouse input (takes focus)"
    case "desktop.type":
      let text = input["text"]?.stringValue ?? ""
      let shown = text.count > 80 ? String(text.prefix(77)) + "…" : text
      return "Type into \(target) with real keystrokes: “\(shown)”"
    case "desktop.scroll":
      return "Scroll \(target) with real wheel input"
    case "desktop.press":
      let keys = input["keys"]?.stringValue ?? "keys"
      let why = label.isEmpty ? "" : " to \(label)"
      return "Press \(keys) in whichever app is in front\(why)"
    case "desktop.screenshot":
      let app = input["app"]?.stringValue.map { "of \($0)" } ?? "of the whole screen"
      let why = label.isEmpty ? "" : " (\(label))"
      return "Take a screenshot \(app) and save it in the workspace\(why)"
    default:
      return nil
    }
  }
}
