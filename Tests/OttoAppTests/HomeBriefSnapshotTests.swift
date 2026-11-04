import AppKit
import Foundation
import OttoCore
import OttoModels
import OttoSecurity
import OttoServices
import OttoTools
import PDFKit
import SwiftUI
import Testing
import WebKit

@testable import OttoApp

/// Opt-in visual check: renders the real Home into PNGs for review. Set
/// OTTO_HOME_SNAPSHOT_DIR and OTTO_HOME_SNAPSHOT_WORKSPACE (a seeded workspace) to run it.
@Suite("Home brief snapshots")
@MainActor
struct HomeBriefSnapshotTests {
  @Test func renderHome() throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_HOME_SNAPSHOT_DIR"], let seed = env["OTTO_HOME_SNAPSHOT_WORKSPACE"]
    else { return }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "home-snap-\(UUID())")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: seed), to: workspace)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    let support = workspace.appending(path: "support")
    let registry = OttoProfileRegistry(
      applicationSupport: support, originalWorkspacePath: workspace.path)
    let services = ApplicationServices(
      store: canvas, workspacePath: workspace.path, profiles: registry)
    _ = try registry.create(
      name: "Personal", symbol: "heart", folder: workspace.appending(path: "personal"))
    let sizes: [(String, CGSize)] = [
      ("wide", CGSize(width: 1440, height: 2300)),
      ("narrow", CGSize(width: 860, height: 2800)),
    ]
    for profile in services.dailyBrief.profiles {
      try services.dailyBrief.selectProfile(profile.id)
      for (name, size) in sizes {
        let view = PersonalHomeView(
          store: canvas, services: services, activity: services.botActivity,
          brief: services.dailyBrief, draft: .constant(""), provider: .constant(.claudeCode),
          conversationTarget: .constant(.newSession), openMarkdown: { _ in },
          openBot: { _ in }, openAgent: { _ in }, openCloud: {},
          openLibrary: { _ in }, hireBot: {}, submit: { _, _, _ in })
        try render(view, size: size, to: "\(output)/\(profile.name)-\(name).png")
      }
    }
    // Home over real theme artwork, light and dark, as the window draws it.
    for themeID in ["silverbough", "halcyon"] {
      canvas.dispatch(.setTheme(themeID))
      let theme = OttoThemeCatalog.theme(id: themeID)
      let view = ZStack {
        ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
        PersonalHomeView(
          store: canvas, services: services, activity: services.botActivity,
          brief: services.dailyBrief, draft: .constant(""), provider: .constant(.claudeCode),
          conversationTarget: .constant(.newSession), openMarkdown: { _ in },
          openBot: { _ in }, openAgent: { _ in }, openCloud: {},
          openLibrary: { _ in }, hireBot: {}, submit: { _, _, _ in })
      }
      .environment(\.ottoPalette, OttoPalette(theme: theme))
      try render(
        view, size: CGSize(width: 1280, height: 820), to: "\(output)/home-\(themeID).png",
        light: theme.isLightAppearance)
    }
    // A profile with nothing to say keeps the ordinary hero and offers setup instead.
    try services.dailyBrief.createProfile(name: "Side project", projectIDs: [UUID()])
    let quiet = PersonalHomeView(
      store: canvas, services: services, activity: services.botActivity,
      brief: services.dailyBrief, draft: .constant(""), provider: .constant(.claudeCode),
      conversationTarget: .constant(.newSession), openMarkdown: { _ in },
      openBot: { _ in }, openAgent: { _ in }, openCloud: {},
      openLibrary: { _ in }, hireBot: {}, submit: { _, _, _ in })
    try render(quiet, size: CGSize(width: 1440, height: 1100), to: "\(output)/empty.png")
    let newProfile = NewProfileSheet(services: services, registry: registry) { _ in }
    try render(newProfile, size: CGSize(width: 520, height: 760), to: "\(output)/new-profile.png")
    let settings = ProfileSettingsSheet(
      services: services, registry: registry, profileID: registry.profiles[0].id, onFinish: {})
    try render(
      settings, size: CGSize(width: 480, height: 640), to: "\(output)/profile-settings.png")
    // As presented from the header, which sets white text over the photo: the sheet must
    // still read in light mode.
    let presented = settings.foregroundStyle(Color(nsColor: .labelColor))
      .foregroundStyle(.white.opacity(0.85))
    try render(
      presented, size: CGSize(width: 480, height: 640),
      to: "\(output)/profile-settings-light.png", light: true)
  }

  /// Home with agent-made cards: numbers with their change, a list kept fresh by an
  /// automation, and a short note, over light and dark artwork.
  @Test func renderHomeCards() throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_HOME_SNAPSHOT_DIR"], let seed = env["OTTO_HOME_SNAPSHOT_WORKSPACE"]
    else { return }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "home-cards-\(UUID())")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: seed), to: workspace)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    var socials = HomeCard(title: "Social followers", style: .metrics, updatedBy: "Claude Code")
    for day in [(12_310, 4_020, 880), (12_402, 4_051, 902), (12_480, 4_049, 941)] {
      socials.apply(
        rows: [
          .init(label: "LinkedIn", value: day.0.formatted()),
          .init(label: "Reddit", value: day.1.formatted()),
          .init(label: "Substack", value: day.2.formatted()),
        ], text: nil, mode: .replace, by: "Claude Code")
    }
    try services.homeCards.add(socials)
    let routine = try services.routines.save(
      Routine(
        name: "Morning meetings", instruction: "List today's meetings",
        trigger: .schedule(cron: "30 7 * * 1-5", intervalSeconds: nil),
        target: .spawnProvider(provider: "Claude Code")))
    var meetings = HomeCard(title: "Today's meetings", style: .list, automationID: routine.id)
    meetings.apply(
      rows: [
        .init(label: "Acme pricing call", value: "11:00", detail: "Jo wants a decision on seats"),
        .init(label: "Design review", value: "14:30", detail: "Home cards and automations"),
        .init(label: "1:1 with Sam", value: "16:00"),
      ], text: nil, mode: .replace, by: routine.name)
    try services.homeCards.add(meetings)
    try services.homeCards.add(
      HomeCard(
        title: "Launch note", style: .text,
        text: "**Otto 0.2** ships Friday. Changelog draft is in Files; Woody is checking the DMG."))
    for themeID in ["halcyon", "silverbough"] {
      canvas.dispatch(.setTheme(themeID))
      let theme = OttoThemeCatalog.theme(id: themeID)
      let view = ZStack {
        ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
        PersonalHomeView(
          store: canvas, services: services, activity: services.botActivity,
          brief: services.dailyBrief, draft: .constant("hello, can you prep my 11:00?"),
          provider: .constant(.claudeCode),
          conversationTarget: .constant(.newSession), openMarkdown: { _ in },
          openBot: { _ in }, openAgent: { _ in }, openCloud: {},
          openLibrary: { _ in }, hireBot: {}, submit: { _, _, _ in })
      }
      .environment(\.ottoPalette, OttoPalette(theme: theme))
      try render(
        view, size: CGSize(width: 1280, height: 1500), to: "\(output)/cards-\(themeID).png",
        light: theme.isLightAppearance)
    }
  }

  /// Home with drafts waiting for review: a tip of the day to post once approved, and one
  /// mid-conversation, over Shorelight. Also the automation editor's "Check with you first?".
  @Test func renderHomeReviews() throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_HOME_SNAPSHOT_DIR"] else { return }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "home-reviews-\(UUID())")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let tip = try services.routines.save(
      Routine(
        name: "Tip of the day", instruction: "Write one practical Otto tip for the community",
        trigger: .schedule(cron: "0 9 * * *", intervalSeconds: nil),
        target: .spawnProvider(provider: "Claude Code"), reviewOnHome: true,
        afterApproval: "Post it in #tips on the Otto Discord"))
    try services.homeReviews.add(
      HomeReview(
        title: "Tip of the day", requester: "Tip of the day",
        draft: """
          💡 Tip of the day: press ⌃⌥Space anywhere on your Mac and just say what you want. \
          Otto picks the right agent, and you can keep working while it runs.
          """,
        afterApproval: tip.afterApproval, agentNodeID: UUID(), routineID: tip.id,
        createdAt: .now.addingTimeInterval(-25 * 60)))
    try services.homeReviews.add(
      HomeReview(
        title: "Reply to Jo about seat pricing", requester: "Aria",
        draft:
          "Hi Jo, thanks for the call. We can do 40 seats at the team rate if you sign by Friday.",
        afterApproval: "Send it from my Gmail",
        notes: [
          .init(author: .person, text: "Can we mention the annual discount too?"),
          .init(author: .agent, text: "Updated the draft."),
        ],
        agentNodeID: UUID(), createdAt: .now.addingTimeInterval(-3 * 3600)))
    // A long Markdown report, like the nightly bug triage: it renders and scrolls in place.
    var report = """
      **Nightly triage, 4 Nov: one new bug (#54) has a fix (PR #56) that's tested and ready.** \
      Before you merge, see the decision below.

      **New since yesterday**

      | # | Title | Verdict | Commit | Tests |
      |---|---|---|---|---|
      | #54 | "OAuth session expired" | Fixed by PR #56 | `7a26ac4` | 2 new, pass |
      | #55 | Telegram drops photos | Needs info | — | — |

      **Decisions for you**
      1. Merge PR #56 now, or wait for the status fix.
      2. Reply to #55 asking for the bot logs.

      """
    for index in 1...12 {
      report += "- PR #\(56 + index): reviewed, tests pass on the nightly branch\n"
    }
    try services.homeReviews.add(
      HomeReview(
        title: "Nightly bug triage + fixes (Bug Fixer)", requester: "Bug Fixer", draft: report,
        agentNodeID: UUID(), createdAt: .now.addingTimeInterval(-2 * 3600)))
    for themeID in ["shorelight", "halcyon"] {
      canvas.dispatch(.setTheme(themeID))
      let theme = OttoThemeCatalog.theme(id: themeID)
      let view = ZStack {
        ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
        PersonalHomeView(
          store: canvas, services: services, activity: services.botActivity,
          brief: services.dailyBrief, draft: .constant(""), provider: .constant(.claudeCode),
          conversationTarget: .constant(.newSession), openMarkdown: { _ in },
          openBot: { _ in }, openAgent: { _ in }, openCloud: {},
          openLibrary: { _ in }, hireBot: {}, submit: { _, _, _ in })
      }
      .environment(\.ottoPalette, OttoPalette(theme: theme))
      try render(
        view, size: CGSize(width: 1280, height: 1300), to: "\(output)/reviews-\(themeID).png",
        light: theme.isLightAppearance)
    }
    let theme = OttoThemeCatalog.theme(id: "shorelight")
    let editor = AutomationEditor(services: services, target: .edit(tip), onFinish: { _ in })
      .environment(\.ottoPalette, OttoPalette(theme: theme))
    try render(
      editor.frame(height: 1180), size: CGSize(width: 620, height: 1180),
      to: "\(output)/reviews-editor.png",
      light: theme.isLightAppearance)
  }

  /// Dashboards and Documents with realistic content, for review.
  @Test func renderWorkPages() throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_HOME_SNAPSHOT_DIR"] else { return }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "work-\(UUID())")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    canvas.dispatch(.setTheme("halcyon"))
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let theme = OttoThemeCatalog.theme(id: "halcyon")
    let palette = OttoPalette(theme: theme)
    let chatPanel: (UUID) -> AnyView = { _ in
      AnyView(
        VStack(alignment: .leading, spacing: 10) {
          Text("You").font(.ottoDisplay(11).weight(.semibold))
          Text("Make the intro shorter").font(.ottoDisplay(12))
          Text("Claude Code").font(.ottoDisplay(11).weight(.semibold)).padding(.top, 8)
          Text("I suggested a tighter opening paragraph — accept it in the document.")
            .font(.ottoDisplay(12))
          Spacer()
        }.padding(14))
    }
    let starter: AssistantStarter = { _, _, _ in UUID() }

    // Dashboard with a number card, a line chart and a bar chart.
    let board = try services.homeCards.createDashboard(name: "Socials")
    _ = try services.homeCards.createDashboard(name: "Revenue")
    var followers = HomeCard(
      title: "Followers", style: .metrics, dashboardID: board.id,
      source: "LinkedIn profile page and reddit.com/user/max/about.json, read 9 Oct 08:00")
    followers.apply(
      rows: [.init(label: "LinkedIn", value: "12,480"), .init(label: "Reddit", value: "4,049")],
      text: nil, mode: .replace, by: "Claude Code")
    try services.homeCards.add(followers)
    var trend = HomeCard(
      title: "LinkedIn followers, last 7 days", style: .line, dashboardID: board.id)
    trend.apply(
      rows: zip(
        ["3 Oct", "4 Oct", "5 Oct", "6 Oct", "7 Oct", "8 Oct", "9 Oct"],
        ["12210", "12260", "12302", "12355", "12401", "12447", "12480"]
      ).map { HomeCardRow(label: $0, value: $1) }, text: nil, mode: .replace, by: "Claude Code")
    try services.homeCards.add(trend)
    var posts = HomeCard(title: "Engagement by post", style: .bar, dashboardID: board.id)
    posts.apply(
      rows: [
        .init(label: "Launch", value: "940"), .init(label: "Hiring", value: "420"),
        .init(label: "Demo", value: "610"), .init(label: "AMA", value: "280"),
      ], text: nil, mode: .replace, by: "Claude Code")
    try services.homeCards.add(posts)
    UserDefaults.standard.set(board.id.uuidString, forKey: "muse.dashboards.selected")
    services.office.setSession(UUID(), path: OfficeStore.dashboardKey(board.id))
    try render(
      DashboardsView(
        services: services, cards: services.homeCards, office: services.office,
        cardPalette: OttoPalette(theme: OttoThemeCatalog.aurora), start: starter,
        openAutomations: {}, conversation: chatPanel
      ).background(palette.surface).environment(\.ottoPalette, palette),
      size: CGSize(width: 1280, height: 900), to: "\(output)/dashboards.png")

    // The same dashboard after arranging: a full-width chart first, purple accent, one card
    // in its own colour, then the page in edit mode.
    try services.homeCards.update(id: trend.id) { $0.width = .full }
    try services.homeCards.update(id: posts.id) { $0.color = .orange }
    try services.homeCards.move(id: trend.id, to: followers.id)
    try services.homeCards.updateDashboard(id: board.id) {
      $0.accent = .purple
      $0.cardStyle = .frosted
    }
    try render(
      DashboardsView(
        services: services, cards: services.homeCards, office: services.office,
        cardPalette: OttoPalette(theme: OttoThemeCatalog.aurora), start: starter,
        openAutomations: {}, conversation: chatPanel
      ).background(palette.surface).environment(\.ottoPalette, palette),
      size: CGSize(width: 1280, height: 1000), to: "\(output)/dashboards-arranged.png")
    try render(
      DashboardsView(
        services: services, cards: services.homeCards, office: services.office,
        cardPalette: OttoPalette(theme: OttoThemeCatalog.aurora), start: starter,
        openAutomations: {}, conversation: chatPanel, editing: true
      ).background(palette.surface).environment(\.ottoPalette, palette),
      size: CGSize(width: 1280, height: 1000), to: "\(output)/dashboards-edit-mode.png")
    try render(
      ScrollView {
        HomeCardsView(
          cards: services.homeCards, services: services, dashboardID: board.id,
          minimumColumnWidth: 340, accent: .purple, editing: true, openAutomations: {}
        ).padding(32)
      }
      .environment(\.ottoPalette, OttoPalette(theme: OttoThemeCatalog.aurora))
      .environment(\.colorScheme, .dark)
      .environment(\.ottoGlassSmoke, 0.5)
      .background(palette.surface),
      size: CGSize(width: 1200, height: 760), to: "\(output)/dashboards-editing.png")

    // Documents: a doc with a pending suggestion, a sheet and a deck.
    let office = services.office
    let doc = try office.create(.document, title: "Q4 plan")
    try office.applyNow(
      .replaceAll(
        "# Q4 plan\nWe will **grow revenue** by focusing on three things this quarter.\n## Priorities\n- Ship Otto 0.2 with Documents and Dashboards\n- Hire two engineers\n- Double weekly active users"
      ), path: doc.path)
    try office.suggest(
      DocSuggestion(
        path: doc.path,
        change: .replace(
          find: "We will grow revenue by focusing on three things this quarter.",
          replace: "This quarter we grow revenue through three bets."),
        note: "Shorter, more direct opening", author: "Claude Code"))
    office.setSession(UUID(), path: doc.path)
    let sheet = try office.create(.spreadsheet, title: "Budget")
    var budget = Spreadsheet()
    for (key, value) in [
      "A1": "Item", "B1": "Monthly", "C1": "Yearly", "A2": "Rent", "B2": "1200",
      "C2": "=B2*12", "A3": "Food", "B3": "300", "C3": "=B3*12", "A4": "Software", "B4": "89",
      "C4": "=B4*12", "A5": "Total", "B5": "=SUM(B2:B4)", "C5": "=SUM(C2:C4)",
    ] { budget.set(key, value) }
    try office.saveSheet(budget, path: sheet.path, touched: ["B5", "C5"])
    // A second tab that reads the first, so the tab strip and cross-tab formulas show.
    try office.saveSheet(
      Spreadsheet(cells: [
        "A1": "Monthly spend", "B1": "=Sheet1!B5", "A2": "Yearly spend", "B2": "=SUM(Sheet1!C2:C4)",
      ]), path: sheet.path, tab: "Summary", touched: ["B1"])
    var tabbed = try office.loadWorkbook(path: sheet.path)
    try tabbed.renameTab(tabbed.tabs[0].id, to: "Costs")
    // Long text: one note runs on into empty cells, another sits in a taller, wrapping row.
    var costs = tabbed.tabs[0].sheet
    costs.set("D2", "Rent goes up 3% in March; landlord confirmed by email on 2 Oct.")
    costs.set("A7", "Notes")
    costs.set(
      "B7",
      "Software covers Figma, Linear and Notion. Cancel Notion if the team moves docs into Otto — that saves about 20 a month."
    )
    costs.columnWidths[1] = 220
    costs.rowHeights[6] = 92
    tabbed.setSheet(costs, for: tabbed.tabs[0].id)
    try office.saveWorkbook(tabbed, path: sheet.path)
    let deck = try office.create(.presentation, title: "Pitch")
    try office.saveDeck(
      Presentation(slides: [
        Slide(title: "Otto", bullets: ["Your personal OS"], layout: .title),
        Slide(
          title: "The problem", bullets: ["Ten apps, no memory", "Agents can't see your work"]),
        Slide(title: "What's next", layout: .section),
      ]), path: deck.path, touched: [])
    UserDefaults.standard.set("", forKey: "muse.documents.open")
    func documents(_ open: String) -> some View {
      UserDefaults.standard.set(open, forKey: "muse.documents.open")
      return DocumentsView(
        services: services, office: office, start: starter, conversation: chatPanel
      ).background(palette.surface).environment(\.ottoPalette, palette)
    }
    try render(documents(""), size: CGSize(width: 1280, height: 800), to: "\(output)/documents.png")
    try render(
      documents(doc.path), size: CGSize(width: 1400, height: 860), to: "\(output)/doc-editor.png")
    try render(
      documents(sheet.path), size: CGSize(width: 1400, height: 760),
      to: "\(output)/sheet-editor.png")
    try render(
      documents(deck.path), size: CGSize(width: 1400, height: 900),
      to: "\(output)/slides-editor.png")
    UserDefaults.standard.set("", forKey: "muse.documents.open")
    try XLSXWriter.data(for: budget, sheetName: "Budget").write(
      to: URL(fileURLWithPath: "\(output)/budget.xlsx"))
    try XLSXWriter.data(for: try office.loadWorkbook(path: sheet.path)).write(
      to: URL(fileURLWithPath: "\(output)/budget-tabs.xlsx"))
  }

  /// Shows what the live end-to-end agent run produced, in the real screens.
  @Test func renderEndToEndWorkspace() throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_HOME_SNAPSHOT_DIR"], let seeded = env["OTTO_E2E_WORKSPACE"]
    else { return }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "e2e-view-\(UUID())")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: seeded), to: workspace)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let palette = OttoPalette(theme: OttoThemeCatalog.theme(id: "halcyon"))
    let starter: AssistantStarter = { _, _, _ in UUID() }
    let panel: (UUID) -> EmptyView = { _ in EmptyView() }
    UserDefaults.standard.set("Documents/E2E brief.docx", forKey: "muse.documents.open")
    try render(
      DocumentsView(
        services: services, office: services.office, start: starter, conversation: panel
      )
      .background(palette.surface).environment(\.ottoPalette, palette),
      size: CGSize(width: 1400, height: 520), to: "\(output)/e2e-doc.png")
    UserDefaults.standard.set("", forKey: "muse.documents.open")
    UserDefaults.standard.set(
      services.homeCards.dashboards.first?.id.uuidString ?? "", forKey: "muse.dashboards.selected")
    try render(
      DashboardsView(
        services: services, cards: services.homeCards, office: services.office,
        cardPalette: OttoPalette(theme: OttoThemeCatalog.aurora), start: starter,
        openAutomations: {}, conversation: panel
      ).background(palette.surface).environment(\.ottoPalette, palette),
      size: CGSize(width: 1280, height: 620), to: "\(output)/e2e-dashboard.png")
  }

  /// The deck engine: every template slide, exports, and the slides editor.
  @Test func renderDeck() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_HOME_SNAPSHOT_DIR"] else { return }
    _ = NSApplication.shared
    var deck = Presentation(
      slides: DeckTemplates.all.map { Slide(title: "", html: $0.html) },
      theme: Presentation.Theme(rawValue: env["OTTO_DECK_THEME"] ?? "") ?? .midnight)
    if let file = env["OTTO_DECK_FILE"] {
      deck = try JSONDecoder().decode(
        Presentation.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
    } else {
      deck.slides[0].html = """
        <div class="backdrop aurora"></div>
        <div class="center stack"><div class="kicker" data-anim="fade">Series A · 2026</div>
        <h1 class="huge gradient-text" data-anim="up">Otto</h1>
        <p class="lead" data-anim="up" data-delay="150">The personal OS where agents do the busywork.</p></div>
        """
    }
    for (index, _) in deck.slides.enumerated() {
      let image = try #require(
        await DeckSnapshotter.shared.image(deck, index: index, width: 960))
      let tiff = try #require(image.tiffRepresentation)
      let png = try #require(
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: "\(output)/deck-\(index + 1).png"))
    }
    let pdf = await DeckSnapshotter.shared.pdf(deck)
    #expect(PDFDocument(data: pdf)?.pageCount == deck.slides.count)
    try pdf.write(to: URL(fileURLWithPath: "\(output)/deck.pdf"))
    let pptx = PPTXWriter.data(
      images: await DeckSnapshotter.shared.pngs(deck), notes: deck.slides.map(\.notes),
      title: "Otto")
    try pptx.write(to: URL(fileURLWithPath: "\(output)/deck.pptx"))
    let editable = await DeckSnapshotter.shared.editablePPTX(deck, title: "Otto")
    try editable.write(to: URL(fileURLWithPath: "\(output)/deck-editable.pptx"))
    try Data(DeckRenderer.page(deck, mode: .present, title: "Otto").utf8).write(
      to: URL(fileURLWithPath: "\(output)/deck.html"))
  }

  /// The slide fits a small editor view without drifting off-centre.
  @Test func renderSmallSlide() async throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_HOME_SNAPSHOT_DIR"] else { return }
    _ = NSApplication.shared
    let deck = Presentation(slides: [Slide(title: "", html: DeckTemplates.all[5].html)])
    for (name, size) in [
      ("small", CGSize(width: 640, height: 360)), ("odd", CGSize(width: 900, height: 420)),
    ] {
      let web = WKWebView(frame: CGRect(origin: .zero, size: size))
      let window = NSWindow(
        contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = web
      web.loadHTMLString(DeckRenderer.page(deck, indices: [0], mode: .edit), baseURL: nil)
      try await Task.sleep(for: .milliseconds(1_200))
      let image = try await web.takeSnapshot(configuration: nil)
      let tiff = try #require(image.tiffRepresentation)
      try NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(
        to: URL(fileURLWithPath: "\(output)/slide-\(name).png"))
    }
  }

  /// Theme photos must cover the whole window at any shape, not only the photo's own.
  @Test func backdropCoversOddWindowShapes() throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_HOME_SNAPSHOT_DIR"] else { return }
    let theme = OttoThemeCatalog.theme(id: "halcyon")
    for (name, size) in [
      ("tall", CGSize(width: 700, height: 1100)), ("wide", CGSize(width: 1800, height: 640)),
      ("window", CGSize(width: 1496, height: 905)),
    ] {
      let view = ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0)
        .environment(\.ottoPalette, OttoPalette(theme: theme))
        .frame(width: size.width, height: size.height)
        .background(Color.red)
      try render(view, size: size, to: "\(output)/backdrop-\(name).png")
    }
  }

  /// Renders the chat surface so the sidebar can be reviewed next to the conversation.
  @Test func renderChat() throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_HOME_SNAPSHOT_DIR"] else { return }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "chat-snap-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    for name in ["Fix webhook retries", "Home brief polish", "Trigify pricing research"] {
      let id = try #require(
        canvas.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs
          .first)
      canvas.dispatch(.renameNode(id: id, name: name))
    }
    let registry = OttoProfileRegistry(
      applicationSupport: workspace.appending(path: "support"),
      originalWorkspacePath: workspace.path)
    _ = try registry.create(
      name: "Personal", symbol: "heart", folder: workspace.appending(path: "personal"))
    let services = ApplicationServices(
      store: canvas, workspacePath: workspace.path, profiles: registry)
    let firstSession = canvas.activeCanvas.nodes.last { $0.kind == .agent }?.id
    for (name, face) in [("Coder", "face.pip"), ("Researcher", "face.sol"), ("Woody", nil)] {
      if let profile = try? services.agentProfiles.save(
        AgentProfile(name: name, instructions: "Help", provider: .claudeCode)), let face
      {
        _ = try? services.botAppearance.save(BotAppearance(profileID: profile.id, avatarRef: face))
      }
    }
    let voice = VoiceController(
      registry: ToolRegistry(), store: canvas, services: services,
      workspacePath: workspace.path, secrets: InMemorySecretStore())
    for themeID in ["silverbough", "halcyon"] {
      canvas.dispatch(.setTheme(themeID))
      let theme = OttoThemeCatalog.theme(id: themeID)
      let view = ZStack {
        ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
        ChatWorkspaceView(
          store: canvas, services: services, voice: voice,
          navigation: .constant(
            ChatSurfaceNavigationState(
              selectedAgentID: firstSession, selectedSessionID: firstSession,
              sessionCanvasID: canvas.activeCanvas.id)), launchAgent: {})
      }
      .environment(\.ottoPalette, OttoPalette(theme: theme))
      try render(
        view, size: CGSize(width: 1280, height: 820), to: "\(output)/chat-\(themeID).png",
        light: theme.isLightAppearance)
    }
  }

  /// Every theme, Home and Chat, tiled into contact sheets for a quick readability review.
  @Test func renderAllThemes() throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_HOME_SNAPSHOT_DIR"], env["OTTO_ALL_THEMES"] == "1" else { return }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "themes-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let now = Date.now
    try services.dailyBrief.add([
      BriefItem(
        kind: .todo, title: "Review Supabase’s critical exposure alerts",
        reason: "Row-level security is off on two tables. Decide who verifies the fix.",
        source: "Supabase via Gmail", needsYou: true, origin: .user, createdAt: now),
      BriefItem(
        kind: .todo, title: "Decide whether to keep two Neon projects",
        reason: "They will be deleted in October unless exported.", source: "Gmail",
        origin: .user, createdAt: now),
      BriefItem(
        kind: .update, title: "Customer reminder is ready for tomorrow",
        reason: "Nothing is needed from you.", source: "Gmail", people: ["Hugo"],
        origin: .user, createdAt: now),
      BriefItem(
        kind: .event, title: "Automation work block", reason: "Focus time.",
        source: "Google Calendar", time: now.addingTimeInterval(3600),
        endTime: now.addingTimeInterval(7200), origin: .user, createdAt: now),
    ])
    let agent = try #require(
      canvas.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    canvas.dispatch(.renameNode(id: agent, name: "Research session"))
    let voice = VoiceController(
      registry: ToolRegistry(), store: canvas, services: services,
      workspacePath: workspace.path, secrets: InMemorySecretStore())
    var homeTiles: [(String, NSBitmapImageRep)] = []
    var chatTiles: [(String, NSBitmapImageRep)] = []
    let size = CGSize(width: 1280, height: 820)
    for theme in OttoThemeCatalog.all {
      canvas.dispatch(.setTheme(theme.id))
      let palette = OttoPalette(theme: theme)
      let home = ZStack {
        GeometryReader { proxy in
          ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        PersonalHomeView(
          store: canvas, services: services, activity: services.botActivity,
          brief: services.dailyBrief, draft: .constant(""), provider: .constant(.claudeCode),
          conversationTarget: .constant(.newSession), openMarkdown: { _ in },
          openBot: { _ in }, openAgent: { _ in }, openCloud: {},
          openLibrary: { _ in }, hireBot: {}, submit: { _, _, _ in })
      }
      .environment(\.ottoPalette, palette)
      homeTiles.append(
        (theme.displayName, try bitmap(home, size: size, light: theme.isLightAppearance)))
      let chat = ZStack {
        GeometryReader { proxy in
          ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        ChatWorkspaceView(
          store: canvas, services: services, voice: voice,
          navigation: .constant(
            ChatSurfaceNavigationState(
              selectedAgentID: agent, selectedSessionID: agent,
              sessionCanvasID: canvas.activeCanvas.id)), launchAgent: {})
      }
      .environment(\.ottoPalette, palette)
      chatTiles.append(
        (theme.displayName, try bitmap(chat, size: size, light: theme.isLightAppearance)))
    }
    try writeSheet(homeTiles, to: "\(output)/all-home.png")
    try writeSheet(chatTiles, to: "\(output)/all-chat.png")
  }

  private func bitmap<V: View>(_ view: V, size: CGSize, light: Bool) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
  }

  /// Tiles renders three across at half size with the theme name above each.
  private func writeSheet(_ tiles: [(String, NSBitmapImageRep)], to path: String) throws {
    let columns = 3
    let tile = CGSize(width: 640, height: 410)
    let label: CGFloat = 26
    let rows = (tiles.count + columns - 1) / columns
    let sheet = NSImage(
      size: CGSize(
        width: tile.width * CGFloat(columns), height: (tile.height + label) * CGFloat(rows)))
    sheet.lockFocus()
    NSColor.black.setFill()
    NSRect(origin: .zero, size: sheet.size).fill()
    for (index, entry) in tiles.enumerated() {
      let column = index % columns
      let row = index / columns
      let origin = CGPoint(
        x: CGFloat(column) * tile.width,
        y: sheet.size.height - CGFloat(row + 1) * (tile.height + label))
      entry.1.draw(in: CGRect(origin: origin, size: tile))
      (entry.0 as NSString).draw(
        at: CGPoint(x: origin.x + 8, y: origin.y + tile.height + 5),
        withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 15)])
    }
    sheet.unlockFocus()
    let tiff = try #require(sheet.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }

  /// The Automations list (empty and filled) and the New automation sheet.
  @Test func renderAutomations() throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_HOME_SNAPSHOT_DIR"] else { return }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "auto-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let theme = OttoThemeCatalog.theme(id: "halcyon")
    let palette = OttoPalette(theme: theme)
    func screen() -> some View {
      ZStack {
        palette.ink
        AutomationsView(store: canvas, services: services, routines: services.routines)
      }
      .environment(\.ottoPalette, palette)
    }
    try render(
      screen(), size: CGSize(width: 1100, height: 760), to: "\(output)/automations-empty.png")
    let bot = try services.agentProfiles.save(
      AgentProfile(name: "Coder", instructions: "Help", provider: .claudeCode))
    _ = try services.routines.save(
      Routine(
        name: "Morning inbox triage", instruction: "List what needs a reply or a decision.",
        trigger: .schedule(cron: "0 8 * * 1-5", intervalSeconds: nil),
        target: .spawnProfile(profileID: bot.id), enabled: true, delivery: .brief(profileID: nil)))
    _ = try services.routines.save(
      Routine(
        name: "Weekly progress report", instruction: "Summarise the week across projects.",
        trigger: .schedule(cron: "0 16 * * 5", intervalSeconds: nil),
        target: .spawnProvider(provider: AgentProvider.codex.rawValue), enabled: false))
    try render(
      screen(), size: CGSize(width: 1100, height: 760), to: "\(output)/automations-list.png")
    let toasts = ZStack { palette.ink }
      .ottoStatusToast(
        .constant(
          OttoStatusToast(
            kind: .success, title: "Running", detail: "“Morning inbox triage” started."))
      )
      .ottoUndoToast(
        .constant(OttoUndoToast(title: "Automation deleted", detail: "“Weekly progress report”")),
        onUndo: {}, onExpire: {}
      )
      .environment(\.ottoPalette, palette)
    try render(toasts, size: CGSize(width: 900, height: 360), to: "\(output)/toasts.png")
    let actions = [
      PaletteQuickAction(
        id: "go.home", title: "Home", subtitle: "Your brief, to-dos and day", symbol: "house",
        keywords: "", perform: {}),
      PaletteQuickAction(
        id: "go.automations", title: "Automations", subtitle: "Tasks that run on a schedule",
        symbol: "clock", keywords: "", perform: {}),
      PaletteQuickAction(
        id: "go.bot.coder", title: "Coder", subtitle: "Bot", symbol: "person.crop.circle",
        keywords: "", accent: .cyan, perform: {}),
      PaletteQuickAction(
        id: "agent.claude", title: "New Claude Code agent", subtitle: "Start a chat agent",
        symbol: "sparkles", keywords: "", accent: .cyan, agentProvider: .claudeCode, perform: {}),
      PaletteQuickAction(
        id: "routine.manager", title: "New automation", subtitle: "Give an agent a task and a time",
        symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90", keywords: "", perform: {}),
    ]
    let paletteView = ZStack {
      palette.ink
      CommandPaletteOverlay(services: services, uiState: WorkspaceUIState(), quickActions: actions)
    }
    .environment(\.ottoPalette, palette)
    try render(paletteView, size: CGSize(width: 1100, height: 720), to: "\(output)/palette.png")
    let editor = AutomationEditor(services: services, target: .new(template: nil)) { _ in }
      .environment(\.ottoPalette, palette)
    try render(editor, size: CGSize(width: 620, height: 700), to: "\(output)/automation-editor.png")
  }

  private func render<V: View>(
    _ view: V, size: CGSize, to path: String, light: Bool = false
  ) throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }
}
