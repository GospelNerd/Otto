import Foundation
import OttoModels
import OttoPersistence

#if canImport(Combine)
  import Combine
#endif

@MainActor
public final class CanvasStore: ObservableObject {
  @Published public private(set) var snapshot: WorkspaceSnapshot
  @Published public private(set) var lastReceipt = "Workspace ready"
  @Published public private(set) var persistenceError: String?

  private let persistence: SQLiteWorkspaceStore?
  private var persistIsDirty = false
  /// Set when the saved workspace exists but could not be read. Saving the in-memory starter
  /// workspace over it would destroy every canvas and session, so writes stop until relaunch.
  public private(set) var persistenceWritesBlocked = false
  /// True until `restore()` has read (or initialised) the saved workspace. A store created
  /// without an explicit snapshot holds only the starter placeholder until then, and saving it
  /// would replace every saved canvas and session. Quitting before the first restore did exactly
  /// that: the one-time move from Muse.app to Otto.app quits within a second of launch and
  /// flushed the placeholder over the migrated workspace.
  public private(set) var isAwaitingRestore: Bool
  private var persistDrainTask: Task<Void, Never>?
  private let persistCoalesceWindow: Duration
  private let preferences: UserDefaults

  /// Pass `snapshot` only when it is the workspace to keep. Without one the store starts from
  /// the starter placeholder and saves nothing until `restore()` has run.
  public init(
    snapshot: WorkspaceSnapshot? = nil,
    persistence: SQLiteWorkspaceStore? = nil,
    persistCoalesceWindow: Duration = .milliseconds(400),
    preferences: UserDefaults = .standard
  ) {
    self.snapshot = snapshot ?? .starter
    self.isAwaitingRestore = snapshot == nil && persistence != nil
    self.persistence = persistence
    self.persistCoalesceWindow = persistCoalesceWindow
    self.preferences = preferences
  }

  public var activeCanvas: OttoCanvas {
    snapshot.canvases.first(where: { $0.id == snapshot.activeCanvasID }) ?? snapshot.canvases[0]
  }

  public var workspaceSurface: WorkspaceSurface { snapshot.workspaceSurface }

  @discardableResult
  public func setWorkspaceSurface(_ surface: WorkspaceSurface) -> CommandReceipt {
    guard snapshot.workspaceSurface != surface else {
      return CommandReceipt(message: "Opened \(surface.rawValue.capitalized)")
    }
    snapshot.workspaceSurface = surface
    let receipt = CommandReceipt(message: "Opened \(surface.rawValue.capitalized)")
    lastReceipt = receipt.message
    persist()
    return receipt
  }

  public func updateChatNavigation(_ navigation: ChatSurfaceNavigationState) {
    guard snapshot.chatNavigation != navigation else { return }
    snapshot.chatNavigation = navigation
    persist()
  }

  public func restore() async {
    guard let persistence else { return }
    do {
      if let restored = try await persistence.loadForRestoration(), !restored.canvases.isEmpty {
        snapshot = restored
        lastReceipt =
          "Restored \(restored.canvases.count) canvas\(restored.canvases.count == 1 ? "" : "es")"
      } else {
        try await persistence.save(snapshot)
      }
      isAwaitingRestore = false
    } catch {
      persistenceWritesBlocked = true
      let backup = try? await persistence.preserveUnreadableSnapshot()
      persistenceError =
        "\(error.localizedDescription)\n\nYour saved workspace was left untouched"
        + (backup.map { " and copied to \($0)" } ?? "")
        + ". Changes made now will not be saved. This usually means a newer Otto (such as"
        + " Otto Dev) saved it, so open that version or update Otto."
    }
  }

  @discardableResult
  public func dispatch(
    _ command: CanvasCommand,
    targetCanvasID: UUID? = nil
  ) -> CommandReceipt {
    switch command {
    case .createCanvas(let name):
      let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let canvas = OttoCanvas(
        name: normalized.isEmpty
          ? "Canvas \(snapshot.canvases.count + 1)" : String(normalized.prefix(80)))
      snapshot.canvases.append(canvas)
      snapshot.activeCanvasID = canvas.id
      let receipt = CommandReceipt(message: "Created \(canvas.name)")
      lastReceipt = receipt.message
      persist()
      return receipt
    case .switchCanvas(let id):
      guard let canvas = snapshot.canvases.first(where: { $0.id == id }) else {
        return CommandReceipt(message: "Canvas \(id.uuidString.prefix(8)) was not found")
      }
      snapshot.activeCanvasID = id
      let receipt = CommandReceipt(message: "Switched to \(canvas.name)")
      lastReceipt = receipt.message
      persist()
      return receipt
    default:
      break
    }
    let resolvedCanvasID = targetCanvasID ?? snapshot.activeCanvasID
    guard let targetIndex = snapshot.canvases.firstIndex(where: { $0.id == resolvedCanvasID })
    else {
      return CommandReceipt(
        message: "Canvas \(resolvedCanvasID.uuidString.prefix(8)) was not found")
    }
    var canvas = snapshot.canvases[targetIndex]
    let receipt: CommandReceipt

    switch command {
    case .createCanvas, .switchCanvas:
      preconditionFailure("Workspace commands return before active-canvas dispatch")
    case .createNode(let kind, let point, let parentAgentID):
      // Structured layouts are durable modes, not one-shot arrange commands. New nodes become
      // the active stage occupant, while every deterministic layout recalculates after insertion
      // so new windows never land as freeform strays.
      let activeLayout = canvas.layoutMode ?? .freeform
      let ordinal = canvas.nodes.filter { $0.kind == kind }.count + 1
      let size = kind.defaultSize
      let name: String
      let subtitle: String
      switch kind {
      case .agent:
        name = AgentNamingPolicy.load(from: preferences).nextName(
          existingNames: canvas.nodes.filter { $0.kind == .agent }.map(\.displayName))
        subtitle = "AGENT · LOCAL"
      case .terminal:
        name = "Terminal \(ordinal)"
        subtitle = "ZSH · LOCAL"
      case .browser:
        name = "Browser \(ordinal)"
        subtitle = BrowserDefaults.subtitle
      case .markdown:
        name = "Notes \(ordinal)"
        subtitle = "MARKDOWN · UNTITLED.MD"
      case .media:
        name = "Media \(ordinal)"
        subtitle = "AUDIO · LOCAL"
      case .label:
        name = "Label \(ordinal)"
        subtitle = "CANVAS NOTE"
      case .group:
        name = "Group \(ordinal)"
        subtitle = "SPATIAL REGION"
      case .connector:
        name = "Connector \(ordinal)"
        subtitle = "DIRECTIONAL LINK"
      case .appMirror:
        name = "Mirror \(ordinal)"
        subtitle = "APP WINDOW · LIVE"
      case .whiteboard:
        name = "Whiteboard \(ordinal)"
        subtitle = "EXCALIDRAW · LOCAL"
      case .gtmGrid:
        name = ordinal == 1 ? "GTM Grid" : "GTM Grid \(ordinal)"
        subtitle = "GTM GRID · EMBEDDED"
      case .widget:
        name = "Widget \(ordinal)"
        subtitle = "CUSTOM CODE · LOCAL"
      case .unsupported(let identifier):
        name = "Unsupported node"
        subtitle = identifier.uppercased()
      }
      var node = OttoNode(
        kind: kind,
        displayName: name,
        subtitle: subtitle,
        frame: WorldRect(x: point.x, y: point.y, width: size.width, height: size.height),
        zIndex: (canvas.nodes.map(\.zIndex).max() ?? -1) + 1,
        status: kind == .agent ? .starting : .idle,
        detail: kind == .agent ? "Starting local runtime…" : "Ready"
      )
      switch kind {
      case .agent:
        // Provider and account identity come from the launch configuration. A generic placeholder
        // must not pretend to be Claude or Codex merely because of its creation order.
        node.content = nil
      case .terminal:
        node.content = .terminal(shell: "zsh")
      case .browser:
        node.content = .browser(url: BrowserDefaults.startURL)
        node.browserSession = BrowserSession(url: BrowserDefaults.startURL)
      case .markdown:
        node.content = .markdown(relativePath: nil, text: "# Untitled\n")
      case .media:
        node.content = .media(source: "")
      case .label:
        node.content = .label(text: "New thought")
      case .group:
        node.content = .group
      case .connector:
        node.content = .connector(sourceNodeID: nil, targetNodeID: nil)
      case .appMirror:
        node.content = .appMirror(windowID: nil, applicationName: nil, windowTitle: nil)
      case .whiteboard:
        node.content = .whiteboard(document: nil, pendingActions: [])
      case .gtmGrid:
        node.content = .gtmGrid(workspaceID: nil, projectID: nil, tableID: nil)
      case .widget:
        node.content = .widget(packagePath: "", state: "{}")
      case .unsupported:
        node.content = nil
      }
      node.parentAgentID = parentAgentID
      canvas.nodes.append(node)
      // Delegation must never steal the conversation focus, even during node creation.
      if parentAgentID == nil { canvas.selectedNodeID = node.id }
      if activeLayout != .freeform {
        arrangeNodes(in: &canvas, layout: activeLayout)
      }
      receipt = CommandReceipt(message: "Created \(name)", affectedNodeIDs: [node.id])

    case .focusNode(let id):
      canvas.selectedNodeID = id
      if let id, let index = canvas.nodes.firstIndex(where: { $0.id == id }) {
        canvas.nodes[index].zIndex = (canvas.nodes.map(\.zIndex).max() ?? 0) + 1
        if canvas.layoutMode == .stage {
          arrangeNodes(in: &canvas, layout: .stage)
        }
        receipt = CommandReceipt(
          message: "Focused \(canvas.nodes[index].displayName)", affectedNodeIDs: [id])
      } else {
        receipt = CommandReceipt(message: "Cleared selection")
      }

    case .moveNode(let id, let point):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      canvas.nodes[index].frame.x = point.x
      canvas.nodes[index].frame.y = point.y
      receipt = CommandReceipt(
        message: "Moved \(canvas.nodes[index].displayName)", affectedNodeIDs: [id])

    case .resizeNode(let id, let width, let height):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      canvas.nodes[index].frame.width = max(260, width)
      canvas.nodes[index].frame.height = max(180, height)
      receipt = CommandReceipt(
        message: "Resized \(canvas.nodes[index].displayName)", affectedNodeIDs: [id])

    case .closeNode(let id):
      guard let node = canvas.nodes.first(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      canvas.nodes.removeAll { $0.id == id }
      if canvas.selectedNodeID == id { canvas.selectedNodeID = nil }
      let activeLayout = canvas.layoutMode ?? .freeform
      if activeLayout != .freeform {
        arrangeNodes(in: &canvas, layout: activeLayout)
      }
      receipt = CommandReceipt(message: "Closed \(node.displayName)", affectedNodeIDs: [id])

    case .closeAll:
      let ids = canvas.nodes.map(\.id)
      canvas.nodes.removeAll()
      canvas.selectedNodeID = nil
      receipt = CommandReceipt(message: "Closed \(ids.count) nodes", affectedNodeIDs: ids)

    case .setNodeStatus(let id, let status, let detail):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      canvas.nodes[index].status = status
      canvas.nodes[index].detail = detail
      receipt = CommandReceipt(
        message: "\(canvas.nodes[index].displayName) is \(status.rawValue)",
        affectedNodeIDs: [id]
      )

    case .setNodeContent(let id, let content):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      canvas.nodes[index].content = content
      if case .agent(let provider) = content {
        canvas.nodes[index].subtitle = "\(provider.rawValue.uppercased()) · LOCAL"
      }
      if case .terminal(let shell) = content {
        canvas.nodes[index].subtitle =
          "\(URL(fileURLWithPath: shell).lastPathComponent.uppercased()) · LOCAL"
      }
      if case .browser(let url) = content {
        var session = canvas.nodes[index].browserSession ?? BrowserSession(url: url)
        if let tabIndex = session.tabs.firstIndex(where: { $0.id == session.activeTabID }) {
          session.tabs[tabIndex].url = url
          if BrowserDefaults.isStartURL(url) { session.tabs[tabIndex].title = "New Tab" }
        }
        canvas.nodes[index].browserSession = session
      }
      receipt = CommandReceipt(
        message: "Updated \(canvas.nodes[index].displayName)",
        affectedNodeIDs: [id]
      )

    case .setBrowserSession(let id, let session):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      canvas.nodes[index].browserSession = session
      receipt = CommandReceipt(
        message: "Updated \(canvas.nodes[index].displayName) tabs",
        affectedNodeIDs: [id]
      )

    case .setBrowserOwner(let id, let agentID):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      guard canvas.nodes[index].kind == .browser else {
        return CommandReceipt(message: "Node is not a browser", affectedNodeIDs: [id])
      }
      canvas.nodes[index].browserOwnerAgentID = agentID
      receipt = CommandReceipt(
        message: "Associated \(canvas.nodes[index].displayName) with its chat",
        affectedNodeIDs: [id]
      )

    case .updateBrowserTab(let id, let tabID, let url, let title):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      guard var session = canvas.nodes[index].browserSession,
        let tabIndex = session.tabs.firstIndex(where: { $0.id == tabID })
      else {
        return CommandReceipt(message: "Browser tab was not found", affectedNodeIDs: [id])
      }
      session.tabs[tabIndex].url = url
      if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
        session.tabs[tabIndex].title = title
      }
      canvas.nodes[index].browserSession = session
      if session.activeTabID == tabID {
        canvas.nodes[index].content = .browser(url: url)
      }
      receipt = CommandReceipt(
        message: "Updated \(canvas.nodes[index].displayName) tab",
        affectedNodeIDs: [id]
      )

    case .setAgentDefinition(let id, let definition):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      canvas.nodes[index].agentDefinition = definition
      receipt = CommandReceipt(
        message: "Saved \(canvas.nodes[index].displayName) configuration",
        affectedNodeIDs: [id]
      )

    case .setNodeWorkTitle(let id, let title):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      let normalized = title?.trimmingCharacters(in: .whitespacesAndNewlines)
      canvas.nodes[index].workTitle =
        normalized?.isEmpty == false
        ? String(normalized!.prefix(80)) : nil
      receipt = CommandReceipt(
        message: "Updated \(canvas.nodes[index].displayName) work title",
        affectedNodeIDs: [id]
      )

    case .setNodePresentation(let id, let presentation):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      let normalized: NodePresentationMode
      if presentation == .terminal, canvas.nodes[index].kind != .agent,
        canvas.nodes[index].kind != .terminal
      {
        normalized = .conversation
      } else if presentation == .files, canvas.nodes[index].kind != .agent {
        normalized = .conversation
      } else {
        normalized = presentation
      }
      if normalized.isExpanded {
        canvas.nodes[index].lastExpandedPresentation = normalized
      }
      canvas.nodes[index].presentationMode = normalized
      canvas.nodes[index].isMinimized = !normalized.isExpanded
      if normalized.isExpanded {
        canvas.selectedNodeID = id
        canvas.nodes[index].lastOpenedAt = .now
        canvas.nodes[index].zIndex = (canvas.nodes.map(\.zIndex).max() ?? 0) + 1
      } else {
        if canvas.selectedNodeID == id { canvas.selectedNodeID = nil }
      }
      receipt = CommandReceipt(
        message: "Presented \(canvas.nodes[index].displayName) as \(normalized.rawValue)",
        affectedNodeIDs: [id]
      )

    case .setNodeMinimized(let id, let minimized):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      let presentation: NodePresentationMode =
        minimized ? .compact : canvas.nodes[index].effectiveExpandedPresentation
      if presentation.isExpanded {
        canvas.nodes[index].lastExpandedPresentation = presentation
      }
      canvas.nodes[index].presentationMode = presentation
      canvas.nodes[index].isMinimized = minimized
      if minimized {
        if canvas.selectedNodeID == id { canvas.selectedNodeID = nil }
      } else {
        canvas.selectedNodeID = id
        canvas.nodes[index].lastOpenedAt = .now
        canvas.nodes[index].zIndex = (canvas.nodes.map(\.zIndex).max() ?? 0) + 1
      }
      receipt = CommandReceipt(
        message: minimized
          ? "Minimized \(canvas.nodes[index].displayName) to rail"
          : "Restored \(canvas.nodes[index].displayName)",
        affectedNodeIDs: [id]
      )

    case .renameNode(let id, let name):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty else {
        return CommandReceipt(message: "Node name cannot be empty", affectedNodeIDs: [id])
      }
      canvas.nodes[index].displayName = String(normalized.prefix(80))
      receipt = CommandReceipt(message: "Renamed node to \(canvas.nodes[index].displayName)")

    case .addAttachments(let id, let attachments):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      var existing = canvas.nodes[index].attachments ?? []
      existing.append(contentsOf: attachments)
      canvas.nodes[index].attachments = existing
      receipt = CommandReceipt(
        message:
          "Attached \(attachments.count) file\(attachments.count == 1 ? "" : "s") to \(canvas.nodes[index].displayName)",
        affectedNodeIDs: [id]
      )

    case .setNodeSubtitle(let id, let subtitle):
      guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else {
        return missingNodeReceipt(id)
      }
      canvas.nodes[index].subtitle = String(subtitle.prefix(120))
      receipt = CommandReceipt(
        message: "Updated \(canvas.nodes[index].displayName) workspace",
        affectedNodeIDs: [id]
      )

    case .setLayout(let layout):
      let target = layout == .organized ? LayoutMode.grid : layout
      applyLayout(target, to: &canvas)
      receipt = CommandReceipt(
        message: "Changed layout to \(target.rawValue)",
        affectedNodeIDs: canvas.nodes.map(\.id)
      )

    case .organize:
      applyLayout(.grid, to: &canvas)
      receipt = CommandReceipt(
        message: "Organized \(canvas.nodes.count) nodes",
        affectedNodeIDs: canvas.nodes.map(\.id)
      )

    case .setTheme(let themeID):
      let canonical = OttoThemeCatalog.canonicalID(themeID) ?? themeID
      canvas.themeID = canonical
      preferences.set(canonical, forKey: OttoPreferenceKey.latestSelectedTheme)
      receipt = CommandReceipt(message: "Changed theme to \(canonical)")

    case .setViewport(let viewport):
      canvas.viewport = viewport
      receipt = CommandReceipt(message: "Canvas at \(Int(viewport.scale * 100))%")

    case .setAutoFit(let enabled):
      canvas.autoFitEnabled = enabled
      receipt = CommandReceipt(message: "Auto-fit \(enabled ? "enabled" : "disabled")")

    case .renameCanvas(let name):
      canvas.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      receipt = CommandReceipt(message: "Renamed canvas to \(canvas.name)")
    }

    canvas.updatedAt = .now
    replaceCanvas(with: canvas, at: targetIndex)
    lastReceipt = receipt.message
    persist()
    return receipt
  }

  private func replaceCanvas(with canvas: OttoCanvas, at index: Int) {
    precondition(snapshot.canvases.indices.contains(index))
    precondition(snapshot.canvases[index].id == canvas.id)
    snapshot.canvases[index] = canvas
  }

  public func canvasID(containing nodeID: UUID) -> UUID? {
    snapshot.canvases.first(where: { canvas in
      canvas.nodes.contains(where: { $0.id == nodeID })
    })?.id
  }

  private func missingNodeReceipt(_ id: UUID) -> CommandReceipt {
    CommandReceipt(message: "Node \(id.uuidString.prefix(8)) was not found")
  }

  // Persistence is coalesced: the first change in a burst saves immediately, and everything that
  // lands during the coalesce window folds into one trailing save. Terminal output, drags, and
  // zoom gestures dispatch far faster than a full-workspace SQLite write can be repeated.
  private func persist() {
    guard persistence != nil, !isAwaitingRestore, !persistenceWritesBlocked else { return }
    persistIsDirty = true
    guard persistDrainTask == nil else { return }
    persistDrainTask = Task { [weak self] in
      while true {
        guard let self, await self.drainPendingPersist() else { return }
      }
    }
  }

  private func drainPendingPersist() async -> Bool {
    guard persistIsDirty, let persistence, !isAwaitingRestore, !persistenceWritesBlocked else {
      persistDrainTask = nil
      return false
    }
    persistIsDirty = false
    let snapshot = snapshot
    do {
      try await persistence.save(snapshot)
      // A completed write disproves an earlier failure notice. Without this the notice outlives
      // the condition that raised it — a momentarily full disk leaves Otto warning that changes
      // are not being saved while it saves them.
      persistenceError = nil
    } catch {
      persistenceError = error.localizedDescription
    }
    try? await Task.sleep(for: persistCoalesceWindow)
    return true
  }

  /// Clears the persistence notice. The alert that shows it cannot clear published state
  /// itself, so dismissing has to come back through the store or the notice returns at once.
  public func dismissPersistenceError() {
    persistenceError = nil
  }

  /// Writes any coalesced-but-unsaved changes now. Call on scene background/termination.
  public func flushPersistence() async {
    let draining = persistDrainTask
    persistDrainTask = nil
    draining?.cancel()
    await draining?.value
    guard let persistence, persistIsDirty, !isAwaitingRestore, !persistenceWritesBlocked else {
      return
    }
    persistIsDirty = false
    do {
      try await persistence.save(snapshot)
      // A completed write disproves an earlier failure notice. Without this the notice outlives
      // the condition that raised it — a momentarily full disk leaves Otto warning that changes
      // are not being saved while it saves them.
      persistenceError = nil
    } catch {
      persistenceError = error.localizedDescription
    }
  }

  private func applyLayout(_ target: LayoutMode, to canvas: inout OttoCanvas) {
    let current = canvas.layoutMode ?? .freeform
    var snapshots = canvas.layoutFrames ?? [:]
    // Deterministic layouts must be recalculated whenever they are invoked. Restoring cached grid,
    // column, stage, or fleet frames makes layout actions stale after selection/node changes.
    // Freeform is the one authored arrangement worth preserving and restoring exactly.
    if current == .freeform {
      snapshots[LayoutMode.freeform.rawValue] = Dictionary(
        uniqueKeysWithValues: canvas.nodes.map { ($0.id, $0.frame) })
    }

    if target == .freeform,
      let saved = snapshots[LayoutMode.freeform.rawValue]
    {
      for index in canvas.nodes.indices {
        if let frame = saved[canvas.nodes[index].id] { canvas.nodes[index].frame = frame }
      }
    } else {
      arrangeNodes(in: &canvas, layout: target)
    }
    canvas.layoutFrames = snapshots
    canvas.layoutMode = target
  }

  private func arrangeNodes(in canvas: inout OttoCanvas, layout: LayoutMode) {
    guard !canvas.nodes.isEmpty else { return }
    switch layout {
    case .freeform:
      break
    case .grid, .organized:
      let columnCount = max(1, Int(ceil(sqrt(Double(canvas.nodes.count)))))
      let rowCount = Int(ceil(Double(canvas.nodes.count) / Double(columnCount)))
      let width = 380.0
      let height = 240.0
      let horizontalStep = 420.0
      let verticalStep = 280.0
      let totalWidth = width + Double(columnCount - 1) * horizontalStep
      let totalHeight = height + Double(rowCount - 1) * verticalStep
      for index in canvas.nodes.indices {
        let column = index % columnCount
        let row = index / columnCount
        canvas.nodes[index].frame = WorldRect(
          x: -totalWidth / 2 + Double(column) * horizontalStep,
          y: -totalHeight / 2 + Double(row) * verticalStep,
          width: width,
          height: height
        )
      }
    case .columns:
      let width = 340.0
      let height = 540.0
      let step = width + 30
      let totalWidth = width + Double(canvas.nodes.count - 1) * step
      for index in canvas.nodes.indices {
        canvas.nodes[index].frame = WorldRect(
          x: -totalWidth / 2 + Double(index) * step,
          y: -height / 2,
          width: width,
          height: height
        )
      }
    case .stage:
      let primaryID = canvas.selectedNodeID ?? canvas.nodes.last?.id
      var sidebarIndex = 0
      for index in canvas.nodes.indices {
        if canvas.nodes[index].id == primaryID {
          canvas.nodes[index].frame = WorldRect(x: -430, y: -300, width: 760, height: 600)
        } else {
          canvas.nodes[index].frame = WorldRect(
            x: 370,
            y: -300 + Double(sidebarIndex) * 180,
            width: 300,
            height: 150
          )
          sidebarIndex += 1
        }
      }
    case .fleet:
      let columnCount = min(2, canvas.nodes.count)
      let rowCount = Int(ceil(Double(canvas.nodes.count) / Double(columnCount)))
      let width = 400.0
      let height = 180.0
      let horizontalStep = 430.0
      let verticalStep = 210.0
      let totalWidth = width + Double(columnCount - 1) * horizontalStep
      let totalHeight = height + Double(rowCount - 1) * verticalStep
      for index in canvas.nodes.indices {
        let column = index % 2
        let row = index / 2
        canvas.nodes[index].frame = WorldRect(
          x: -totalWidth / 2 + Double(column) * horizontalStep,
          y: -totalHeight / 2 + Double(row) * verticalStep,
          width: width,
          height: height
        )
      }
    }
  }
}
