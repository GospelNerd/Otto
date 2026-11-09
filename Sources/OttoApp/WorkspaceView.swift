import AppKit
import OttoApplicationTools
import OttoCore
import OttoDocuments
import OttoModels
import OttoObservability
import OttoRemote
import OttoRuntime
import OttoServices
import OttoVoice
import OttoWorktrees
import SwiftUI

extension Notification.Name {
  static let ottoReplayVoiceOnboarding = Notification.Name("io.openotto.replay-voice-onboarding")
}

struct WorkspaceView: View {
  @Environment(\.ottoSpaceVisible) private var spaceVisible
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openSettings) private var openSettings
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.ottoMotion) private var motion
  @State private var showingBoatCloud = false
  @Namespace private var surfacePickerSelection
  @ObservedObject var store: CanvasStore
  @ObservedObject var services: ApplicationServices
  @ObservedObject var voice: VoiceController
  @ObservedObject var uiState: WorkspaceUIState
  /// Home is where Otto opens: the brief, cards and the composer.
  @State private var showingPersonalHome = true
  /// When the person last left Otto or their Mac, for opening Home on a new day.
  @State private var awaySince: Date?
  @State private var homeDraft = ""
  @State private var homeProvider: AgentProvider = .codex
  @State private var homeConversationTarget: HomeConversationTarget = .newSession
  @State private var conversationError: String?
  @State private var showingHireBot = false
  @State private var showingCreateTeam = false
  @State private var agentLaunchPoint = WorldPoint(x: 0, y: 0)
  @AppStorage("otto.onboarding.completed") private var onboardingCompleted = false
  @AppStorage(OttoPreferenceKey.fontScale) private var fontScaleRaw = OttoFontScale.standard
    .rawValue
  // 0 (never set) defers to the active theme's designed nodeOpacity.
  @AppStorage(OttoPreferenceKey.matteOpacity) private var matteOpacity = 0.0
  @State private var showingOnboarding = false
  @AppStorage(FirstRunPreferences.tourCompleted) private var tourCompleted = false
  @State private var showingTour = false
  @State private var tourStep = 0
  @State private var windowIsVisible = true
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private var activeTheme: OttoThemeDefinition {
    OttoThemeCatalog.theme(id: store.activeCanvas.themeID)
  }

  private var palette: OttoPalette {
    OttoPalette(theme: activeTheme, matteOpacity: matteOpacity > 0 ? matteOpacity : nil)
  }

  var body: some View {
    ZStack {
      // Window-glass themes need the base gone so the desktop shows through; the frost in
      // ThemeBackgroundView carries legibility. Reduced transparency drops the backdrop
      // entirely, so the solid base must come back with it.
      if activeTheme.resolvedSurfaceMaterial != .windowGlass || reduceTransparency {
        palette.ink.ignoresSafeArea()
      }
      // The backdrop is pinned to the window's frame so artwork can never size this root
      // ZStack; inside it, photos are aspect-filled and cropped like a wallpaper.
      GeometryReader { geometry in
        ThemeBackgroundView(
          theme: activeTheme,
          isActive: scenePhase == .active && windowIsVisible,
          scrimScale: 0.25
        )
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
        .id(activeTheme.id)
      }
      .ignoresSafeArea()
      .allowsHitTesting(false)
      WindowVisibilityObserver(isVisible: $windowIsVisible)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
      if showingPersonalHome {
        personalHome
      } else {
        chatSurface
      }

      if uiState.showsCommandPalette {
        // The palette choreographs its own entrance and exit (slow in, faster out).
        CommandPaletteOverlay(
          services: services, uiState: uiState, quickActions: paletteQuickActions
        )
        .transition(.identity)
      }

      // The surface switch shares the traffic lights' line in both surfaces, sitting just
      // after the chat band's sidebar toggle (80pt + 26pt control + 6pt gap). Centred over
      // content it covered the transcript and the node cards, and it moved relative to the
      // conversation whenever the sidebar collapsed.
      VStack {
        HStack {
          workspaceSurfacePicker
            .homeTourTarget(.surfaceSwitcher)
            .padding(.leading, 112)
          Spacer()
        }
        .padding(.top, 2.5)
        Spacer()
      }
      // The surfaces draw under the titlebar, so the switch has to as well. Respecting the
      // safe area here dropped it a full row below the sidebar toggle it belongs beside.
      .ignoresSafeArea(.container, edges: .top)
      .zIndex(6)

      if showingOnboarding {
        FirstRunWelcomeView(services: services, complete: finishWelcome)
          .transition(.opacity)
          .zIndex(20)
      }
    }
    .overlayPreferenceValue(HomeTourAnchorsKey.self) { anchors in
      if showingTour, showingPersonalHome, !showingOnboarding {
        HomeTourOverlay(anchors: anchors, stepIndex: $tourStep, finish: finishTour)
          .transition(.opacity)
      }
    }
    .preferredColorScheme(
      // Black text on bright photos, white on dark ones, on every screen including Home.
      activeTheme.isLightAppearance ? .light : .dark
    )
    .alert("Persistence notice", isPresented: errorBinding) {
      Button("Dismiss", role: .cancel) { store.dismissPersistenceError() }
    } message: {
      Text(store.persistenceError ?? "Unknown database error")
    }
    .alert(
      "Conversation error",
      isPresented: Binding(
        get: { conversationError != nil },
        set: { if !$0 { conversationError = nil } }
      )
    ) {
      Button("Dismiss", role: .cancel) { conversationError = nil }
    } message: {
      Text(conversationError ?? "Could not open the conversation")
    }
    .sheet(isPresented: $showingHireBot) {
      HireBotSheet(services: services, hired: openHiredBot)
        .environment(\.ottoPalette, palette)
    }
    .sheet(isPresented: $showingCreateTeam) {
      CreateTeamSheet(services: services) { _ in }
        .environment(\.ottoPalette, palette)
    }
    .sheet(isPresented: $uiState.showsMemoryInspector) {
      MemoryInspectorView(services: services)
    }
    .sheet(isPresented: $showingBoatCloud) {
      VStack {
        HStack {
          Spacer()
          Button("Done") { showingBoatCloud = false }
        }.padding()
        BoatCloudView(cloud: services.boatCloud)
      }
    }
    .sheet(isPresented: $uiState.showsRoutineManager) {
      RoutineManagerView(store: store, services: services)
    }
    .sheet(isPresented: $uiState.showsFeedback) {
      FeedbackSheet { uiState.showsFeedback = false }
        .environment(\.ottoPalette, palette)
    }
    .onReceive(NotificationCenter.default.publisher(for: .ottoSendFeedback)) { _ in
      guard spaceVisible else { return }
      uiState.showsFeedback = true
    }
    .onAppear {
      if !onboardingCompleted { showingOnboarding = true }
      openRequestedBrowser()
    }
    .onChange(of: uiState.requestsBrowser) { _, requested in
      if requested { openRequestedBrowser() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .ottoReplayVoiceOnboarding)) { _ in
      guard spaceVisible else { return }
      showingTour = false
      showingOnboarding = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .ottoStartHomeTour)) { _ in
      guard spaceVisible else { return }
      startTour()
    }
    .onReceive(MorningHome.leaving) { _ in
      if awaySince == nil { awaySince = .now }
    }
    .onReceive(MorningHome.returning) { _ in
      guard let since = awaySince else { return }
      awaySince = nil
      if MorningHome.shouldOpenHome(awaySince: since), !showingPersonalHome {
        withAnimation(motion.enter(.moderate)) { showingPersonalHome = true }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .ottoOpenCompletedConversation)) {
      notification in
      if spaceVisible, let nodeID = notification.object as? UUID,
        store.snapshot.canvases.contains(where: { $0.nodes.contains(where: { $0.id == nodeID }) })
      {
        openHomeAgent(nodeID)
      }
    }
    .onChange(of: services.botNavigationRequest) { _, request in
      if request != nil { showingPersonalHome = false }
    }
    #if DEBUG
      .onReceive(NotificationCenter.default.publisher(for: OttoDevProbe.goNotification)) { note in
        let place = note.object as? String ?? ""
        if place == "home" {
          showingPersonalHome = true
        } else if let destination = ChatSurfaceDestination(rawValue: place) {
          openChatDestination(destination)
        }
        OttoDevProbe.log("go \(place) showingPersonalHome=\(showingPersonalHome)")
      }
    #endif
    .environment(\.ottoPalette, palette)
    .dynamicTypeSize(dynamicTypeSize)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.activeCanvas.themeID)
  }

  /// Lands a new user on Home with their starter agent ready and its first task in the box,
  /// then offers the tour.
  private func finishWelcome(_ result: FirstRunResult) {
    onboardingCompleted = true
    UserDefaults.standard.set(true, forKey: FirstRunPreferences.gettingStartedActive)
    UserDefaults.standard.set(false, forKey: FirstRunPreferences.gettingStartedDismissed)
    if let bot = result.hiredBot {
      homeConversationTarget = .bot(bot.id)
      homeDraft = result.firstTask ?? ""
    }
    withAnimation(motion.exit(.moderate)) {
      showingOnboarding = false
      showingPersonalHome = true
    }
    if !tourCompleted { startTour() }
  }

  private func startTour() {
    showingPersonalHome = true
    tourStep = 0
    withAnimation(motion.enter(.moderate)) { showingTour = true }
  }

  private func finishTour() {
    tourCompleted = true
    withAnimation(motion.exit(.fast)) { showingTour = false }
  }

  private var personalHome: some View {
    PersonalHomeView(
      store: store, services: services, activity: services.botActivity,
      brief: services.dailyBrief, draft: $homeDraft, provider: $homeProvider,
      conversationTarget: $homeConversationTarget,
      openMarkdown: openHomeMarkdown,
      openBot: { profile in
        showingPersonalHome = false
        agentLaunchPoint = nextPlacementPoint()
        openHiredBot(profile)
      },
      openAgent: openHomeAgent,
      openCloud: { showingBoatCloud = true },
      openLibrary: { destination in
        var navigation = store.snapshot.chatNavigation
        navigation.destination = destination
        store.updateChatNavigation(navigation)
        store.setWorkspaceSurface(.chat)
        showingPersonalHome = false
      },
      hireBot: {
        agentLaunchPoint = nextPlacementPoint()
        showingHireBot = true
      },
      submit: { target, provider, prompt in
        let id: UUID
        switch target {
        case .newSession:
          let newID = try await quickLaunchAgentForChat(provider)
          id = newID
          // File the session under the Home profile's project so its folders and account apply.
          if let projectID = services.dailyBrief.selectedProfile.defaultProjectID {
            try? services.selectProject(channelID: newID, projectID: projectID)
          }
        case .bot(let profileID):
          guard let entry = services.botRoster().first(where: { $0.profile.id == profileID }) else {
            throw NSError(
              domain: "OttoHome", code: 2,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "This bot is no longer available. Choose another conversation."
              ])
          }
          if let existing = existingHomeBotNodeID(
            profileID: profileID,
            canonicalNodeID: entry.nodeID, canvases: store.snapshot.canvases)
          {
            id = existing
          } else {
            id = try await services.openBotChannel(entry.profile, at: nextPlacementPoint())
          }
        case .session(let sessionID):
          let roster = services.botRoster()
          guard
            homeSessionNodes(
              canvases: store.snapshot.canvases,
              botProfileIDs: Set(roster.map { $0.profile.id }),
              botNodeIDs: Set(roster.compactMap(\.nodeID)),
              backgroundNodeIDs: services.office.boundSessionIDs
            ).contains(where: { $0.id == sessionID })
          else {
            throw NSError(
              domain: "OttoHome", code: 3,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "This session is no longer available. Choose another conversation."
              ])
          }
          id = sessionID
        }
        // Leave Home as soon as the destination exists. Optional snapshot work must not
        // strand the person behind a disabled Home composer while the turn is prepared.
        openHomeAgent(id)
        do {
          try await services.sendPrompt(agentID: id, prompt: prompt)
        } catch {
          await services.recordConversationSendFailure(agentID: id, prompt: prompt, error: error)
          conversationError = error.localizedDescription
          return
        }
      }
    )
    .ignoresSafeArea(.container, edges: .top)
  }

  /// A note opens in the user's own editor.
  private func openHomeMarkdown(_ path: String) {
    NSWorkspace.shared.open(
      URL(fileURLWithPath: services.documents.rootPath).appending(path: path))
  }

  /// "Jump to" entries: the places, bots and recent sessions people move between most.
  private var jumpActions: [PaletteQuickAction] {
    var jumps: [PaletteQuickAction] = [
      PaletteQuickAction(
        id: "go.home", title: "Home", subtitle: "Your brief, to-dos and day",
        symbol: "house", keywords: "home brief today dashboard",
        perform: { showingPersonalHome = true }),
      PaletteQuickAction(
        id: "go.chat", title: "Chat", subtitle: "Your bots, teams and sessions",
        symbol: "bubble.left.and.bubble.right", keywords: "chat conversations bots teams sessions",
        perform: { openChatDestination(.conversation) }),
      PaletteQuickAction(
        id: "go.documents", title: "Documents",
        subtitle: "Documents, spreadsheets and presentations",
        symbol: "doc.richtext", keywords: "documents spreadsheets presentations slides sheets",
        perform: { openChatDestination(.documents) }),
      PaletteQuickAction(
        id: "go.dashboards", title: "Dashboards", subtitle: "Your dashboards and cards",
        symbol: "chart.bar.xaxis", keywords: "dashboards cards charts metrics",
        perform: { openChatDestination(.dashboards) }),
      PaletteQuickAction(
        id: "go.skills", title: "Skills", subtitle: "Skills every bot and session can use",
        symbol: "sparkles", keywords: "skills library instructions claude codex hermes",
        perform: { openChatDestination(.skills) }),
      PaletteQuickAction(
        id: "go.browser", title: "Browser", subtitle: "Your browser tabs",
        symbol: "globe", keywords: "browser tabs web website internet",
        perform: { openChatDestination(.browser) }),
      PaletteQuickAction(
        id: "go.automations", title: "Automations", subtitle: "Tasks that run on a schedule",
        symbol: "clock", keywords: "automations routines schedule",
        perform: { openChatDestination(.routines) }),
      PaletteQuickAction(
        id: "go.activity", title: "Activity", subtitle: "What your agents did and need",
        symbol: "tray", keywords: "activity inbox needs you",
        perform: { openChatDestination(.activity) }),
      PaletteQuickAction(
        id: "go.settings", title: "Settings", subtitle: "Connections, appearance and preferences",
        symbol: "gearshape", keywords: "settings preferences accounts connections appearance",
        perform: { openSettings() }),
      PaletteQuickAction(
        id: "help.feedback", title: "Send feedback",
        subtitle: "Report a bug or suggest an idea on GitHub",
        symbol: "bubble.left.and.exclamationmark.bubble.right",
        keywords: "feedback bug report idea suggestion problem help github",
        perform: { uiState.showsFeedback = true }),
      PaletteQuickAction(
        id: "help.community", title: "Join the Otto community",
        subtitle: "Questions, updates and what others build, on Discord",
        symbol: "person.3", keywords: "community discord help chat support questions",
        perform: { OttoCommunityLinks.openDiscord() }),
      PaletteQuickAction(
        id: "go.files", title: "Files & notes", subtitle: "Notes and media",
        symbol: "doc.text", keywords: "files notes documents media",
        perform: { openChatDestination(.files) }),
    ]
    for entry in services.botRoster() {
      jumps.append(
        PaletteQuickAction(
          id: "go.bot.\(entry.profile.id.uuidString)", title: entry.profile.name,
          subtitle: "Bot", symbol: "person.crop.circle",
          keywords: "bot chat \(entry.profile.name) \(entry.profile.role)", accent: .cyan,
          searchOnly: true,
          perform: {
            showingPersonalHome = false
            agentLaunchPoint = nextPlacementPoint()
            openHiredBot(entry.profile)
          }))
    }
    let roster = services.botRoster()
    let sessions = homeSessionNodes(
      canvases: store.snapshot.canvases, botProfileIDs: Set(roster.map { $0.profile.id }),
      botNodeIDs: Set(roster.compactMap(\.nodeID)),
      backgroundNodeIDs: services.office.boundSessionIDs)
    for node in sessions.prefix(8) {
      jumps.append(
        PaletteQuickAction(
          id: "go.session.\(node.id.uuidString)", title: node.displayName,
          subtitle: "Session", symbol: "bubble.left",
          keywords: "session chat \(node.displayName)",
          agentProvider: node.declaredAgentProvider,
          searchOnly: true,
          perform: { openHomeAgent(node.id) }))
    }
    return jumps
  }

  private func openRequestedBrowser() {
    guard uiState.requestsBrowser else { return }
    uiState.requestsBrowser = false
    uiState.showsCommandPalette = false
    openChatDestination(.browser)
  }

  private func openChatDestination(_ destination: ChatSurfaceDestination) {
    var navigation = store.snapshot.chatNavigation
    navigation.destination = destination
    store.updateChatNavigation(navigation)
    store.setWorkspaceSurface(.chat)
    showingPersonalHome = false
  }

  private func openHomeAgent(_ id: UUID) {
    guard let canvas = store.snapshot.canvases.first(where: { $0.nodes.contains { $0.id == id } }),
      let node = canvas.nodes.first(where: { $0.id == id })
    else { return }
    if node.kind == .terminal {
      // A waiting terminal in "Needs you": Chat opens it in the work drawer.
      services.revealTerminal(id)
      store.setWorkspaceSurface(.chat)
      showingPersonalHome = false
      return
    }
    if let profileID = node.agentDefinition?.profileID,
      services.botRoster().contains(where: { $0.profile.id == profileID })
    {
      store.updateChatNavigation(
        chatNavigationSelectingHiredBot(
          store.snapshot.chatNavigation, profileID: profileID, nodeID: id))
    } else {
      store.updateChatNavigation(
        ChatSurfaceNavigationState(
          selectedAgentID: id, selectedSessionID: id, sessionCanvasID: canvas.id,
          sidebarList: .sessions, destination: .conversation))
    }
    store.dispatch(.focusNode(id), targetCanvasID: canvas.id)
    store.setWorkspaceSurface(.chat)
    showingPersonalHome = false
  }

  private var chatSurface: some View {
    ChatWorkspaceView(
      store: store,
      services: services,
      voice: voice,
      navigation: chatNavigationBinding,
      launchAgent: {
        agentLaunchPoint = WorldPoint(
          x: store.activeCanvas.viewport.centerX,
          y: store.activeCanvas.viewport.centerY
        )
        showingHireBot = true
      },
      quickLaunchAgent: { provider, folder in
        try await quickLaunchAgentForChat(provider, workingDirectory: folder)
      }
    )
    .environment(\.ottoWindowIsActive, scenePhase == .active && windowIsVisible)
    .ignoresSafeArea(.container, edges: .top)
  }

  private var dynamicTypeSize: DynamicTypeSize {
    switch OttoFontScale(rawValue: fontScaleRaw) ?? .standard {
    case .extraSmall: .xSmall
    case .small: .small
    case .standard: .medium
    case .large: .large
    case .extraLarge: .xLarge
    }
  }

  private var chatNavigationBinding: Binding<ChatSurfaceNavigationState> {
    Binding(
      get: { store.snapshot.chatNavigation },
      set: { store.updateChatNavigation($0) }
    )
  }

  private func openHiredBot(_ profile: AgentProfile) {
    showingPersonalHome = false
    store.setWorkspaceSurface(.chat)
    store.updateChatNavigation(
      chatNavigationSelectingHiredBot(
        store.snapshot.chatNavigation, profileID: profile.id, nodeID: nil))
    Task {
      do {
        let nodeID = try await services.openBotChannel(profile, at: agentLaunchPoint)
        store.updateChatNavigation(
          chatNavigationSelectingHiredBot(
            store.snapshot.chatNavigation, profileID: profile.id, nodeID: nodeID))
        store.dispatch(.focusNode(nodeID))
      } catch {
        conversationError = error.localizedDescription
      }
    }
  }

  /// The Home/Chat switch uses the active theme's own colours on a light theme without artwork
  /// (Daylight), and the same dark Aurora plate on every other screen and theme.
  private var surfacePickerPalette: OttoPalette {
    OttoPalette(theme: activeTheme.isPlainLight ? activeTheme : OttoThemeCatalog.aurora)
  }

  private var workspaceSurfacePicker: some View {
    // Segmented tabs after Fluid Functionalism: the selected plate slides on the moderate
    // spring while a hover wash glides between segments on the fast one.
    OttoFluidHover(
      axis: .horizontal,
      style: OttoFluidHoverStyle(fill: surfacePickerPalette.paper.opacity(0.06), cornerRadius: 5)
    ) {
      HStack(spacing: 2) {
        Button {
          withAnimation(motion.enter(.moderate)) { showingPersonalHome = true }
        } label: {
          Text("Home")
            .font(.ottoDisplay(11).weight(showingPersonalHome ? .semibold : .medium))
            .foregroundStyle(
              showingPersonalHome
                ? surfacePickerPalette.paper : surfacePickerPalette.paper.opacity(0.75)
            )
            .frame(minWidth: 52, minHeight: 22)
            .padding(.horizontal, 8)
            .background(
              showingPersonalHome ? surfacePickerPalette.raised : .clear,
              in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Home")
        .accessibilityValue(showingPersonalHome ? "Selected" : "Not selected")
        .ottoHoverItem("personal-home")
        workspaceSurfaceButton(.chat)
          .ottoHoverItem(WorkspaceSurface.chat)
      }
    }
    // A flat segmented control, not a floating pill: it lives in reserved chrome now, so
    // the signal colour stays reserved for status and selection elsewhere.
    .padding(2)
    .frame(height: 26)
    .background(
      activeTheme.isPlainLight
        ? surfacePickerPalette.raised.opacity(0.9) : Color.black.opacity(0.55),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Workspace surface")
  }

  private func workspaceSurfaceButton(_ surface: WorkspaceSurface) -> some View {
    let isSelected = !showingPersonalHome
    return Button {
      withAnimation(motion.enter(.moderate)) {
        showingPersonalHome = false
        _ = store.setWorkspaceSurface(surface)
      }
    } label: {
      OttoWeightStableText(
        surface.rawValue.capitalized, size: 11, active: isSelected,
        activeWeight: .semibold, restingWeight: .medium,
        activeColor: surfacePickerPalette.paper,
        restingColor: surfacePickerPalette.paper.opacity(0.75)
      )
      .frame(minWidth: 52, minHeight: 22)
      .padding(.horizontal, 8)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(surfacePickerPalette.raised)
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
            .matchedGeometryEffect(id: "workspace-surface", in: surfacePickerSelection)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open \(surface.rawValue.capitalized)")
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.persistenceError != nil },
      set: { if !$0 { store.dismissPersistenceError() } }
    )
  }

  /// Current app navigation and conversation actions.
  private var paletteQuickActions: [PaletteQuickAction] {
    let actions = [
      PaletteQuickAction(
        id: "agent.claude",
        title: "New Claude Code session",
        subtitle: "Start a new Claude Code conversation",
        symbol: "sparkles",
        keywords: "claude code agent ai chat launch spawn",
        accent: .cyan,
        agentProvider: .claudeCode,
        perform: { quickLaunchAgent(.claudeCode) }
      ),
      PaletteQuickAction(
        id: "agent.codex",
        title: "New Codex session",
        subtitle: "Start a new Codex conversation",
        symbol: "chevron.left.forwardslash.chevron.right",
        keywords: "codex openai agent ai chat launch spawn",
        accent: .amber,
        agentProvider: .codex,
        perform: { quickLaunchAgent(.codex) }
      ),
      PaletteQuickAction(
        id: "agent.hermes",
        title: "New Hermes session",
        subtitle: "Use the Hermes connection configured in Agent settings",
        symbol: "wing",
        keywords: "hermes agent local remote gateway launch spawn",
        accent: .red,
        agentProvider: .hermes,
        perform: { quickLaunchAgent(.hermes) }
      ),
      PaletteQuickAction(
        id: "agent.kimi",
        title: "New Kimi session",
        subtitle: "Start a new Kimi Code conversation",
        symbol: "moon.stars",
        keywords: "kimi code moonshot agent ai chat launch spawn",
        agentProvider: .kimi,
        perform: { quickLaunchAgent(.kimi) }
      ),
      PaletteQuickAction(
        id: "agent.cursor",
        title: "New Cursor session",
        subtitle: "Start a new Cursor CLI conversation",
        symbol: "cursorarrow.rays",
        keywords: "cursor composer agent ai chat launch spawn grok",
        agentProvider: .cursor,
        perform: { quickLaunchAgent(.cursor) }
      ),
      PaletteQuickAction(
        id: "agent.opencode",
        title: "New OpenCode session",
        subtitle: "Start a new OpenCode conversation",
        symbol: "chevron.right.square",
        keywords: "opencode open code sst agent ai chat launch spawn",
        agentProvider: .openCode,
        perform: { quickLaunchAgent(.openCode) }
      ),
      PaletteQuickAction(
        id: "agent.pi",
        title: "New Pi session",
        subtitle: "Start a new Pi conversation",
        symbol: "function",
        keywords: "pi pi.dev earendil zechner agent ai chat launch spawn",
        agentProvider: .pi,
        perform: { quickLaunchAgent(.pi) }
      ),
      PaletteQuickAction(
        id: "agent.grok",
        title: "New Grok session",
        subtitle: "Start a new Grok conversation",
        symbol: "bolt.fill",
        keywords: "grok xai x.ai agent ai chat launch spawn",
        agentProvider: .grok,
        perform: { quickLaunchAgent(.grok) }
      ),
      PaletteQuickAction(
        id: "bot.hire",
        title: "Hire a bot",
        subtitle: "Create a persistent bot with a name, job, and canonical channel",
        symbol: "person.crop.circle.badge.plus",
        keywords: "hire bot custom agent profile persona job title teammate",
        perform: {
          agentLaunchPoint = nextPlacementPoint()
          showingHireBot = true
        }
      ),
      PaletteQuickAction(
        id: "bot.team",
        title: "Create a team",
        subtitle: "Start a persistent group conversation between saved bots",
        symbol: "person.3",
        keywords: "team group bots conversation",
        perform: { showingCreateTeam = true }
      ),
      PaletteQuickAction(
        id: "memory.inspector",
        title: "Memory",
        subtitle: "Explore memories and their connections",
        symbol: "brain",
        keywords:
          "memory brain graph connections sources entities topics inspector manage knowledge",
        perform: { uiState.showsMemoryInspector = true }
      ),
    ]
    return jumpActions + actions
  }

  private func quickLaunchAgent(_ provider: AgentProvider) {
    Task {
      do { _ = try await quickLaunchAgentForChat(provider) } catch {
        conversationError = error.localizedDescription
      }
    }
  }

  /// Starts a one-off session. A failure (a missing Otto Harness key, a CLI that will not start)
  /// is thrown so the caller can show it; swallowing it left the person with a closed menu and
  /// no session, and no idea why.
  private func quickLaunchAgentForChat(
    _ provider: AgentProvider, workingDirectory: String? = nil
  ) async throws -> UUID {
    let point = nextPlacementPoint()
    let key =
      switch provider {
      case .claudeCode: OttoPreferenceKey.claudePermissionMode
      case .codex: OttoPreferenceKey.codexPermissionMode
      case .openAI: OttoPreferenceKey.codexPermissionMode
      case .hermes: OttoPreferenceKey.hermesPermissionMode
      case .cursor: OttoPreferenceKey.cursorPermissionMode
      case .kimi: OttoPreferenceKey.kimiPermissionMode
      case .openCode: OttoPreferenceKey.openCodePermissionMode
      case .pi: OttoPreferenceKey.piPermissionMode
      case .grok: OttoPreferenceKey.grokPermissionMode
      case .shell: OttoPreferenceKey.shellPermissionMode
      }
    let mode =
      AgentPermissionMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "")
      ?? .workspaceWrite
    return try await services.spawnAgent(
      provider: provider,
      workingDirectory: provider.startsInProjectFolder ? workingDirectory : nil,
      at: point,
      permissionMode: mode
    ).agentID
  }

  private func nextPlacementPoint() -> WorldPoint {
    let canvas = store.activeCanvas
    let offset = Double(canvas.nodes.count * 22)
    return WorldPoint(
      x: canvas.viewport.centerX - 170 + offset,
      y: canvas.viewport.centerY - 100 + offset
    )
  }

}
