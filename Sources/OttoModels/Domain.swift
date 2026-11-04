import Foundation

public enum NodeKind: Codable, CaseIterable, Hashable, Sendable {
  case agent
  case terminal
  case browser
  case markdown
  case media
  case label
  case group
  case connector
  case appMirror
  case whiteboard
  case gtmGrid
  case widget
  case unsupported(String)

  public static let allCases: [NodeKind] = [
    .agent, .terminal, .browser, .markdown, .media, .label, .group, .connector, .appMirror,
    .whiteboard, .gtmGrid, .widget,
  ]

  public init?(rawValue: String) {
    switch rawValue {
    case "agent": self = .agent
    case "terminal": self = .terminal
    case "browser": self = .browser
    case "markdown": self = .markdown
    case "media": self = .media
    case "label": self = .label
    case "group": self = .group
    case "connector": self = .connector
    case "appMirror": self = .appMirror
    case "whiteboard": self = .whiteboard
    case "gtmGrid": self = .gtmGrid
    case "widget": self = .widget
    default: self = .unsupported(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .agent: "agent"
    case .terminal: "terminal"
    case .browser: "browser"
    case .markdown: "markdown"
    case .media: "media"
    case .label: "label"
    case .group: "group"
    case .connector: "connector"
    case .appMirror: "appMirror"
    case .whiteboard: "whiteboard"
    case .gtmGrid: "gtmGrid"
    case .widget: "widget"
    case .unsupported(let value): value
    }
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = NodeKind(rawValue: value) ?? .unsupported(value)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var defaultSize: (width: Double, height: Double) {
    switch self {
    case .agent: (560, 420)
    case .terminal: (420, 270)
    case .browser: (840, 560)
    case .markdown: (360, 300)
    case .media: (400, 250)
    case .label: (320, 180)
    case .group: (520, 360)
    case .connector: (320, 180)
    case .appMirror: (520, 340)
    case .whiteboard: (720, 520)
    case .gtmGrid: (1_000, 680)
    case .widget: (460, 340)
    case .unsupported: (420, 280)
    }
  }
}

/// Lossless Codable storage for fields written by a newer Otto build or an out-of-process
/// extension. Unknown data remains attached to its node across load/save cycles instead of being
/// coerced into a known node type or silently discarded.
public enum OpaqueCodableValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([OpaqueCodableValue])
  case object([String: OpaqueCodableValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([OpaqueCodableValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: OpaqueCodableValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported opaque Codable value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
  case claudeCode = "Claude Code"
  case codex = "Codex"
  case openAI = "OpenAI API"
  case cursor = "Cursor"
  case grok = "Grok"
  case hermes = "Hermes"
  case kimi = "Kimi"
  case openCode = "OpenCode"
  case pi = "Pi"
  case shell = "Shell"

  /// Whether a new session may start in a project's own source folder rather than the Otto
  /// workspace. Only providers that neither auto-trust their working directory nor write MCP
  /// config into it qualify: Claude Code (reads CLAUDE.md and .claude/) and Codex (reads
  /// AGENTS.md). Cursor and Pi launch pre-approved, and Kimi, Cursor, Pi and Grok write their
  /// Otto MCP config into the folder they start in; Otto Harness reads no repository setup.
  public var startsInProjectFolder: Bool { self == .claudeCode || self == .codex }
}

/// How a provider should structure work inside one Otto agent node. Otto remains the owner of
/// cross-provider orchestration; these strategies control only a worker's internal execution.
public enum AgentExecutionStrategy: String, Codable, CaseIterable, Sendable {
  case direct
  case delegated
  case scriptedWorkflow

  public func isSupported(by provider: AgentProvider) -> Bool {
    switch self {
    case .direct: true
    case .delegated: provider != .shell
    case .scriptedWorkflow: provider == .claudeCode
    }
  }
}

public enum NodeStatus: String, Codable, CaseIterable, Sendable {
  case starting = "STARTING"
  case idle = "IDLE"
  case working = "WORKING"
  case done = "DONE"
  case waiting = "WAITING"
  case failed = "FAILED"
  case stopped = "STOPPED"
}

/// How a node is presented without changing the lifetime of its underlying work.
/// Conversation and terminal are expanded canvas windows; compact and hidden are viewless.
public enum NodePresentationMode: String, Codable, CaseIterable, Sendable {
  case conversation
  case terminal
  /// Files the agent has created or edited, rendered next to the conversation.
  case files
  case compact
  case hidden

  public var isExpanded: Bool {
    self == .conversation || self == .terminal || self == .files
  }
}

public struct AgentDefinition: Codable, Equatable, Sendable {
  public var provider: AgentProvider
  public var repositoryPath: String?
  public var workingDirectory: String
  public var launchCommand: String
  public var approvedArguments: [String]
  public var environmentProfileID: String?
  public var permissionMode: String
  public var model: String?
  public var effort: String?
  /// Optional so workspaces saved before execution strategies continue to decode as direct.
  public var executionStrategy: AgentExecutionStrategy?
  public var resumeSessionID: String?
  /// Optional reusable identity. Generic provider nodes intentionally leave these fields nil.
  public var profileID: UUID?
  public var profileRevision: Int?
  public var profileInstructions: String?
  /// Provider account this agent runs on. Nil inherits the project default, then the global
  /// default account, then the Mac's existing provider login.
  public var accountID: UUID?
  /// Configured helpers must never fall back to another subscription. With this flag,
  /// a nil accountID explicitly uses this Mac’s login.
  public var requiresExplicitAccount: Bool?

  public init(
    provider: AgentProvider,
    repositoryPath: String? = nil,
    workingDirectory: String,
    launchCommand: String,
    approvedArguments: [String] = [],
    environmentProfileID: String? = nil,
    permissionMode: String,
    model: String? = nil,
    effort: String? = nil,
    executionStrategy: AgentExecutionStrategy = .direct,
    resumeSessionID: String? = nil,
    profileID: UUID? = nil,
    profileRevision: Int? = nil,
    profileInstructions: String? = nil,
    accountID: UUID? = nil,
    requiresExplicitAccount: Bool? = nil
  ) {
    self.provider = provider
    self.repositoryPath = repositoryPath
    self.workingDirectory = workingDirectory
    self.launchCommand = launchCommand
    self.approvedArguments = approvedArguments
    self.environmentProfileID = environmentProfileID
    self.permissionMode = permissionMode
    self.model = model
    self.effort = effort
    self.executionStrategy = executionStrategy
    self.resumeSessionID = resumeSessionID
    self.profileID = profileID
    self.profileRevision = profileRevision
    self.profileInstructions = profileInstructions
    self.accountID = accountID
    self.requiresExplicitAccount = requiresExplicitAccount
  }

  public var effectiveExecutionStrategy: AgentExecutionStrategy {
    executionStrategy ?? .direct
  }
}

public enum LayoutMode: String, Codable, CaseIterable, Sendable {
  case freeform
  case grid
  case columns
  case organized
  case stage
  case fleet

  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = LayoutMode(rawValue: raw) ?? .freeform
  }
}

/// The product-level destination of an Otto workspace beside Home. Switching it never
/// arranges, focuses, or otherwise mutates a canvas.
///
/// Otto once also had a spatial `canvas` surface. It has been retired, so a stored `"canvas"` (or
/// any value this build does not know) decodes as Chat and older workspaces keep loading.
public enum WorkspaceSurface: String, Codable, CaseIterable, Sendable {
  case chat

  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = WorkspaceSurface(rawValue: raw) ?? .chat
  }
}

public enum ChatSidebarList: String, Codable, Sendable {
  case sessions
  case bots

  /// A list added by a newer Otto falls back to Sessions instead of failing the workspace.
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: raw) ?? .sessions
  }
}

public enum ChatSurfaceDestination: String, Codable, CaseIterable, Identifiable, Sendable {
  case conversation = "Chat"
  case activity = "Activity"
  case files = "Files & notes"
  case routines = "Routines"
  case dashboards = "Dashboards"
  case documents = "Documents"
  case browser = "Browser"
  case skills = "Skills"

  /// A place added by a newer Otto (or Otto Dev) falls back to the conversation. Failing here
  /// fails the whole workspace snapshot, which used to let the next save wipe every session.
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: raw) ?? .conversation
  }

  public var id: String { rawValue }
  /// What people see. Raw values stay as saved; "Routines" is shown as Automations.
  public var title: String { self == .routines ? "Automations" : rawValue }
}

/// Chat owns its navigation independently from the active canvas. Stable identifiers here let a
/// surface switch (and a workspace restoration) return to the same conversation.
public struct ChatSurfaceNavigationState: Codable, Equatable, Sendable {
  public var selectedProfileID: UUID?
  public var selectedTeamID: UUID?
  public var selectedAgentID: UUID?
  public var selectedSessionID: UUID?
  public var sessionCanvasID: UUID?
  public var sidebarList: ChatSidebarList
  public var destination: ChatSurfaceDestination
  public var libraryCanvasID: UUID?

  public init(
    selectedProfileID: UUID? = nil,
    selectedTeamID: UUID? = nil,
    selectedAgentID: UUID? = nil,
    selectedSessionID: UUID? = nil,
    sessionCanvasID: UUID? = nil,
    sidebarList: ChatSidebarList = .sessions,
    destination: ChatSurfaceDestination = .conversation,
    libraryCanvasID: UUID? = nil
  ) {
    self.selectedProfileID = selectedProfileID
    self.selectedTeamID = selectedTeamID
    self.selectedAgentID = selectedAgentID
    self.selectedSessionID = selectedSessionID
    self.sessionCanvasID = sessionCanvasID
    self.sidebarList = sidebarList
    self.destination = destination
    self.libraryCanvasID = libraryCanvasID
  }
}

public enum NodeContent: Codable, Equatable, Sendable {
  case agent(provider: AgentProvider)
  case terminal(shell: String)
  case browser(url: String)
  case markdown(relativePath: String?, text: String)
  case media(source: String)
  case label(text: String)
  case group
  case connector(sourceNodeID: UUID?, targetNodeID: UUID?)
  /// A live mirror of another application's window. windowID is a CGWindowID and is only valid
  /// for the current login session; a restored node with a stale ID re-enters picking mode.
  case appMirror(windowID: UInt32?, applicationName: String?, windowTitle: String?)
  case whiteboard(document: String?, pendingActions: [WhiteboardAction])
  /// The native GTM Grid renderer hosted directly by Otto. Optional identifiers let a future
  /// renderer bridge restore a node to the same workspace, project, and table without changing
  /// the persisted content shape.
  case gtmGrid(workspaceID: String?, projectID: String?, tableID: String?)
  /// A user-owned widget package inside the workspace. Otto owns the sandbox and lifecycle while
  /// the package keeps its HTML, styles, scripts, and manifest portable and directly editable.
  case widget(packagePath: String, state: String)
}

public struct WidgetManifest: Codable, Equatable, Sendable {
  public var name: String
  public var description: String?
  public var entry: String
  public var permissions: WidgetPermissions
  public var schedule: WidgetSchedule?
  /// Native typed view rendered by Otto. When set, the package needs no HTML entry — the
  /// canvas renders the latest validated data payload directly.
  public var view: WidgetViewDescriptor?
  /// User-owned data job whose stdout populates the typed view on the widget's schedule.
  public var job: WidgetJob?
  /// User-chosen colors that override the app theme for this widget alone.
  public var theme: WidgetTheme?

  public init(
    name: String,
    description: String? = nil,
    entry: String = "index.html",
    permissions: WidgetPermissions = WidgetPermissions(),
    schedule: WidgetSchedule? = nil,
    view: WidgetViewDescriptor? = nil,
    job: WidgetJob? = nil,
    theme: WidgetTheme? = nil
  ) {
    self.name = name
    self.description = description
    self.entry = entry
    self.permissions = permissions
    self.schedule = schedule
    self.view = view
    self.job = job
    self.theme = theme
  }
}

/// Per-widget colors, independent of the app theme, as "#RRGGBB" (or "#RGB") hex strings.
/// Any field left nil falls back to the theme-derived default, so a widget can override just
/// its background ("make it black and green") without restating everything.
public struct WidgetTheme: Codable, Equatable, Sendable {
  public var background: String?
  public var accent: String?
  public var text: String?

  public init(background: String? = nil, accent: String? = nil, text: String? = nil) {
    self.background = background
    self.accent = accent
    self.text = text
  }

  public var isEmpty: Bool {
    background == nil && accent == nil && text == nil
  }

  /// Validates a single hex color string; returns the normalized "#RRGGBB" form.
  public static func normalizedHex(_ value: String) -> String? {
    var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.allSatisfy(\.isHexDigit) else { return nil }
    switch hex.count {
    case 3:
      let expanded = hex.map { "\($0)\($0)" }.joined()
      return "#\(expanded.uppercased())"
    case 6:
      return "#\(hex.uppercased())"
    default:
      return nil
    }
  }

  /// Red/green/blue components in 0...1, or nil when the string is not a valid hex color.
  public static func components(_ value: String) -> (red: Double, green: Double, blue: Double)? {
    guard let normalized = normalizedHex(value) else { return nil }
    let hex = String(normalized.dropFirst())
    var raw: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&raw) else { return nil }
    return (
      red: Double((raw >> 16) & 0xFF) / 255,
      green: Double((raw >> 8) & 0xFF) / 255,
      blue: Double(raw & 0xFF) / 255
    )
  }
}

public struct WidgetPermissions: Codable, Equatable, Sendable {
  public var network: [String]

  public init(network: [String] = []) {
    self.network = network
  }
}

public struct WidgetSchedule: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var intervalSeconds: Int
  /// Five-field cron expression. When set and valid, it takes precedence over the interval
  /// for background job scheduling.
  public var cron: String?

  public init(enabled: Bool = false, intervalSeconds: Int = 300, cron: String? = nil) {
    self.enabled = enabled
    self.intervalSeconds = intervalSeconds
    self.cron = cron
  }
}

public enum BrowserDefaults {
  public static let startURL = "otto://start"
  /// Tabs saved before the rename still hold this start page.
  public static let legacyStartURL = "muse://start"

  public static func isStartURL(_ value: String) -> Bool {
    value == startURL || value == legacyStartURL
  }
  public static let blankURL = "about:blank"
  public static let subtitle = "OTTO BROWSER"
}

public struct BrowserTab: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var url: String

  public init(id: UUID = UUID(), title: String = "New Tab", url: String = BrowserDefaults.blankURL)
  {
    self.id = id
    self.title = title
    self.url = url
  }
}

public struct BrowserSession: Codable, Equatable, Sendable {
  public var tabs: [BrowserTab]
  public var activeTabID: UUID

  public init(tabs: [BrowserTab], activeTabID: UUID) {
    let normalizedTabs = tabs.isEmpty ? [BrowserTab()] : tabs
    self.tabs = normalizedTabs
    self.activeTabID =
      normalizedTabs.contains(where: { $0.id == activeTabID })
      ? activeTabID : normalizedTabs[0].id
  }

  public init(url: String) {
    let tab = BrowserTab(
      title: [BrowserDefaults.startURL, BrowserDefaults.blankURL].contains(url)
        ? "New Tab" : "Loading…",
      url: url
    )
    self.init(tabs: [tab], activeTabID: tab.id)
  }

  public var activeTab: BrowserTab? {
    tabs.first(where: { $0.id == activeTabID })
  }
}

public struct BrowserBookmark: Identifiable, Codable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var url: String

  public init(title: String, url: String) {
    self.title = title
    self.url = url
    self.id = url
  }
}

public enum WhiteboardShapeType: String, Codable, CaseIterable, Sendable {
  case rectangle
  case ellipse
  case diamond
  case text
  case note
  case arrow
}

public struct WhiteboardShape: Codable, Equatable, Sendable {
  public var id: String
  public var type: WhiteboardShapeType
  public var x: Double
  public var y: Double
  public var width: Double?
  public var height: Double?
  public var text: String?
  public var color: String?

  public init(
    id: String = UUID().uuidString.lowercased(),
    type: WhiteboardShapeType,
    x: Double,
    y: Double,
    width: Double? = nil,
    height: Double? = nil,
    text: String? = nil,
    color: String? = nil
  ) {
    self.id = id
    self.type = type
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.text = text
    self.color = color
  }
}

public enum WhiteboardActionKind: String, Codable, Sendable {
  case createShapes
  case deleteShapes
  case clear
  case fit
}

public struct WhiteboardAction: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var kind: WhiteboardActionKind
  public var shapes: [WhiteboardShape]?
  public var shapeIDs: [String]?

  public init(
    id: UUID = UUID(),
    kind: WhiteboardActionKind,
    shapes: [WhiteboardShape]? = nil,
    shapeIDs: [String]? = nil
  ) {
    self.id = id
    self.kind = kind
    self.shapes = shapes
    self.shapeIDs = shapeIDs
  }
}

public struct OttoAttachment: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var displayName: String
  public var relativePath: String
  public var mimeType: String
  public var byteCount: Int64
  public var importedAt: Date

  public init(
    id: UUID = UUID(),
    displayName: String,
    relativePath: String,
    mimeType: String,
    byteCount: Int64,
    importedAt: Date = .now
  ) {
    self.id = id
    self.displayName = displayName
    self.relativePath = relativePath
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.importedAt = importedAt
  }
}

public struct OttoNode: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var kind: NodeKind
  public var displayName: String
  public var subtitle: String
  public var frame: WorldRect
  public var zIndex: Int
  public var status: NodeStatus
  public var detail: String
  public var content: NodeContent?
  public var agentDefinition: AgentDefinition?
  public var workTitle: String?
  public var presentationMode: NodePresentationMode?
  public var lastExpandedPresentation: NodePresentationMode?
  public var isMinimized: Bool?
  public var attachments: [OttoAttachment]?
  public var browserSession: BrowserSession?
  /// The agent conversation whose Chat work panel owns this browser surface.
  public var browserOwnerAgentID: UUID?
  /// Delegated runtime owned by a parent conversation, rather than a standalone session.
  public var parentAgentID: UUID?

  public var isStandaloneAgent: Bool { kind == .agent && parentAgentID == nil }
  public var createdAt: Date
  public var lastOpenedAt: Date?
  public var unsupportedContentPayload: OpaqueCodableValue?
  public var additionalPayload: [String: OpaqueCodableValue]

  public init(
    id: UUID = UUID(),
    kind: NodeKind,
    displayName: String,
    subtitle: String,
    frame: WorldRect,
    zIndex: Int,
    status: NodeStatus = .idle,
    detail: String = "Ready",
    content: NodeContent? = nil,
    agentDefinition: AgentDefinition? = nil,
    workTitle: String? = nil,
    presentationMode: NodePresentationMode? = nil,
    lastExpandedPresentation: NodePresentationMode? = nil,
    isMinimized: Bool? = false,
    attachments: [OttoAttachment]? = nil,
    browserSession: BrowserSession? = nil,
    browserOwnerAgentID: UUID? = nil,
    parentAgentID: UUID? = nil,
    createdAt: Date = .now,
    lastOpenedAt: Date? = .now,
    unsupportedContentPayload: OpaqueCodableValue? = nil,
    additionalPayload: [String: OpaqueCodableValue] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.displayName = displayName
    self.subtitle = subtitle
    self.frame = frame
    self.zIndex = zIndex
    self.status = status
    self.detail = detail
    self.content = content
    self.agentDefinition = agentDefinition
    self.workTitle = workTitle
    self.presentationMode = presentationMode
    self.lastExpandedPresentation = lastExpandedPresentation
    self.isMinimized = isMinimized
    self.attachments = attachments
    self.browserSession = browserSession
    self.browserOwnerAgentID = browserOwnerAgentID
    self.parentAgentID = parentAgentID
    self.createdAt = createdAt
    self.lastOpenedAt = lastOpenedAt
    self.unsupportedContentPayload = unsupportedContentPayload
    self.additionalPayload = additionalPayload
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id, kind, displayName, subtitle, frame, zIndex, status, detail, content, agentDefinition
    case workTitle
    case presentationMode, lastExpandedPresentation, isMinimized, attachments, createdAt
    case browserSession
    case browserOwnerAgentID, parentAgentID
    case lastOpenedAt
  }

  private struct PayloadKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) {
      self.stringValue = stringValue
      self.intValue = nil
    }
    init?(intValue: Int) {
      self.stringValue = String(intValue)
      self.intValue = intValue
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decode(NodeKind.self, forKey: .kind)
    displayName = try container.decode(String.self, forKey: .displayName)
    subtitle = try container.decode(String.self, forKey: .subtitle)
    frame = try container.decode(WorldRect.self, forKey: .frame)
    zIndex = try container.decode(Int.self, forKey: .zIndex)
    status = try container.decode(NodeStatus.self, forKey: .status)
    detail = try container.decode(String.self, forKey: .detail)
    if container.contains(.content), try !container.decodeNil(forKey: .content) {
      if let known = try? container.decode(NodeContent.self, forKey: .content) {
        content = known
        unsupportedContentPayload = nil
      } else {
        content = nil
        unsupportedContentPayload = try container.decode(
          OpaqueCodableValue.self, forKey: .content)
      }
    } else {
      content = nil
      unsupportedContentPayload = nil
    }
    agentDefinition = try container.decodeIfPresent(AgentDefinition.self, forKey: .agentDefinition)
    workTitle = try container.decodeIfPresent(String.self, forKey: .workTitle)
    presentationMode = try container.decodeIfPresent(
      NodePresentationMode.self, forKey: .presentationMode)
    lastExpandedPresentation = try container.decodeIfPresent(
      NodePresentationMode.self, forKey: .lastExpandedPresentation)
    isMinimized = try container.decodeIfPresent(Bool.self, forKey: .isMinimized)
    attachments = try container.decodeIfPresent([OttoAttachment].self, forKey: .attachments)
    browserSession = try container.decodeIfPresent(BrowserSession.self, forKey: .browserSession)
    browserOwnerAgentID = try container.decodeIfPresent(UUID.self, forKey: .browserOwnerAgentID)
    parentAgentID = try container.decodeIfPresent(UUID.self, forKey: .parentAgentID)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)

    let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
    let payload = try decoder.container(keyedBy: PayloadKey.self)
    additionalPayload = try payload.allKeys.reduce(into: [:]) { result, key in
      guard !knownKeys.contains(key.stringValue) else { return }
      result[key.stringValue] = try payload.decode(OpaqueCodableValue.self, forKey: key)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(subtitle, forKey: .subtitle)
    try container.encode(frame, forKey: .frame)
    try container.encode(zIndex, forKey: .zIndex)
    try container.encode(status, forKey: .status)
    try container.encode(detail, forKey: .detail)
    if let content {
      try container.encode(content, forKey: .content)
    } else if let unsupportedContentPayload {
      try container.encode(unsupportedContentPayload, forKey: .content)
    } else {
      try container.encodeNil(forKey: .content)
    }
    try container.encodeIfPresent(agentDefinition, forKey: .agentDefinition)
    try container.encodeIfPresent(workTitle, forKey: .workTitle)
    try container.encodeIfPresent(presentationMode, forKey: .presentationMode)
    try container.encodeIfPresent(lastExpandedPresentation, forKey: .lastExpandedPresentation)
    try container.encodeIfPresent(isMinimized, forKey: .isMinimized)
    try container.encodeIfPresent(attachments, forKey: .attachments)
    try container.encodeIfPresent(browserSession, forKey: .browserSession)
    try container.encodeIfPresent(browserOwnerAgentID, forKey: .browserOwnerAgentID)
    try container.encodeIfPresent(parentAgentID, forKey: .parentAgentID)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)

    var payload = encoder.container(keyedBy: PayloadKey.self)
    let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
    for (name, value) in additionalPayload where !knownKeys.contains(name) {
      guard let key = PayloadKey(stringValue: name) else { continue }
      try payload.encode(value, forKey: key)
    }
  }

  /// Resolves legacy canvases that only persisted `isMinimized` into the explicit model.
  public var effectivePresentationMode: NodePresentationMode {
    if let presentationMode { return presentationMode }
    if isMinimized == true { return .compact }
    return kind == .terminal ? .terminal : .conversation
  }

  public var effectiveExpandedPresentation: NodePresentationMode {
    if let lastExpandedPresentation, lastExpandedPresentation.isExpanded {
      return lastExpandedPresentation
    }
    let current = effectivePresentationMode
    if current.isExpanded { return current }
    return kind == .terminal ? .terminal : .conversation
  }
}

public struct OttoCanvas: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var viewport: Viewport
  public var nodes: [OttoNode]
  public var selectedNodeID: UUID?
  public var themeID: String?
  public var layoutMode: LayoutMode?
  public var layoutFrames: [String: [UUID: WorldRect]]?
  public var autoFitEnabled: Bool?
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    viewport: Viewport = Viewport(),
    nodes: [OttoNode] = [],
    selectedNodeID: UUID? = nil,
    themeID: String? = OttoThemeCatalog.defaultThemeID,
    layoutMode: LayoutMode? = .freeform,
    layoutFrames: [String: [UUID: WorldRect]]? = [:],
    autoFitEnabled: Bool? = true,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.name = name
    self.viewport = viewport
    self.nodes = nodes
    self.selectedNodeID = selectedNodeID
    self.themeID = themeID
    self.layoutMode = layoutMode
    self.layoutFrames = layoutFrames
    self.autoFitEnabled = autoFitEnabled
    self.updatedAt = updatedAt
  }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
  public var canvases: [OttoCanvas]
  public var activeCanvasID: UUID
  public var workspaceSurface: WorkspaceSurface
  public var chatNavigation: ChatSurfaceNavigationState

  public init(
    canvases: [OttoCanvas],
    activeCanvasID: UUID,
    workspaceSurface: WorkspaceSurface = .chat,
    chatNavigation: ChatSurfaceNavigationState = ChatSurfaceNavigationState()
  ) {
    self.canvases = canvases
    self.activeCanvasID = activeCanvasID
    self.workspaceSurface = workspaceSurface
    self.chatNavigation = chatNavigation
  }

  private enum CodingKeys: String, CodingKey {
    case canvases
    case activeCanvasID
    case workspaceSurface
    case chatNavigation
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    canvases = try container.decode([OttoCanvas].self, forKey: .canvases)
    activeCanvasID = try container.decode(UUID.self, forKey: .activeCanvasID)
    // Navigation is disposable UI state: anything a newer build wrote that this build cannot
    // read resets it rather than making the canvases and sessions unreadable.
    chatNavigation =
      (try? container.decodeIfPresent(ChatSurfaceNavigationState.self, forKey: .chatNavigation))
      ?? ChatSurfaceNavigationState()

    // Before WorkspaceSurface existed, Chat was persisted as a canvas layout; LayoutMode's
    // forward-compatible decoder turns that removed value into freeform, preserving every node
    // frame, viewport, and selection. Chat is now the only surface, so a missing, legacy, or
    // unknown value all restore it.
    workspaceSurface =
      (try? container.decodeIfPresent(WorkspaceSurface.self, forKey: .workspaceSurface)) ?? .chat
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(canvases, forKey: .canvases)
    try container.encode(activeCanvasID, forKey: .activeCanvasID)
    try container.encode(workspaceSurface, forKey: .workspaceSurface)
    try container.encode(chatNavigation, forKey: .chatNavigation)
  }

  public static var starter: WorkspaceSnapshot {
    let canvasID = UUID()
    return WorkspaceSnapshot(
      canvases: [OttoCanvas(id: canvasID, name: "Workspace")],
      activeCanvasID: canvasID,
      workspaceSurface: .chat
    )
  }
}
