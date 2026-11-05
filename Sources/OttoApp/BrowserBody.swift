import AppKit
import OttoApplicationTools
import OttoBrowser
import OttoCore
import OttoModels
import OttoServices
import SwiftUI
import WebKit

struct BrowserBody: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.ottoWindowIsActive) private var windowIsActive
  @AppStorage(BrowserBookmarkPreferences.onboardingCompletedKey)
  private var importOnboardingCompleted = false
  let node: OttoNode
  let scale: Double
  let isSelected: Bool
  let isDragging: Bool
  let runtime: BrowserRuntime
  let capture: (UUID) async throws -> BrowserScreenshotOutput
  let updateContent: (NodeContent) -> Void
  let updateBrowserSession: (BrowserSession) -> Void
  let updateBrowserTab: (UUID, String, String?) -> Void
  var chrome: BrowserChromeStyle = .canvas
  @ObservedObject private var history = BrowserHistoryStore.shared
  @State private var lastRecordedURL: String?
  @State private var state: BrowserRuntimeState?
  @State private var address = ""
  @State private var startQuery = ""
  @State private var startFocusRequest = 0
  @State private var addressFocusRequest = 0
  @State private var captureStatus: String?
  @State private var dragSnapshot: NSImage?
  @State private var sidebarVisible = false
  @State private var agentRailVisible = false
  @State private var bookmarks: [BrowserBookmark] = []
  /// The person's own pinned sites once they pin or unpin one; until then the first imported
  /// bookmarks (or Otto's defaults) stand in.
  @AppStorage("otto.browser.pinnedSites") private var pinnedSitesData = Data()
  @State private var importRequest: BrowserImportRequest?
  @State private var agentAuraPhase: BrowserAgentControlPhase?
  @State private var agentAuraVisible = false
  @State private var agentAuraDismissTask: Task<Void, Never>?
  @State private var browserActivities: [BrowserActivityEntry] = []
  /// Keep the active page and one recently-used page alive. Additional tabs retain their model
  /// state but release WebKit processes until selected again.
  @State private var warmTabIDs: [UUID] = []

  var body: some View {
    chromeContent
      .background {
        OttoBrowserInputMonitor(
          isEnabled: isSelected && windowIsActive,
          perform: performBrowserShortcut
        )
      }
      .onChange(of: isDragging) { _, dragging in
        if dragging {
          Task {
            guard let capture = try? await runtime.capture(nodeID: node.id),
              let image = NSImage(data: capture.pngData)
            else { return }
            dragSnapshot = image
          }
        } else {
          dragSnapshot = nil
        }
      }
      .onChange(of: state?.agentControlPhase) { _, phase in
        updateAgentAura(phase)
      }
      .onChange(of: sessionValue.activeTabID, initial: true) { _, tabID in
        retainWarmTab(tabID)
      }
      .onReceive(NotificationCenter.default.publisher(for: BrowserLinkTabRequest.name)) {
        guard let request = BrowserLinkTabRequest(notification: $0), request.nodeID == node.id,
          BrowserLinkTabRequest.claim(request.id)
        else { return }
        openLinkInNewTab(request.url)
      }
      .onChange(of: sessionValue.tabs.map(\.id)) { _, tabIDs in
        let valid = Set(tabIDs)
        warmTabIDs.removeAll { !valid.contains($0) }
      }
      .overlay {
        // Chat layouts glow around the page well itself (see compactPage); the canvas card
        // glows around the whole node.
        if case .canvas = chrome, agentAuraVisible, windowIsActive {
          BrowserAgentControlAura(
            phase: agentAuraPhase ?? .observing,
            cornerRadius: 10 * scale,
            scale: scale
          )
          .allowsHitTesting(false)
          .transition(.opacity)
        }
      }
      .onDisappear {
        agentAuraDismissTask?.cancel()
      }
      .task(id: node.id) {
        bookmarks = BrowserBookmarkPreferences.load()
        let session = sessionValue
        if node.browserSession == nil { updateBrowserSession(session) }
        let initialURL = session.activeTab?.url ?? addressValue
        let initial = await runtime.synchronize(nodeID: node.id, session: session)
        state = initial
        address = displayedBrowserAddress(initialURL)
        appendBrowserActivity(initial.lastActivity)
        if isLocalBrowserURL(initialURL) { agentRailVisible = true }
        if !importOnboardingCompleted {
          await prepareImport()
        }
        for await update in await runtime.updates(nodeID: node.id) {
          guard !Task.isCancelled else { break }
          state = update
          address = displayedBrowserAddress(update.url)
          appendBrowserActivity(update.lastActivity)
          if !update.isLoading, update.errorMessage == nil,
            update.url != lastRecordedURL, update.url.hasPrefix("http")
          {
            history.record(url: update.url, title: update.title)
            lastRecordedURL = update.url
          }
          if isLocalBrowserURL(update.url), !agentRailVisible {
            withAnimation(.easeOut(duration: 0.18)) { agentRailVisible = true }
          }
        }
      }
      .sheet(item: $importRequest) { request in
        BrowserImportView(
          sources: request.sources,
          importSources: { try await importBookmarks(from: $0, includeSignIns: $1) },
          skip: { importOnboardingCompleted = true }
        )
        .environment(\.ottoPalette, palette)
      }
  }

  @ViewBuilder private var chromeContent: some View {
    switch chrome {
    case .canvas:
      canvasLayout
    case .panel:
      VStack(spacing: 0) {
        OttoBrowserCompactBar(
          address: $address,
          addressFocusRequest: addressFocusRequest,
          state: state,
          goBack: goBack,
          goForward: goForward,
          reloadOrStop: reloadOrStop,
          submit: submitAddress
        )
        OttoBrowserPanelTabs(
          session: sessionValue, selectTab: selectTab, closeTab: closeTab, newTab: newTab)
        compactPage
      }
    case .place(let aiVisible, let toggleAI, _):
      VStack(spacing: 0) {
        OttoBrowserTabStrip(
          address: $address,
          addressFocusRequest: addressFocusRequest,
          session: sessionValue,
          state: state,
          pinned: pinnedSites,
          aiVisible: aiVisible,
          navigate: navigate,
          selectTab: selectTab,
          closeTab: closeTab,
          newTab: newTab,
          submit: submitAddress,
          goBack: goBack,
          goForward: goForward,
          reloadOrStop: reloadOrStop,
          showImport: showImport,
          toggleAI: toggleAI,
          openInNewTab: { url in
            newTab()
            navigate(url)
          },
          pin: pinSite,
          unpin: unpinSite
        )
        compactPage
      }
    }
  }

  /// Inside Chat the page sits in a rounded well; the edge glow alone says an agent is on it.
  private var compactPage: some View {
    pageSurface
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay {
        if agentAuraVisible, windowIsActive {
          BrowserAgentControlAura(
            phase: agentAuraPhase ?? .observing, cornerRadius: 10, scale: 1
          )
          .allowsHitTesting(false)
          .transition(.opacity)
        }
      }
      .padding([.horizontal, .bottom], 9)
  }

  private func reloadOrStop() {
    Task {
      if state?.isLoading == true {
        try? await runtime.stop(nodeID: node.id)
      } else {
        try? await runtime.refresh(nodeID: node.id)
      }
    }
  }

  /// The canvas node's full browser: toolbar, bookmarks, tab sidebar and agent rail.
  private var canvasLayout: some View {
    VStack(spacing: 0) {
      OttoBrowserToolbar(
        address: $address,
        addressFocusRequest: addressFocusRequest,
        scale: scale,
        state: state,
        sidebarSelected: sidebarVisible,
        agentRailSelected: agentRailVisible,
        captureStatus: captureStatus,
        toggleSidebar: { withAnimation(.easeOut(duration: 0.16)) { sidebarVisible.toggle() } },
        newTab: newTab,
        goHome: { navigate(BrowserDefaults.startURL) },
        goBack: goBack,
        goForward: goForward,
        reloadOrStop: {
          Task {
            if state?.isLoading == true {
              try? await runtime.stop(nodeID: node.id)
            } else {
              try? await runtime.refresh(nodeID: node.id)
            }
          }
        },
        submit: submitAddress,
        capture: capturePage,
        toggleAgentRail: {
          withAnimation(.easeOut(duration: 0.16)) { agentRailVisible.toggle() }
        }
      )

      GeometryReader { geometry in
        HStack(spacing: 0) {
          if sidebarVisible, geometry.size.width >= 470 * scale {
            OttoBrowserSidebar(
              session: sessionValue,
              scale: scale,
              selectTab: selectTab,
              closeTab: closeTab,
              newTab: newTab,
              showImport: showImport
            )
            .transition(.move(edge: .leading).combined(with: .opacity))
          }

          VStack(spacing: 0) {
            OttoBrowserBookmarksBar(
              bookmarks: bookmarks,
              scale: scale,
              navigate: navigate,
              showImport: showImport
            )
            pageSurface
          }

          if agentRailVisible, geometry.size.width >= 760 * scale {
            OttoBrowserAgentRail(
              state: state,
              activities: browserActivities,
              isBuildMode: isLocalDevelopment,
              scale: scale,
              inspect: { Task { _ = try? await runtime.inspectPage(nodeID: node.id) } },
              capture: capturePage,
              close: { withAnimation(.easeOut(duration: 0.16)) { agentRailVisible = false } }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
      }
    }
  }

  private var addressValue: String {
    guard case .browser(let url) = node.content else { return BrowserDefaults.startURL }
    return url
  }

  private func updateAgentAura(_ phase: BrowserAgentControlPhase?) {
    agentAuraDismissTask?.cancel()
    if let phase {
      agentAuraPhase = phase
      withAnimation(.easeOut(duration: 0.14)) { agentAuraVisible = true }
      return
    }
    // Each browser tool call is momentary, while the agent thinks for a few seconds between
    // them. Linger across those gaps so the glow reads as one continuous session of control
    // instead of flickering on every click.
    agentAuraDismissTask = Task {
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.9)) { agentAuraVisible = false }
    }
  }

  private var sessionValue: BrowserSession {
    node.browserSession ?? BrowserSession(url: addressValue)
  }

  private var isLocalDevelopment: Bool {
    isLocalBrowserURL(state?.url ?? addressValue)
  }

  private func appendBrowserActivity(_ activity: BrowserActivityEntry?) {
    guard let activity, browserActivities.last?.id != activity.id else { return }
    browserActivities.append(activity)
    browserActivities = Array(browserActivities.suffix(40))
  }

  private var mountedTabs: [BrowserTab] {
    let activeID = sessionValue.activeTabID
    return sessionValue.tabs.filter { $0.id == activeID || warmTabIDs.contains($0.id) }
  }

  private func retainWarmTab(_ tabID: UUID) {
    warmTabIDs.removeAll { $0 == tabID }
    warmTabIDs.insert(tabID, at: 0)
    if warmTabIDs.count > 2 { warmTabIDs.removeLast(warmTabIDs.count - 2) }
  }

  @ViewBuilder private var pageSurface: some View {
    if let state {
      ZStack {
        // Keep a bounded warm set mounted so the active page and the previous tab retain transient
        // DOM state without allowing every tab to own a permanent WebContent process.
        ForEach(mountedTabs) { tab in
          BrowserWebView(
            state: state,
            tabID: tab.id,
            tabURL: tab.url,
            isActive: sessionValue.activeTabID == tab.id,
            runtime: runtime
          )
          .opacity(
            sessionValue.activeTabID == tab.id && !showsStartSurface && !showsBlankSurface
              && !(isDragging && dragSnapshot != nil) ? 1 : 0
          )
          .allowsHitTesting(
            sessionValue.activeTabID == tab.id && !showsStartSurface && !showsBlankSurface
              && !isDragging
          )
        }

        if case .place(_, _, let askOtto) = chrome, showsStartSurface || showsBlankSurface {
          OttoStartSurface(
            query: $startQuery,
            focusRequest: startFocusRequest,
            navigate: { url in
              startQuery = ""
              navigate(url)
            },
            askOtto: askOtto,
            history: history,
            bookmarks: bookmarks
          )
          .transition(.opacity)
        } else if showsBlankSurface {
          LinearGradient(
            colors: [palette.surface, palette.ink.opacity(0.36)],
            startPoint: .top,
            endPoint: .bottom
          )
        }

        if showsStartSurface, !isPlace {
          OttoBrowserStartSurface(
            query: $startQuery,
            focusRequest: startFocusRequest,
            scale: scale,
            submit: submitStartQuery,
            newTab: newTab
          )
          .transition(.opacity)
        }

        // WebKit composites pages in a separate process, so moving nodes use a captured frame.
        if isDragging, let dragSnapshot {
          Image(nsImage: dragSnapshot)
            .resizable()
            .scaledToFill()
            .clipped()
        }

        if let errorMessage = state.errorMessage, !showsStartSurface && !showsBlankSurface {
          VStack(spacing: 8 * scale) {
            Image(systemName: "wifi.exclamationmark")
              .font(.system(size: 18 * scale, weight: .semibold))
            Text("PAGE DIDN'T LOAD")
              .font(.ottoMono(max(7, 9 * scale), weight: .black))
            Text(errorMessage)
              .font(.ottoMono(max(6, 7 * scale)))
              .multilineTextAlignment(.center)
              .lineLimit(4)
            Button("Return to Otto Start") { navigate(BrowserDefaults.startURL) }
              .buttonStyle(.bordered)
          }
          .foregroundStyle(palette.paper.opacity(0.82))
          .padding(18 * scale)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(palette.surface.opacity(0.96))
        }
      }
    } else {
      ZStack {
        palette.ink
        ProgressView("Opening browser…")
          .font(.ottoMono(max(7, 8 * scale)))
          .foregroundStyle(palette.muted)
      }
    }
  }

  private var showsStartSurface: Bool {
    let value = state?.url ?? addressValue
    guard let components = URLComponents(string: value) else { return false }
    return OttoNames.isAppURLScheme(components.scheme)
      && components.host?.lowercased() == "start"
  }

  private var showsBlankSurface: Bool {
    (state?.url ?? addressValue) == BrowserDefaults.blankURL
  }

  private func submitAddress() {
    guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard let destination = normalizedBrowserDestination(address) else { return }
    navigate(destination)
  }

  private func submitStartQuery() {
    guard let destination = normalizedBrowserDestination(startQuery) else { return }
    startQuery = ""
    navigate(destination)
  }

  private func navigate(_ url: String) {
    navigate(url, updatingTab: true)
  }

  private func navigate(_ url: String, updatingTab: Bool) {
    address = url
    updateContent(.browser(url: url))
    if updatingTab {
      var session = sessionValue
      if let index = session.tabs.firstIndex(where: { $0.id == session.activeTabID }) {
        session.tabs[index].url = url
        session.tabs[index].title =
          (BrowserDefaults.isStartURL(url) || url == BrowserDefaults.blankURL)
          ? "New Tab" : "Loading…"
        updateBrowserSession(session)
      }
    }
    Task { try? await runtime.navigate(nodeID: node.id, url: url) }
  }

  private var pinnedSites: [BrowserBookmark] {
    if let saved = try? JSONDecoder().decode([BrowserBookmark].self, from: pinnedSitesData) {
      return saved
    }
    return Array((bookmarks.isEmpty ? OttoBrowserDefaults.bookmarks : bookmarks).prefix(4))
  }

  private func savePinnedSites(_ sites: [BrowserBookmark]) {
    pinnedSitesData = (try? JSONEncoder().encode(sites)) ?? Data()
  }

  private func pinSite(_ tab: BrowserTab) {
    guard tab.url.hasPrefix("http"),
      let host = URL(string: tab.url)?.host,
      !pinnedSites.contains(where: { OttoBrowserTabStrip.sameSite($0.url, tab.url) })
    else { return }
    let title = tab.title.isEmpty || tab.title == "Loading…" ? host : tab.title
    savePinnedSites(pinnedSites + [BrowserBookmark(title: title, url: tab.url)])
  }

  private func unpinSite(_ site: BrowserBookmark) {
    savePinnedSites(pinnedSites.filter { $0.url != site.url })
  }

  private var isPlace: Bool {
    if case .place = chrome { return true }
    return false
  }

  /// An empty tab in the Browser place shows Otto's box, which takes the typing; elsewhere the
  /// address field does.
  private func focusEmptyTab() {
    if isPlace { startFocusRequest += 1 } else { addressFocusRequest += 1 }
  }

  private func performBrowserShortcut(_ action: OttoBrowserInputAction) {
    switch action {
    case .newTab: newTab()
    case .closeTab: closeTab(sessionValue.activeTabID)
    case .focusAddress:
      if showsStartSurface || showsBlankSurface {
        focusEmptyTab()
      } else {
        addressFocusRequest += 1
      }
    case .reload: Task { try? await runtime.refresh(nodeID: node.id) }
    case .back: goBack()
    case .forward: goForward()
    case .nextTab, .previousTab:
      let session = sessionValue
      guard let index = session.tabs.firstIndex(where: { $0.id == session.activeTabID }),
        !session.tabs.isEmpty
      else { return }
      let offset = action == .nextTab ? 1 : -1
      selectTab(session.tabs[(index + offset + session.tabs.count) % session.tabs.count].id)
    case .reopenTab:
      guard let closed = BrowserClosedTabs.shared.pop(nodeID: node.id) else { return }
      var session = sessionValue
      let tab = BrowserTab(title: closed.title, url: closed.url)
      session.tabs.append(tab)
      session.activeTabID = tab.id
      updateBrowserSession(session)
      address = displayedBrowserAddress(tab.url)
      updateContent(.browser(url: tab.url))
      Task { try? await runtime.openTab(nodeID: node.id, url: tab.url, tabID: tab.id) }
    }
  }

  /// Open a page's new-window link beside it as a tab, the way a desktop browser does.
  private func openLinkInNewTab(_ url: String) {
    var session = sessionValue
    let tab = BrowserTab(title: "Loading…", url: url)
    session.tabs.append(tab)
    session.activeTabID = tab.id
    updateBrowserSession(session)
    address = displayedBrowserAddress(url)
    updateContent(.browser(url: url))
    Task { try? await runtime.openTab(nodeID: node.id, url: url, tabID: tab.id) }
  }

  private func newTab() {
    var session = sessionValue
    let tab = BrowserTab()
    session.tabs.append(tab)
    session.activeTabID = tab.id
    updateBrowserSession(session)
    startQuery = ""
    address = ""
    focusEmptyTab()
    updateContent(.browser(url: tab.url))
    Task { try? await runtime.openTab(nodeID: node.id, url: tab.url, tabID: tab.id) }
  }

  private func selectTab(_ id: UUID) {
    var session = sessionValue
    guard let tab = session.tabs.first(where: { $0.id == id }) else { return }
    session.activeTabID = id
    updateBrowserSession(session)
    address = displayedBrowserAddress(tab.url)
    if tab.url == BrowserDefaults.blankURL { focusEmptyTab() }
    updateContent(.browser(url: tab.url))
    Task {
      try? await runtime.activateTab(
        nodeID: node.id,
        tab: BrowserRuntimeTab(id: tab.id, url: tab.url, title: tab.title)
      )
    }
  }

  private func closeTab(_ id: UUID) {
    var session = sessionValue
    guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
    let wasActive = session.activeTabID == id
    let closed = session.tabs.remove(at: index)
    BrowserClosedTabs.shared.remember(closed, nodeID: node.id)
    if session.tabs.isEmpty {
      let replacement = BrowserTab()
      session.tabs = [replacement]
      session.activeTabID = replacement.id
    } else if wasActive {
      session.activeTabID = session.tabs[min(index, session.tabs.count - 1)].id
    }
    updateBrowserSession(session)
    let active = session.activeTab
    if wasActive, let active {
      address = displayedBrowserAddress(active.url)
      if active.url == BrowserDefaults.blankURL { focusEmptyTab() }
      updateContent(.browser(url: active.url))
    }
    Task {
      try? await runtime.closeTab(
        nodeID: node.id,
        tabID: id,
        activating: wasActive
          ? active.map { BrowserRuntimeTab(id: $0.id, url: $0.url, title: $0.title) }
          : nil
      )
    }
  }

  private func capturePage() {
    guard !showsStartSurface && !showsBlankSurface else {
      captureStatus = "Open a page before capturing"
      return
    }
    Task {
      do {
        let output = try await capture(node.id)
        captureStatus = "Saved \(output.pixelWidth)×\(output.pixelHeight)"
      } catch {
        captureStatus = error.localizedDescription
      }
    }
  }

  private func goBack() {
    Task { try? await runtime.back(nodeID: node.id) }
  }

  private func goForward() {
    Task { try? await runtime.forward(nodeID: node.id) }
  }

  private func showImport() {
    Task { await prepareImport(force: true) }
  }

  private func prepareImport(force: Bool = false) async {
    let sources = await Task.detached { BrowserProfileImporter.discover() }.value
    if sources.isEmpty {
      if force { captureStatus = "No browser profiles found" }
      return
    }
    if !force, !BrowserImportPresentationGate.claim() { return }
    importRequest = BrowserImportRequest(sources: sources)
  }

  private func importBookmarks(
    from sources: [BrowserImportSource], includeSignIns: Bool
  ) async throws -> Int {
    let imported = try await Task.detached {
      var collected: [BrowserBookmark] = []
      var lastError: (any Error)?
      for source in sources {
        do {
          collected += try BrowserProfileImporter.importBookmarks(from: source)
        } catch {
          lastError = error
        }
      }
      if collected.isEmpty, !includeSignIns, let lastError { throw lastError }
      return collected
    }.value
    let merged = BrowserBookmarkPreferences.merging(imported, into: bookmarks)
    bookmarks = merged
    BrowserBookmarkPreferences.save(merged)
    if includeSignIns {
      try await importSignIns(from: sources.filter(\.canImportSignIns))
    }
    importOnboardingCompleted = true
    return imported.count
  }

  /// Copies sign-in cookies into the shared browser store, so every Otto browser tab is signed in.
  private func importSignIns(from sources: [BrowserImportSource]) async throws {
    guard !sources.isEmpty else { return }
    let (cookies, failure) = await Task.detached {
      var passwords: [BrowserImportSource.Browser: String] = [:]
      var cookies: [HTTPCookie] = []
      var failure: (any Error)?
      for source in sources {
        guard let cookiesURL = source.cookiesURL,
          let service = source.browser.safeStorageService
        else { continue }
        do {
          let password =
            try passwords[source.browser]
            ?? ChromiumCookieImporter.safeStoragePassword(
              service: service, browser: source.browser.rawValue)
          passwords[source.browser] = password
          cookies += try ChromiumCookieImporter.readCookies(
            databaseURL: cookiesURL, password: password, browser: source.browser.rawValue
          ).compactMap { $0.httpCookie() }
        } catch {
          failure = error
        }
      }
      return (cookies, failure)
    }.value
    let store = WKWebsiteDataStore.default().httpCookieStore
    for cookie in cookies {
      await store.setCookie(cookie)
    }
    if cookies.isEmpty, let failure { throw failure }
  }
}

/// WebKit sessions belong to the application, not to whichever panel is currently visible.
/// A renderer is created on demand and parked in an unshown window when its panel unmounts.
@MainActor
internal enum BrowserRendererPool {
  private static var stores: [ObjectIdentifier: CanvasStore] = [:]
  private static var entries: [UUID: Entry] = [:]

  @MainActor
  fileprivate final class Entry {
    let runtime: BrowserRuntime
    let webView: WKWebView
    let coordinator: BrowserWebView.Coordinator
    let window: NSWindow
    var mounted = false
    var lastUsed = Date()
    var updates: Task<Void, Never>?

    init(spec: BrowserWebView) {
      runtime = spec.runtime
      coordinator = BrowserWebView.Coordinator(
        nodeID: spec.state.nodeID, tabID: spec.tabID, runtime: spec.runtime,
        requestedURL: spec.state.url, requestedRevision: spec.state.revision,
        report: { report in
          BrowserRendererPool.report(
            report, nodeID: spec.state.nodeID,
            tabID: spec.tabID, runtime: spec.runtime)
        })
      webView = spec.makeWebView(coordinator: coordinator)
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = webView
      webView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
      spec.apply(to: webView, coordinator: coordinator)
      updates = Task { [weak self] in
        for await state in await spec.runtime.updates(nodeID: spec.state.nodeID) {
          guard !Task.isCancelled, let self else { break }
          let current = BrowserWebView(
            state: state, tabID: spec.tabID,
            tabURL: state.tabs.first(where: { $0.id == spec.tabID })?.url ?? spec.tabURL,
            isActive: state.activeTabID == spec.tabID, runtime: spec.runtime)
          current.apply(to: self.webView, coordinator: self.coordinator)
        }
      }
    }

    func close() {
      updates?.cancel()
      webView.stopLoading()
      webView.navigationDelegate = nil
      webView.uiDelegate = nil
      webView.configuration.userContentController.removeScriptMessageHandler(
        forName: BrowserWebView.Coordinator.diagnosticMessageName)
      webView.configuration.userContentController.removeScriptMessageHandler(
        forName: BrowserWebView.Coordinator.selectionMessageName)
      webView.configuration.userContentController.removeScriptMessageHandler(
        forName: BrowserPasswordBridge.name, contentWorld: BrowserPasswordBridge.world)
      coordinator.unregisterHandlers()
      coordinator.closePopupWindows()
      window.close()
    }
  }

  static func configure(store: CanvasStore, runtime: BrowserRuntime) async {
    stores[ObjectIdentifier(runtime)] = store
    await runtime.setRendererPreparation { [weak store, weak runtime] state in
      guard let store, let runtime,
        let canvasID = store.canvasID(containing: state.nodeID),
        let node = store.snapshot.canvases.flatMap(\.nodes).first(where: { $0.id == state.nodeID })
      else { throw BrowserRuntimeError.unknownNode(state.nodeID) }
      // Other web surfaces, such as GTM Grid, own their own renderer and URL scheme.
      guard node.kind == .browser else { return }
      if node.browserSession == nil {
        let session = BrowserSession(
          tabs: state.tabs.map {
            BrowserTab(id: $0.id, title: $0.title ?? "New Tab", url: $0.url)
          }, activeTabID: state.activeTabID)
        store.dispatch(.setBrowserSession(id: node.id, session: session), targetCanvasID: canvasID)
      }
      let spec = BrowserWebView(
        state: state, tabID: state.activeTabID,
        tabURL: state.url, isActive: true, runtime: runtime)
      let entry = renderer(for: spec)
      spec.apply(to: entry.webView, coordinator: entry.coordinator)
      // Handler registration and the initial navigation run asynchronously on WebKit.
      for _ in 0..<200 {
        try Task.checkCancellation()
        if entry.webView.url != nil, !entry.webView.isLoading { return }
        try await Task.sleep(for: .milliseconds(50))
      }
      throw BrowserRuntimeError.pageInspectionUnavailable(state.nodeID)
    }
  }

  static func passwordPage(tabID: UUID?) -> WKWebView? {
    guard let tabID, let entry = entries[tabID], entry.mounted,
      !entry.webView.isHidden, entry.webView.window?.isVisible == true
    else { return nil }
    return entry.webView
  }

  /// Whether any pooled renderer's parking window is on screen. Renderers must stay unshown.
  static var hasVisibleRendererWindow: Bool {
    entries.values.contains { $0.window.isVisible }
  }

  static func prune(snapshot: WorkspaceSnapshot, runtime: BrowserRuntime? = nil) {
    let validTabs = Set(
      snapshot.canvases.flatMap(\.nodes).flatMap {
        $0.browserSession?.tabs.map(\.id) ?? []
      })
    for id in Array(entries.keys)
    where !validTabs.contains(id)
      && (runtime == nil || entries[id]?.runtime === runtime)
    {
      entries.removeValue(forKey: id)?.close()
    }
    // Bound detached WebContent processes, while allowing in-flight observations to finish.
    let parked = entries.filter {
      !$0.value.mounted && (runtime == nil || $0.value.runtime === runtime)
    }.sorted {
      $0.value.lastUsed > $1.value.lastUsed
    }
    for (id, entry) in parked.dropFirst(4) where entry.lastUsed.timeIntervalSinceNow < -60 {
      entries.removeValue(forKey: id)?.close()
    }
  }

  fileprivate static func renderer(for spec: BrowserWebView) -> Entry {
    if let entry = entries[spec.tabID] {
      entry.lastUsed = Date()
      return entry
    }
    let entry = Entry(spec: spec)
    entries[spec.tabID] = entry
    return entry
  }

  fileprivate static func park(tabID: UUID) {
    guard let entry = entries[tabID] else { return }
    entry.mounted = false
    // SwiftUI finishes removing its NSView after dismantleNSView returns.
    Task { @MainActor [weak entry] in
      await Task.yield()
      guard let entry, !entry.mounted else { return }
      entry.webView.removeFromSuperview()
      entry.window.contentView = entry.webView
      entry.webView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    }
  }

  private static func report(
    _ report: BrowserPageReport, nodeID: UUID, tabID: UUID,
    runtime: BrowserRuntime
  ) {
    Task {
      guard let state = await runtime.state(nodeID: nodeID), state.activeTabID == tabID,
        state.revision == report.expectedRevision,
        let store = stores[ObjectIdentifier(runtime)],
        let canvasID = store.canvasID(containing: nodeID)
      else { return }
      try? await runtime.reportLoaded(
        nodeID: nodeID, url: report.url, title: report.title,
        canGoBack: report.canGoBack, canGoForward: report.canGoForward,
        isLoading: report.isLoading, errorMessage: report.errorMessage,
        expectedRevision: report.expectedRevision)
      store.dispatch(
        .updateBrowserTab(
          id: nodeID, tabID: tabID,
          url: report.url, title: report.title), targetCanvasID: canvasID)
    }
  }
}

struct BrowserWebView: NSViewRepresentable {
  let state: BrowserRuntimeState
  let tabID: UUID
  let tabURL: String
  let isActive: Bool
  let runtime: BrowserRuntime

  func makeCoordinator() -> Coordinator {
    BrowserRendererPool.renderer(for: self).coordinator
  }

  func makeNSView(context: Context) -> WKWebView {
    let renderer = BrowserRendererPool.renderer(for: self)
    renderer.mounted = true
    renderer.webView.removeFromSuperview()
    return renderer.webView
  }

  func makeWebView(coordinator: Coordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    // Browser nodes share Otto's persistent WebKit store so a login made in one node survives
    // node recreation and app relaunch. This remains isolated from Safari, Chrome, and Dia.
    configuration.websiteDataStore = .default()
    // WKWebView's macOS user agent does not identify itself as Safari, which causes some sites to
    // show an unsupported-browser banner despite using the current system WebKit. This temporary
    // compatibility token goes away when the Chromium renderer becomes the default.
    configuration.applicationNameForUserAgent = safariCompatibilityToken()
    // Without this WebKit hides the Fullscreen API, so video players' fullscreen buttons do nothing.
    configuration.preferences.isElementFullscreenEnabled = true
    configuration.userContentController.add(
      coordinator, name: Coordinator.diagnosticMessageName)
    configuration.userContentController.add(
      coordinator, name: Coordinator.selectionMessageName)
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: Coordinator.diagnosticBridgeScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      ))
    let passwordBridge = BrowserPasswordBridge.install(in: configuration)
    let webView = WKWebView(frame: .zero, configuration: configuration)
    BrowserSignInDiagnostics.configure(webView)
    passwordBridge.webView = webView
    webView.navigationDelegate = coordinator
    webView.uiDelegate = coordinator
    webView.allowsBackForwardNavigationGestures = true
    webView.isHidden = !isActive
    return webView
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    BrowserRendererPool.park(tabID: coordinator.tabID)
  }

  private func safariCompatibilityToken() -> String {
    let version =
      Bundle(path: "/Applications/Safari.app")?.object(
        forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String
    return "Version/\(version ?? "18.0") Safari/605.1.15"
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    apply(to: webView, coordinator: context.coordinator)
  }

  func apply(to webView: WKWebView, coordinator: Coordinator) {
    coordinator.requestedURL = state.url
    coordinator.requestedRevision = state.revision
    coordinator.isActive = isActive
    // SwiftUI opacity does not make the hosted AppKit view invisible to WebKit. Explicitly hiding
    // the inactive page stops its display link and remote layer commits while keeping DOM state.
    webView.isHidden = !isActive
    guard isActive, state.activeTabID == tabID else {
      coordinator.handlersRegistered = false
      return
    }
    coordinator.registerHandlers(for: webView)
    coordinator.updateSelectionMode(webView, enabled: state.selectionModeEnabled)
    guard coordinator.lastAppliedRevision != state.revision else { return }
    coordinator.lastAppliedRevision = state.revision
    switch state.requestedAction {
    case .activateTab:
      // A live web view already contains the tab's transient page state. Only restored tabs that
      // have never been rendered need their recorded URL loaded on first activation.
      if webView.url == nil, let url = URL(string: tabURL), !OttoNames.isAppURLScheme(url.scheme) {
        coordinator.track(
          webView.load(URLRequest(url: url)),
          revision: state.revision,
          requestedURL: tabURL
        )
      } else {
        coordinator.publish(webView, navigation: nil)
      }
    case .navigate:
      // otto:// (and legacy muse://) pages are drawn by Otto itself. Loading one hands the URL to macOS, which shows
      // a "no application set to open" alert.
      guard let url = URL(string: state.url), !OttoNames.isAppURLScheme(url.scheme) else {
        return
      }
      coordinator.track(
        webView.load(URLRequest(url: url)),
        revision: state.revision,
        requestedURL: state.url
      )
    case .back:
      if let item = webView.backForwardList.backList.last(where: {
        BrowserHistoryNavigation.isPage($0.url)
      }) {
        coordinator.track(
          webView.go(to: item), revision: state.revision, requestedURL: state.url)
      }
    case .forward:
      if let item = webView.backForwardList.forwardList.first(where: {
        BrowserHistoryNavigation.isPage($0.url)
      }) {
        coordinator.track(
          webView.go(to: item), revision: state.revision, requestedURL: state.url)
      }
    case .refresh:
      coordinator.track(
        webView.reload(), revision: state.revision, requestedURL: state.url)
    case .stop:
      webView.stopLoading()
      coordinator.publish(webView, navigation: nil)
    }
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let diagnosticMessageName = "ottoBrowserDiagnostics"
    static let selectionMessageName = "ottoElementSelection"
    static let diagnosticBridgeScript = """
      (() => {
        const report = (value) => {
          try {
            window.webkit.messageHandlers.ottoBrowserDiagnostics.postMessage(String(value));
          } catch (_) {}
        };
        window.addEventListener('error', event => report(event.message || 'Unknown page error'));
        window.addEventListener('unhandledrejection', event =>
          report(event.reason && event.reason.message ? event.reason.message : event.reason));
      })();
      """
    let nodeID: UUID
    let tabID: UUID
    let runtime: BrowserRuntime
    var requestedURL: String
    var requestedRevision: Int
    var report: (BrowserPageReport) -> Void
    var lastAppliedRevision = -1
    var isActive = false
    let handlerOwnerID = UUID()
    var handlersRegistered = false
    let agentCursor = BrowserAgentCursor()
    var appliedSelectionMode: Bool?
    var navigationContexts: [ObjectIdentifier: (revision: Int, requestedURL: String)] = [:]
    let popupWindows = BrowserPopupWindows()
    var externalNavigation = BrowserExternalNavigation()
    private var appHandoffPending = false

    init(
      nodeID: UUID,
      tabID: UUID,
      runtime: BrowserRuntime,
      requestedURL: String,
      requestedRevision: Int,
      report: @escaping (BrowserPageReport) -> Void
    ) {
      self.nodeID = nodeID
      self.tabID = tabID
      self.runtime = runtime
      self.requestedURL = requestedURL
      self.requestedRevision = requestedRevision
      self.report = report
    }

    func updateSelectionMode(_ webView: WKWebView, enabled: Bool) {
      guard appliedSelectionMode != enabled else { return }
      appliedSelectionMode = enabled
      webView.evaluateJavaScript(Self.selectionScript(enabled: enabled))
    }

    static func selectionScript(enabled: Bool) -> String {
      """
      (() => {
        const key = '__ottoElementPicker';
        const old = window[key];
        if (old) old.dispose();
        if (!\(enabled ? "true" : "false")) return;

        const overlay = document.createElement('div');
        overlay.setAttribute('data-otto-picker', 'true');
        Object.assign(overlay.style, {
          position: 'fixed', pointerEvents: 'none', zIndex: '2147483647',
          border: '2px solid #83d6b2', borderRadius: '5px',
          background: 'rgba(131,214,178,.10)',
          boxShadow: '0 0 0 1px rgba(10,20,17,.65), 0 0 24px rgba(131,214,178,.22)',
          display: 'none', transition: 'all 55ms ease-out'
        });
        document.documentElement.appendChild(overlay);
        let hovered = null;

        const eligible = node => {
          const element = node && node.nodeType === 1 ? node : node?.parentElement;
          if (!element || element === overlay || element.closest('[data-otto-picker]')) return null;
          if (element === document.documentElement || element === document.body) return null;
          return element;
        };
        const move = event => {
          hovered = eligible(event.target);
          if (!hovered) { overlay.style.display = 'none'; return; }
          const rect = hovered.getBoundingClientRect();
          Object.assign(overlay.style, {
            display: 'block', left: `${rect.left}px`, top: `${rect.top}px`,
            width: `${rect.width}px`, height: `${rect.height}px`
          });
        };
        const selectorFor = element => {
          if (element.id) return `#${CSS.escape(element.id)}`;
          const testID = element.getAttribute('data-testid');
          if (testID) return `[data-testid="${CSS.escape(testID)}"]`;
          const path = [];
          let current = element;
          while (current && current.nodeType === 1 && path.length < 6) {
            let part = current.tagName.toLowerCase();
            const parent = current.parentElement;
            if (parent) {
              const siblings = [...parent.children].filter(child => child.tagName === current.tagName);
              if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
            }
            path.unshift(part);
            current = parent;
          }
          return path.join(' > ');
        };
        const choose = event => {
          const element = eligible(event.target) || hovered;
          if (!element) return;
          event.preventDefault();
          event.stopPropagation();
          event.stopImmediatePropagation();
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          const text = (element.innerText || element.textContent || '').trim().replace(/\\s+/g, ' ');
          const name = element.getAttribute('aria-label') || element.getAttribute('alt') ||
            element.getAttribute('title') || text;
          window.webkit.messageHandlers.\(selectionMessageName).postMessage({
            url: location.href,
            route: `${location.pathname}${location.search}${location.hash}`,
            tagName: element.tagName.toLowerCase(),
            role: element.getAttribute('role') || '',
            accessibleName: name.slice(0, 280),
            text: text.slice(0, 500),
            selector: selectorFor(element),
            bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
            styles: {
              display: style.display, position: style.position, color: style.color,
              backgroundColor: style.backgroundColor, fontFamily: style.fontFamily,
              fontSize: style.fontSize, fontWeight: style.fontWeight,
              borderRadius: style.borderRadius, padding: style.padding, margin: style.margin
            }
          });
          window[key].dispose();
        };
        const keydown = event => {
          if (event.key !== 'Escape') return;
          window[key].dispose();
          window.webkit.messageHandlers.\(selectionMessageName).postMessage({ cancelled: true });
        };
        const dispose = () => {
          document.removeEventListener('mousemove', move, true);
          document.removeEventListener('click', choose, true);
          document.removeEventListener('keydown', keydown, true);
          overlay.remove();
          window[key] = null;
        };
        window[key] = { dispose };
        document.addEventListener('mousemove', move, true);
        document.addEventListener('click', choose, true);
        document.addEventListener('keydown', keydown, true);
      })();
      """
    }

    private func handleSelectionMessage(_ message: WKScriptMessage) {
      guard let payload = message.body as? [String: Any] else { return }
      if payload["cancelled"] as? Bool == true {
        Task { try? await runtime.setSelectionMode(nodeID: nodeID, enabled: false) }
        return
      }
      guard let bounds = payload["bounds"] as? [String: Any],
        let x = number(bounds["x"]), let y = number(bounds["y"]),
        let width = number(bounds["width"]), let height = number(bounds["height"])
      else { return }
      let rawStyles = payload["styles"] as? [String: Any] ?? [:]
      let styles = rawStyles.reduce(into: [String: String]()) { result, entry in
        if let value = entry.value as? String { result[entry.key] = value }
      }
      let selection = BrowserElementSelection(
        nodeID: nodeID,
        tabID: tabID,
        url: payload["url"] as? String ?? requestedURL,
        route: payload["route"] as? String ?? "",
        tagName: payload["tagName"] as? String ?? "element",
        role: nonEmpty(payload["role"] as? String),
        accessibleName: payload["accessibleName"] as? String ?? "",
        text: payload["text"] as? String ?? "",
        selector: payload["selector"] as? String ?? "",
        bounds: BrowserElementBounds(x: x, y: y, width: width, height: height),
        styles: styles
      )
      Task { try? await runtime.reportSelection(nodeID: nodeID, selection: selection) }
    }

    private func number(_ value: Any?) -> Double? {
      if let number = value as? NSNumber { return number.doubleValue }
      return value as? Double
    }

    private func nonEmpty(_ value: String?) -> String? {
      guard let value, !value.isEmpty else { return nil }
      return value
    }

    func track(_ navigation: WKNavigation?, revision: Int, requestedURL: String) {
      guard let navigation else { return }
      navigationContexts[ObjectIdentifier(navigation)] = (revision, requestedURL)
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      if message.name == Self.selectionMessageName {
        handleSelectionMessage(message)
        return
      }
      guard message.name == Self.diagnosticMessageName, let detail = message.body as? String else {
        return
      }
      Task { await runtime.reportPageDiagnostic(nodeID: nodeID, message: detail) }
    }

    func registerHandlers(for webView: WKWebView) {
      guard !handlersRegistered else { return }
      handlersRegistered = true
      // The task only registers the handlers; the handlers themselves hold weak references.
      Task { [self, webView] in
        await runtime.registerCaptureHandler(nodeID: nodeID, ownerID: handlerOwnerID) {
          @MainActor [weak webView] in
          guard let webView else { throw BrowserRuntimeError.captureUnavailable(self.nodeID) }
          let image = try await webView.takeSnapshot(configuration: nil)
          guard let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
          else { throw BrowserRuntimeError.captureUnavailable(self.nodeID) }
          return BrowserCapture(
            pngData: png,
            pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh
          )
        }
        await runtime.registerPageHandler(
          nodeID: nodeID,
          ownerID: handlerOwnerID,
          snapshot: { @MainActor [weak self, weak webView] nodeID in
            guard let self, let webView else {
              throw BrowserRuntimeError.pageInspectionUnavailable(nodeID)
            }
            return try await self.inspectPage(webView, nodeID: nodeID)
          },
          interact: { @MainActor [weak self, weak webView] nodeID, request in
            guard let self, let webView else {
              throw BrowserRuntimeError.pageInteractionUnavailable(nodeID)
            }
            return try await self.interact(webView, nodeID: nodeID, request: request)
          },
          assess: { @MainActor [weak self, weak webView] nodeID, request in
            guard let self, let webView else {
              throw BrowserRuntimeError.pageInteractionUnavailable(nodeID)
            }
            return try await self.assessInteraction(webView, request: request)
          }
        )
      }
    }

    func unregisterHandlers() {
      Task {
        await runtime.unregisterCaptureHandler(nodeID: nodeID, ownerID: handlerOwnerID)
        await runtime.unregisterPageHandler(nodeID: nodeID, ownerID: handlerOwnerID)
      }
    }

    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
        if externalNavigation.handOff(url) { return nil }
        if BrowserPopupWindows.switchesAccount(from: webView.url, to: url) {
          webView.load(navigationAction.request)
          return nil
        }
        if let url = BrowserPopupWindows.tabURL(
          navigationType: navigationAction.navigationType, url: url,
          isMainFrame: navigationAction.sourceFrame.isMainFrame)
        {
          BrowserLinkTabRequest.post(nodeID: nodeID, url: url.absoluteString)
          return nil
        }
      }
      return popupWindows.webView(
        webView, createWebViewWith: configuration,
        for: navigationAction, windowFeatures: windowFeatures)
    }

    func webView(
      _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
      initiatedByFrame frame: WKFrameInfo,
      completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
      BrowserFilePicker.present(parameters, for: webView, completionHandler: completionHandler)
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      // Native new-tab surfaces never belong in page history. This also cancels swipe
      // navigation to legacy internal URLs retained by an older renderer.
      if let url = navigationAction.request.url,
        OttoNames.isAppURLScheme(url.scheme)
          || (navigationAction.navigationType == .backForward
            && !BrowserHistoryNavigation.isPage(url))
      {
        decisionHandler(.cancel)
        return
      }
      if navigationAction.targetFrame?.isMainFrame != false,
        let url = navigationAction.request.url, externalNavigation.handOff(url)
      {
        appHandoffPending = true
        decisionHandler(.cancel)
        publish(webView, navigation: nil, isTerminal: true)
        return
      }
      decisionHandler(.allow)
    }

    func closePopupWindows() { popupWindows.closeAll() }

    private func inspectPage(_ webView: WKWebView, nodeID: UUID) async throws
      -> BrowserPageSnapshot
    {
      let json = try await evaluateString(browserInspectionScript, in: webView)
      let decoded = try JSONDecoder().decode(DOMSnapshot.self, from: Data(json.utf8))
      return BrowserPageSnapshot(
        nodeID: nodeID,
        url: decoded.url,
        title: decoded.title,
        pageRevision: decoded.revision,
        elements: decoded.elements
      )
    }

    private func interact(
      _ webView: WKWebView,
      nodeID: UUID,
      request: BrowserInteractionRequest
    ) async throws -> BrowserInteractionResult {
      let encoded = try JSONEncoder().encode(request)
      guard let requestJSON = String(data: encoded, encoding: .utf8) else {
        throw BrowserRuntimeError.pageInteractionUnavailable(nodeID)
      }
      if request.kind == .click || request.kind == .type {
        // Bring the target on screen and glide the visible agent cursor to it first, so the
        // person can follow what the agent is about to do.
        let located = try await evaluateString(browserLocateScript(requestJSON), in: webView)
        let target = try JSONDecoder().decode(DOMLocateResult.self, from: Data(located.utf8))
        try target.throwIfFailed(nodeID: nodeID, elementID: request.elementID)
        if let x = target.x, let y = target.y {
          let point = CGPoint(x: x, y: y)
          await agentCursor.move(toPagePoint: point, in: webView)
          // A real mouse press through WebKit arrives as trusted input, which some sites require
          // and which matches what a person does. Fall back to scripted events when the point
          // is covered by something else or the page is not in a window.
          if request.kind == .click, target.hit == true,
            BrowserAgentCursor.nativeClick(atPagePoint: point, in: webView)
          {
            agentCursor.press()
            return BrowserInteractionResult(
              nodeID: nodeID,
              pageRevision: request.revision,
              url: webView.url?.absoluteString ?? target.url,
              message: "Clicked element"
            )
          }
          if request.kind == .click { agentCursor.press() }
        }
      }
      let json = try await evaluateString(browserInteractionScript(requestJSON), in: webView)
      let decoded = try JSONDecoder().decode(DOMInteractionResult.self, from: Data(json.utf8))
      guard decoded.ok else {
        switch decoded.error {
        case "stale": throw BrowserRuntimeError.stalePageSnapshot
        case "missing":
          throw BrowserRuntimeError.pageElementNotFound(request.elementID ?? "unknown")
        default: throw BrowserRuntimeError.pageInteractionUnavailable(nodeID)
        }
      }
      return BrowserInteractionResult(
        nodeID: nodeID,
        pageRevision: request.revision,
        url: decoded.url,
        message: decoded.message ?? "Browser interaction completed"
      )
    }

    private func assessInteraction(
      _ webView: WKWebView,
      request: BrowserInteractionRequest
    ) async throws -> BrowserInteractionAssessment {
      let encoded = try JSONEncoder().encode(request)
      guard let requestJSON = String(data: encoded, encoding: .utf8) else {
        throw BrowserRuntimeError.pageInteractionUnavailable(nodeID)
      }
      let json = try await evaluateString(
        browserInteractionAssessmentScript(requestJSON), in: webView)
      return try JSONDecoder().decode(BrowserInteractionAssessment.self, from: Data(json.utf8))
    }

    private func evaluateString(_ script: String, in webView: WKWebView) async throws -> String {
      try await withCheckedThrowingContinuation { continuation in
        webView.evaluateJavaScript(script) { value, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let value = value as? String {
            continuation.resume(returning: value)
          } else {
            continuation.resume(
              throwing: BrowserRuntimeError.pageInspectionUnavailable(self.nodeID))
          }
        }
      }
    }

    private struct DOMSnapshot: Codable {
      var url: String
      var title: String?
      var revision: String
      var elements: [BrowserPageElement]
    }

    private struct DOMInteractionResult: Codable {
      var ok: Bool
      var error: String?
      var url: String
      var message: String?
    }

    private struct DOMLocateResult: Codable {
      var ok: Bool
      var error: String?
      var url: String
      var x: Double?
      var y: Double?
      var hit: Bool?

      func throwIfFailed(nodeID: UUID, elementID: String?) throws {
        guard !ok else { return }
        switch error {
        case "stale": throw BrowserRuntimeError.stalePageSnapshot
        case "missing": throw BrowserRuntimeError.pageElementNotFound(elementID ?? "unknown")
        default: throw BrowserRuntimeError.pageInteractionUnavailable(nodeID)
        }
      }
    }

    /// Scrolls the target into view and reports its centre in page (CSS) coordinates, plus
    /// whether a real click there would land on it rather than on an overlay.
    private func browserLocateScript(_ requestJSON: String) -> String {
      """
      (() => {
        const request = \(requestJSON);
        const page = window.__ottoAgentPage;
        const result = (value) => JSON.stringify({url: location.href, ...value});
        if (!page || page.revision !== request.revision) {
          return result({ok: false, error: 'stale'});
        }
        const element = page.elements.get(request.elementID);
        if (!element || !element.isConnected) return result({ok: false, error: 'missing'});
        element.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
        const rect = element.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        let top = document.elementFromPoint(x, y);
        while (top && top.shadowRoot) {
          const inner = top.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === top) break;
          top = inner;
        }
        let hit = false;
        for (let node = top; node; node = node.parentNode || node.host) {
          if (node === element) { hit = true; break; }
        }
        const inside = x >= 0 && y >= 0 && x <= innerWidth && y <= innerHeight;
        return result({ok: true, x, y, hit: hit && inside});
      })()
      """
    }

    private var browserInspectionScript: String {
      #"""
      (() => {
        const selector = [
          'a[href]', 'button', 'input', 'textarea', 'select', 'summary',
          '[role="button"]', '[role="link"]', '[role="checkbox"]', '[role="menuitem"]',
          '[contenteditable="true"]', '[tabindex]'
        ].join(',');
        const roots = [document];
        for (let index = 0; index < roots.length; index += 1) {
          for (const element of roots[index].querySelectorAll('*')) {
            if (element.shadowRoot) roots.push(element.shadowRoot);
          }
        }
        const candidates = roots.flatMap(root => Array.from(root.querySelectorAll(selector)));
        const elements = new Map();
        const revision = (globalThis.crypto && crypto.randomUUID)
          ? crypto.randomUUID()
          : `${Date.now()}-${Math.random()}`;
        let nextID = 0;
        const output = [];
        for (const element of candidates) {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          if (rect.width <= 0 || rect.height <= 0 || style.visibility === 'hidden' ||
              style.display === 'none') continue;
          const tag = element.tagName.toLowerCase();
          const inputType = tag === 'input' ? (element.type || 'text').toLowerCase() : '';
          const role = element.getAttribute('role') ||
            (tag === 'a' ? 'link' : tag === 'button' || tag === 'summary' ? 'button' :
             tag === 'select' ? 'combobox' : inputType === 'checkbox' ? 'checkbox' :
             tag === 'input' || tag === 'textarea' || element.isContentEditable ? 'textbox' : tag);
          const label = element.getAttribute('aria-label') ||
            (element.labels && element.labels[0] && element.labels[0].innerText) ||
            element.alt || element.title || element.innerText || element.placeholder || '';
          const id = `e${++nextID}`;
          elements.set(id, element);
          const nonTextInputTypes = new Set([
            'button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio', 'range', 'reset',
            'submit'
          ]);
          const canType = tag === 'textarea' || element.isContentEditable ||
            (tag === 'input' && !nonTextInputTypes.has(inputType));
          const actions = canType ? ['type'] : tag === 'select' ? ['select'] : ['click'];
          output.push({
            id,
            role,
            name: String(label).trim().replace(/\s+/g, ' ').slice(0, 240),
            placeholder: element.placeholder || null,
            bounds: {x: rect.x, y: rect.y, width: rect.width, height: rect.height},
            actions,
            isDisabled: Boolean(element.disabled || element.getAttribute('aria-disabled') === 'true'),
            isSensitive: inputType === 'password',
            isInViewport: rect.bottom >= 0 && rect.right >= 0 &&
              rect.top <= innerHeight && rect.left <= innerWidth
          });
        }
        window.__ottoAgentPage = {revision, elements};
        // Off-screen elements stay addressable (interactions scroll them into view), but the
        // visible ones lead so a truncated list still covers what the user is looking at.
        output.sort((left, right) => Number(right.isInViewport) - Number(left.isInViewport));
        return JSON.stringify({
          url: location.href,
          title: document.title || null,
          revision,
          elements: output.slice(0, 1_000).map(({isInViewport, ...element}) => element)
        });
      })()
      """#
    }

    private func browserInteractionScript(_ requestJSON: String) -> String {
      """
      (() => {
        const request = \(requestJSON);
        const page = window.__ottoAgentPage;
        const result = (value) => JSON.stringify({url: location.href, ...value});
        if (!page || page.revision !== request.revision) {
          return result({ok: false, error: 'stale'});
        }
        if (request.kind === 'scroll') {
          window.scrollBy({left: request.deltaX || 0, top: request.deltaY || 0, behavior: 'instant'});
          return result({ok: true, message: 'Scrolled page'});
        }
        const element = page.elements.get(request.elementID);
        if (!element || !element.isConnected) return result({ok: false, error: 'missing'});
        element.scrollIntoView({block: 'center', inline: 'center'});
        if (request.kind === 'click') {
          // Many apps (X, LinkedIn, Radix/Headless UI menus) act on pointerdown or mousedown and
          // ignore a bare element.click(), so replay the full pointer sequence at the centre.
          const rect = element.getBoundingClientRect();
          const point = {
            bubbles: true, cancelable: true, composed: true, view: window, button: 0,
            clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2
          };
          const pointer = {...point, pointerId: 1, pointerType: 'mouse', isPrimary: true};
          element.dispatchEvent(new PointerEvent('pointerover', pointer));
          element.dispatchEvent(new MouseEvent('mouseover', point));
          element.dispatchEvent(new PointerEvent('pointerdown', {...pointer, buttons: 1}));
          element.dispatchEvent(new MouseEvent('mousedown', {...point, buttons: 1}));
          element.focus({preventScroll: true});
          element.dispatchEvent(new PointerEvent('pointerup', pointer));
          element.dispatchEvent(new MouseEvent('mouseup', point));
          element.click();
          return result({ok: true, message: 'Clicked element'});
        }
        if (request.kind === 'type') {
          element.focus();
          if (element.isContentEditable) {
            // Rich editors (Draft.js on X, Lexical, ProseMirror, Quill) keep their own document
            // model. Assigning textContent rewrites the DOM behind their back, so the text
            // vanishes on the next render and Post/Send stays disabled. Select the existing
            // content and insert through the editing pipeline, which fires beforeinput/input
            // events those editors handle exactly like real typing.
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(element);
            selection.removeAllRanges();
            selection.addRange(range);
            const text = request.text || '';
            if ((element.innerText || '').trim()) document.execCommand('delete', false);
            const inserted = text ? document.execCommand('insertText', false, text) : true;
            // Only plain contenteditable regions without an editing pipeline reach this fallback;
            // overwriting a model-backed editor here would desynchronise it again.
            if (!inserted) {
              element.textContent = text;
              element.dispatchEvent(new InputEvent('input', {
                bubbles: true, inputType: 'insertText', data: text
              }));
            }
            return result({ok: true, message: 'Entered text'});
          } else {
            // Use the native property setter so React and other controlled-input frameworks see
            // the change instead of immediately restoring their stale state.
            const prototype = element.tagName.toLowerCase() === 'textarea'
              ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
            if (setter) setter.call(element, request.text || '');
            else element.value = request.text || '';
          }
          element.dispatchEvent(new InputEvent('input', {
            bubbles: true, inputType: 'insertText', data: request.text || ''
          }));
          element.dispatchEvent(new Event('change', {bubbles: true}));
          return result({ok: true, message: 'Entered text'});
        }
        return result({ok: false, error: 'unsupported'});
      })()
      """
    }

    private func browserInteractionAssessmentScript(_ requestJSON: String) -> String {
      """
      (() => {
        const request = \(requestJSON);
        const page = window.__ottoAgentPage;
        if (!page || page.revision !== request.revision) {
          return JSON.stringify({requiresConfirmation: false, reason: null});
        }
        const element = page.elements.get(request.elementID);
        if (!element || !element.isConnected) {
          return JSON.stringify({requiresConfirmation: false, reason: null});
        }
        const tag = element.tagName.toLowerCase();
        const type = String(element.type || '').toLowerCase();
        const label = String(
          element.getAttribute('aria-label') || element.innerText || element.title || element.value || ''
        ).trim().split(' ').filter(Boolean).join(' ').slice(0, 120);
        const href = String(element.getAttribute('href') || '').toLowerCase();
        const normalizedLabel = label.toLowerCase().replace(/[^a-z0-9]+/g, ' ');
        const labelWords = new Set(normalizedLabel.split(' ').filter(Boolean));
        const commits = [
          'send', 'submit', 'publish', 'post', 'delete', 'remove', 'purchase', 'buy', 'pay',
          'order', 'book', 'reserve', 'transfer', 'connect', 'follow', 'unfollow', 'like',
          'accept', 'decline', 'confirm', 'signout'
        ].some(word => labelWords.has(word));
        const submitsForm =
          (tag === 'input' && ['submit', 'image'].includes(type)) ||
          (tag === 'button' && element.closest('form') && (!type || type === 'submit'));
        const externalProtocol = href.startsWith('mailto:') || href.startsWith('tel:');
        const requiresConfirmation = Boolean(
          submitsForm || externalProtocol || element.hasAttribute('download') || commits
        );
        return JSON.stringify({
          requiresConfirmation,
          reason: requiresConfirmation ? `This may perform “${label || 'a consequential action'}”` : null
        });
      })()
      """
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
      appHandoffPending = false
      publish(webView, navigation: navigation)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
      appHandoffPending = false
      publish(webView, navigation: navigation, isTerminal: true)
      if appliedSelectionMode == true {
        appliedSelectionMode = nil
        updateSelectionMode(webView, enabled: true)
      }
    }
    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation?,
      withError error: any Error
    ) {
      if consumeNavigationCancellation(error, in: webView, navigation: navigation) { return }
      appHandoffPending = false
      let handedOff = externalNavigation.handOffRedirectFailure(error)
      publish(
        webView,
        navigation: navigation,
        errorDescription: handedOff ? nil : error.localizedDescription,
        isTerminal: true
      )
    }
    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation?,
      withError error: any Error
    ) {
      if consumeNavigationCancellation(error, in: webView, navigation: navigation) { return }
      appHandoffPending = false
      let handedOff = externalNavigation.handOffRedirectFailure(error)
      publish(
        webView,
        navigation: navigation,
        errorDescription: handedOff ? nil : error.localizedDescription,
        isTerminal: true
      )
    }

    private func consumeNavigationCancellation(
      _ error: any Error, in webView: WKWebView, navigation: WKNavigation?
    ) -> Bool {
      let failure = error as NSError
      let cancelled = failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled
      // WebKit's policy-change error is expected only after we handed this load to an app.
      let interrupted =
        appHandoffPending && failure.domain == "WebKitErrorDomain"
        && failure.code == 102
      guard cancelled || interrupted else { return false }
      if appHandoffPending {
        publish(webView, navigation: navigation, isTerminal: true)
        appHandoffPending = false
      }
      if let navigation { navigationContexts[ObjectIdentifier(navigation)] = nil }
      return true
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      publish(
        webView,
        navigation: nil,
        errorDescription: "The browser rendering process stopped unexpectedly."
      )
    }

    func publish(
      _ webView: WKWebView,
      navigation: WKNavigation?,
      errorDescription: String? = nil,
      isTerminal: Bool = false
    ) {
      guard isActive else { return }
      let key = navigation.map(ObjectIdentifier.init)
      let context =
        key.flatMap { navigationContexts[$0] }
        ?? (requestedRevision, requestedURL)
      if isTerminal, let key { navigationContexts[key] = nil }
      let url = webView.url?.absoluteString ?? context.requestedURL
      report(
        BrowserPageReport(
          url: url,
          title: webView.title,
          canGoBack: webView.backForwardList.backList.contains {
            BrowserHistoryNavigation.isPage($0.url)
          },
          canGoForward: webView.backForwardList.forwardList.contains {
            BrowserHistoryNavigation.isPage($0.url)
          },
          isLoading: isTerminal ? false : webView.isLoading,
          errorMessage: errorDescription,
          expectedRevision: context.revision
        ))
    }

  }
}

/// The agent's visible pointer on a browser page. It glides to each element before the agent
/// clicks or types, pulses on a click, and fades once the agent stops. It is a subview of the
/// WKWebView, so it follows the page in every layout, never appears in the agent's own page
/// screenshots (those capture web content only), and lets the person's mouse pass through.
@MainActor
final class BrowserAgentCursor {
  private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  @Observable final class Model {
    var pressCount = 0
  }

  /// The hosting frame leaves room for the click ring around the arrow's tip.
  static let frameSize = CGSize(width: 96, height: 64)
  static let tip = CGPoint(x: 22, y: 22)

  private let model = Model()
  private var host: NSView?
  private var hideTask: Task<Void, Never>?

  func move(toPagePoint pagePoint: CGPoint, in webView: WKWebView) async {
    hideTask?.cancel()
    let target = Self.viewPoint(pagePoint, in: webView)
    let origin = NSPoint(
      x: target.x - Self.tip.x,
      y: webView.isFlipped
        ? target.y - Self.tip.y : target.y - (Self.frameSize.height - Self.tip.y))
    let host = hostView(in: webView)
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if host.alphaValue < 0.05 || reduceMotion {
      host.setFrameOrigin(origin)
      await animate(duration: reduceMotion ? 0 : 0.18) { host.animator().alphaValue = 1 }
    } else {
      let distance = hypot(host.frame.origin.x - origin.x, host.frame.origin.y - origin.y)
      let duration = min(0.65, max(0.25, distance / 1_300))
      await animate(duration: duration) { host.animator().setFrameOrigin(origin) }
    }
    // A brief settle so the person sees where it landed before the action happens.
    try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 120))
    scheduleHide()
  }

  func press() {
    model.pressCount += 1
    scheduleHide()
  }

  /// Sends a real left click through WebKit at a page (CSS) point. Returns false when the page
  /// is not in a window, in which case the caller falls back to scripted events.
  static func nativeClick(atPagePoint pagePoint: CGPoint, in webView: WKWebView) -> Bool {
    guard let window = webView.window else { return false }
    let location = webView.convert(viewPoint(pagePoint, in: webView), to: nil)
    let time = ProcessInfo.processInfo.systemUptime
    func event(_ type: NSEvent.EventType, _ offset: TimeInterval, clicks: Int, pressure: Float)
      -> NSEvent?
    {
      NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [], timestamp: time + offset,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
        pressure: pressure)
    }
    guard let move = event(.mouseMoved, 0, clicks: 0, pressure: 0),
      let down = event(.leftMouseDown, 0.01, clicks: 1, pressure: 1),
      let up = event(.leftMouseUp, 0.07, clicks: 1, pressure: 0)
    else { return false }
    webView.mouseMoved(with: move)
    webView.mouseDown(with: down)
    webView.mouseUp(with: up)
    return true
  }

  private static func viewPoint(_ pagePoint: CGPoint, in webView: WKWebView) -> CGPoint {
    let scale = webView.pageZoom * webView.magnification
    let y = pagePoint.y * scale
    return CGPoint(x: pagePoint.x * scale, y: webView.isFlipped ? y : webView.bounds.height - y)
  }

  private func hostView(in webView: WKWebView) -> NSView {
    if let host, host.superview === webView { return host }
    host?.removeFromSuperview()
    let view = PassthroughHostingView(rootView: BrowserAgentCursorShape(model: model))
    view.frame = NSRect(origin: .zero, size: Self.frameSize)
    view.wantsLayer = true
    view.alphaValue = 0
    webView.addSubview(view)
    host = view
    return view
  }

  private func scheduleHide() {
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      // Matches the page glow: the cursor stays through the agent's thinking gaps.
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled, let host = self?.host else { return }
      await self?.animate(duration: 0.6) { host.animator().alphaValue = 0 }
    }
  }

  private func animate(duration: TimeInterval, _ changes: @escaping () -> Void) async {
    await withCheckedContinuation { continuation in
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        changes()
      } completionHandler: {
        continuation.resume()
      }
    }
  }
}

/// A pointer arrow in the agent glow's cyan-to-blue, with an Otto tag so it is never mistaken
/// for the person's own cursor, and a ring that expands from the tip on each click.
struct BrowserAgentCursorShape: View {
  let model: BrowserAgentCursor.Model
  /// True once the ring has finished expanding (and is invisible); a click resets it.
  @State private var ring = true

  var body: some View {
    ZStack(alignment: .topLeading) {
      Circle()
        .stroke(Color(red: 0.30, green: 0.55, blue: 1.0), lineWidth: 2)
        .frame(width: 36, height: 36)
        .scaleEffect(ring ? 1 : 0.2)
        .opacity(ring ? 0 : 0.9)
        .position(BrowserAgentCursor.tip)
      arrow
        .offset(x: BrowserAgentCursor.tip.x, y: BrowserAgentCursor.tip.y)
      HStack(spacing: 3) {
        OttoMark(size: 13)
        Text("Otto")
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(Color(red: 0.11, green: 0.12, blue: 0.16))
      }
      .padding(.leading, 4)
      .padding(.trailing, 7)
      .padding(.vertical, 2)
      .background(.white, in: Capsule())
      .overlay(
        Capsule().stroke(
          LinearGradient(
            colors: [
              Color(red: 0.38, green: 0.86, blue: 0.95), Color(red: 0.30, green: 0.55, blue: 1.0),
            ],
            startPoint: .leading, endPoint: .trailing),
          lineWidth: 1.5)
      )
      .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
      .offset(x: BrowserAgentCursor.tip.x + 16, y: BrowserAgentCursor.tip.y + 20)
    }
    .frame(
      width: BrowserAgentCursor.frameSize.width, height: BrowserAgentCursor.frameSize.height,
      alignment: .topLeading
    )
    .onChange(of: model.pressCount) { _, _ in
      var reset = Transaction()
      reset.disablesAnimations = true
      withTransaction(reset) { ring = false }
      Task { @MainActor in
        withAnimation(.easeOut(duration: 0.45)) { ring = true }
      }
    }
    .accessibilityHidden(true)
  }

  private var arrow: some View {
    let shape = AgentArrow()
    return
      shape
      .fill(
        LinearGradient(
          colors: [
            Color(red: 0.38, green: 0.86, blue: 0.95), Color(red: 0.30, green: 0.55, blue: 1.0),
          ],
          startPoint: .topLeading, endPoint: .bottomTrailing)
      )
      .overlay(shape.stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round)))
      .frame(width: 16, height: 23)
      .shadow(color: .black.opacity(0.3), radius: 2.5, y: 1.5)
  }
}

/// The classic pointer silhouette with its tip at the origin.
private struct AgentArrow: Shape {
  func path(in rect: CGRect) -> Path {
    let sx = rect.width / 13
    let sy = rect.height / 19
    let points: [(Double, Double)] = [
      (0, 0), (0, 16), (4, 12.4), (6.8, 18.6), (9.4, 17.5), (6.7, 11.5), (12, 11.5),
    ]
    var path = Path()
    path.move(to: CGPoint(x: points[0].0 * sx, y: points[0].1 * sy))
    for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0 * sx, y: point.1 * sy)) }
    path.closeSubpath()
    return path
  }
}

/// A soft light that bleeds inward from the page edges while an agent is reading or operating
/// it: cool cyan-to-blue, slowly circulating, brighter while the agent acts. It is clipped to the
/// page so nothing spills over neighbouring chrome, and it never intercepts input.
struct BrowserAgentControlAura: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let phase: BrowserAgentControlPhase
  let cornerRadius: Double
  let scale: Double

  var body: some View {
    TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      let rotation = reduceMotion ? 0.0 : time.truncatingRemainder(dividingBy: 8) / 8 * 360
      let breath = reduceMotion ? 1.0 : 0.85 + 0.15 * sin(time * 2 * .pi / 2.8)
      let intensity = (phase == .acting ? 1.0 : 0.85) * breath
      let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      let colors = AngularGradient(
        colors: [cyan, blue, violet, cyan, blue, cyan],
        center: .center,
        angle: .degrees(rotation)
      )
      // Normal blending, not additive: additive light vanishes on white pages, which are most
      // of the web.
      ZStack {
        // Wide, heavily blurred band: the glow that washes in from the edges.
        shape
          .strokeBorder(colors, lineWidth: 34 * scale)
          .blur(radius: 16 * scale)
          .opacity(0.8 * intensity)
        // Tighter inner band gives the light a defined source at the rim.
        shape
          .strokeBorder(colors, lineWidth: 10 * scale)
          .blur(radius: 5 * scale)
          .opacity(0.95 * intensity)
        // Solid rim.
        shape
          .strokeBorder(colors, lineWidth: 3 * scale)
          .opacity(intensity)
      }
      .clipShape(shape)
    }
    .accessibilityHidden(true)
  }

  private var cyan: Color { Color(red: 0.38, green: 0.86, blue: 0.95) }
  private var blue: Color { Color(red: 0.30, green: 0.55, blue: 1.0) }
  private var violet: Color {
    phase == .acting ? Color(red: 0.55, green: 0.48, blue: 1.0) : palette.cyan
  }
}

struct BrowserPageReport {
  var url: String
  var title: String?
  var canGoBack: Bool
  var canGoForward: Bool
  var isLoading: Bool
  var errorMessage: String?
  var expectedRevision: Int
}

private func normalizedBrowserDestination(_ value: String) -> String? {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return BrowserDefaults.startURL }
  if BrowserDefaults.isStartURL(trimmed) { return BrowserDefaults.startURL }

  let looksLikeAddress =
    trimmed.contains("://")
    || trimmed.hasPrefix("localhost")
    || trimmed.contains(".") && !trimmed.contains(" ")
  guard looksLikeAddress else {
    var search = URLComponents(string: "https://www.google.com/search")
    search?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
    return search?.url?.absoluteString
  }

  let scheme = trimmed.hasPrefix("localhost") ? "http" : "https"
  let normalized = trimmed.contains("://") ? trimmed : "\(scheme)://\(trimmed)"
  guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased())
  else { return nil }
  return url.absoluteString
}

private func isLocalBrowserURL(_ value: String) -> Bool {
  guard let host = URL(string: value)?.host?.lowercased() else { return false }
  return ["localhost", "127.0.0.1", "::1"].contains(host)
}

private func displayedBrowserAddress(_ value: String) -> String {
  value == BrowserDefaults.blankURL || BrowserDefaults.isStartURL(value) ? "" : value
}

/// Hands a link that asked for a new window from the page's web view to the browser view that
/// owns the tab list. Several views can show one browser node, so only the first claim acts.
@MainActor
struct BrowserLinkTabRequest {
  static let name = Notification.Name("OttoBrowserLinkTabRequest")
  private static var claimed: Set<UUID> = []
  let id: UUID
  let nodeID: UUID
  let url: String

  static func post(nodeID: UUID, url: String) {
    NotificationCenter.default.post(
      name: name, object: nil,
      userInfo: ["id": UUID(), "nodeID": nodeID, "url": url])
  }

  init?(notification: Notification) {
    guard let id = notification.userInfo?["id"] as? UUID,
      let nodeID = notification.userInfo?["nodeID"] as? UUID,
      let url = notification.userInfo?["url"] as? String
    else { return nil }
    self.id = id
    self.nodeID = nodeID
    self.url = url
  }

  static func claim(_ id: UUID) -> Bool { claimed.insert(id).inserted }
}

/// Shared by toolbar history and WebKit's swipe-navigation policy.
enum BrowserHistoryNavigation {
  static func isPage(_ url: URL) -> Bool {
    !OttoNames.isAppURLScheme(url.scheme) && url.absoluteString != BrowserDefaults.blankURL
  }
}
