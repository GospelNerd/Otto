import Foundation
import OttoApplicationTools
import OttoBrowser
import OttoCore
import OttoDocuments
import OttoMedia
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("Spatial workflow tools")
struct SpatialWorkflowTests {
  @Test("Opening Chat never mutates canvas layout; the retired Canvas surface is rejected")
  func workspaceSurfaceToolPreservesCanvasLayout() async throws {
    let node = OttoNode(
      kind: .markdown,
      displayName: "Plan",
      subtitle: "MARKDOWN",
      frame: WorldRect(x: 72, y: -41, width: 480, height: 320),
      zIndex: 0
    )
    let canvas = OttoCanvas(name: "Tool routing", nodes: [node], layoutMode: .stage)
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await registry.register(WorkspaceSurfaceSetTool(store: store))
    let context = ToolContext(
      actorID: "surface-routing", scopes: [.canvasRead, .canvasWrite], source: .voice)
    let originalFrames = await store.activeCanvas.nodes.map(\.frame)

    _ = try await registry.call(
      name: "surface.set",
      input: .object(["surface": .string("chat")]),
      context: context
    )

    #expect(await store.workspaceSurface == .chat)
    #expect(await store.activeCanvas.layoutMode == .stage)
    #expect(await store.activeCanvas.nodes.map(\.frame) == originalFrames)

    await #expect(throws: (any Error).self) {
      _ = try await registry.call(
        name: "surface.set",
        input: .object(["surface": .string("canvas")]),
        context: context
      )
    }
    #expect(await store.activeCanvas.nodes.map(\.frame) == originalFrames)
  }

  @Test("GTM Grid can no longer be created; agents are pointed to spreadsheets")
  func gtmGridIsRemoved() async throws {
    let canvas = OttoCanvas(name: "No GTM Grid")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor(), browserRuntime: BrowserRuntime())
    let context = ToolContext(actorID: "agent", scopes: [.canvasRead, .canvasWrite])
    await #expect(throws: (any Error).self) {
      _ = try await registry.call(
        name: "node.create",
        input: try JSONValue.encode(NodeCreateInput(kind: .gtmGrid, x: 0, y: 0)),
        context: context)
    }
    #expect(await store.activeCanvas.nodes.isEmpty)
  }

  @Test("Browser semantic tools allow routine clicks and confirm commitments")
  func semanticBrowserTools() async throws {
    let canvas = OttoCanvas(name: "Agent browser")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let runtime = BrowserRuntime()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor(),
      browserRuntime: runtime
    )
    let context = ToolContext(actorID: "agent", scopes: [.canvasRead, .canvasWrite])
    let browser = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(
        BrowserOpenInput(url: "https://example.test", x: 0, y: 0)),
      context: context
    ).decode(NodeCreateOutput.self)
    let element = BrowserPageElement(
      id: "e1",
      role: "button",
      name: "Inbox",
      bounds: BrowserElementBounds(x: 10, y: 20, width: 120, height: 40),
      actions: [.click]
    )
    let sendElement = BrowserPageElement(
      id: "e2",
      role: "button",
      name: "Send",
      bounds: BrowserElementBounds(x: 10, y: 70, width: 120, height: 40),
      actions: [.click]
    )
    await runtime.registerPageHandler(
      nodeID: browser.node.id,
      snapshot: { nodeID in
        BrowserPageSnapshot(
          nodeID: nodeID,
          url: "https://example.test",
          pageRevision: "r1",
          elements: [element, sendElement]
        )
      },
      interact: { nodeID, request in
        BrowserInteractionResult(
          nodeID: nodeID,
          pageRevision: request.revision,
          url: "https://example.test",
          message: "Clicked"
        )
      },
      assess: { _, request in
        BrowserInteractionAssessment(
          requiresConfirmation: request.elementID == "e2",
          reason: request.elementID == "e2" ? "This may send a message" : nil
        )
      }
    )

    let snapshot = try await registry.call(
      name: "browser.inspect",
      input: try JSONValue.encode(BrowserNodeInput(nodeID: browser.node.id)),
      context: context
    ).decode(BrowserPageSnapshot.self)
    #expect(snapshot.elements.first?.name == "Inbox")

    let clickInput = try JSONValue.encode(
      BrowserElementInput(
        nodeID: browser.node.id, pageRevision: snapshot.pageRevision, elementID: "Inbox"))
    let routineResult = try await registry.call(
      name: "browser.click", input: clickInput, context: context
    ).decode(BrowserInteractionResult.self)
    #expect(routineResult.message == "Clicked")

    let consequentialInput = try JSONValue.encode(
      BrowserElementInput(
        nodeID: browser.node.id, pageRevision: snapshot.pageRevision, elementID: "Send"))
    await #expect(throws: ToolRegistryError.confirmationRequired("browser.click")) {
      try await registry.call(name: "browser.click", input: consequentialInput, context: context)
    }
    let confirmed = ToolContext(
      actorID: "agent", scopes: [.canvasRead, .canvasWrite], confirmed: true)
    let result = try await registry.call(
      name: "browser.click", input: consequentialInput, context: confirmed
    ).decode(BrowserInteractionResult.self)
    #expect(result.message == "Clicked")

    _ = try await runtime.navigate(nodeID: browser.node.id, url: "http://localhost:3000")
    let localResult = try await registry.call(
      name: "browser.click", input: consequentialInput, context: context
    ).decode(BrowserInteractionResult.self)
    #expect(localResult.message == "Clicked")
  }

  @Test("Browser URLs reject credentials and control characters")
  func maliciousBrowserURLs() async throws {
    let canvas = OttoCanvas(name: "Browser security")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor())
    let context = ToolContext(actorID: "browser-security", scopes: [.canvasWrite])

    for url in ["https://user:secret@example.com", "https://example.com/\u{0}"] {
      await #expect(throws: ToolRegistryError.self) {
        try await registry.call(
          name: "browser.open",
          input: try JSONValue.encode(BrowserOpenInput(url: url, x: 0, y: 0)),
          context: context
        )
      }
    }
    #expect(await store.activeCanvas.nodes.isEmpty)
  }

  @Test("Browser, document, layout, and theme survive SQLite-compatible encoding")
  func completeWorkflow() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-flow-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let canvas = OttoCanvas(name: "Spatial flow")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let documents = WorkspaceDocumentStore(rootPath: root.path)
    let browserRuntime = BrowserRuntime()
    let mediaRuntime = MediaRuntime()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor(),
      documents: documents,
      browserRuntime: browserRuntime,
      mediaRuntime: mediaRuntime,
      workspacePath: root.path
    )
    let context = ToolContext(actorID: "voice", scopes: [.canvasRead, .canvasWrite])
    try await documents.replace(relativePath: "existing.md", text: "# Existing\n")

    let browser = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(BrowserOpenInput(url: "localhost:3000", x: 10, y: 20)),
      context: context
    ).decode(NodeCreateOutput.self)
    #expect(browser.node.content == .browser(url: "http://localhost:3000"))
    let screenshotBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
    await browserRuntime.registerCaptureHandler(nodeID: browser.node.id) {
      BrowserCapture(pngData: screenshotBytes, pixelWidth: 1_024, pixelHeight: 640)
    }
    let screenshot = try await registry.call(
      name: "browser.screenshot",
      input: try JSONValue.encode(BrowserNodeInput(nodeID: browser.node.id)),
      context: context
    ).decode(BrowserScreenshotOutput.self)
    #expect(screenshot.pixelWidth == 1_024)
    #expect(screenshot.pixelHeight == 640)
    #expect(screenshot.byteCount == screenshotBytes.count)
    #expect(
      try Data(contentsOf: root.appending(path: screenshot.relativePath)) == screenshotBytes)

    let navigated = try await registry.call(
      name: "browser.navigate",
      input: try JSONValue.encode(
        BrowserNavigateInput(nodeID: browser.node.id, url: "example.com/docs")),
      context: context
    ).decode(MutationOutput.self)
    #expect(navigated.affectedNodeIDs == [browser.node.id])
    var browserState = try await registry.call(
      name: "browser.get_state",
      input: try JSONValue.encode(BrowserNodeInput(nodeID: browser.node.id)),
      context: context
    ).decode(BrowserRuntimeState.self)
    #expect(browserState.url == "http://example.com/docs")
    #expect(browserState.requestedAction == .navigate)

    browserState = try await registry.call(
      name: "browser.refresh",
      input: try JSONValue.encode(BrowserNodeInput(nodeID: browser.node.id)),
      context: context
    ).decode(BrowserRuntimeState.self)
    #expect(browserState.requestedAction == .refresh)
    browserState = try await registry.call(
      name: "browser.back",
      input: try JSONValue.encode(BrowserNodeInput(nodeID: browser.node.id)),
      context: context
    ).decode(BrowserRuntimeState.self)
    #expect(browserState.requestedAction == .back)
    browserState = try await registry.call(
      name: "browser.forward",
      input: try JSONValue.encode(BrowserNodeInput(nodeID: browser.node.id)),
      context: context
    ).decode(BrowserRuntimeState.self)
    #expect(browserState.requestedAction == .forward)

    let media = try await registry.call(
      name: "media.open",
      input: try JSONValue.encode(
        MediaOpenInput(source: "https://example.test/audio.mp3", x: 800, y: 20)),
      context: context
    ).decode(NodeCreateOutput.self)
    #expect(media.node.content == .media(source: "https://example.test/audio.mp3"))
    var mediaState = try await registry.call(
      name: "media.play",
      input: try JSONValue.encode(MediaNodeInput(nodeID: media.node.id)),
      context: context
    ).decode(MediaRuntimeState.self)
    #expect(mediaState.isPlaying)
    mediaState = try await registry.call(
      name: "media.set_volume",
      input: try JSONValue.encode(MediaVolumeInput(nodeID: media.node.id, volume: 0.35)),
      context: context
    ).decode(MediaRuntimeState.self)
    #expect(mediaState.volume == 0.35)
    mediaState = try await registry.call(
      name: "media.seek",
      input: try JSONValue.encode(MediaSeekInput(nodeID: media.node.id, position: 15)),
      context: context
    ).decode(MediaRuntimeState.self)
    #expect(mediaState.position == 15)
    mediaState = try await registry.call(
      name: "media.stop",
      input: try JSONValue.encode(MediaNodeInput(nodeID: media.node.id)),
      context: context
    ).decode(MediaRuntimeState.self)
    #expect(!mediaState.isPlaying)
    #expect(mediaState.position == 0)

    let document = try await registry.call(
      name: "document.create",
      input: try JSONValue.encode(
        DocumentCreateInput(
          relativePath: "goals.md", text: "# Goals\n- [ ] Test\n", x: 400, y: 20)),
      context: context
    ).decode(NodeCreateOutput.self)
    #expect(try await documents.read(relativePath: "goals.md").contains("Test"))
    #expect(document.message.contains("[Open document](<\(documents.rootPath)/goals.md>)"))
    #expect(document.message.contains("not a Documents entry"))
    #expect(
      document.node.content == .markdown(relativePath: "goals.md", text: "# Goals\n- [ ] Test\n"))

    let openedDocument = try await registry.call(
      name: "document.open",
      input: try JSONValue.encode(DocumentOpenInput(relativePath: "existing.md", x: 600, y: 400)),
      context: context
    ).decode(NodeCreateOutput.self)
    #expect(openedDocument.message.contains("[Open document](<\(documents.rootPath)/existing.md>)"))
    #expect(
      openedDocument.node.content
        == .markdown(relativePath: "existing.md", text: "# Existing\n"))

    _ = try await registry.call(
      name: "document.append",
      input: try JSONValue.encode(
        DocumentAppendInput(nodeID: document.node.id, text: "- [ ] Ship\n")),
      context: context
    )
    _ = try await registry.call(
      name: "document.update_checklist_item",
      input: try JSONValue.encode(
        DocumentChecklistInput(
          nodeID: document.node.id,
          itemNumber: 2,
          completed: true,
          replacementText: "Ship private beta"
        )),
      context: context
    )
    let read = try await registry.call(
      name: "document.read",
      input: try JSONValue.encode(DocumentNodeInput(nodeID: document.node.id)),
      context: context
    ).decode(DocumentReadOutput.self)
    #expect(read.text == "# Goals\n- [ ] Test\n- [x] Ship private beta\n")
    #expect(try await documents.read(relativePath: "goals.md") == read.text)
    #expect(
      await store.activeCanvas.nodes.first(where: { $0.id == document.node.id })?.content
        == .markdown(relativePath: "goals.md", text: read.text))

    let themeList = try await registry.call(
      name: "theme.list",
      input: .object([:]),
      context: context
    ).decode([OttoThemeDefinition].self)
    #expect(
      themeList.map(\.id) == [
        "field-notes", "aurora", "highfell", "silverbough", "mistfall", "duneveil",
        "halcyon", "ringfall", "shorelight", "farfield", "afterglow", "nightspire", "graphite",
        "velvet", "nightscreen", "glasswing", "nightglass", "daylight",
      ])
    let geometryBeforeTheme = await store.activeCanvas.nodes.map(\.frame)
    _ = try await registry.call(
      name: "theme.set",
      input: try JSONValue.encode(ThemeSetInput(themeID: "ringfall")),
      context: context
    )
    #expect(await store.activeCanvas.nodes.map(\.frame) == geometryBeforeTheme)

    let snapshot = await store.snapshot
    #expect(snapshot.canvases[0].themeID == "ringfall")
    #expect(
      Set(snapshot.canvases[0].nodes.map(\.id))
        == Set([browser.node.id, document.node.id, openedDocument.node.id, media.node.id]))
    let encoded = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded) == snapshot)
  }

  @Test("Browser open leaves the runtime session on the requested URL")
  func browserOpenSyncsRuntimeURL() async throws {
    let canvas = OttoCanvas(name: "Browser runtime sync")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let browserRuntime = BrowserRuntime()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor(), browserRuntime: browserRuntime)
    let context = ToolContext(actorID: "voice", scopes: [.canvasWrite], source: .voice)

    let output = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(BrowserOpenInput(url: "https://www.bbc.com", x: 0, y: 0)),
      context: context
    ).decode(NodeCreateOutput.self)
    let state = try #require(await browserRuntime.state(nodeID: output.node.id))
    #expect(state.url == "https://www.bbc.com")
    #expect(output.node.content == .browser(url: "https://www.bbc.com"))
  }

  @Test("Agent browser opens reuse one canvas node and add tabs")
  func agentBrowserOpenReusesCanvasNode() async throws {
    let canvas = OttoCanvas(name: "One browser, many tabs")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let browserRuntime = BrowserRuntime()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor(), browserRuntime: browserRuntime)

    let initial = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(
        BrowserOpenInput(url: "https://first.example", x: 0, y: 0)),
      context: ToolContext(
        actorID: "otto-ui", scopes: [.canvasWrite], source: .userInterface)
    ).decode(NodeCreateOutput.self)
    let agentContext = ToolContext(
      actorID: "agent",
      scopes: [.canvasWrite],
      source: .agent,
      sourceCanvasID: canvas.id
    )

    let second = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(
        BrowserOpenInput(url: "https://second.example", x: 500, y: 0)),
      context: agentContext
    ).decode(NodeCreateOutput.self)
    let third = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(
        BrowserOpenInput(url: "https://third.example", x: 1_000, y: 0)),
      context: agentContext
    ).decode(NodeCreateOutput.self)

    #expect(await store.activeCanvas.nodes.count == 1)
    #expect(second.node.id == initial.node.id)
    #expect(third.node.id == initial.node.id)
    #expect(second.message == "Opened a new tab in Browser 1")
    let state = try #require(await browserRuntime.state(nodeID: initial.node.id))
    let persistedNode = try #require(
      await store.activeCanvas.nodes.first(where: { $0.id == initial.node.id }))
    let persisted = try #require(persistedNode.browserSession)
    #expect(state.tabs.count == 3)
    #expect(state.url == "https://third.example")
    #expect(
      persisted.tabs.map(\.url)
        == ["https://first.example", "https://second.example", "https://third.example"])
    #expect(persisted.tabs.map(\.id) == state.tabs.map(\.id))
    #expect(persisted.activeTabID == state.activeTabID)
    #expect(persistedNode.content == .browser(url: "https://third.example"))
    let encoded = try JSONEncoder().encode(persisted)
    #expect(try JSONDecoder().decode(BrowserSession.self, from: encoded) == persisted)
  }

  @Test("Agent browser opens report the browser to the initiating conversation")
  func agentBrowserOpenReportsConversationAssociation() async throws {
    let agentID = UUID()
    let canvas = OttoCanvas(name: "Chat browser")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let requests = AgentBrowserOpenRequestBox()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor(),
      agentBrowserOpenHandler: { request in await requests.record(request) }
    )

    let output = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(
        BrowserOpenInput(url: "https://chat.example", x: 400, y: 0)),
      context: ToolContext(
        actorID: "otto-agent-\(agentID.uuidString)",
        scopes: [.canvasWrite],
        source: .agent,
        sourceNodeID: agentID,
        sourceCanvasID: canvas.id
      )
    ).decode(NodeCreateOutput.self)

    let request = try #require(await requests.latest)
    #expect(request.agentID == agentID)
    #expect(request.browserID == output.node.id)
    #expect(output.node.browserOwnerAgentID == agentID)
  }

  @Test("Each agent reuses its own Chat browser")
  func agentBrowserOpenKeepsConversationBrowsersSeparate() async throws {
    let firstAgentID = UUID()
    let secondAgentID = UUID()
    let canvas = OttoCanvas(name: "Conversation browsers")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor())

    func open(_ url: String, for agentID: UUID) async throws -> NodeCreateOutput {
      try await registry.call(
        name: "browser.open",
        input: try JSONValue.encode(BrowserOpenInput(url: url, x: 0, y: 0)),
        context: ToolContext(
          actorID: "otto-agent-\(agentID.uuidString)",
          scopes: [.canvasWrite],
          source: .agent,
          sourceNodeID: agentID,
          sourceCanvasID: canvas.id
        )
      ).decode(NodeCreateOutput.self)
    }

    let first = try await open("https://first.example", for: firstAgentID)
    let second = try await open("https://second.example", for: secondAgentID)
    let firstAgain = try await open("https://third.example", for: firstAgentID)

    #expect(first.node.id != second.node.id)
    #expect(firstAgain.node.id == first.node.id)
    let browsers = await store.activeCanvas.nodes.filter { $0.kind == .browser }
    #expect(browsers.count == 2)
    #expect(
      browsers.first(where: { $0.id == first.node.id })?.browserSession?.tabs.map(\.url)
        == ["https://first.example", "https://third.example"])
    #expect(
      browsers.first(where: { $0.id == second.node.id })?.browserOwnerAgentID == secondAgentID)
  }

  @Test(
    "Implicit agent tabs stay in their conversation; explicit targets do not attach to its drawer")
  func agentOpenTabKeepsBrowserOwnership() async throws {
    let canvas = OttoCanvas(name: "Isolated browser tabs")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let requests = AgentBrowserOpenRequestBox()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor(),
      agentBrowserOpenHandler: { request in await requests.record(request) })
    let workspace = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(BrowserOpenInput(url: "https://workspace.example", x: 0, y: 0)),
      context: ToolContext(actorID: "person", scopes: [.canvasWrite], source: .userInterface)
    ).decode(NodeCreateOutput.self)
    let firstID = UUID()
    let secondID = UUID()
    func openTab(_ url: String, for agentID: UUID, nodeID: UUID? = nil) async throws
      -> BrowserRuntimeState
    {
      try await registry.call(
        name: "browser.open_tab",
        input: try JSONValue.encode(BrowserOpenTabInput(url: url, nodeID: nodeID)),
        context: ToolContext(
          actorID: "agent-\(agentID)", scopes: [.canvasWrite], source: .agent,
          sourceNodeID: agentID, sourceCanvasID: canvas.id)
      ).decode(BrowserRuntimeState.self)
    }
    let first = try await openTab("https://first.example", for: firstID)
    let second = try await openTab("https://second.example", for: secondID)
    let again = try await openTab("https://third.example", for: firstID)
    #expect(first.nodeID != workspace.node.id)
    #expect(first.nodeID != second.nodeID)
    #expect(again.nodeID == first.nodeID)
    let lastOwnedRequest = await requests.latest
    #expect(lastOwnedRequest?.browserID == first.nodeID)

    // A helper can intentionally act in Browser, but that must never attach the workspace's
    // browser to its drawer or change persistent ownership.
    let explicit = try await openTab(
      "https://intentional.example", for: firstID, nodeID: workspace.node.id)
    #expect(explicit.nodeID == workspace.node.id)
    #expect(await requests.latest == lastOwnedRequest)
    let browsers = await store.activeCanvas.nodes.filter { $0.kind == .browser }
    #expect(browsers.count == 3)
    #expect(
      browsers.first { $0.id == first.nodeID }?.browserSession?.tabs.map(\.url)
        == ["https://first.example", "https://third.example"])
    #expect(
      browsers.first { $0.id == second.nodeID }?.browserSession?.tabs.map(\.url)
        == ["https://second.example"])
    #expect(browsers.first { $0.id == workspace.node.id }?.browserOwnerAgentID == nil)
    #expect(
      browsers.first { $0.id == workspace.node.id }?.browserSession?.tabs.map(\.url)
        == ["https://workspace.example", "https://intentional.example"])
  }

  @Test("Concurrent agent opens create one browser with durable tabs")
  func concurrentAgentBrowserOpensUseOneNode() async throws {
    let canvas = OttoCanvas(name: "Concurrent browser opens")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let browserRuntime = BrowserRuntime()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor(), browserRuntime: browserRuntime)
    let context = ToolContext(
      actorID: "agent",
      scopes: [.canvasWrite],
      source: .agent,
      sourceCanvasID: canvas.id
    )
    let urls = (0..<20).map { "https://concurrent-\($0).example" }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, url) in urls.enumerated() {
        group.addTask {
          _ = try await registry.call(
            name: "browser.open",
            input: try JSONValue.encode(
              BrowserOpenInput(url: url, x: Double(index * 20), y: 0)),
            context: context
          )
        }
      }
      try await group.waitForAll()
    }

    let nodes = await store.activeCanvas.nodes.filter { $0.kind == .browser }
    let node = try #require(nodes.first)
    let session = try #require(node.browserSession)
    let runtime = try #require(await browserRuntime.state(nodeID: node.id))
    #expect(nodes.count == 1)
    #expect(session.tabs.count == urls.count)
    #expect(Set(session.tabs.map(\.url)) == Set(urls))
    #expect(Set(session.tabs.map(\.id)).count == urls.count)
    #expect(session.tabs.map(\.id) == runtime.tabs.map(\.id))
    #expect(session.activeTabID == runtime.activeTabID)
  }

  @Test("UI browser opens remain separate nodes")
  func userInterfaceBrowserOpensCreateSeparateNodes() async throws {
    let canvas = OttoCanvas(name: "Explicit browser windows")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let browserRuntime = BrowserRuntime()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor(), browserRuntime: browserRuntime)
    let context = ToolContext(
      actorID: "otto-ui", scopes: [.canvasWrite], source: .userInterface)

    let first = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(
        BrowserOpenInput(url: "https://one.example", x: 0, y: 0)),
      context: context
    ).decode(NodeCreateOutput.self)
    let second = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(
        BrowserOpenInput(url: "https://two.example", x: 500, y: 0)),
      context: context
    ).decode(NodeCreateOutput.self)

    #expect(first.node.id != second.node.id)
    #expect(await store.activeCanvas.nodes.filter { $0.kind == .browser }.count == 2)
  }

  @Test("Restored tabs hydrate with stable IDs before an agent adds another")
  func restoredBrowserTabsHydrateBeforeAgentOpen() async throws {
    let canvas = OttoCanvas(name: "Restored browser")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let browserRuntime = BrowserRuntime()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor(), browserRuntime: browserRuntime)
    let uiContext = ToolContext(
      actorID: "otto-ui", scopes: [.canvasWrite], source: .userInterface)
    let browser = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(
        BrowserOpenInput(url: "https://first.example", x: 0, y: 0)),
      context: uiContext
    ).decode(NodeCreateOutput.self)
    let restoredTabs = [
      BrowserTab(url: "https://first.example"),
      BrowserTab(url: "https://second.example"),
      BrowserTab(url: "https://third.example"),
    ]
    let restored = BrowserSession(tabs: restoredTabs, activeTabID: restoredTabs[1].id)
    _ = await store.dispatch(
      .setBrowserSession(id: browser.node.id, session: restored), targetCanvasID: canvas.id)
    _ = await store.dispatch(
      .setNodeContent(id: browser.node.id, content: .browser(url: restoredTabs[1].url)),
      targetCanvasID: canvas.id)

    let state = try await registry.call(
      name: "browser.open_tab",
      input: try JSONValue.encode(
        BrowserOpenTabInput(url: "https://fourth.example", nodeID: browser.node.id)),
      context: ToolContext(
        actorID: "agent",
        scopes: [.canvasWrite],
        source: .agent,
        sourceCanvasID: canvas.id)
    ).decode(BrowserRuntimeState.self)
    let persistedNode = try #require(
      await store.activeCanvas.nodes.first(where: { $0.id == browser.node.id }))
    let persisted = try #require(persistedNode.browserSession)

    #expect(persisted.tabs.prefix(3).map(\.id) == restoredTabs.map(\.id))
    #expect(persisted.tabs.map(\.id) == state.tabs.map(\.id))
    #expect(persisted.tabs.map(\.url).last == "https://fourth.example")
    #expect(persisted.activeTabID == state.activeTabID)
  }

  @Test("Headless automation does not steal canvas selection")
  func automationBrowserOpenPreservesSelection() async throws {
    let canvas = OttoCanvas(name: "Headless browser")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let browserRuntime = BrowserRuntime()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor(), browserRuntime: browserRuntime)
    let uiContext = ToolContext(
      actorID: "otto-ui", scopes: [.canvasWrite], source: .userInterface)
    let browser = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(
        BrowserOpenInput(url: "https://first.example", x: 0, y: 0)),
      context: uiContext
    ).decode(NodeCreateOutput.self)
    let note = try await registry.call(
      name: "node.create",
      input: try JSONValue.encode(NodeCreateInput(kind: .markdown, x: 500, y: 0)),
      context: uiContext
    ).decode(NodeCreateOutput.self)

    _ = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(
        BrowserOpenInput(url: "https://background.example", x: 0, y: 0)),
      context: ToolContext(
        actorID: "automation",
        scopes: [.canvasWrite],
        source: .automation,
        sourceCanvasID: canvas.id)
    )

    #expect(await store.activeCanvas.selectedNodeID == note.node.id)
    #expect(await store.activeCanvas.nodes.filter { $0.kind == .browser }.count == 1)
    let persistedBrowser = try #require(
      await store.activeCanvas.nodes.first(where: { $0.id == browser.node.id }))
    #expect(persistedBrowser.browserSession?.tabs.count == 2)
  }

  @Test("Agents open tabs in the selected browser and can read element selection context")
  func browserTabsAndSelectionTools() async throws {
    let canvas = OttoCanvas(name: "Browser agent context")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let browserRuntime = BrowserRuntime()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor(), browserRuntime: browserRuntime)
    let writeContext = ToolContext(
      actorID: "agent",
      scopes: [.canvasRead, .canvasWrite],
      source: .agent,
      sourceCanvasID: canvas.id)

    let browser = try await registry.call(
      name: "browser.open",
      input: try JSONValue.encode(BrowserOpenInput(url: "https://mail.example", x: 0, y: 0)),
      context: writeContext
    ).decode(NodeCreateOutput.self)
    let tabState = try await registry.call(
      name: "browser.open_tab",
      input: try JSONValue.encode(BrowserOpenTabInput(url: "http://localhost:3000/profile")),
      context: writeContext
    ).decode(BrowserRuntimeState.self)
    #expect(await store.activeCanvas.nodes.count == 1)
    #expect(tabState.nodeID == browser.node.id)
    #expect(tabState.tabs.count == 2)

    let expected = BrowserElementSelection(
      nodeID: browser.node.id,
      tabID: tabState.activeTabID,
      url: tabState.url,
      route: "/profile",
      tagName: "h1",
      accessibleName: "Your profile",
      text: "Your profile",
      selector: "main > h1",
      bounds: BrowserElementBounds(x: 32, y: 48, width: 180, height: 40),
      capturedAt: Date(timeIntervalSince1970: 1_234)
    )
    _ = try await browserRuntime.reportSelection(nodeID: browser.node.id, selection: expected)
    let actual = try await registry.call(
      name: "browser.get_selection",
      input: try JSONValue.encode(BrowserSelectionInput()),
      context: writeContext
    ).decode(BrowserElementSelection.self)
    #expect(actual == expected)
  }

  @Test("Runtime register keeps an existing session, so stale URLs need explicit navigation")
  func registerIsNoOpOnExistingSession() async throws {
    // Pins the BrowserRuntime behavior BrowserOpenTool's race guard depends on: when the view
    // registered the node first with the default URL, a second register must not silently win,
    // and navigate must move the session to the requested URL.
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    _ = await runtime.register(nodeID: nodeID, url: "http://localhost:3000")
    let stale = await runtime.register(nodeID: nodeID, url: "https://www.bbc.com")
    #expect(stale.url == "http://localhost:3000")
    _ = try await runtime.navigate(nodeID: nodeID, url: "https://www.bbc.com")
    let state = try #require(await runtime.state(nodeID: nodeID))
    #expect(state.url == "https://www.bbc.com")
    #expect(state.requestedAction == .navigate)
  }

  @Test("External browser tool validates URLs and reports opener outcome")
  func externalBrowserOpen() async throws {
    let canvas = OttoCanvas(name: "External browser")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let opened = OpenedURLBox()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor(),
      externalOpener: { url in
        await opened.record(url)
        return true
      }
    )
    let context = ToolContext(actorID: "voice", scopes: [.canvasWrite])

    let result = try await registry.call(
      name: "browser.open_external",
      input: try JSONValue.encode(BrowserOpenExternalInput(url: "www.bbc.com")),
      context: context
    ).decode(MutationOutput.self)
    #expect(result.affectedNodeIDs.isEmpty)
    #expect(await opened.urls.map(\.absoluteString) == ["http://www.bbc.com"])
    #expect(await store.activeCanvas.nodes.isEmpty)

    await #expect(throws: ToolRegistryError.self) {
      try await registry.call(
        name: "browser.open_external",
        input: try JSONValue.encode(BrowserOpenExternalInput(url: "file:///etc/passwd")),
        context: context
      )
    }
    #expect(await opened.urls.count == 1)
  }

  @Test("External browser tool surfaces opener refusal as an error")
  func externalBrowserOpenFailure() async throws {
    let canvas = OttoCanvas(name: "External browser failure")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor(),
      externalOpener: { _ in false }
    )
    let context = ToolContext(actorID: "voice", scopes: [.canvasWrite])
    await #expect(throws: ToolRegistryError.self) {
      try await registry.call(
        name: "browser.open_external",
        input: try JSONValue.encode(BrowserOpenExternalInput(url: "https://www.bbc.com")),
        context: context
      )
    }
  }
}

private actor OpenedURLBox {
  private(set) var urls: [URL] = []
  func record(_ url: URL) { urls.append(url) }
}

private actor AgentBrowserOpenRequestBox {
  private(set) var latest: AgentBrowserOpenRequest?
  func record(_ request: AgentBrowserOpenRequest) { latest = request }
}
