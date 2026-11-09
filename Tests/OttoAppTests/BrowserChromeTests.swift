import AppKit
import Foundation
import OttoBrowser
import OttoModels
import SwiftUI
import Testing

@testable import OttoApp

@Suite("Browser in Chat")
struct BrowserChromeTests {
  @Test @MainActor func pageMessageNamesTheActivePageTabsAndNode() {
    let active = BrowserTab(title: "Clay pricing", url: "https://www.clay.com/pricing")
    let other = BrowserTab(title: "Apollo — Pricing", url: "https://www.apollo.io/pricing")
    let start = BrowserTab(title: "New Tab", url: BrowserDefaults.startURL)
    var node = OttoNode(
      kind: .browser, displayName: "Browser", subtitle: "OTTO BROWSER",
      frame: WorldRect(x: 0, y: 0, width: 800, height: 600), zIndex: 1)
    node.browserSession = BrowserSession(tabs: [active, other, start], activeTabID: active.id)

    let message = ChatBrowserPlace<EmptyView, EmptyView>.message("Compare these", browser: node)

    // The page details ride in Otto's hidden context envelope; the person sees only their words.
    #expect(PromptSubmission.originalUserText(message) == "Compare these")
    #expect(message.contains("Active tab: Clay pricing — https://www.clay.com/pricing"))
    #expect(message.contains("- Apollo — Pricing — https://www.apollo.io/pricing"))
    // Otto's own start page is not a page an agent can read.
    #expect(!message.contains(BrowserDefaults.startURL))
    #expect(message.contains(node.id.uuidString))
    #expect(message.contains("Ask before submitting"))
  }

  @Test func newTabBoxGuessesWhatThePersonMeant() {
    typealias Surface = OttoStartSurface
    #expect(Surface.choices(for: "") == [])
    #expect(Surface.choices(for: "clay.com") == [.open("https://clay.com"), .ask, .search])
    #expect(Surface.choices(for: "localhost:3000").first == .open("http://localhost:3000"))
    #expect(Surface.choices(for: "https://x.com/home").first == .open("https://x.com/home"))
    #expect(Surface.choices(for: "what is clay").first == .ask)
    #expect(Surface.choices(for: "best crm for startups in 2026").first == .ask)
    #expect(Surface.choices(for: "pricing?").first == .ask)
    #expect(Surface.choices(for: "weather london") == [.search, .ask])
    #expect(Surface.choices(for: "v1.2") == [.search, .ask])
    #expect(Surface.searchURL("a&b c").contains("q=a%26b%20c"))
  }

  @Test @MainActor func newTabQuestionsTellOttoToResearch() {
    let blank = BrowserTab()
    var node = OttoNode(
      kind: .browser, displayName: "Browser", subtitle: "OTTO BROWSER",
      frame: WorldRect(x: 0, y: 0, width: 800, height: 600), zIndex: 1)
    node.browserSession = BrowserSession(tabs: [blank], activeTabID: blank.id)
    let message = ChatBrowserPlace<EmptyView, EmptyView>.message("best CRMs", browser: node)
    #expect(message.contains("web research assistant"))
    #expect(message.contains("Only open a site in this browser when the request needs it"))
    #expect(PromptSubmission.originalUserText(message) == "best CRMs")
  }

  @Test func eachBrowserGetsItsOwnHelperKey() {
    let first = UUID()
    let second = UUID()
    #expect(ChatBrowserPlace<EmptyView, EmptyView>.sessionKey(first) == "browser:\(first)")
    #expect(
      ChatBrowserPlace<EmptyView, EmptyView>.sessionKey(first)
        != ChatBrowserPlace<EmptyView, EmptyView>.sessionKey(second))
  }

  @Test func browserIsAChatPlace() {
    #expect(ChatSurfaceDestination(rawValue: "Browser") == .browser)
    #expect(ChatSurfaceDestination.browser.title == "Browser")
  }

  @Test func allTabsMenuListsEveryTabAndMarksTheActiveOne() {
    var tabs = (1...8).map { BrowserTab(title: "Tab \($0)", url: "https://example.com/\($0)") }
    tabs[4] = BrowserTab(title: "", url: BrowserDefaults.blankURL)
    let items = BrowserAllTabsItem.items(tabs: tabs, activeTabID: tabs[6].id)
    #expect(items.count == 8)
    #expect(items.map(\.id) == tabs.map(\.id))
    #expect(
      items.map(\.title)
        == ["Tab 1", "Tab 2", "Tab 3", "Tab 4", "New Tab", "Tab 6", "Tab 7", "Tab 8"])
    #expect(items.filter(\.isActive).map(\.id) == [tabs[6].id])
  }

  @Test func tabStripOverflowsOnlyWhenTabsExceedTheRoom() {
    #expect(!OttoBrowserTabStrip.tabsOverflow(contentWidth: 500, containerWidth: 600))
    #expect(!OttoBrowserTabStrip.tabsOverflow(contentWidth: 600, containerWidth: 600))
    #expect(!OttoBrowserTabStrip.tabsOverflow(contentWidth: 600.4, containerWidth: 600))
    #expect(OttoBrowserTabStrip.tabsOverflow(contentWidth: 601, containerWidth: 600))
    // Nothing is measured yet: never show the control for an unlaid-out strip.
    #expect(!OttoBrowserTabStrip.tabsOverflow(contentWidth: 900, containerWidth: 0))
  }

  /// Eight tabs in a strip too narrow for them overflow their scroll view and grow the
  /// all-tabs chevron; two tabs with room to spare do neither, so the chrome stays as it was
  /// for people who never overflow. SwiftUI backs `ScrollView` and `Menu` with AppKit views on
  /// macOS, so the hosted strip is probed through them (its accessibility tree is not built
  /// for in-process callers).
  @Test @MainActor func overflowControlAppearsOnlyWhenTabsDoNotFit() async throws {
    _ = NSApplication.shared
    var menus: [Int: Int] = [:]
    for (count, width, expected) in [(8, 760, true), (2, 1400, false)] {
      let tabs = (1...count).map {
        BrowserTab(title: "Open tab \($0)", url: "https://example.com/\($0)")
      }
      let session = BrowserSession(tabs: tabs, activeTabID: tabs[0].id)
      let probe = try await Self.probe(Self.strip(session), width: width)
      #expect(probe.overflows == expected, "\(count) tabs at \(width)pt")
      menus[width] = probe.menus
    }
    // The overflowing strip carries exactly one menu more: the all-tabs control. (The other
    // is the Passwords menu, present at both widths.)
    #expect(menus[760] == (menus[1400] ?? 0) + 1)
    #expect((menus[1400] ?? 0) >= 1)
  }

  @Test @MainActor func drawerTabsStayReachableAtNarrowWidths() async throws {
    _ = NSApplication.shared
    for (count, width, expectedOverflow) in [(8, 420, true), (2, 900, false)] {
      let tabs = (1...count).map {
        BrowserTab(title: "Page \($0)", url: "https://example.com/\($0)")
      }
      let session = BrowserSession(tabs: tabs, activeTabID: tabs.last!.id)
      let view = OttoBrowserPanelTabs(
        session: session, selectTab: { _ in }, closeTab: { _ in }, newTab: {}
      ).environment(\.ottoPalette, OttoPalette(theme: OttoThemeCatalog.theme(id: "shorelight")))
      let probe = try await Self.probe(view, width: width)
      #expect(probe.overflows == expectedOverflow)
      #expect(probe.menus >= 1)  // The all-tabs menu is always reachable outside the scroller.
    }
  }

  @MainActor private static func strip(_ session: BrowserSession) -> some View {
    OttoBrowserTabStrip(
      address: .constant(session.activeTab?.url ?? ""), addressFocusRequest: 0,
      session: session, state: nil, pinned: [], aiVisible: false,
      navigate: { _ in }, selectTab: { _ in }, closeTab: { _ in }, newTab: {},
      submit: {}, goBack: {}, goForward: {}, reloadOrStop: {}, showImport: {},
      toggleAI: {}
    )
    .environment(\.ottoPalette, OttoPalette(theme: OttoThemeCatalog.fieldNotes))
  }

  /// Hosts `view` at `width` in an offscreen window and reports whether its widest scroll
  /// view (the tab row) overflows, and how many menu buttons it holds.
  @MainActor private static func probe(
    _ view: some View, width: Int
  ) async throws -> (overflows: Bool, menus: Int) {
    let host = NSHostingView(rootView: view.frame(width: CGFloat(width), height: 44))
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: width, height: 44),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    var views: [NSView] = []
    func collect(_ view: NSView) {
      views.append(view)
      view.subviews.forEach(collect)
    }
    collect(host)
    let tabRow = try #require(
      views.compactMap { $0 as? NSScrollView }
        .max { ($0.documentView?.frame.width ?? 0) < ($1.documentView?.frame.width ?? 0) })
    let overflows = OttoBrowserTabStrip.tabsOverflow(
      contentWidth: tabRow.documentView?.frame.width ?? 0,
      containerWidth: tabRow.contentView.bounds.width)
    let menus = views.filter { String(describing: type(of: $0)).contains("PopupButton") }
    return (overflows, menus.count)
  }

  /// Opt-in rendering of the new chrome in the default light theme and a dark one.
  @Test @MainActor func renderChrome() async throws {
    guard let directory = ProcessInfo.processInfo.environment["OTTO_BROWSER_CHROME_SNAPSHOTS"]
    else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let tabs = [
      BrowserTab(title: "Clay pricing — Plans", url: "https://www.clay.com/pricing"),
      BrowserTab(title: "Apollo — Pricing", url: "https://www.apollo.io/pricing"),
      BrowserTab(title: "Common Room — Plans", url: "https://www.commonroom.io/pricing"),
      BrowserTab(title: "maxtrigify/Muse · PR #41", url: "https://github.com/maxtrigify/Muse"),
    ]
    let session = BrowserSession(tabs: tabs, activeTabID: tabs[0].id)
    let state = BrowserRuntimeState(
      nodeID: UUID(), url: tabs[0].url, title: tabs[0].title, canGoBack: true,
      tabs: tabs.map { BrowserRuntimeTab(id: $0.id, url: $0.url, title: $0.title) },
      activeTabID: tabs[0].id)
    var driving = state
    driving.agentControlPhase = .acting

    for theme in [
      OttoThemeCatalog.theme(id: "shorelight"), OttoThemeCatalog.theme(id: "highfell"),
      OttoThemeCatalog.fieldNotes,
    ] {
      let palette = OttoPalette(theme: theme)
      let view = VStack(spacing: 0) {
        OttoBrowserTabStrip(
          address: .constant("clay.com/pricing"), addressFocusRequest: 0, session: session,
          state: state, pinned: OttoBrowserDefaults.bookmarks, aiVisible: false,
          navigate: { _ in }, selectTab: { _ in }, closeTab: { _ in }, newTab: {},
          submit: {}, goBack: {}, goForward: {}, reloadOrStop: {}, showImport: {},
          toggleAI: {})
        Rectangle().fill(Color.white).frame(height: 120)
          .clipShape(RoundedRectangle(cornerRadius: 10)).padding([.horizontal, .bottom], 9)
        OttoBrowserCompactBar(
          address: .constant("https://www.linkedin.com/feed/"), addressFocusRequest: 0,
          state: driving, goBack: {}, goForward: {}, reloadOrStop: {}, submit: {}
        )
        .frame(width: 660)
        OttoBrowserPanelTabs(
          session: session, selectTab: { _ in }, closeTab: { _ in }, newTab: {}
        )
        .frame(width: 660)
        HStack(spacing: 18) {
          ForEach([BrowserAgentControlPhase.observing, .acting], id: \.self) { phase in
            Rectangle().fill(Color.white).frame(width: 560, height: 340)
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .overlay {
                BrowserAgentControlAura(phase: phase, cornerRadius: 10, scale: 1)
              }
          }
        }
        .padding(9)
      }
      .environment(\.ottoPalette, palette)
      .frame(width: 1200)
      .background(palette.surface)

      let host = NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true))
      let window = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      window.setContentSize(NSSize(width: 1200, height: host.fittingSize.height))
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("chrome-\(theme.id).png"))
    }

    // Eight tabs in 900pt: the strip fades at its right edge and grows the all-tabs chevron.
    do {
      let many = (1...8).map {
        BrowserTab(title: "Open tab \($0) — a long title", url: "https://example.com/\($0)")
      }
      let palette = OttoPalette(theme: OttoThemeCatalog.theme(id: "highfell"))
      let view = OttoBrowserTabStrip(
        address: .constant("example.com/3"), addressFocusRequest: 0,
        session: BrowserSession(tabs: many, activeTabID: many[2].id), state: nil,
        pinned: [], aiVisible: false, navigate: { _ in }, selectTab: { _ in },
        closeTab: { _ in }, newTab: {}, submit: {}, goBack: {}, goForward: {},
        reloadOrStop: {}, showImport: {}, toggleAI: {}
      )
      .environment(\.ottoPalette, palette)
      .frame(width: 900, height: 44)
      .background(palette.surface)
      let host = NSHostingView(rootView: view)
      let window = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 44),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(250))
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("chrome-overflow.png"))
    }

    for (name, text) in [
      ("otto-new-tab-empty", ""), ("otto-new-tab-typed", "what is clay"),
      ("otto-new-tab-history", "linedin"),
    ] {
      let historyDefaults = UserDefaults(suiteName: "browser-chrome-snapshot")!
      historyDefaults.removePersistentDomain(forName: "browser-chrome-snapshot")
      let history = BrowserHistoryStore(defaults: historyDefaults)
      history.record(url: "https://www.linkedin.com/feed/", title: "LinkedIn")
      let page = OttoStartSurface(
        query: .constant(text), focusRequest: 0, navigate: { _ in }, askOtto: { _ in },
        history: history
      )
      .environment(\.ottoPalette, OttoPalette(theme: OttoThemeCatalog.theme(id: "highfell")))
      .frame(width: 1100, height: 620)
      let host = NSHostingView(rootView: page)
      let window = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 620),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(250))
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    // ImageRenderer draws blur faithfully, unlike cacheDisplay, so the agent glow is rendered
    // on its own over a white page and a dark page.
    let glow = HStack(spacing: 18) {
      ForEach([Color.white, Color(white: 0.1)], id: \.self) { page in
        ForEach([BrowserAgentControlPhase.observing, .acting], id: \.self) { phase in
          Rectangle().fill(page).frame(width: 420, height: 280)
            .overlay { BrowserAgentControlAura(phase: phase, cornerRadius: 10, scale: 1) }
            .overlay {
              BrowserAgentCursorShape(model: BrowserAgentCursor.Model())
                .scaleEffect(2, anchor: .topLeading)
                .frame(width: 192, height: 128, alignment: .topLeading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
      }
    }
    .padding(18)
    .background(Color(white: 0.85))
    .environment(\.ottoPalette, OttoPalette(theme: OttoThemeCatalog.fieldNotes))
    let renderer = ImageRenderer(content: glow)
    renderer.scale = 1
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("agent-glow.png"))
  }
}
