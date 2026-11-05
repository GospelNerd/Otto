import AppKit
import OttoApplicationTools
import OttoBrowser
import OttoCore
import OttoModels
import OttoRuntime
import OttoServices
import OttoTools
import OttoVoice
import SwiftUI
import UniformTypeIdentifiers

struct ChatCanvasSelection: Equatable {
  let canvasID: UUID
  let nodeID: UUID?
}

/// A New session choice of Otto's harness, held while the person adds an API key.
struct HarnessKeySetupRequest: Identifiable {
  let id = UUID()
  let projectID: UUID?
  let folder: String?
}

enum ChatFocusedAgentTarget: Equatable {
  case session(canvasID: UUID, nodeID: UUID)
  case bot(profileID: UUID, nodeID: UUID)
}

func changedChatFocusedAgentTarget(
  previous: [ChatCanvasSelection],
  current: [ChatCanvasSelection],
  canvases: [OttoCanvas],
  hiredProfileIDs: Set<UUID>
) -> ChatFocusedAgentTarget? {
  let previousByCanvas = Dictionary(uniqueKeysWithValues: previous.map { ($0.canvasID, $0.nodeID) })
  guard
    let changed = current.first(where: {
      previousByCanvas[$0.canvasID] != .some($0.nodeID)
    }),
    let nodeID = changed.nodeID,
    let node = canvases.first(where: { $0.id == changed.canvasID })?.nodes.first(where: {
      $0.id == nodeID && $0.isStandaloneAgent
    })
  else { return nil }

  if let profileID = node.agentDefinition?.profileID, hiredProfileIDs.contains(profileID) {
    return .bot(profileID: profileID, nodeID: nodeID)
  }
  return .session(canvasID: changed.canvasID, nodeID: nodeID)
}

func chatNavigationSelectingHiredBot(
  _ current: ChatSurfaceNavigationState,
  profileID: UUID,
  nodeID: UUID?
) -> ChatSurfaceNavigationState {
  var navigation = current
  navigation.selectedProfileID = profileID
  navigation.selectedTeamID = nil
  navigation.selectedAgentID = nodeID
  navigation.selectedSessionID = nil
  navigation.sidebarList = .bots
  navigation.destination = .conversation
  return navigation
}

/// The conversation-first workspace surface. Chat never moves or replaces canvas nodes: it
/// presents the same durable agent runtimes and supporting objects through a focused workspace.
/// The Bots tab lists saved AgentProfiles and their canonical channels, not ad-hoc canvas nodes.
struct ChatWorkspaceView: View {
  @Environment(\.ottoSpaceVisible) private var spaceVisible
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.openSettings) private var openSettings
  @ObservedObject var store: CanvasStore
  @ObservedObject var services: ApplicationServices
  @ObservedObject var voice: VoiceController
  @Environment(\.ottoWindowIsActive) private var notificationWindowIsActive
  @State private var notificationVisibilityID = UUID()
  @Binding var navigation: ChatSurfaceNavigationState
  let launchAgent: () -> Void
  /// Starts a session for a provider, in the given folder when it is not nil.
  var quickLaunchAgent: (AgentProvider, String?) async throws -> UUID = { _, _ in
    throw RuntimeError.launchFailed("This window cannot start sessions")
  }

  @State private var showingProjectContext = false
  @State private var showingCreateProject = false
  @State private var projectCreationChannelID: UUID?
  @State private var newSessionProjectID: UUID?
  @State private var initializedSessionProject = false
  @State private var projectContextError: String?

  private var selectedProfileID: UUID? {
    get { navigation.selectedProfileID }
    nonmutating set { navigation.selectedProfileID = newValue }
  }
  private var selectedTeamID: UUID? {
    get { navigation.selectedTeamID }
    nonmutating set { navigation.selectedTeamID = newValue }
  }
  private var selectedAgentID: UUID? {
    get { navigation.selectedAgentID }
    nonmutating set { navigation.selectedAgentID = newValue }
  }
  private var selectedSessionID: UUID? {
    get { navigation.selectedSessionID }
    nonmutating set { navigation.selectedSessionID = newValue }
  }
  private var sessionCanvasID: UUID? {
    get { navigation.sessionCanvasID }
    nonmutating set { navigation.sessionCanvasID = newValue }
  }
  private var sidebarList: ChatSidebarList {
    get { navigation.sidebarList }
    nonmutating set { navigation.sidebarList = newValue }
  }
  private var destination: ChatSurfaceDestination {
    get { navigation.destination }
    nonmutating set { navigation.destination = newValue }
  }
  @State private var showingAgentDetails = false
  @AppStorage("otto.workPanelWidth") private var preferredWorkPanelWidth = 0.0
  @State private var workPanelDragStart: Double?
  @State private var showingSidebar = true
  @State private var showingEnvironment = false
  @State private var conversationsWithWorkPanel: Set<String> = []

  /// Visibility belongs to the conversation, not the shared Chat workspace view. Bot keys
  /// survive runtime replacement and cannot collide with sessions backed by the same node.
  private var showingWorkPanel: Bool {
    get {
      guard let key = sidebarSelectedRowID else { return false }
      return conversationsWithWorkPanel.contains(key)
    }
    nonmutating set {
      guard let key = sidebarSelectedRowID else { return }
      if newValue {
        conversationsWithWorkPanel.insert(key)
      } else {
        conversationsWithWorkPanel.remove(key)
      }
    }
  }
  @State private var workTabs: [UUID: [WorkTab]] = [:]
  @State private var standaloneTerminalID: UUID?
  /// Bumped to put keyboard focus in a terminal when it is revealed.
  @State private var terminalFocusTokens: [UUID: Int] = [:]
  @State private var selectedWorkTabIDs: [UUID: UUID] = [:]
  @State private var sideChatAgentIDs: [UUID: UUID] = [:]
  @State private var creatingSideChatFor: UUID?
  @State private var sideChatError: String?
  @State private var showingHire = false
  @State private var showingTeam = false
  /// Not private so snapshot tests can open the New session menu.
  @State var showingSessionCreator = false
  /// Why the last one-off session failed to start, shown as an alert.
  @State private var sessionLaunchError: String?
  /// A New session request for Otto's harness that is waiting on an API key or local server.
  @State private var harnessKeySetup: HarnessKeySetupRequest?
  @State private var hoveredSessionID: UUID?
  @State private var renamingSessionID: UUID?
  @State private var sessionNameDraft = ""
  @State private var panelRoutineID: UUID?
  @State private var teamDraft = ""
  @State private var teamMentions: [TeamMention] = []
  @State private var teamMentionSelection = 0
  @State private var teamError: String?
  @State private var teamNotice: String?
  @State private var pendingDeletion: DeletionTarget?
  @State private var pendingClear: ClearChatTarget?
  @State private var editingBot: AgentProfile?
  @State private var editingTeam: BotChannel?
  @State private var sidebarQuery = ""
  @State private var collapsedGroups: Set<SidebarGroup> = []
  @State private var hoveredSidebarGroup: SidebarGroup?
  @Environment(\.ottoMotion) private var motion
  @Namespace private var workTabSelection
  @FocusState private var sidebarSearchFocused: Bool
  @FocusState private var teamComposerFocused: Bool
  /// Identity glyph size for bot, team, and session rows in the rail. Shared so the leading
  /// lane lines up across the three row kinds; the row height follows it.
  private static let sidebarAvatarSize: CGFloat = 24
  private static let sidebarRowHeight: CGFloat = 34

  /// Sidebar sections, each collapsible on its own.
  private enum SidebarGroup: String, Hashable {
    case teams
    case bots
    case sessions
  }

  private enum WorkSurface: String, CaseIterable, Identifiable {
    case review
    case terminal
    case browser
    case files
    case sideChat
    case routines
    case playbooks

    var id: String { rawValue }
    var title: String {
      switch self {
      case .review: "Review"
      case .terminal: "Terminal"
      case .browser: "Browser"
      case .files: "Files"
      case .sideChat: "Side chat"
      case .routines: "Automations"
      case .playbooks: "Playbooks"
      }
    }
    var symbol: String {
      switch self {
      case .review: "doc.text.magnifyingglass"
      case .terminal: "terminal"
      case .browser: "globe"
      case .files: "folder"
      case .sideChat: "bubble.left.and.bubble.right"
      case .routines: "clock.arrow.trianglehead.counterclockwise.rotate.90"
      case .playbooks: "book.pages"
      }
    }
  }

  private struct WorkTab: Identifiable, Equatable {
    let id: UUID
    var surface: WorkSurface
    var title: String
    var browserID: UUID?
    var filePath: String?
    /// A terminal an agent started with terminal.run / terminal.open, rather than the agent's own.
    var terminalID: UUID?

    init(
      id: UUID = UUID(),
      surface: WorkSurface,
      title: String? = nil,
      browserID: UUID? = nil,
      filePath: String? = nil,
      terminalID: UUID? = nil
    ) {
      self.id = id
      self.surface = surface
      self.title = title ?? surface.title
      self.browserID = browserID
      self.filePath = filePath
      self.terminalID = terminalID
    }
  }

  private struct TeamMention: Identifiable, Equatable {
    let id: String
    let profileID: UUID?
    let handle: String
    let title: String
  }

  struct ClearChatTarget: Identifiable, Equatable {
    let id: UUID
    let name: String
    let isBot: Bool
  }

  private struct DeletionTarget: Identifiable {
    enum Kind: Equatable { case bot, team }
    let id: UUID
    let kind: Kind
    let name: String
    let nodeID: UUID?
  }

  private var agents: [OttoNode] {
    store.activeCanvas.nodes.filter { $0.kind == .agent }
  }

  private var allAgentNodes: [OttoNode] {
    store.snapshot.canvases.flatMap { $0.nodes.filter { $0.kind == .agent } }
  }

  private var roster: [BotRosterEntry] { services.botRoster() }
  private var teams: [BotChannel] { services.teamChannels() }

  private var hiredProfileIDs: Set<UUID> { Set(roster.map(\.profile.id)) }
  private var hiredNodeIDs: Set<UUID> { Set(roster.compactMap(\.nodeID)) }

  private var canvasSelections: [ChatCanvasSelection] {
    store.snapshot.canvases.map {
      ChatCanvasSelection(canvasID: $0.id, nodeID: $0.selectedNodeID)
    }
  }

  /// One-off canvas agents that are not a hired bot's canonical channel.
  private var boundHelperIDs: Set<UUID> { services.office.boundSessionIDs }

  /// Dashboards and Documents keep their helper beside the work, so focus changes from starting
  /// that helper must not pull the person into a conversation.
  private var onWorkPage: Bool {
    destination == .dashboards || destination == .documents || destination == .browser
  }

  private var sessionAgents: [OttoNode] {
    let sideChatIDs = Set(sideChatAgentIDs.values)
    // Sessions are not tied to a canvas the user can see: list them from every canvas.
    let nodes = store.snapshot.canvases.flatMap(\.nodes)
    return nodes.filter { node in
      if !node.isStandaloneAgent { return false }
      if sideChatIDs.contains(node.id) { return false }
      // Helpers bound to a document or dashboard live beside it, not in this list.
      if boundHelperIDs.contains(node.id) { return false }
      if hiredNodeIDs.contains(node.id) { return false }
      if let profileID = node.agentDefinition?.profileID, hiredProfileIDs.contains(profileID) {
        return false
      }
      return true
    }
  }

  private var selectedEntry: BotRosterEntry? {
    guard selectedSessionID == nil else { return nil }
    if let selectedProfileID {
      return roster.first { $0.profile.id == selectedProfileID }
    }
    return nil
  }

  private var selectedAgent: OttoNode? {
    if let selectedSessionID,
      let session = allAgentNodes.first(where: { $0.id == selectedSessionID })
    {
      return session
    }
    if let nodeID = selectedEntry?.nodeID ?? selectedAgentID,
      let match = allAgentNodes.first(where: { $0.id == nodeID })
    {
      return match
    }
    return nil
  }

  private var mentionableProfiles: [AgentProfile] {
    if let teamID = selectedTeamID,
      let team = services.botChannels.channel(id: teamID)
    {
      return team.memberProfileIDs.compactMap { services.agentProfiles.profile(id: $0) }
    }
    return services.agentProfiles.activeProfiles
  }

  /// Window chrome geometry, measured against the macOS 26 titlebar: the traffic
  /// lights are 14pt across, centred 15.5pt below the window top, and the green
  /// button ends 67pt in. A band of twice that centre height shares their line,
  /// so the controls in it read as one row with the window buttons.
  private enum Chrome {
    static let bandHeight: CGFloat = 31
    static let control: CGFloat = 26
    static let leading: CGFloat = 80
  }

  private var hasThemeArtwork: Bool {
    OttoThemeCatalog.theme(id: store.activeCanvas.themeID).backgroundAsset != nil
      && palette.surfaceMaterial != .windowGlass && palette.surfaceMaterial != .matte
  }

  /// One tint over the artwork for the whole chat; plain themes keep their designed planes.
  private var chatBackdrop: Color {
    // Only reached without the frost (Reduce Transparency): keep it near-solid then.
    hasThemeArtwork ? palette.ink.opacity(0.92) : palette.workspaceSurface
  }
  private var conversationSurface: Color {
    hasThemeArtwork ? Color.clear : palette.chatCardSurface
  }
  private var conversationPalette: OttoPalette {
    hasThemeArtwork ? palette.overThemeArtwork() : palette
  }

  private var notificationVisibleNodeID: UUID? {
    notificationWindowIsActive && destination == .conversation && selectedTeamID == nil
      ? selectedAgentID : nil
  }

  var body: some View {
    VStack(spacing: 0) {
      windowChrome
      HStack(spacing: 0) {
        if showingSidebar {
          sidebar
            .frame(width: 248)
            // Over a clear photo the rail is a solid panel so its list stays readable.
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
        // Flush shell: the rail and the conversation share one surface, split by a hairline,
        // so the chrome recedes and the conversation reads as the page.
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          // Over artwork the rail and conversation share one tint, so Chat reads as one
          // surface with the theme behind it rather than two panels.
          .background(conversationSurface)
          .environment(\.ottoPalette, conversationPalette)
          .overlay(alignment: .leading) {
            if showingSidebar {
              Rectangle().fill(palette.paper.opacity(0.06)).frame(width: 1)
            }
          }
        if let terminal = terminalNodes.first(where: { $0.id == standaloneTerminalID }) {
          standaloneTerminalDrawer(terminal)
        }
      }
    }
    // The chat root sits directly over the theme backdrop, so matte themes let it breathe.
    // Over theme artwork, Chat is the photo plus one light frost across the whole window:
    // no per-message cards or panels. The frost follows light/dark so text stands out.
    .background {
      if hasThemeArtwork && !reduceTransparency {
        Rectangle().fill(.ultraThinMaterial)
      } else {
        chatBackdrop
      }
    }
    .overlay(alignment: .topLeading) { sessionCreatorLayer }
    .modifier(
      SessionRenameAlert(
        isPresented: isRenamingSession, name: $sessionNameDraft,
        cancel: { renamingSessionID = nil }, save: saveSessionName)
    )
    .onAppear {
      if sessionCanvasID == nil { sessionCanvasID = store.activeCanvas.id }
      repairSelection()
      restoreAgentBrowserAssociations()
      applyBotNavigation(services.botNavigationRequest)
      if let request = services.terminalRevealRequest,
        Date().timeIntervalSince(request.createdAt) < 5
      {
        applyTerminalReveal(request)
      }
    }
    .onChange(of: services.terminalRevealRequest) { _, request in
      if let request { applyTerminalReveal(request) }
    }
    .onChange(of: services.botNavigationRequest) { _, request in
      applyBotNavigation(request)
    }
    .onChange(of: services.agentBrowserOpenRequest) { _, request in
      applyAgentBrowserOpenRequest(request)
    }
    .onChange(of: store.activeCanvas.id) { _, _ in repairSelection() }
    .onChange(of: canvasSelections) { previous, current in
      guard
        let target = changedChatFocusedAgentTarget(
          previous: previous,
          current: current,
          canvases: store.snapshot.canvases,
          hiredProfileIDs: hiredProfileIDs
        )
      else { return }
      applyFocusedAgentTarget(target)
    }
    .onChange(of: store.snapshot.canvases.map(\.id)) { _, canvasIDs in
      if let sessionCanvasID, !canvasIDs.contains(sessionCanvasID) {
        self.sessionCanvasID = store.activeCanvas.id
      }
    }
    .onChange(of: agents.map(\.id)) { _, _ in repairSelection() }
    .onChange(of: roster.map(\.id)) { _, _ in repairSelection() }
    .onChange(of: sessionAgents.map(\.id)) { _, _ in repairSelection() }
    .onChange(of: notificationVisibleNodeID, initial: true) { _, nodeID in
      CompletionNotifications.shared.visibleConversations[notificationVisibilityID] =
        spaceVisible ? nodeID : nil
    }
    .onChange(of: spaceVisible) { _, visible in
      CompletionNotifications.shared.visibleConversations[notificationVisibilityID] =
        visible ? notificationVisibleNodeID : nil
    }
    .onDisappear {
      CompletionNotifications.shared.visibleConversations.removeValue(
        forKey: notificationVisibilityID)
      closeAllSideChats()
    }
    .sheet(isPresented: $showingCreateProject) {
      CreateConversationProjectSheet { name, folders in
        let project = try services.conversationProjects.create(name: name, sourceFolders: folders)
        if let channelID = projectCreationChannelID {
          try services.selectProject(channelID: channelID, projectID: project.id)
        } else {
          newSessionProjectID = project.id
          showingSessionCreator = true
        }
      }
    }
    .sheet(isPresented: $showingHire) {
      HireBotSheet(services: services, hired: selectHiredBot)
        .environment(\.ottoPalette, palette)
    }
    .sheet(isPresented: $showingTeam) {
      CreateTeamSheet(services: services) { channel in
        selectedTeamID = channel.id
        selectedProfileID = channel.orchestratorProfileID ?? channel.memberProfileIDs.first
        selectedSessionID = nil
        sidebarList = .bots
        destination = .conversation
        if let leadID = selectedProfileID,
          let lead = roster.first(where: { $0.profile.id == leadID })
        {
          Task { await openEntry(lead) }
        }
      }
      .environment(\.ottoPalette, palette)
    }
    .modifier(
      HarnessKeySetupPresentation(
        request: $harnessKeySetup, services: services, palette: palette,
        launch: { request in
          Task {
            await launchSession(.openAI, folder: request.folder, projectID: request.projectID)
          }
        }
      )
    )
    .modifier(SessionLaunchErrorAlert(message: $sessionLaunchError))
    .sheet(item: $editingBot) { profile in
      HireBotSheet(services: services, editing: profile) { _ in }
        .environment(\.ottoPalette, palette)
    }
    .sheet(item: $editingTeam) { channel in
      CreateTeamSheet(services: services, editing: channel) { _ in }
        .environment(\.ottoPalette, palette)
    }
    .confirmationDialog(
      pendingDeletion.map { "Delete \($0.name)?" } ?? "Delete?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      presenting: pendingDeletion
    ) { target in
      Button("Delete \(target.kind == .team ? "team" : "bot")", role: .destructive) {
        performDeletion(target)
      }
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: { target in
      Text(
        target.kind == .team
          ? "This removes the shared team and its room from Bots. The member bots stay available."
          : "This removes the bot profile and archives its canonical chat and private memory."
      )
    }
    .modifier(ClearChatConfirmation(target: $pendingClear, services: services))
  }

  private var launchPoint: WorldPoint {
    WorldPoint(x: store.activeCanvas.viewport.centerX, y: store.activeCanvas.viewport.centerY)
  }

  private func selectHiredBot(_ profile: AgentProfile) {
    navigation = chatNavigationSelectingHiredBot(
      navigation, profileID: profile.id, nodeID: nil)
    Task {
      do {
        let nodeID = try await services.openBotChannel(profile, at: launchPoint)
        navigation = chatNavigationSelectingHiredBot(
          navigation, profileID: profile.id, nodeID: nodeID)
        store.dispatch(.focusNode(nodeID))
      } catch {
        sideChatError = error.localizedDescription
      }
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      // The profile switch lives in the header.
      VStack(spacing: 2) {
        sidebarSearchRow
          .padding(.bottom, 6)
        sidebarActionRow(title: "New", symbol: "plus") {
          showingSessionCreator.toggle()
        }
        .help("Start a session, hire a bot, or create a team")
        sidebarPlaces
      }
      .padding(.horizontal, 10)
      .padding(.top, 8)

      ScrollView {
        // One highlight for the whole rail: it glides between teams, bots, and sessions
        // instead of blinking off at every group header.
        OttoFluidHover(
          axis: .vertical,
          style: OttoFluidHoverStyle(
            fill: palette.paper.opacity(0.06),
            selectedFill: palette.paper.opacity(0.10),
            cornerRadius: 7),
          selected: sidebarSelectedRowID
        ) {
          LazyVStack(alignment: .leading, spacing: 1) {
            if !filteredTeams.isEmpty {
              sidebarGroupHeader(.teams, title: "teams") {
                Button {
                  showingTeam = true
                } label: {
                  sidebarAddGlyph(.teams)
                }
                .buttonStyle(.ottoChrome(cornerRadius: 5))
                .help("Create a team")
                .accessibilityLabel("Create a team")
              }
              if !collapsedGroups.contains(.teams) {
                ForEach(filteredTeams) { team in
                  teamRow(team)
                    .transition(.ottoUnfold(reduceMotion: motion.reduceMotion))
                }
              }
            }

            sidebarGroupHeader(.bots, title: "bots") {
              Button {
                showingHire = true
              } label: {
                sidebarAddGlyph(.bots)
              }
              .buttonStyle(.ottoChrome(cornerRadius: 5))
              .help("Hire a bot")
              .accessibilityLabel("Hire a bot")
            }
            if !collapsedGroups.contains(.bots) {
              if filteredRoster.isEmpty {
                if sidebarQueryText.isEmpty && teams.isEmpty {
                  sidebarEmpty(
                    title: "No bots yet",
                    detail: "Hire a durable teammate. Its chat stays pinned here."
                  ) {
                    Button("Hire a bot") { showingHire = true }
                  }
                }
              } else {
                ForEach(filteredRoster) { entry in
                  botRow(entry)
                    .transition(.ottoUnfold(reduceMotion: motion.reduceMotion))
                }
              }
            }

            sidebarGroupHeader(.sessions, title: "sessions") {
              Button {
                showingSessionCreator = true
              } label: {
                sidebarAddGlyph(.sessions)
              }
              .buttonStyle(.ottoChrome(cornerRadius: 5))
              .help("Start a session")
              .accessibilityLabel("Start a session")
            }
            if !collapsedGroups.contains(.sessions) {
              if filteredSessions.isEmpty {
                if sidebarQueryText.isEmpty {
                  sidebarEmpty(
                    title: "No sessions loaded",
                    detail: "One-off chats with an agent land here. They are not hired bots."
                  ) {
                    EmptyView()
                  }
                }
              } else {
                ForEach(filteredSessions) { node in
                  sessionRow(node)
                    .transition(.ottoUnfold(reduceMotion: motion.reduceMotion))
                }
              }
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
        }
      }
      // No scroll thumb in the rail: on light themes it read as a stray white bar.
      .ottoScrollChrome(showsThumb: false)
      .frame(maxHeight: .infinity)

      VStack(spacing: 0) {
        voiceControlRow
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
        sidebarIdentityRow
          .padding(.horizontal, 10)
          .overlay(alignment: .top) {
            Rectangle().fill(palette.paper.opacity(0.06)).frame(height: 1)
          }
      }
    }
  }

  /// Places live at the top of the rail, like a short table of contents, with quiet counts.
  private var sidebarPlaces: some View {
    OttoFluidHover(
      axis: .vertical,
      style: OttoFluidHoverStyle(
        fill: palette.paper.opacity(0.05),
        selectedFill: palette.paper.opacity(0.08),
        cornerRadius: 7),
      selected: destination == .conversation ? nil : destination
    ) {
      VStack(spacing: 1) {
        destinationRow(
          .activity, symbol: "tray",
          count: ActivityNeedsYou(
            services: services, activity: services.botActivity, reviews: services.homeReviews
          ).count)
        destinationRow(
          .routines, symbol: "clock", count: services.routines.routines.count)
        destinationRow(
          .browser, symbol: "globe", count: chatBrowserNode?.browserSession?.tabs.count ?? 0)
        destinationRow(
          .dashboards, symbol: "chart.bar.xaxis", count: services.homeCards.dashboards.count)
        destinationRow(
          .documents, symbol: "doc.richtext", count: services.office.files.count)
        destinationRow(
          .files, symbol: "doc.text", count: libraryItems(kinds: [.markdown, .media]).count)
        destinationRow(.skills, symbol: "sparkles", count: services.skills.entries.count)
      }
    }
  }

  private var sidebarSearchRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.muted)
        .frame(width: 18)
      TextField("Search", text: $sidebarQuery)
        .textFieldStyle(.plain)
        .font(.ottoDisplay(13))
        .foregroundStyle(palette.paper)
        .focused($sidebarSearchFocused)
      if !sidebarQuery.isEmpty {
        Button {
          sidebarQuery = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(palette.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 7)
    .frame(height: 30)
    .background(
      palette.paper.opacity(sidebarSearchFocused ? 0.06 : 0.03),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(palette.paper.opacity(sidebarSearchFocused ? 0.14 : 0.07), lineWidth: 1)
    )
    .contentShape(Rectangle())
    .onTapGesture { sidebarSearchFocused = true }
  }

  private func sidebarActionRow(
    title: String, symbol: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .regular))
          .frame(width: 18)
        Text(title)
          .font(.ottoDisplay(13))
        Spacer(minLength: 0)
      }
      .foregroundStyle(palette.paper.opacity(0.78))
      .padding(.horizontal, 7)
      .frame(height: 30)
      .contentShape(Rectangle())
    }
    .buttonStyle(.ottoChrome)
  }

  private func sidebarGroupHeader<Trailing: View>(
    _ group: SidebarGroup, title: String, @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    let collapsed = collapsedGroups.contains(group)
    return HStack(spacing: 4) {
      Button {
        withAnimation(motion.enter(.moderate)) {
          if collapsed {
            collapsedGroups.remove(group)
          } else {
            collapsedGroups.insert(group)
          }
        }
      } label: {
        HStack(spacing: 4) {
          Text(title.uppercased())
            .font(.ottoMicro)
            .tracking(2.2)
            .foregroundStyle(palette.muted)
          Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(palette.muted)
            .rotationEffect(.degrees(collapsed ? -90 : 0))
            .opacity(hoveredSidebarGroup == group || collapsed ? 1 : 0)
            .animation(motion.enter(.fast), value: collapsed)
            .animation(motion.fade, value: hoveredSidebarGroup == group)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(collapsed ? "Expand \(title)" : "Collapse \(title)")
      trailing()
    }
    .padding(.horizontal, 8)
    .frame(height: 26)
    .padding(.top, 12)
    .onHover { hovering in
      if hovering {
        hoveredSidebarGroup = group
      } else if hoveredSidebarGroup == group {
        hoveredSidebarGroup = nil
      }
    }
  }

  private func sidebarAddGlyph(_ group: SidebarGroup) -> some View {
    Image(systemName: "plus")
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(palette.muted)
      .frame(width: 18, height: 18)
      .opacity(hoveredSidebarGroup == group ? 1 : 0)
      .animation(motion.fade, value: hoveredSidebarGroup == group)
      .contentShape(Rectangle())
  }

  /// One rail row: a leading identity glyph, a single-line name, and an optional status dot.
  /// `running` swaps the trailing slot for the same spinner session rows use, so a bot or
  /// team that is working for you reads the same way as a busy session.
  private func sidebarRowLabel<Leading: View>(
    title: String, active: Bool, dot: Color?, running: Bool = false,
    @ViewBuilder leading: () -> Leading
  ) -> some View {
    HStack(spacing: 8) {
      leading()
        .frame(width: Self.sidebarAvatarSize, height: Self.sidebarAvatarSize)
      OttoWeightStableText(
        title, size: 13, active: active,
        activeColor: palette.paper, restingColor: palette.paper.opacity(0.78))
      Spacer(minLength: 4)
      if running {
        ProgressView().controlSize(.mini)
          .frame(width: 18, height: 18)
          .accessibilityLabel("Working")
      } else if let dot {
        Circle().fill(dot).frame(width: 5, height: 5)
      }
    }
    .padding(.horizontal, 7)
    .frame(height: Self.sidebarRowHeight)
    .contentShape(Rectangle())
  }

  /// The rail row the selection fill sits on. Rows are keyed by kind so a bot and a session
  /// with the same underlying node never collide.
  private var sidebarSelectedRowID: String? {
    guard destination == .conversation else { return nil }
    if let selectedTeamID { return "team:\(selectedTeamID)" }
    if let selectedSessionID { return "session:\(selectedSessionID)" }
    if let selectedProfileID { return "bot:\(selectedProfileID)" }
    return nil
  }

  private var sidebarIdentityRow: some View {
    let summary = services.presenceSummary()
    return HStack(spacing: 8) {
      Button {
        openSettings()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "gearshape").font(.system(size: 12))
          Text("Settings").font(.ottoDisplay(12))
        }
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 6)
        .frame(height: 26)
        .contentShape(Rectangle())
      }
      .buttonStyle(.ottoChrome(cornerRadius: 6))
      .help("Open settings")
      .accessibilityLabel("Open settings")
      Button {
        NotificationCenter.default.post(name: .ottoSendFeedback, object: nil)
      } label: {
        Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
          .font(.system(size: 11))
          .foregroundStyle(palette.muted)
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.ottoChrome(cornerRadius: 6))
      .help("Send feedback")
      .accessibilityLabel("Send feedback")
      Button {
        OttoCommunityLinks.openDiscord()
      } label: {
        DiscordGlyph(size: 12, color: palette.muted)
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.ottoChrome(cornerRadius: 6))
      .help("Join the Otto community on Discord")
      .accessibilityLabel("Join the Otto community on Discord")
      Spacer(minLength: 4)
      HStack(spacing: 5) {
        Circle()
          .fill(summary.needsYou > 0 ? palette.cyan : palette.signal)
          .frame(width: 6, height: 6)
        Text(
          (summary.needsYou > 0 ? "\(summary.needsYou) needs you" : "\(summary.active) active")
            .uppercased()
        )
        .font(.ottoMicro).tracking(1.6)
        .foregroundStyle(palette.muted)
        .lineLimit(1)
      }
      .help("\(summary.active) active · \(summary.needsYou) needs you")
    }
    .frame(height: 38)
  }

  private var sidebarQueryText: String {
    sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func sidebarMatches(_ text: String) -> Bool {
    sidebarQueryText.isEmpty || text.lowercased().contains(sidebarQueryText)
  }

  private var filteredRoster: [BotRosterEntry] {
    roster.filter { sidebarMatches($0.profile.name) || sidebarMatches($0.profile.handle) }
  }

  private var filteredTeams: [BotChannel] {
    teams.filter { sidebarMatches(teamTitle($0)) }
  }

  private var filteredSessions: [OttoNode] {
    sessionAgents.filter { sidebarMatches($0.displayName) }
  }

  /// The session creator, kept inside the window. A `.popover` is a separate
  /// AppKit window and is free to lay out past the app frame; an overlay is
  /// clamped to the chat shell and anchored beside the rail that opened it.
  @ViewBuilder private var sessionCreatorLayer: some View {
    ZStack(alignment: .topLeading) {
      if showingSessionCreator {
        Color.black.opacity(0.001)
          .contentShape(Rectangle())
          .onTapGesture { showingSessionCreator = false }
        sessionCreatorPopover
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(palette.paper.opacity(0.10), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
          .padding(.leading, showingSidebar ? 256 : Chrome.leading + 8)
          .padding(.top, Chrome.bandHeight + 8)
          .transition(.ottoPopup(from: .top, reduceMotion: motion.reduceMotion))
          .onExitCommand { showingSessionCreator = false }
      }
    }
    .animation(
      motion.presence(.fast, isPresented: showingSessionCreator), value: showingSessionCreator)
  }

  /// Starts a one-off session and opens it, or says why it could not start.
  private func launchSession(_ provider: AgentProvider, folder: String?, projectID: UUID?) async {
    let agentID: UUID
    do { agentID = try await quickLaunchAgent(provider, folder) } catch {
      sessionLaunchError = error.localizedDescription
      return
    }
    do { try services.selectProject(channelID: agentID, projectID: projectID) } catch {
      projectContextError = error.localizedDescription
    }
    selectNewSession(agentID)
  }

  private var sessionCreatorPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("NEW SESSION")
        .font(.ottoMono(8, weight: .black))
        .tracking(1.2)
        .foregroundStyle(palette.signal)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)

      VStack(alignment: .leading, spacing: 8) {
        Picker("Project", selection: $newSessionProjectID) {
          Text("Unassigned").tag(UUID?.none)
          ForEach(services.conversationProjects.projects) { project in
            Text(project.name).tag(Optional(project.id))
          }
        }
        .onAppear {
          guard !initializedSessionProject else { return }
          initializedSessionProject = true
          if newSessionProjectID == nil {
            newSessionProjectID =
              services.conversationProjects.projects.first { $0.isLegacyWorkspace }?.id
          }
        }
        Button {
          projectCreationChannelID = nil
          showingSessionCreator = false
          showingCreateProject = true
        } label: {
          Label("New project…", systemImage: "folder.badge.plus")
        }
        if let projectContextError {
          Text(projectContextError).font(.caption).foregroundStyle(.red)
        }
      }.padding(.horizontal, 12).padding(.bottom, 8)

      OttoFluidHover(
        axis: .vertical,
        style: OttoFluidHoverStyle(fill: palette.paper.opacity(0.06), cornerRadius: 6, inset: 0)
      ) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(SessionLaunchProviderCatalog.providers, id: \.self) { provider in
            Button {
              showingSessionCreator = false
              sidebarList = .sessions
              let projectID = newSessionProjectID
              // A project with a source folder runs Claude Code and Codex sessions there, so the
              // repository's own agent setup (CLAUDE.md, .claude/, AGENTS.md) applies.
              let folder = services.conversationProjects.workingFolder(
                projectID: projectID, provider: provider)
              Task {
                // Otto's harness has no login of its own: with no vendor key and no local
                // server the launch can only fail, so ask for one first and start afterwards.
                if provider == .openAI,
                  await !OttoHarnessLaunchReadiness.isReady(accounts: services.providerAccounts)
                {
                  harnessKeySetup = HarnessKeySetupRequest(projectID: projectID, folder: folder)
                  return
                }
                await launchSession(provider, folder: folder, projectID: projectID)
              }
            } label: {
              HStack(spacing: 10) {
                AgentProviderLogo(provider: provider, size: 15, color: palette.paper)
                Text(SessionLaunchProviderCatalog.title(for: provider))
                  .font(.ottoDisplay(12).weight(.medium))
                Spacer()
              }
              .contentShape(Rectangle())
              .padding(.horizontal, 12)
              .frame(height: 32)
            }
            .buttonStyle(.plain)
            .ottoHoverItem("provider:\(provider.rawValue)")
          }

          Divider().overlay(palette.paper.opacity(0.08))
            .padding(.vertical, 6)

          creatorAction("Hire a bot", symbol: "person.crop.circle.badge.plus") {
            showingSessionCreator = false
            sidebarList = .bots
            showingHire = true
          }
          .ottoHoverItem("creator:hire")
          creatorAction("Create a team", symbol: "person.3") {
            showingSessionCreator = false
            sidebarList = .bots
            showingTeam = true
          }
          .ottoHoverItem("creator:team")
          if let selectedEntry {
            creatorAction(
              "Give \(selectedEntry.profile.name) a routine", symbol: "clock.badge.plus"
            ) {
              showingSessionCreator = false
              openRoutinePanel()
            }
            .ottoHoverItem("creator:routine")
          }
        }
        .padding(.horizontal, 6)
      }
    }
    .foregroundStyle(palette.paper)
    .padding(.bottom, 8)
    .frame(width: 218)
    // A floating menu needs its own opaque plate. `paneSurface` is a 14% tint meant for
    // panes that sit on the window acrylic; over the transcript it let the conversation
    // read straight through the provider list, so match the session provider picker instead.
    .background(palette.raised.opacity(0.94))
  }

  private func creatorAction(
    _ title: String, symbol: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.ottoDisplay(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder private var content: some View {
    switch destination {
    case .conversation:
      if let selectedAgent {
        conversation(for: selectedAgent)
      } else {
        emptyConversation
      }
    case .activity:
      activityInbox
    case .files:
      resourceBrowser(
        title: "Files & notes",
        subtitle: "Notes and media in this profile",
        symbol: "doc.on.doc",
        items: libraryItems(kinds: [.markdown, .media])
      )
    case .routines:
      routinesBrowser
    case .dashboards:
      DashboardsView(
        services: services, cards: services.homeCards, office: services.office,
        cardPalette: cardPalette,
        start: startAssistant, openAutomations: { destination = .routines },
        conversation: { nodeID in assistantConversation(nodeID) })
    case .documents:
      DocumentsView(services: services, office: services.office, start: startAssistant) {
        nodeID in
        assistantConversation(nodeID)
      }
    case .skills:
      SkillsView(services: services, library: services.skills)
    case .browser:
      ChatBrowserPlace(
        services: services,
        browser: chatBrowserNode,
        ensureBrowser: { _ = ensureChatBrowser() },
        start: startAssistant,
        page: { browser, chrome in chatBrowserBody(browser, chrome: chrome) },
        conversation: { nodeID in assistantConversation(nodeID) }
      )
    }
  }

  // MARK: Terminals

  /// Every terminal in the workspace, newest first. Terminals started by agents live on whatever
  /// canvas the agent used; their work tabs retain access across conversations.
  private var terminalNodes: [OttoNode] {
    store.snapshot.canvases.flatMap(\.nodes)
      .filter { $0.kind == .terminal }
      .sorted { $0.createdAt > $1.createdAt }
  }

  private func terminalSnapshot(_ id: UUID) -> AgentRuntimeSnapshot? {
    services.fleetStore.snapshot(for: id)
  }

  private func terminalStatus(_ node: OttoNode) -> ChatTerminalStatus {
    // The node status is what the store publishes, so it drives re-rendering; the snapshot adds
    // whether typing is hidden and the exit code.
    let snapshot = terminalSnapshot(node.id)
    if node.status == .waiting {
      return .waiting(
        hiddenInput: snapshot?.attentionToken == TerminalInputWaitDetector.hiddenInputToken)
    }
    return ChatTerminalStatus.resolve(snapshot, fallback: node.status)
  }

  private func terminalIsWaiting(_ id: UUID) -> Bool {
    terminalNodes.first { $0.id == id }.map { terminalStatus($0).isWaiting } ?? false
  }

  private func terminalCommand(_ node: OttoNode) -> String? {
    // terminal.run keeps the command as the subtitle; bare shells keep the "ZSH · LOCAL" label.
    node.subtitle.isEmpty || node.subtitle.hasSuffix("· LOCAL") ? nil : node.subtitle
  }

  private func terminalOwner(_ node: OttoNode) -> OttoNode? {
    guard let ownerID = node.parentAgentID else { return nil }
    return allAgentNodes.first { $0.id == ownerID }
  }

  /// The owner's conversation can be shown in Chat: a listed session or a hired bot's channel.
  private func ownerIsVisibleInChat(_ owner: OttoNode) -> Bool {
    sessionAgents.contains { $0.id == owner.id } || roster.contains { $0.nodeID == owner.id }
  }

  private func waitingTerminalNotices(owner ownerID: UUID) -> [ChatTerminalNotice] {
    terminalNodes.filter { $0.parentAgentID == ownerID }.compactMap { node in
      guard case .waiting(let hidden) = terminalStatus(node) else { return nil }
      let reason =
        terminalSnapshot(node.id)?.attentionReason
        ?? services.attentionItems.first { $0.nodeID == node.id }?.reason
      return ChatTerminalNotice(
        id: node.id, title: node.displayName, prompt: reason, hiddenInput: hidden)
    }
  }

  /// Brings a terminal forward in its conversation's work drawer. Terminals without a
  /// visible conversation use the same right-hand drawer beside the current page.
  /// Create command tabs only here, on an explicit user reveal. Registering all commands
  /// still exposes routine terminals whenever a browser has already opened the work panel.
  private func applyTerminalReveal(_ request: TerminalRevealRequest) {
    guard let terminal = terminalNodes.first(where: { $0.id == request.terminalID }) else {
      return
    }
    terminalFocusTokens[terminal.id, default: 0] += 1
    guard let owner = terminalOwner(terminal), ownerIsVisibleInChat(owner),
      let canvasID = store.canvasID(containing: owner.id)
    else {
      showingWorkPanel = false
      standaloneTerminalID = terminal.id
      return
    }
    standaloneTerminalID = nil
    if let profileID = owner.agentDefinition?.profileID,
      roster.contains(where: { $0.profile.id == profileID && $0.nodeID == owner.id })
    {
      navigation = chatNavigationSelectingHiredBot(
        navigation, profileID: profileID, nodeID: owner.id)
    } else {
      destination = .conversation
      sessionCanvasID = canvasID
      sidebarList = .sessions
      selectedTeamID = nil
      selectedProfileID = nil
      selectedSessionID = owner.id
      selectedAgentID = owner.id
    }
    let tab: WorkTab
    if let existing = workTabs[owner.id]?.first(where: { $0.terminalID == terminal.id }) {
      tab = existing
    } else {
      tab = WorkTab(surface: .terminal, title: terminal.displayName, terminalID: terminal.id)
      workTabs[owner.id, default: []].append(tab)
    }
    selectedWorkTabIDs[owner.id] = tab.id
    withAnimation(.easeOut(duration: 0.16)) {
      showingWorkPanel = true
      showingAgentDetails = false
      showingEnvironment = false
    }
  }

  @ViewBuilder private func workOwnedTerminal(_ terminalID: UUID, owner: OttoNode) -> some View {
    if let terminal = terminalNodes.first(where: { $0.id == terminalID }) {
      terminalPane(terminal, showsOwner: false)
    } else {
      VStack(spacing: 8) {
        Image(systemName: "terminal").font(.system(size: 22, weight: .light))
        Text("This terminal was closed.").font(.ottoDisplay(13))
      }
      .foregroundStyle(palette.muted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func terminalPane(_ terminal: OttoNode, showsOwner: Bool) -> some View {
    let owner = terminalOwner(terminal)
    let canOpenOwner = showsOwner && owner.map(ownerIsVisibleInChat) == true
    return ChatAgentSnapshotHost(model: services.fleetStore.model(for: terminal.id)) { snapshot in
      ChatTerminalPane(
        title: terminal.displayName,
        command: terminalCommand(terminal),
        ownerName: showsOwner ? owner?.displayName : nil,
        snapshot: snapshot,
        fallbackStatus: terminal.status,
        sessionKey: "chat-terminal-\(terminal.id.uuidString)",
        focusToken: terminalFocusTokens[terminal.id] ?? 0,
        send: { data in
          Task { try? await services.sendTerminalBytes(terminalID: terminal.id, data: data) }
        },
        resize: { columns, rows in
          Task {
            try? await services.resizeTerminal(
              terminalID: terminal.id, columns: columns, rows: rows)
          }
        },
        stop: { Task { try? await services.stop(agentID: terminal.id) } },
        openConversation: canOpenOwner
          ? { services.revealTerminal(terminal.id) } : nil,
        // In a conversation's work panel the tab's close button is enough.
        remove: showsOwner
          ? {
            if standaloneTerminalID == terminal.id { standaloneTerminalID = nil }
            Task { try? await services.closeNode(nodeID: terminal.id) }
          } : nil
      )
    }
    .id(terminal.id)
  }

  /// A terminal can outlive its conversation or be opened directly by the person.
  /// Keep it accessible in the work drawer without introducing another navigation place.
  private func standaloneTerminalDrawer(_ terminal: OttoNode) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label(terminal.displayName, systemImage: "terminal")
          .font(.ottoDisplay(12))
          .lineLimit(1)
        Spacer()
        Button {
          standaloneTerminalID = nil
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close work panel")
      }
      .padding(12)
      Divider()
      terminalPane(terminal, showsOwner: true)
    }
    .background(palette.paneSurface)
    .frame(width: 420)
  }

  // MARK: Browser place

  /// The Browser place keeps one browser per workspace, remembered by node ID.
  private var chatBrowserDefaultsKey: String {
    "otto.chatBrowserNodeID.\(services.documents.rootPath)"
  }

  private var chatBrowserNode: OttoNode? {
    guard let raw = UserDefaults.standard.string(forKey: chatBrowserDefaultsKey),
      let id = UUID(uuidString: raw)
    else { return nil }
    return store.snapshot.canvases.flatMap(\.nodes).first { $0.id == id && $0.kind == .browser }
  }

  @discardableResult private func ensureChatBrowser() -> UUID? {
    if let existing = chatBrowserNode { return existing.id }
    let canvasID = store.activeCanvas.id
    guard
      let browserID = store.dispatch(
        .createNode(kind: .browser, at: launchPoint), targetCanvasID: canvasID
      ).affectedNodeIDs.first
    else { return nil }
    store.dispatch(
      .setNodeContent(id: browserID, content: .browser(url: BrowserDefaults.startURL)),
      targetCanvasID: canvasID)
    store.dispatch(
      .setBrowserSession(id: browserID, session: BrowserSession(url: BrowserDefaults.startURL)),
      targetCanvasID: canvasID)
    UserDefaults.standard.set(browserID.uuidString, forKey: chatBrowserDefaultsKey)
    return browserID
  }

  @ViewBuilder private func chatBrowserBody(
    _ browser: OttoNode, chrome: BrowserChromeStyle
  ) -> some View {
    if let canvasID = store.canvasID(containing: browser.id) {
      BrowserBody(
        node: browser,
        scale: 1,
        isSelected: true,
        isDragging: false,
        runtime: services.browserRuntime,
        capture: services.captureBrowser,
        updateContent: {
          store.dispatch(.setNodeContent(id: browser.id, content: $0), targetCanvasID: canvasID)
        },
        updateBrowserSession: {
          store.dispatch(
            .setBrowserSession(id: browser.id, session: $0), targetCanvasID: canvasID)
        },
        updateBrowserTab: { tabID, url, title in
          store.dispatch(
            .updateBrowserTab(id: browser.id, tabID: tabID, url: url, title: title),
            targetCanvasID: canvasID)
        },
        chrome: chrome
      )
      .id(browser.id)
    }
  }

  /// Dashboards and Home cards keep their smoked-glass look: light themes borrow a dark palette.
  private var cardPalette: OttoPalette {
    OttoThemeCatalog.theme(id: store.activeCanvas.themeID).isLightAppearance
      ? OttoPalette(theme: OttoThemeCatalog.aurora) : palette
  }

  /// The helper's conversation, shown beside a dashboard or document.
  @ViewBuilder private func assistantConversation(_ nodeID: UUID) -> some View {
    if let node = store.snapshot.canvases.flatMap(\.nodes).first(where: { $0.id == nodeID }) {
      agentConversationBody(for: node, routesMentions: false, isSelected: true)
    } else {
      Text("This chat has ended. Ask again to start a new one.")
        .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }

  /// Sends a message to the helper bound to `key` (a document path or dashboard), starting one
  /// for `target` if needed. The helper stays beside its document or dashboard: it is kept out of
  /// the Sessions list and Chat never navigates to it.
  private func startAssistant(_ target: AssistantTarget, _ message: String, _ key: String)
    async throws -> UUID
  {
    let nodes = store.snapshot.canvases.flatMap(\.nodes)
    let id: UUID
    if let existing = services.office.session(path: key),
      nodes.contains(where: { $0.id == existing })
    {
      id = existing
    } else {
      switch target {
      case .provider(let provider):
        do { id = try await quickLaunchAgent(provider, nil) } catch {
          throw NSError(
            domain: "Otto", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Couldn’t start \(provider.rawValue). \(error.localizedDescription)"
            ])
        }
      case .bot(let profileID):
        guard let entry = services.botRoster().first(where: { $0.profile.id == profileID }) else {
          throw NSError(
            domain: "Otto", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "That bot is no longer available."])
        }
        id = try await services.openBotChannel(entry.profile, at: launchPoint)
      }
      // Bind before the first turn so the hidden instructions travel with it.
      services.office.setSession(id, path: key)
    }
    // A bot's channel is shared with its own chat, so it gets the instructions with this turn
    // only, as hidden context, rather than for every turn.
    if case .bot = target,
      let instructions = ApplicationServices.workInstructions(
        key: key, office: services.office, cards: services.homeCards)
    {
      try await services.sendPrompt(agentID: id, prompt: message, hiddenContext: instructions)
    } else {
      try await services.sendPrompt(agentID: id, prompt: message)
    }
    return id
  }

  private var activityInbox: some View {
    ActivityInboxView(
      services: services, activity: services.botActivity, reviews: services.homeReviews,
      agentName: { id in allAgentNodes.first { $0.id == id }?.displayName },
      openAgent: { id in
        if let node = allAgentNodes.first(where: { $0.id == id }) { selectSession(node) }
      },
      openDeepLink: openDeepLink
    )
  }

  private func openDeepLink(_ link: BotActivityDeepLink) {
    switch link {
    case .bot(let profileID, _):
      selectedProfileID = profileID
      selectedTeamID = nil
      destination = .conversation
      if let entry = roster.first(where: { $0.profile.id == profileID }) {
        Task { await openEntry(entry) }
      }
    case .team(let channelID):
      selectedTeamID = channelID
      selectedProfileID = nil
      destination = .conversation
    case .agent(let nodeID):
      if let node = allAgentNodes.first(where: { $0.id == nodeID }) { selectSession(node) }
    case .routine:
      destination = .routines
    case .effect, .memory:
      break
    }
  }

  @ViewBuilder private func conversation(for node: OttoNode) -> some View {
    VStack(spacing: 0) {
      if let channelID = selectedTeamID
        ?? (selectedSessionID == nil ? selectedEntry?.channel?.id : selectedSessionID)
      {
        projectContextBar(channelID: channelID, node: node)
      }
      GeometryReader { geometry in
        let minimumPanelWidth = min(300.0, geometry.size.width * 0.5)
        let maximumPanelWidth = max(minimumPanelWidth, geometry.size.width - 280)
        let defaultPanelWidth = min(max(380, geometry.size.width * 0.48), 720)
        let workPanelWidth = min(
          maximumPanelWidth,
          max(
            minimumPanelWidth,
            preferredWorkPanelWidth > 0 ? preferredWorkPanelWidth : defaultPanelWidth))
        let trailingInset = showingWorkPanel ? workPanelWidth : 0
        ZStack(alignment: .trailing) {
          Group {
            if let teamID = selectedTeamID, let team = services.botChannels.channel(id: teamID) {
              teamConversation(team)
                .environment(
                  \.openURL,
                  OpenURLAction { url in
                    openConversationLink(url, for: node, workspaceRoot: services.documents.rootPath)
                  })
            } else {
              agentConversationBody(
                for: node,
                routesMentions: true,
                isSelected: !showingWorkPanel || activeWorkTab(for: node)?.surface != .sideChat
              )
            }
          }
          .padding(.trailing, trailingInset)
          .animation(.easeOut(duration: 0.16), value: showingWorkPanel)
          if showingWorkPanel {
            workPanel(for: node)
              .frame(width: workPanelWidth)
              .frame(maxHeight: .infinity)
              .overlay(alignment: .leading) {
                WorkPanelResizeHandle(
                  began: { workPanelDragStart = workPanelWidth },
                  changed: { translation in
                    preferredWorkPanelWidth = min(
                      maximumPanelWidth,
                      max(minimumPanelWidth, (workPanelDragStart ?? workPanelWidth) - translation))
                  },
                  ended: { workPanelDragStart = nil }
                )
                .frame(width: 10)
                .offset(x: -5)
                .help("Drag to resize the work panel")
              }
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
        .overlay(alignment: .topTrailing) {
          if showingEnvironment && !showingWorkPanel {
            environmentCard(for: node)
              .padding(16)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
      }
    }
  }

  /// What a project does when an agent's account hits its usage limit. Switching needs an
  /// explicit fallback account so project work never moves accounts by surprise.
  @ViewBuilder private func usageLimitPolicyControls(projectID: UUID) -> some View {
    let project = services.conversationProjects.projects.first { $0.id == projectID }
    let policy = project?.usageLimitPolicy ?? .ask
    let fallback = project?.usageLimitFallbackAccountID
    let save: (ProviderUsageLimitPolicy, UUID?) -> Void = { policy, fallback in
      do {
        try services.conversationProjects.setUsageLimitPolicy(
          projectID: projectID, policy: policy, fallbackAccountID: fallback)
      } catch {
        projectContextError = error.localizedDescription
      }
    }
    Picker(
      "At a usage limit",
      selection: Binding(
        get: { policy },
        set: { next in
          save(next, fallback ?? services.providerAccounts.accounts.first?.id)
        })
    ) {
      Text("Ask me").tag(ProviderUsageLimitPolicy.ask)
      Text("Wait for reset").tag(ProviderUsageLimitPolicy.waitForReset)
      Text("Switch account").tag(ProviderUsageLimitPolicy.switchAccount)
    }
    if policy != .waitForReset {
      Picker(
        policy == .switchAccount ? "Switch to" : "Suggest first",
        selection: Binding<UUID?>(get: { fallback }, set: { save(policy, $0) })
      ) {
        Text("None").tag(UUID?.none)
        ForEach(services.providerAccounts.accounts) { account in
          Text(account.name).tag(Optional(account.id))
        }
      }
    }
  }

  private func projectContextBar(channelID: UUID, node: OttoNode) -> some View {
    let context = services.conversationProjects.context(channelID: channelID)
    return HStack(spacing: 10) {
      Button {
        projectContextError = nil
        showingProjectContext = true
      } label: {
        Label("Working in: \(context.name)", systemImage: "folder")
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.paper.opacity(0.86))
      }
      .buttonStyle(.plain)
      .popover(isPresented: $showingProjectContext) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Project context").font(.headline)
          Text("This chat continues across projects. Earlier messages stay in its history.")
            .font(.caption).foregroundStyle(.secondary)
          Picker(
            "Working in",
            selection: Binding<UUID?>(
              get: { services.conversationProjects.context(channelID: channelID).projectID },
              set: { id in
                do { try services.selectProject(channelID: channelID, projectID: id) } catch {
                  projectContextError = error.localizedDescription
                }
              })
          ) {
            Text("Unassigned").tag(UUID?.none)
            ForEach(services.conversationProjects.projects) { project in
              Text(project.name).tag(Optional(project.id))
            }
          }
          if !context.sourceFolders.isEmpty {
            Text("Source folders").font(.subheadline)
            ForEach(context.sourceFolders, id: \.self) { path in
              Label(path, systemImage: "folder").font(.caption).textSelection(.enabled)
            }
          }
          if let projectID = context.projectID, !services.providerAccounts.accounts.isEmpty {
            Picker(
              "Default account",
              selection: Binding<UUID?>(
                get: {
                  services.conversationProjects.projects.first { $0.id == projectID }?
                    .defaultAccountID
                },
                set: { id in
                  do {
                    try services.conversationProjects.setDefaultAccount(
                      projectID: projectID, accountID: id)
                  } catch {
                    projectContextError = error.localizedDescription
                  }
                })
            ) {
              Text("Global default").tag(UUID?.none)
              ForEach(services.providerAccounts.accounts) { account in
                Text(account.name).tag(Optional(account.id))
              }
            }
            Text("Agents in \(context.name) run on this account unless one is chosen per agent.")
              .font(.caption).foregroundStyle(.secondary)
            usageLimitPolicyControls(projectID: projectID)
          }
          Button {
            projectCreationChannelID = channelID
            showingProjectContext = false
            showingCreateProject = true
          } label: {
            Label("New project…", systemImage: "folder.badge.plus")
          }
          Text(
            "Running work keeps its original project. Folder access and permissions stay unchanged."
          )
          .font(.caption).foregroundStyle(.secondary)
          if let projectContextError = projectContextError
            ?? services.conversationProjects.persistenceError
          {
            Text(projectContextError).font(.caption).foregroundStyle(.red)
          }
        }.padding(16).frame(width: 350)
      }
      if let running = services.runningProjectDescription(channelID: channelID) {
        Text(running).font(.ottoDisplay(11)).foregroundStyle(palette.muted)
      }
      Spacer()
      Text(node.agentDefinition?.workingDirectory ?? services.documents.rootPath)
        .font(.ottoDisplay(11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
        .help("Working directory; independent of project context")
    }.padding(.horizontal, 16).padding(.vertical, 8)
  }

  private func openConversationLink(
    _ url: URL, for node: OttoNode, workspaceRoot: String
  ) -> OpenURLAction.Result {
    if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
      guard let browserID = createWorkBrowser(for: node, url: url.absoluteString) else {
        return .discarded
      }
      let tab = WorkTab(surface: .browser, title: url.host ?? "Browser", browserID: browserID)
      workTabs[node.id, default: []].append(tab)
      selectedWorkTabIDs[node.id] = tab.id
      withAnimation(.easeOut(duration: 0.16)) {
        showingWorkPanel = true
        showingEnvironment = false
        showingAgentDetails = false
      }
      return .handled
    }
    guard let path = chatDocumentLinkPath(url, workspaceRoot: workspaceRoot) else {
      return .systemAction
    }
    let existing = workTabs[node.id, default: []].first {
      $0.surface == .files && $0.filePath == path
    }
    let tab =
      existing
      ?? WorkTab(
        surface: .files, title: (path as NSString).lastPathComponent, filePath: path)
    if existing == nil { workTabs[node.id, default: []].append(tab) }
    selectedWorkTabIDs[node.id] = tab.id
    withAnimation(.easeOut(duration: 0.16)) {
      showingWorkPanel = true
      showingEnvironment = false
      showingAgentDetails = false
    }
    return .handled
  }

  private func agentConversationBody(
    for node: OttoNode, routesMentions: Bool, isSelected: Bool
  ) -> some View {
    ChatAgentSnapshotHost(model: services.fleetStore.model(for: node.id)) { snapshot in
      AgentConversationBody(
        node: node,
        snapshot: services.privateConversationSnapshot(snapshot, nodeID: node.id),
        turnChanges: services.turnChanges[node.id],
        turnDiff: { file in await services.turnDiff(agentID: node.id, file: file) },
        revertTurn: { try await services.revertLastTurn(agentID: node.id) },
        history: services.runHistory[node.id, default: []],
        scale: 1,
        isSelected: isSelected,
        presentation: .conversation,
        isStageMode: false,
        hidesSurfaceBar: true,
        responseInspectorAllowed: !showingWorkPanel,
        onInspectResponse: {
          showingWorkPanel = false
          showingEnvironment = false
        },
        onOpenLink: { url in
          openConversationLink(
            url, for: selectedAgent ?? node,
            workspaceRoot: node.agentDefinition?.workingDirectory ?? services.documents.rootPath)
        },
        ottoWorkspacePath: services.defaultWorkspacePath,
        enterStage: {},
        focus: { store.dispatch(.focusNode(node.id)) },
        setPresentation: {
          store.dispatch(.setNodePresentation(id: node.id, presentation: $0))
        },
        send: { text, isInput in
          Task {
            if routesMentions {
              await routeComposer(text, from: node, isInput: isInput)
            } else if isInput && !AgentSlashCommandParser.isCommand(text) {
              do {
                try await services.sendInput(agentID: node.id, text: text)
              } catch {
                await services.recordConversationSendFailure(
                  agentID: node.id, prompt: text, error: error)
              }
            } else {
              do {
                try await services.sendPrompt(agentID: node.id, prompt: text)
              } catch {
                await services.recordConversationSendFailure(
                  agentID: node.id, prompt: text, error: error)
              }
            }
          }
        },
        sendBytes: { data in
          Task { try? await services.sendTerminalBytes(terminalID: node.id, data: data) }
        },
        resize: { columns, rows in
          Task {
            try? await services.resizeTerminal(
              terminalID: node.id, columns: columns, rows: rows)
          }
        },
        interrupt: { Task { try? await services.interrupt(agentID: node.id) } },
        stop: { Task { try? await services.stop(agentID: node.id) } },
        restart: { Task { try? await services.restart(agentID: node.id) } },
        resolvePermission: {
          approved in
          Task { await services.resolveAgentPermission(agentID: node.id, approved: approved) }
        },
        alwaysAllowPermission: {
          Task { await services.alwaysAllowAgentPermission(agentID: node.id) }
        },
        resolveChoice: {
          answer in Task { await services.resolveAgentChoice(agentID: node.id, answer: answer) }
        },
        setPermissionMode: { setPermissionMode($0, for: node.id) },
        setModel: { model, effort in setModel(model, effort: effort, for: node.id) },
        setExecutionStrategy: { setExecutionStrategy($0, for: node.id) },
        handoffTargets: {
          agents.filter { $0.id != node.id }.map {
            AgentHandoffTarget(id: $0.id, name: $0.displayName)
          }
        },
        handoff: { targetID, prompt in
          Task { try? await services.sendPrompt(agentID: targetID, prompt: prompt) }
        },
        openBrowser: { url in
          Task {
            _ = try? await services.openBrowser(
              url: url,
              at: WorldPoint(x: node.frame.x + node.frame.width + 48, y: node.frame.y)
            )
          }
        },
        mentionProfiles: mentionableProfiles,
        mentionAppearance: { services.botAppearance.appearance(for: $0) },
        waitingTerminals: waitingTerminalNotices(owner: node.id),
        openTerminal: { services.revealTerminal($0) },
        voiceInsertion: isSelected ? voice.chatVoiceInsertion : nil,
        consumeVoiceInsertion: { voice.consumeChatVoiceInsertion($0) }
      )
      .id(node.id)
    }
  }

  /// The band that shares the traffic lights' line. Every control here keeps a
  /// fixed home, so nothing jumps when the sidebar opens or the surface changes.
  private var windowChrome: some View {
    HStack(spacing: 6) {
      chromeControl(
        symbol: "sidebar.left",
        isOn: showingSidebar,
        help: showingSidebar ? "Hide sidebar" : "Show sidebar"
      ) {
        withAnimation(motion.enter(.moderate)) { showingSidebar.toggle() }
      }
      Spacer(minLength: 8)
      if chromeAgent != nil {
        chromeControl(
          symbol: "list.bullet.rectangle",
          isOn: showingEnvironment && !showingWorkPanel,
          help: showingEnvironment ? "Hide pinned environment" : "Show pinned environment"
        ) {
          withAnimation(.easeOut(duration: 0.16)) {
            showingEnvironment.toggle()
            if showingEnvironment { showingWorkPanel = false }
          }
        }
        chromeControl(
          symbol: "sidebar.right",
          isOn: showingWorkPanel,
          help: showingWorkPanel ? "Hide work panel" : "Show work panel"
        ) {
          withAnimation(.easeOut(duration: 0.16)) {
            showingWorkPanel.toggle()
            if showingWorkPanel { showingAgentDetails = false }
          }
        }
        Divider().frame(height: 14).overlay(palette.chromeForeground.opacity(0.2))
          .padding(.horizontal, 4)
      }
      OttoHeaderControls(
        services: services, store: store, needsAttention: !services.botActivity.needsUser.isEmpty,
        openActivity: { destination = .activity })
    }
    .foregroundStyle(palette.chromeForeground)
    .padding(.leading, Chrome.leading)
    .padding(.trailing, 18)
    .frame(height: Chrome.bandHeight)
    // The same banner as Home on every theme, so the header never changes between screens.
    // Its tint and text both come from the theme: a fixed black wash with white glyphs was
    // ~2:1 on every light theme and over bright artwork.
    .background(palette.chromeBand)
  }

  /// The agent whose work controls belong in the band. Team rooms and the
  /// library surfaces carry no per-agent controls.
  private var chromeAgent: OttoNode? {
    guard destination == .conversation, selectedTeamID == nil else { return nil }
    return selectedAgent
  }

  private func chromeControl(
    symbol: String,
    isOn: Bool,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .semibold))
        .frame(width: Chrome.control, height: Chrome.control)
        .background(
          isOn ? palette.chromeForeground.opacity(0.18) : palette.chromeForeground.opacity(0.06),
          in: RoundedRectangle(cornerRadius: 7)
        )
        .animation(motion.tint, value: isOn)
    }
    .buttonStyle(.ottoChrome)
    .help(help)
    .accessibilityLabel(help)
  }

  private func workOverflowMenu(for node: OttoNode) -> some View {
    Menu {
      ForEach(availableWorkSurfaces) { surface in
        Button(surface.title, systemImage: surface.symbol) {
          openWorkSurface(surface)
        }
      }
    } label: {
      Image(systemName: "square.grid.2x2")
        .font(.system(size: 12, weight: .semibold))
        .frame(width: Chrome.control, height: Chrome.control)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 7))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .foregroundStyle(palette.paper)
    .help(
      showsBotRoutines
        ? "Open review, terminal, browser, files, side chat, or routines"
        : "Open review, terminal, browser, files, or side chat"
    )
    .accessibilityLabel("Open work surfaces")
  }

  private func openWorkSurface(_ surface: WorkSurface) {
    guard let node = selectedAgent else { return }
    let browserID = surface == .browser ? createWorkBrowser(for: node) : nil
    let title = surface == .browser ? "New tab" : (surface == .files ? "Open file" : surface.title)
    let tab = WorkTab(surface: surface, title: title, browserID: browserID)
    workTabs[node.id, default: []].append(tab)
    selectedWorkTabIDs[node.id] = tab.id
    withAnimation(.easeOut(duration: 0.16)) {
      showingWorkPanel = true
      showingAgentDetails = false
    }
  }

  private func applyAgentBrowserOpenRequest(_ request: AgentBrowserOpenRequest?) {
    guard let request,
      allAgentNodes.contains(where: { $0.id == request.agentID }),
      store.snapshot.canvases.contains(where: { canvas in
        canvas.nodes.contains(where: {
          $0.id == request.browserID && $0.kind == .browser
            && $0.browserOwnerAgentID == request.agentID
        })
      })
    else { return }

    let existing = workTabs[request.agentID, default: []].first {
      $0.surface == .browser && $0.browserID == request.browserID
    }
    let tab: WorkTab
    if let existing {
      tab = existing
    } else {
      tab = WorkTab(surface: .browser, title: "New tab", browserID: request.browserID)
      workTabs[request.agentID, default: []].append(tab)
    }
    selectedWorkTabIDs[request.agentID] = tab.id

    // A background bot may open a browser without stealing the user's current conversation. Its
    // browser remains associated and appears when that chat is selected.
    guard selectedAgent?.id == request.agentID else { return }
    withAnimation(.easeOut(duration: 0.16)) {
      showingWorkPanel = true
      showingAgentDetails = false
    }
  }

  private func restoreAgentBrowserAssociations() {
    for browser in store.snapshot.canvases.flatMap(\.nodes) {
      guard browser.kind == .browser, let agentID = browser.browserOwnerAgentID,
        allAgentNodes.contains(where: { $0.id == agentID })
      else { continue }
      if workTabs[agentID, default: []].contains(where: { $0.browserID == browser.id }) {
        continue
      }
      workTabs[agentID, default: []].append(
        WorkTab(surface: .browser, title: "New tab", browserID: browser.id))
    }
  }

  private func workPanel(for node: OttoNode) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let tab = activeWorkTab(for: node) {
        workTabBar(for: node)
        Divider().overlay(palette.paper.opacity(0.08))
        Group {
          switch tab.surface {
          case .review: workReview(for: node)
          case .terminal:
            if let terminalID = tab.terminalID {
              workOwnedTerminal(terminalID, owner: node)
            } else {
              workTerminal(for: node)
            }
          case .browser: workBrowser(for: node, tab: tab)
          case .files: workFiles(for: node, tab: tab)
          case .sideChat: workSideChat(for: node)
          case .routines:
            if showsBotRoutines {
              workRoutines(for: node)
            } else {
              workSurfacePicker
            }
          case .playbooks:
            if let profileID = selectedEntry?.profile.id {
              PlaybookManagerView(services: services, profileID: profileID).id(profileID)
            } else {
              workSurfacePicker
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        workSurfacePicker
      }
    }
    .background(palette.paneSurface)
  }

  private func workTabBar(for node: OttoNode) -> some View {
    HStack(spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        // Chrome tabs the Fluid Functionalism way: the selected plate slides between tabs on
        // the moderate spring and a hover wash glides underneath on the fast one.
        OttoFluidHover(
          axis: .horizontal,
          style: OttoFluidHoverStyle(fill: palette.paper.opacity(0.05), cornerRadius: 8)
        ) {
          HStack(spacing: 5) {
            ForEach(workTabs[node.id] ?? []) { tab in
              let selected = selectedWorkTabIDs[node.id] == tab.id
              HStack(spacing: 7) {
                Button {
                  withAnimation(motion.enter(.moderate)) {
                    selectedWorkTabIDs[node.id] = tab.id
                  }
                } label: {
                  HStack(spacing: 5) {
                    Image(systemName: tab.surface.symbol)
                      .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    OttoWeightStableText(
                      displayTitle(for: tab), size: 12, active: selected,
                      activeColor: palette.paper, restingColor: palette.muted)
                    if let terminalID = tab.terminalID, terminalIsWaiting(terminalID) {
                      Circle().fill(palette.amber).frame(width: 6, height: 6)
                        .accessibilityLabel("Waiting for you")
                    }
                  }
                }
                .buttonStyle(.plain)
                Button {
                  closeWorkTab(tab.id, for: node)
                } label: {
                  Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(.ottoChrome(cornerRadius: 4))
                .opacity(selected ? 0.72 : 0.45)
                .accessibilityLabel("Close \(displayTitle(for: tab))")
              }
              .foregroundStyle(selected ? palette.paper : palette.muted)
              .animation(motion.tint, value: selected)
              .padding(.leading, 10)
              .padding(.trailing, 6)
              .frame(height: 30)
              .background {
                if selected {
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.raised)
                    .matchedGeometryEffect(id: "work-tab-selection", in: workTabSelection)
                }
              }
              .background(
                palette.ink.opacity(0.2),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
              )
              .ottoHoverItem(tab.id)
            }
          }
        }
      }
      workTabMenu
      Spacer(minLength: 0)
      Button {
        withAnimation(motion.exit(.moderate)) { showingWorkPanel = false }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 26, height: 26)
      }
      .buttonStyle(.ottoChrome)
      .foregroundStyle(palette.muted)
      .help("Close work panel")
      .accessibilityLabel("Close work panel")
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
  }

  private var workTabMenu: some View {
    Menu {
      ForEach(availableWorkSurfaces) { surface in
        Button(surface.title, systemImage: surface.symbol) {
          openWorkSurface(surface)
        }
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 28, height: 28)
        .background(palette.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .foregroundStyle(palette.paper)
    .help("New work tab")
    .accessibilityLabel("New work tab")
  }

  private func activeWorkTab(for node: OttoNode) -> WorkTab? {
    let tabs = workTabs[node.id] ?? []
    guard let selectedID = selectedWorkTabIDs[node.id] else { return tabs.first }
    return tabs.first { $0.id == selectedID } ?? tabs.first
  }

  private func displayTitle(for tab: WorkTab) -> String {
    if let terminalID = tab.terminalID {
      return terminalNodes.first { $0.id == terminalID }?.displayName ?? tab.title
    }
    guard let browserID = tab.browserID,
      let browser = store.snapshot.canvases.flatMap(\.nodes).first(where: { $0.id == browserID }),
      let activeTab = browser.browserSession?.activeTab
    else { return tab.title }
    let title = activeTab.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty { return title }
    if BrowserDefaults.isStartURL(activeTab.url) || activeTab.url == BrowserDefaults.blankURL {
      return "New tab"
    }
    return URL(string: activeTab.url)?.host ?? activeTab.url
  }

  private func closeWorkTab(_ tabID: UUID, for node: OttoNode) {
    guard let index = (workTabs[node.id] ?? []).firstIndex(where: { $0.id == tabID })
    else { return }
    guard let tab = workTabs[node.id]?[index] else { return }
    if let browserID = tab.browserID,
      store.snapshot.canvases.flatMap(\.nodes).contains(where: {
        $0.id == browserID && $0.browserOwnerAgentID == node.id
      })
    {
      store.dispatch(.closeNode(browserID))
    }
    workTabs[node.id, default: []].remove(at: index)
    if selectedWorkTabIDs[node.id] == tabID {
      let remaining = workTabs[node.id] ?? []
      selectedWorkTabIDs[node.id] =
        remaining.indices.contains(index)
        ? remaining[index].id : remaining.last?.id
    }
  }

  private func createWorkBrowser(
    for node: OttoNode, url: String = BrowserDefaults.blankURL
  ) -> UUID? {
    guard let canvasID = store.canvasID(containing: node.id) else { return nil }
    guard
      let browserID = store.dispatch(
        .createNode(
          kind: .browser,
          at: WorldPoint(x: node.frame.x + node.frame.width + 48, y: node.frame.y)
        ),
        targetCanvasID: canvasID
      ).affectedNodeIDs.first
    else { return nil }
    let session = BrowserSession(url: url)
    store.dispatch(
      .setNodeContent(id: browserID, content: .browser(url: url)),
      targetCanvasID: canvasID)
    store.dispatch(
      .setBrowserSession(id: browserID, session: session), targetCanvasID: canvasID)
    store.dispatch(
      .setBrowserOwner(id: browserID, agentID: node.id), targetCanvasID: canvasID)
    return browserID
  }

  private func filePathBinding(for tabID: UUID, nodeID: UUID) -> Binding<String?> {
    Binding(
      get: {
        workTabs[nodeID]?.first(where: { $0.id == tabID })?.filePath
      },
      set: { path in
        guard let index = workTabs[nodeID]?.firstIndex(where: { $0.id == tabID })
        else { return }
        workTabs[nodeID, default: []][index].filePath = path
        workTabs[nodeID, default: []][index].title =
          path.map {
            ($0 as NSString).lastPathComponent
          } ?? "Open file"
      }
    )
  }

  private var workSurfacePicker: some View {
    VStack(alignment: .leading, spacing: 0) {
      Spacer()
      VStack(alignment: .leading, spacing: 22) {
        ForEach(availableWorkSurfaces) { surface in
          Button {
            openWorkSurface(surface)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: surface.symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 18)
              Text(surface.title)
                .font(.ottoDisplay(14))
              Spacer()
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .foregroundStyle(palette.paper)
      .frame(width: 280)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.paneSurface)
  }

  @ViewBuilder private func workReview(for node: OttoNode) -> some View {
    if let summary = services.turnChanges[node.id] {
      TurnReviewSheet(
        summary: summary,
        turnDiff: { file in await services.turnDiff(agentID: node.id, file: file) },
        initialPath: nil,
        close: { withAnimation(.easeOut(duration: 0.16)) { showingWorkPanel = false } }
      )
    } else {
      ContentUnavailableView(
        "Nothing to review",
        systemImage: "doc.text.magnifyingglass",
        description: Text("Changes from this bot or session's latest completed turn appear here.")
      )
      .foregroundStyle(palette.paper)
    }
  }

  @ViewBuilder private func workSideChat(for parent: OttoNode) -> some View {
    if let sideChatID = sideChatAgentIDs[parent.id],
      let sideChat = allAgentNodes.first(where: { $0.id == sideChatID })
    {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Label("Temporary side chat", systemImage: "bubble.left.and.bubble.right")
            .font(.ottoDisplay(13).weight(.semibold))
          Spacer()
          Button("End", role: .destructive) { closeSideChat(for: parent.id) }
            .buttonStyle(.plain)
            .font(.ottoMono(7, weight: .bold))
            .foregroundStyle(palette.red)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        Divider().overlay(palette.paper.opacity(0.08))
        agentConversationBody(for: sideChat, routesMentions: false, isSelected: true)
      }
    } else if creatingSideChatFor == parent.id {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Starting a temporary side chat…")
          .font(.ottoMono(8))
          .foregroundStyle(palette.muted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView {
        Label("Side chat", systemImage: "bubble.left.and.bubble.right")
      } description: {
        Text(
          sideChatError
            ?? "Start a separate, temporary session using this bot's provider, workspace, and permissions."
        )
      } actions: {
        Button("Start side chat") { startSideChat(for: parent) }
          .buttonStyle(.borderedProminent)
          .tint(palette.signal)
      }
      .foregroundStyle(palette.paper)
    }
  }

  private func startSideChat(for parent: OttoNode) {
    guard sideChatAgentIDs[parent.id] == nil,
      let definition = parent.agentDefinition
    else { return }
    creatingSideChatFor = parent.id
    sideChatError = nil
    Task {
      do {
        let output = try await services.spawnAgent(
          provider: definition.provider,
          displayName: "Side chat · \(parent.displayName)",
          workingDirectory: definition.workingDirectory,
          at: WorldPoint(x: parent.frame.x + 44, y: parent.frame.y + 44),
          executionStrategy: definition.executionStrategy ?? .direct,
          permissionMode: AgentPermissionMode(rawValue: definition.permissionMode)
            ?? .workspaceWrite,
          isolatedWorktree: false
        )
        sideChatAgentIDs[parent.id] = output.agentID
        creatingSideChatFor = nil
      } catch {
        creatingSideChatFor = nil
        sideChatError = error.localizedDescription
      }
    }
  }

  private func closeSideChat(for parentID: UUID) {
    guard let agentID = sideChatAgentIDs.removeValue(forKey: parentID) else { return }
    Task { try? await services.stop(agentID: agentID) }
    store.dispatch(.closeNode(agentID))
  }

  private func closeAllSideChats() {
    let sideChats = sideChatAgentIDs
    sideChatAgentIDs.removeAll()
    for agentID in sideChats.values {
      Task { try? await services.stop(agentID: agentID) }
      store.dispatch(.closeNode(agentID))
    }
  }

  private func environmentCard(for node: OttoNode) -> some View {
    let entry = selectedEntry
    let changes = services.turnChanges[node.id]
    let plugins =
      entry.map { services.harnessPlugins(for: $0.profile.provider) }
      ?? (node.agentDefinition.map { services.harnessPlugins(for: $0.provider) } ?? [])
    let extras = plugins.filter { $0.source != HarnessPluginCatalog.ottoSource }
    let sources = workFilePaths(for: node)
    return VStack(alignment: .leading, spacing: 10) {
      Text("Environment")
        .font(.ottoDisplay(13).weight(.semibold))
      environmentRow(
        symbol: "arrow.triangle.swap",
        title: "Changes",
        trailing: changes.map {
          "+\($0.totalAdditions) -\($0.totalDeletions)"
        } ?? "No diff yet"
      )
      environmentRow(
        symbol: "circle.fill",
        title: entry.map { $0.needsYou ? "Needs you" : $0.presence.rawValue.capitalized }
          ?? (services.fleet[node.id]?.state.rawValue.capitalized ?? "Idle"),
        trailing: permissionLabel(node)
      )
      if !extras.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Plugins")
            .font(.ottoMono(7, weight: .black))
            .foregroundStyle(palette.muted)
          PluginLogoRow(plugins: extras, palette: palette, size: 22)
        }
      }
      if !sources.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Sources")
            .font(.ottoMono(7, weight: .black))
            .foregroundStyle(palette.muted)
          ForEach(sources.prefix(4), id: \.self) { path in
            Text((path as NSString).lastPathComponent)
              .font(.ottoDisplay(12))
              .lineLimit(1)
          }
          if sources.count > 4 {
            Button("View all") { openWorkSurface(.files) }
              .font(.ottoMono(7, weight: .bold))
              .foregroundStyle(palette.cyan)
              .buttonStyle(.plain)
          }
        }
      }
      if showsBotRoutines {
        environmentRoutines(for: node, entry: entry)
      }
    }
    .foregroundStyle(palette.paper)
    .padding(14)
    .frame(width: 280, alignment: .leading)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(palette.paper.opacity(0.08))
    )
    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
  }

  @ViewBuilder
  private func environmentRoutines(for node: OttoNode, entry: BotRosterEntry?) -> some View {
    let owned = routinesOwnedBy(profileID: entry?.profile.id, nodeID: node.id)
    let ownerName = entry?.profile.name ?? node.displayName
    VStack(alignment: .leading, spacing: 6) {
      Text("Automations")
        .font(.ottoMono(7, weight: .black))
        .foregroundStyle(palette.muted)
      if owned.isEmpty {
        Text("None assigned")
          .font(.ottoDisplay(12))
          .foregroundStyle(palette.muted)
      } else {
        ForEach(owned.prefix(4)) { routine in
          Button {
            openRoutinePanel(routineID: routine.id)
          } label: {
            HStack(spacing: 8) {
              Circle()
                .fill(routine.enabled ? palette.signal : palette.muted)
                .frame(width: 6, height: 6)
              Text(routine.name)
                .font(.ottoDisplay(12).weight(.semibold))
                .lineLimit(1)
              Spacer(minLength: 4)
              Text(routine.enabled ? "ON" : "OFF")
                .font(.ottoMono(6.5, weight: .bold))
                .foregroundStyle(palette.muted)
            }
          }
          .buttonStyle(.plain)
        }
        if owned.count > 4 {
          Button("View all") { destination = .routines }
            .font(.ottoMono(7, weight: .bold))
            .foregroundStyle(palette.cyan)
            .buttonStyle(.plain)
        }
      }
      Button {
        openRoutinePanel()
      } label: {
        Text("Give \(ownerName) a routine")
          .font(.ottoMono(7, weight: .black))
          .foregroundStyle(palette.cyan)
      }
      .buttonStyle(.plain)
    }
  }

  private func environmentRow(symbol: String, title: String, trailing: String) -> some View {
    HStack {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 16)
        .foregroundStyle(palette.muted)
      Text(title)
        .font(.ottoDisplay(13))
      Spacer()
      Text(trailing)
        .font(.ottoMono(7, weight: .bold))
        .foregroundStyle(palette.muted)
    }
  }

  private func workRoutines(for node: OttoNode) -> some View {
    let entry = selectedEntry
    return RoutineManagerView(
      store: store,
      services: services,
      style: .embedded,
      initialRoutineID: panelRoutineID,
      prefillProfileID: entry?.profile.id,
      prefillNodeID: entry == nil ? node.id : nil
    )
    .id(node.id)
  }

  private func workFiles(for node: OttoNode, tab: WorkTab) -> some View {
    let root = node.agentDefinition?.workingDirectory ?? FileManager.default.currentDirectoryPath
    let selectedFile = filePathBinding(for: tab.id, nodeID: node.id)
    let selectedPath = selectedFile.wrappedValue.map { resolvedWorkPath($0, for: node) }
    return HStack(spacing: 0) {
      Group {
        if let selectedPath {
          VStack(alignment: .leading, spacing: 0) {
            Button("Browse files") { selectedFile.wrappedValue = nil }
              .font(.ottoMono(8, weight: .bold))
              .padding(12)
            WorkFileEditor(path: selectedPath, palette: palette)
              .id(selectedPath)
          }
        } else {
          ContentUnavailableView {
            Label("Open file", systemImage: "folder")
          } description: {
            Text("Select a file from the workspace tree")
          }
          .foregroundStyle(palette.paper)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if selectedPath == nil {
        Divider().overlay(palette.paper.opacity(0.08))
        WorkspaceFileTree(
          rootPath: root,
          selectedPath: selectedFile,
          palette: palette
        )
        .frame(width: 260)
      }
    }
  }

  private func workFilePaths(for node: OttoNode) -> [String] {
    let fromTurn = services.turnChanges[node.id]?.files.map(\.path) ?? []
    let fromResult = services.fleet[node.id]?.structuredResult?.filesChanged ?? []
    var seen = Set<String>()
    var ordered: [String] = []
    for path in (fromTurn + fromResult).reversed() {
      guard seen.insert(path).inserted else { continue }
      ordered.append(path)
    }
    return ordered
  }

  private func resolvedWorkPath(_ path: String, for node: OttoNode) -> String {
    if path.hasPrefix("/") { return path }
    let base =
      node.agentDefinition?.workingDirectory ?? FileManager.default.currentDirectoryPath
    return (base as NSString).appendingPathComponent(path)
  }

  private func workTerminal(for node: OttoNode) -> some View {
    ChatAgentSnapshotHost(model: services.fleetStore.model(for: node.id)) { snapshot in
      EmulatedTerminalView(
        output: snapshot?.output ?? "",
        outputStartOffset: snapshot?.outputStartOffset ?? 0,
        outputEndOffset: snapshot?.outputEndOffset ?? 0,
        sessionKey: "work-\(node.id.uuidString)",
        acceptsInput: snapshot?.state != .stopped,
        replayExistingOutput: snapshot?.executionMode != .interactiveProvider,
        send: { data in
          Task { try? await services.sendTerminalBytes(terminalID: node.id, data: data) }
        },
        resize: { columns, rows in
          Task {
            try? await services.resizeTerminal(
              terminalID: node.id, columns: columns, rows: rows)
          }
        }
      )
      .padding(8)
      .background(palette.ink)
    }
  }

  @ViewBuilder private func workBrowser(for node: OttoNode, tab: WorkTab) -> some View {
    if let browserID = tab.browserID,
      let canvasID = store.canvasID(containing: browserID),
      let browser = store.snapshot.canvases.flatMap(\.nodes).first(where: {
        $0.id == browserID && $0.browserOwnerAgentID == node.id
      })
    {
      BrowserBody(
        node: browser,
        scale: 1,
        isSelected: true,
        isDragging: false,
        runtime: services.browserRuntime,
        capture: services.captureBrowser,
        updateContent: {
          store.dispatch(
            .setNodeContent(id: browser.id, content: $0), targetCanvasID: canvasID)
        },
        updateBrowserSession: {
          store.dispatch(
            .setBrowserSession(id: browser.id, session: $0), targetCanvasID: canvasID)
        },
        updateBrowserTab: { tabID, url, title in
          store.dispatch(
            .updateBrowserTab(id: browser.id, tabID: tabID, url: url, title: title),
            targetCanvasID: canvasID)
        },
        chrome: .panel
      )
      .id(browser.id)
    } else {
      ContentUnavailableView {
        Label("Browser could not open", systemImage: "globe.badge.chevron.backward")
      } description: {
        Text("Otto could not create a browser for this tab.")
      }
      .foregroundStyle(palette.paper)
    }
  }

  private var chatThemeMenu: some View {
    Menu {
      ForEach(OttoThemeCatalog.all, id: \.id) { theme in
        Button {
          store.dispatch(.setTheme(theme.id))
        } label: {
          if store.activeCanvas.themeID == theme.id {
            Label(theme.displayName, systemImage: "checkmark")
          } else {
            Text(theme.displayName)
          }
        }
      }
    } label: {
      Image(systemName: "paintpalette")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(palette.muted)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .frame(width: 22)
    .help("Choose theme")
    .accessibilityLabel("Choose theme")
  }

  private var showsBotRoutines: Bool {
    sidebarList == .bots && selectedTeamID == nil && selectedEntry != nil
  }

  private var availableWorkSurfaces: [WorkSurface] {
    WorkSurface.allCases.filter {
      ($0 != .routines && $0 != .playbooks) || showsBotRoutines
    }
  }

  private func closeRoutineWorkTabs() {
    for (nodeID, tabs) in workTabs {
      let kept = tabs.filter { $0.surface != .routines }
      workTabs[nodeID] = kept
      if let selected = selectedWorkTabIDs[nodeID],
        tabs.contains(where: { $0.id == selected && $0.surface == .routines })
      {
        selectedWorkTabIDs[nodeID] = kept.last?.id
      }
    }
  }

  private func sidebarEmpty<Action: View>(
    title: String, detail: String, @ViewBuilder action: () -> Action
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.ottoDisplay(12.5).weight(.medium))
      Text(detail)
        .font(.ottoDisplay(11))
        .foregroundStyle(palette.muted)
        .fixedSize(horizontal: false, vertical: true)
      action()
        .font(.ottoDisplay(11.5).weight(.medium))
        .foregroundStyle(palette.cyan)
    }
    .foregroundStyle(palette.paper.opacity(0.86))
    .padding(.horizontal, 7)
    .padding(.vertical, 8)
  }

  private func sessionRow(_ node: OttoNode) -> some View {
    let active = destination == .conversation && selectedSessionID == node.id
    let hovered = hoveredSessionID == node.id
    let preview = sessionPreview(node)
    return HStack(spacing: 4) {
      Button {
        selectSession(node)
      } label: {
        HStack(spacing: 8) {
          // Which assistant the session runs on, shown the way people recognise it: its logo.
          AgentProviderLogo(
            provider: node.declaredAgentProvider, size: 13,
            color: palette.paper.opacity(active ? 0.95 : 0.75)
          )
          .frame(width: Self.sidebarAvatarSize, height: Self.sidebarAvatarSize)
          .background(
            palette.paper.opacity(active ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 7))
          VStack(alignment: .leading, spacing: 2) {
            OttoWeightStableText(
              node.displayName, size: 13, active: active,
              activeColor: palette.paper, restingColor: palette.paper.opacity(0.86))
            Text(preview)
              .font(.ottoDisplay(11))
              .foregroundStyle(palette.muted)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Spacer(minLength: 4)
          if !hovered, node.status == .working || node.status == .starting {
            ProgressView().controlSize(.mini)
              .accessibilityLabel("Session running")
              .frame(width: 18, height: 18)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(preview.isEmpty ? sessionStatusLabel(node.status) : preview)
      .accessibilityLabel("Open session \(node.displayName)")

      if hovered {
        Button {
          beginSessionRename(node)
        } label: {
          Image(systemName: "pencil")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(palette.muted)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Rename session")
        .accessibilityLabel("Rename session \(node.displayName)")

        Button {
          closeSession(node)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(palette.muted)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close session")
        .accessibilityLabel("Close session \(node.displayName)")
      }
    }
    .padding(.horizontal, 7)
    .frame(height: 44)
    .contentShape(Rectangle())
    .ottoHoverItem("session:\(node.id)")
    .onHover { hovering in
      if hovering {
        hoveredSessionID = node.id
      } else if hoveredSessionID == node.id {
        hoveredSessionID = nil
      }
    }
    .contextMenu {
      Button("Rename session…", systemImage: "pencil") { beginSessionRename(node) }
      Button("Clear chat…", systemImage: "eraser") {
        pendingClear = ClearChatTarget(id: node.id, name: node.displayName, isBot: false)
      }
      Divider()
      Button("Close session", systemImage: "xmark", role: .destructive) {
        closeSession(node)
      }
    }
  }

  // Kept out of `body`: the inline binding and alert closures pushed Swift 6.2's type checker
  // over its time limit for the whole body expression (Xcode 26.3, which CI pins).
  private var isRenamingSession: Binding<Bool> {
    Binding(
      get: { renamingSessionID != nil },
      set: { if !$0 { renamingSessionID = nil } })
  }

  private func beginSessionRename(_ node: OttoNode) {
    guard sessionAgents.contains(where: { $0.id == node.id }) else { return }
    sessionNameDraft = node.displayName
    renamingSessionID = node.id
  }

  private func saveSessionName() {
    defer { renamingSessionID = nil }
    guard let nodeID = renamingSessionID else { return }
    let name = sessionNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      sessionAgents.contains(where: { $0.id == nodeID }),
      let canvasID = store.snapshot.canvases.first(where: { canvas in
        canvas.nodes.contains(where: { $0.id == nodeID })
      })?.id
    else { return }
    store.dispatch(.renameNode(id: nodeID, name: name), targetCanvasID: canvasID)
  }

  /// What a session is *about*, for the rail's second line. The brief — the first thing
  /// asked — is what makes the row identifiable, and unlike the last result it stays put
  /// for the life of the session. Live work prefixes it so the rail doubles as a progress
  /// glance. Bots don't get this: their name already carries the identity.
  private func sessionPreview(_ node: OttoNode) -> String {
    let snapshot = services.fleet[node.id]
    let firstAsk = snapshot?.transcript.lazy
      .filter { $0.role == .user }
      .map { Self.humanRequest($0.text) }
      .first { !$0.isEmpty }
    let brief = firstAsk ?? snapshot?.lastPrompt.map(Self.humanRequest) ?? node.detail
    let condensed =
      brief
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { line in line.contains { $0.isLetter || $0.isNumber } } ?? ""
    let summary = condensed.isEmpty ? sessionStatusLabel(node.status) : condensed
    return summary
  }

  /// The words a person typed, without what Otto or the provider wrapped around them: Otto
  /// context packets keep only the trailing user message, and injected instruction files or
  /// environment blocks are not a request at all.
  nonisolated static func humanRequest(_ text: String) -> String {
    guard
      let body = PromptSubmission.visibleUserText(
        text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return "" }
    let injected = ["# AGENTS.md instructions", "<environment_context>", "<user_instructions>"]
    if injected.contains(where: { body.hasPrefix($0) }) { return "" }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Idle work reads as a hollow ring, live work as a filled dot.
  @ViewBuilder private func sessionStatusDot(_ status: NodeStatus) -> some View {
    let color = sessionStatusColor(status)
    switch status {
    case .idle, .stopped:
      Circle()
        .strokeBorder(color.opacity(0.75), lineWidth: 1.2)
        .frame(width: 7, height: 7)
    default:
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
    }
  }

  private func sessionStatusLabel(_ status: NodeStatus) -> String {
    switch status {
    case .starting: "Starting"
    case .idle: "Idle"
    case .working: "Working"
    case .done: "Done"
    case .waiting: "Needs you"
    case .failed: "Failed"
    case .stopped: "Stopped"
    }
  }

  private func sessionStatusColor(_ status: NodeStatus) -> Color {
    switch status {
    case .idle, .stopped: palette.muted
    case .done: palette.signal
    case .working, .starting: palette.amber
    case .waiting: palette.cyan
    case .failed: palette.red
    }
  }

  private func closeSession(_ node: OttoNode) {
    if services.fleet[node.id] != nil {
      Task { try? await services.stop(agentID: node.id) }
    }
    guard
      let canvasID = store.snapshot.canvases.first(where: { canvas in
        canvas.nodes.contains { $0.id == node.id }
      })?.id
    else { return }
    if selectedSessionID == node.id {
      selectedSessionID = nil
      selectedAgentID = nil
    }
    store.dispatch(.closeNode(node.id), targetCanvasID: canvasID)
  }

  private func selectSession(_ node: OttoNode) {
    selectedSessionID = node.id
    selectedProfileID = nil
    selectedTeamID = nil
    selectedAgentID = node.id
    sidebarList = .sessions
    destination = .conversation
    if let canvas = store.snapshot.canvases.first(where: {
      $0.nodes.contains { $0.id == node.id }
    }) {
      store.dispatch(.focusNode(node.id), targetCanvasID: canvas.id)
    }
  }

  private func selectNewSession(_ agentID: UUID) {
    sessionCanvasID = store.activeCanvas.id
    selectedSessionID = agentID
    selectedProfileID = nil
    selectedTeamID = nil
    selectedAgentID = agentID
    sidebarList = .sessions
    destination = .conversation
    store.dispatch(.focusNode(agentID))
  }

  private func botRow(_ entry: BotRosterEntry) -> some View {
    let active =
      destination == .conversation && selectedTeamID == nil && selectedSessionID == nil
      && selectedProfileID == entry.profile.id
    let preview = entry.needsYou ? "Needs you" : (entry.preview.isEmpty ? "Ready" : entry.preview)
    return Button {
      selectedProfileID = entry.profile.id
      selectedTeamID = nil
      selectedSessionID = nil
      sidebarList = .bots
      destination = .conversation
      Task { await openEntry(entry) }
    } label: {
      sidebarRowLabel(
        title: entry.profile.name,
        active: active,
        dot: entry.needsYou ? palette.cyan : nil,
        running: isBotRunning(entry)
      ) {
        profileAvatar(entry, size: Self.sidebarAvatarSize)
      }
    }
    .buttonStyle(.plain)
    .ottoHoverItem("bot:\(entry.profile.id)")
    .help(preview)
    .accessibilityLabel("Open chat with \(entry.profile.name)")
    .contextMenu {
      Button("Edit bot…") { editingBot = entry.profile }
      if let nodeID = entry.nodeID {
        Button("Clear chat…", systemImage: "eraser") {
          pendingClear = ClearChatTarget(id: nodeID, name: entry.profile.name, isBot: true)
        }
      }
      Divider()
      Button("Delete bot…", role: .destructive) {
        pendingDeletion = DeletionTarget(
          id: entry.profile.id,
          kind: .bot,
          name: entry.profile.name,
          nodeID: entry.nodeID
        )
      }
    }
  }

  /// A bot is "running" when its runtime lifecycle is busy. The canvas node status is checked
  /// too because that store is what this view observes, so the spinner tracks live turns.
  private func isBotRunning(_ entry: BotRosterEntry) -> Bool {
    if entry.avatarState == .working { return true }
    guard let nodeID = entry.nodeID,
      let status = allAgentNodes.first(where: { $0.id == nodeID })?.status
    else { return false }
    return status == .working || status == .starting
  }

  private func teamTitle(_ channel: BotChannel) -> String {
    let namesByID = Dictionary(
      uniqueKeysWithValues: channel.memberProfileIDs.compactMap { id in
        services.agentProfiles.profile(id: id).map { (id, $0.name) }
      })
    return channel.displayTitle(profileNames: namesByID)
  }

  private func teamRow(_ channel: BotChannel) -> some View {
    let title = teamTitle(channel)
    let active = destination == .conversation && selectedTeamID == channel.id
    return Button {
      selectedTeamID = channel.id
      selectedSessionID = nil
      sidebarList = .bots
      destination = .conversation
      let leadID = channel.orchestratorProfileID ?? channel.memberProfileIDs.first
      selectedProfileID = leadID
      if let leadID, let lead = roster.first(where: { $0.profile.id == leadID }) {
        Task { await openEntry(lead) }
      }
    } label: {
      sidebarRowLabel(
        title: title, active: active, dot: nil,
        running: services.isTeamRunning(channelID: channel.id)
      ) {
        TeamAvatarView(
          name: title,
          members: teamAvatarMembers(channel),
          size: Self.sidebarAvatarSize
        )
      }
    }
    .buttonStyle(.plain)
    .ottoHoverItem("team:\(channel.id)")
    .help(teamSubtitle(channel))
    .accessibilityLabel("Open team \(title)")
    .contextMenu {
      Button("Edit team…") { editingTeam = channel }
      Divider()
      Button("Delete team…", role: .destructive) {
        pendingDeletion = DeletionTarget(
          id: channel.id,
          kind: .team,
          name: title,
          nodeID: nil
        )
      }
    }
  }

  private func teamSubtitle(_ channel: BotChannel) -> String {
    let lead = channel.orchestratorProfileID.flatMap {
      services.agentProfiles.profile(id: $0)
    }
    if let lead {
      return "\(channel.memberProfileIDs.count) bots · @\(lead.handle) leads"
    }
    return "\(channel.memberProfileIDs.count) bots · group"
  }

  private func teamCharterBanner(_ channel: BotChannel) -> some View {
    let lead = channel.orchestratorProfileID.flatMap { services.agentProfiles.profile(id: $0) }
    let brief = channel.instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        TeamAvatarView(
          name: channel.displayTitle(
            profileNames: Dictionary(
              uniqueKeysWithValues: channel.memberProfileIDs.compactMap { id in
                services.agentProfiles.profile(id: id).map { (id, $0.name) }
              })),
          members: teamAvatarMembers(channel),
          size: 30
        )
        Text(
          channel.displayTitle(
            profileNames: Dictionary(
              uniqueKeysWithValues: channel.memberProfileIDs.compactMap { id in
                services.agentProfiles.profile(id: id).map { (id, $0.name) }
              }))
        )
        .font(.ottoDisplay(13).weight(.semibold))
        .foregroundStyle(palette.paper)
        if let lead {
          Text("@\(lead.handle) is the orchestrator")
            .font(.ottoMono(8, weight: .bold))
            .foregroundStyle(palette.signal)
        }
        Spacer()
      }
      if !brief.isEmpty {
        Text(brief)
          .font(.ottoMono(8))
          .foregroundStyle(palette.muted)
          .lineLimit(3)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.raised.opacity(0.7))
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.paper.opacity(0.08)).frame(height: 1)
    }
  }

  private func teamConversation(_ channel: BotChannel) -> some View {
    let session = services.teamSession(channelID: channel.id)
    let messages = session?.messages ?? []
    return VStack(spacing: 0) {
      teamCharterBanner(channel)
      TeamApprovalView(services: services, channelID: channel.id)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 14) {
            if messages.isEmpty {
              VStack(spacing: 9) {
                Image(systemName: "bubble.left.and.bubble.right")
                  .font(.system(size: 22, weight: .medium))
                  .foregroundStyle(palette.signal)
                Text("Start the room")
                  .font(.ottoDisplay(18).weight(.semibold))
                  .foregroundStyle(palette.paper)
                Text(
                  "Message @channel, a teammate, or the orchestrator. Replies stay together here."
                )
                .font(.ottoDisplay(11))
                .foregroundStyle(palette.muted)
              }
              .frame(maxWidth: .infinity)
              .padding(.top, 80)
            }
            ForEach(messages) { message in
              teamMessageRow(message, channel: channel)
                .id(message.id)
            }
            if services.isTeamRunning(channelID: channel.id) {
              HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Team is working…")
                  .font(.ottoMono(8, weight: .bold))
                  .foregroundStyle(palette.muted)
                Spacer()
              }
              .padding(.horizontal, 18)
            }
          }
          .padding(.horizontal, 18)
          .padding(.vertical, 18)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onChange(of: messages.count) { _, _ in
          if let id = messages.last?.id {
            withAnimation(motion.enter(.moderate)) { proxy.scrollTo(id, anchor: .bottom) }
          }
        }
      }
      .id(session?.id ?? channel.id)
      Divider().overlay(palette.paper.opacity(0.08))
      teamComposer(channel)
    }
    // Same background as a bot chat: over theme art the window's frost shows through.
    .background(hasThemeArtwork ? Color.clear : palette.workspaceSurface)
  }

  private func teamMessageRow(_ message: BotGroupMessage, channel: BotChannel) -> some View {
    switch message.author {
    case .user:
      return AnyView(
        HStack {
          Spacer(minLength: 90)
          teamMessageBubble(message.text, channel: channel, isUser: true)
        })
    case .bot(let profileID):
      let profile = services.agentProfiles.profile(id: profileID)
      let entry = roster.first { $0.profile.id == profileID }
      return AnyView(
        HStack(alignment: .top, spacing: 9) {
          if let entry {
            profileAvatar(entry, size: 30)
          } else {
            Image(systemName: "cpu")
              .frame(width: 30, height: 30)
              .background(palette.raised, in: RoundedRectangle(cornerRadius: 9))
          }
          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
              Text(profile?.name ?? "Teammate")
                .font(.ottoDisplay(11).weight(.semibold))
                .foregroundStyle(palette.paper)
              if let profile {
                Text("@\(profile.handle)")
                  .font(.ottoMono(7, weight: .bold))
                  .foregroundStyle(palette.signal)
              }
              Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.ottoMono(6.5))
                .foregroundStyle(palette.muted)
            }
            teamMessageBubble(message.text, channel: channel, isUser: false)
          }
          Spacer(minLength: 90)
        })
    }
  }

  private func teamMessageBubble(
    _ text: String, channel: BotChannel, isUser: Bool
  ) -> some View {
    let parts = teamMessageParts(text, channel: channel)
    // Rich replies contain flexible-width tables and diagrams. Measuring duplicate
    // copies in ViewThatFits can keep the main thread busy negotiating their sizes.
    // Keep one message tree with a stable width proposal from the conversation.
    return VStack(alignment: .leading, spacing: 7) {
      teamMessageMentions(parts.mentions, isUser: isUser)
      if !parts.text.isEmpty {
        teamMessageText(parts.text, isUser: isUser)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      isUser ? palette.paper.opacity(0.84) : palette.raised,
      in: RoundedRectangle(cornerRadius: 13)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 13).stroke(palette.paper.opacity(0.08), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func teamMessageMentions(_ mentions: [TeamMention], isUser: Bool) -> some View {
    if !mentions.isEmpty {
      HStack(spacing: 5) {
        ForEach(mentions) { mention in
          teamMentionChip(mention, style: isUser ? .userMessage : .botMessage)
        }
      }
    }
  }

  private func teamMessageText(_ text: String, isUser: Bool) -> some View {
    Group {
      if isUser {
        Text(text)
          .font(.ottoDisplay(12))
          .foregroundStyle(palette.ink)
      } else {
        MarkdownMessageView(
          text: text, scale: 1, palette: palette,
          assetDirectory: URL(fileURLWithPath: services.documents.rootPath, isDirectory: true)
        )
      }
    }
    .textSelection(.enabled)
  }

  private func teamComposer(_ channel: BotChannel) -> some View {
    let choices = teamMentionChoices(channel)
    return VStack(spacing: 7) {
      if !choices.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
            Button {
              insertTeamMention(choice)
            } label: {
              HStack(spacing: 9) {
                Image(
                  systemName: choice.profileID == nil ? "person.3.fill" : "person.crop.circle.fill"
                )
                .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                  Text(choice.title).font(.ottoDisplay(11).weight(.semibold))
                  Text("@\(choice.handle)").font(.ottoMono(7))
                }
                Spacer()
                if index == teamMentionSelection {
                  Text("↵").font(.ottoMono(7, weight: .black))
                }
              }
              .foregroundStyle(index == teamMentionSelection ? palette.ink : palette.paper)
              .padding(.horizontal, 10)
              .frame(height: 40)
              .background(index == teamMentionSelection ? palette.signal : Color.clear)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 11))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.paper.opacity(0.1)))
        .shadow(color: palette.ink.opacity(0.3), radius: 16, y: 7)
      }
      HStack(spacing: 7) {
        if !teamMentions.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
              ForEach(teamMentions) { mention in
                Button {
                  teamMentions.removeAll { $0.id == mention.id }
                } label: {
                  teamMentionChip(mention, style: .composer)
                }
                .buttonStyle(.plain)
                .help("Remove @\(mention.handle)")
              }
            }
          }
          .fixedSize(horizontal: true, vertical: false)
        }
        TextField("Message \(channel.name ?? "team")", text: $teamDraft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.ottoDisplay(12))
          .foregroundStyle(palette.paper)
          .lineLimit(1...)
          .composerScroll(maxHeight: 140)
          .focused($teamComposerFocused)
          .onSubmit { submitTeamComposer(channel) }
          .onKeyPress(.upArrow) { moveTeamMentionSelection(-1, choices: choices) }
          .onKeyPress(.downArrow) { moveTeamMentionSelection(1, choices: choices) }
          .onChange(of: teamDraft) { _, text in
            teamMentionSelection = 0
            ComposerDrafts.save(text, for: "team:\(channel.id)")
          }
          // Each team channel keeps its own unsent text.
          .onChange(of: channel.id, initial: true) { old, new in
            if old != new { ComposerDrafts.save(teamDraft, for: "team:\(old)") }
            teamDraft = ComposerDrafts.text(for: "team:\(new)")
          }
        Button {
          submitTeamComposer(channel, forceSend: true)
        } label: {
          Image(systemName: "arrow.up")
            .font(.system(size: 9, weight: .bold))
            .frame(width: 27, height: 27)
            .foregroundStyle(palette.ink)
            .background(palette.signal, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(
          teamDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && teamMentions.isEmpty)
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 9)
      .background(palette.raised, in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.paper.opacity(0.1)))
      if let teamError {
        Text(teamError)
          .font(.ottoMono(7))
          .foregroundStyle(palette.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let teamNotice {
        Text(teamNotice)
          .font(.ottoMono(7, weight: .bold))
          .foregroundStyle(palette.signal)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private enum TeamMentionChipStyle: Equatable {
    case composer
    case userMessage
    case botMessage
  }

  private func teamMentionChip(
    _ mention: TeamMention, style: TeamMentionChipStyle
  ) -> some View {
    let emphasized = style != .botMessage
    return HStack(spacing: 4) {
      Image(systemName: mention.profileID == nil ? "person.2.fill" : "at")
        .font(.system(size: 8, weight: .bold))
      Text("@\(mention.handle)")
        .lineLimit(1)
    }
    .font(.ottoMono(8, weight: .bold))
    .foregroundStyle(emphasized ? palette.ink : palette.signal)
    .padding(.horizontal, 8)
    .frame(height: 24)
    .background(
      emphasized ? palette.signal.opacity(0.92) : palette.signal.opacity(0.14),
      in: Capsule()
    )
    .overlay(
      Capsule().stroke(
        emphasized ? palette.ink.opacity(0.08) : palette.signal.opacity(0.28),
        lineWidth: 1
      )
    )
  }

  private func teamMentionChoices(_ channel: BotChannel) -> [TeamMention] {
    guard let at = teamDraft.lastIndex(of: "@") else { return [] }
    let fragment = String(teamDraft[teamDraft.index(after: at)...])
    guard !fragment.contains(where: { $0.isWhitespace }) else { return [] }
    let needle = fragment.lowercased()
    let channelMention = TeamMention(
      id: "channel", profileID: nil, handle: "channel",
      title: "Everyone in \(channel.name ?? "team")")
    let members = channel.memberProfileIDs.compactMap { id -> TeamMention? in
      guard let profile = services.agentProfiles.profile(id: id) else { return nil }
      return TeamMention(
        id: profile.id.uuidString, profileID: profile.id, handle: profile.handle,
        title: profile.name)
    }
    return ([channelMention] + members).filter { choice in
      !teamMentions.contains(where: { $0.id == choice.id })
        && (needle.isEmpty || choice.handle.hasPrefix(needle)
          || choice.title.lowercased().hasPrefix(needle))
    }
  }

  private func insertTeamMention(_ mention: TeamMention) {
    if let at = teamDraft.lastIndex(of: "@") {
      teamDraft = String(teamDraft[..<at])
    }
    if !teamMentions.contains(where: { $0.id == mention.id }) { teamMentions.append(mention) }
    teamMentionSelection = 0
    teamComposerFocused = true
  }

  private func moveTeamMentionSelection(
    _ delta: Int, choices: [TeamMention]
  ) -> KeyPress.Result {
    guard !choices.isEmpty else { return .ignored }
    teamMentionSelection =
      (teamMentionSelection + delta % choices.count + choices.count) % choices.count
    return .handled
  }

  private func submitTeamComposer(_ channel: BotChannel, forceSend: Bool = false) {
    let choices = teamMentionChoices(channel)
    if !forceSend, !choices.isEmpty {
      insertTeamMention(choices[min(teamMentionSelection, choices.count - 1)])
      return
    }
    let prose = teamDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = teamMentions.map { "@\($0.handle)" }.joined(separator: " ")
    let text = [prefix, prose].filter { !$0.isEmpty }.joined(separator: " ")
    guard !text.isEmpty else { return }
    if teamMentions.isEmpty, ["/new", "/reset"].contains(prose.lowercased()) {
      teamDraft = ""
      teamError = nil
      do {
        _ = try services.startNewTeamSession(channelID: channel.id)
        teamNotice = "Fresh team session started. Durable agent memory is unchanged."
      } catch {
        teamNotice = nil
        teamError = error.localizedDescription
      }
      return
    }
    if teamMentions.isEmpty, ["/compact", "/compress"].contains(prose.lowercased()) {
      teamDraft = ""
      teamError = nil
      do {
        _ = try services.compactTeamSession(channelID: channel.id)
        teamNotice = "Older room context compacted. Recent messages remain verbatim."
      } catch {
        teamNotice = nil
        teamError = error.localizedDescription
      }
      return
    }
    teamDraft = ""
    teamMentions = []
    teamError = nil
    teamNotice = nil
    Task {
      do {
        try await services.sendTeamMessage(channelID: channel.id, text: text, at: launchPoint)
      } catch {
        teamError = error.localizedDescription
      }
    }
  }

  private func teamMessageParts(
    _ text: String, channel: BotChannel
  ) -> (mentions: [TeamMention], text: String) {
    var visible = text
    var mentions: [TeamMention] = []
    for token in BotMentionResolver.mentions(in: text) {
      let lowered = token.lowercased()
      if ["@channel", "@everyone", "@all"].contains(lowered) {
        if !mentions.contains(where: { $0.id == "channel" }) {
          mentions.append(
            TeamMention(id: "channel", profileID: nil, handle: "channel", title: "Everyone"))
        }
      } else if case .matched(let profile) = BotMentionResolver.resolve(
        token,
        in: channel.memberProfileIDs.compactMap { services.agentProfiles.profile(id: $0) }
      ) {
        if !mentions.contains(where: { $0.profileID == profile.id }) {
          mentions.append(
            TeamMention(
              id: profile.id.uuidString, profileID: profile.id, handle: profile.handle,
              title: profile.name))
        }
      }
      visible = visible.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
    }
    return (mentions, visible.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func routeComposer(_ text: String, from node: OttoNode, isInput: Bool) async {
    let profiles = services.agentProfiles.activeProfiles
    let mentioned = BotMentionResolver.mentions(in: text).compactMap { token -> AgentProfile? in
      if case .matched(let profile) = BotMentionResolver.resolve(token, in: profiles) {
        return profile
      }
      return nil
    }

    if let teamID = selectedTeamID, let team = services.botChannels.channel(id: teamID) {
      await routeTeamMessage(text, team: team, visibleNode: node, mentioned: mentioned)
      return
    }

    if let sender = selectedEntry?.profile {
      for other in mentioned where other.id != sender.id {
        _ = try? await services.deliverBotMessage(
          BotMessageInput(to: other.name, body: text, senderProfileID: sender.id),
          context: ToolContext(
            actorID: "otto-app",
            scopes: [.agentControl],
            source: .userInterface
          )
        )
      }
    }
    if isInput && !AgentSlashCommandParser.isCommand(text) {
      do {
        try await services.sendInput(agentID: node.id, text: text)
      } catch {
        await services.recordConversationSendFailure(agentID: node.id, prompt: text, error: error)
      }
    } else {
      do {
        try await services.sendPrompt(agentID: node.id, prompt: text)
      } catch {
        await services.recordConversationSendFailure(agentID: node.id, prompt: text, error: error)
      }
    }
  }

  private func routeTeamMessage(
    _ text: String,
    team: BotChannel,
    visibleNode: OttoNode,
    mentioned: [AgentProfile]
  ) async {
    let members = team.memberProfileIDs.compactMap { services.agentProfiles.profile(id: $0) }
    var targets = mentioned.filter { member in team.memberProfileIDs.contains(member.id) }
    if targets.isEmpty {
      if let leadID = team.orchestratorProfileID,
        let lead = members.first(where: { $0.id == leadID })
      {
        targets = [lead]
      } else {
        targets = members
      }
    }
    services.resetTeamMentionHops(channelID: team.id)
    var firstRecipient: (profileID: UUID, nodeID: UUID)?
    for target in targets {
      guard let nodeID = await ensureBotNode(target) else { continue }
      do {
        // Team charters are part of the agent's hidden bootstrap. The visible prompt must remain
        // exactly what the user typed so operating instructions never leak into chat history.
        try await services.sendPrompt(agentID: nodeID, prompt: text)
        if firstRecipient == nil { firstRecipient = (target.id, nodeID) }
      } catch {
        await services.recordConversationSendFailure(agentID: nodeID, prompt: text, error: error)
        continue
      }
    }
    if let firstRecipient, firstRecipient.nodeID != visibleNode.id {
      // Team chats currently project one canonical bot transcript at a time. Follow the routed
      // message to its recipient so the user's send and the bot's response are immediately visible.
      selectedProfileID = firstRecipient.profileID
      selectedAgentID = firstRecipient.nodeID
    } else if firstRecipient == nil {
      // A missing/stale bot channel should not turn the send button into a no-op.
      do {
        try await services.sendPrompt(agentID: visibleNode.id, prompt: text)
      } catch {
        await services.recordConversationSendFailure(
          agentID: visibleNode.id, prompt: text, error: error)
      }
    }
  }

  private func ensureBotNode(_ profile: AgentProfile) async -> UUID? {
    if let nodeID = services.liveAgentNodeID(
      services.botChannels.canonicalChannel(for: profile.id)?.nodeID)
      ?? roster.first(where: { $0.profile.id == profile.id })?.nodeID
    {
      return nodeID
    }
    return try? await services.openBotChannel(profile, at: launchPoint)
  }

  private func openEntry(_ entry: BotRosterEntry) async {
    do {
      let nodeID = try await services.openBotChannel(entry.profile, at: launchPoint)
      selectedAgentID = nodeID
      store.dispatch(.focusNode(nodeID))
    } catch {
      if let nodeID = entry.nodeID {
        selectedAgentID = nodeID
        store.dispatch(.focusNode(nodeID))
      }
    }
  }

  private func destinationRow(
    _ target: ChatSurfaceDestination, symbol: String, count: Int, attention: Bool = false
  ) -> some View {
    let active = destination == target
    return Button {
      destination = target
    } label: {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .regular))
          .frame(width: 18)
          .animation(motion.tint, value: active)
        OttoWeightStableText(
          target.title, size: 13, active: active,
          activeColor: palette.paper, restingColor: palette.paper.opacity(0.78))
        Spacer(minLength: 4)
        if attention {
          Text("NEEDS YOU")
            .font(.ottoMicro).tracking(1.2)
            .foregroundStyle(palette.amber)
          Circle().fill(palette.amber).frame(width: 6, height: 6)
        } else if count > 0 {
          Text("\(count)")
            .font(.ottoMicro)
            .foregroundStyle(palette.muted)
        }
      }
      .foregroundStyle(palette.paper.opacity(active ? 1 : 0.78))
      .padding(.horizontal, 7)
      .frame(height: 30)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .ottoHoverItem(target)
  }

  private var voiceControlRow: some View {
    HStack(spacing: 4) {
      Button {
        guard !usesPressAndHoldVoice else { return }
        Task { await voice.toggleVoice() }
      } label: {
        HStack(spacing: 10) {
          Image(systemName: voiceShowsListening ? "waveform" : "mic.slash.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(voiceShowsListening ? palette.ink : palette.muted)
            .frame(width: 24, height: 24)
            .background(
              voiceShowsListening ? palette.signal : palette.raised,
              in: Circle()
            )
          VStack(alignment: .leading, spacing: 1) {
            Text("Voice")
              .font(.ottoDisplay(12.5).weight(.medium))
            Text(voiceStatusLabel)
              .font(.ottoDisplay(10.5))
              .foregroundStyle(voiceShowsListening ? palette.signal : palette.muted)
          }
          Spacer(minLength: 0)
        }
        .foregroundStyle(palette.paper)
        .contentShape(Rectangle())
        .padding(.leading, 7)
        .frame(height: 42)
      }
      .buttonStyle(.plain)
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            guard usesPressAndHoldVoice, !voice.isHoldingVoice else { return }
            let toChat = selectedAgent != nil
            Task { await voice.beginHeldVoice(fallingBackToChat: toChat) }
          }
          .onEnded { _ in
            guard usesPressAndHoldVoice else { return }
            Task { await voice.endHeldVoice() }
          }
      )
      .disabled(voice.isVoiceActionInFlight)
      .opacity(voice.isVoiceActionInFlight ? 0.68 : 1)
      .help(voice.localVoiceResultDetail ?? voice.primaryVoiceActionLabel)
      .accessibilityLabel(voice.primaryVoiceActionLabel)

      voiceModeMenu
    }
    .padding(.horizontal, 3)
    .background(
      voice.isMicrophoneActive ? palette.signal.opacity(0.08) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
  }

  private var voiceModeMenu: some View {
    Menu {
      Section("Start") {
        Button("Talk to Otto", systemImage: "waveform") {
          Task { await voice.toggleTalk() }
        }
        Button("Give local command", systemImage: "command") {
          Task { await voice.toggleCommand() }
        }
        Button("Dictate verbatim", systemImage: "text.cursor") {
          Task { await voice.toggleDictation() }
        }
      }

      Section("Operating mode") {
        ForEach(VoiceOperatingMode.allCases) { mode in
          Button {
            voice.operatingMode = mode
          } label: {
            if voice.operatingMode == mode {
              Label(mode.displayName, systemImage: "checkmark")
            } else {
              Text(mode.displayName)
            }
          }
        }
      }

      Divider()
      Button("Voice Settings…", systemImage: "slider.horizontal.3") {
        openSettings()
      }
    } label: {
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(palette.muted)
        .frame(width: 28, height: 34)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Choose voice mode")
    .accessibilityLabel("Choose voice mode")
  }

  private var usesPressAndHoldVoice: Bool {
    voice.operatingMode == .pushToTalk || voice.operatingMode == .outputOnly
  }

  /// Lit from the moment a hold starts, so pressing the control gives instant feedback.
  private var voiceShowsListening: Bool { voice.isMicrophoneActive || voice.isHoldingVoice }

  private var voiceStatusLabel: String {
    if voice.localTranscribing { return "Transcribing…" }
    if !voiceShowsListening, let result = voice.localVoiceResult { return result }
    if voiceShowsListening {
      return "Listening · \(voice.operatingMode.displayName)"
    }
    return voice.operatingMode.displayName
  }

  private var emptyConversation: some View {
    ContentUnavailableView {
      Label(
        sidebarList == .bots ? "No bot selected" : "No session selected",
        systemImage: "sparkles.rectangle.stack"
      )
    } description: {
      Text(
        sidebarList == .bots
          ? "Hire a bot to pin a durable identity. Its conversation is the inbox."
          : "Turn helpers are one-off sessions. They never join your Bots roster or gain a durable identity."
      )
    } actions: {
      if sidebarList == .bots {
        Button("Hire a bot") { showingHire = true }
          .buttonStyle(.borderedProminent)
          .tint(palette.signal)
      }
    }
    .foregroundStyle(palette.paper)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func resourceBrowser(
    title: String, subtitle: String, symbol: String, items: [LibraryItem]
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      workspaceHeader(title: title, subtitle: subtitle)
      if items.isEmpty {
        ContentUnavailableView(
          "Nothing here yet",
          systemImage: symbol,
          description: Text("Notes and media your agents save will appear here.")
        )
        .foregroundStyle(palette.paper)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            ForEach(items) { item in
              Button {
                openLibraryItem(item)
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: resourceSymbol(item.node.kind))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.signal)
                    .frame(width: 38, height: 38)
                    .background(palette.signal.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                  VStack(alignment: .leading, spacing: 4) {
                    Text(item.node.displayName).font(.ottoDisplay(15).weight(.semibold))
                    Text(resourceKindLabel(item.node.kind))
                      .font(.ottoMono(7))
                      .foregroundStyle(palette.muted)
                  }
                  Spacer()
                  Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.muted)
                }
                .foregroundStyle(palette.paper)
                .padding(14)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.paper.opacity(0.08)))
              }
              .buttonStyle(.plain)
            }
          }
          .padding(20)
        }
      }
    }
  }

  private var routinesBrowser: some View {
    AutomationsView(
      store: store, services: services, routines: services.routines,
      onOpenSession: { selectSession($0) },
      runConversation: { AnyView(assistantConversation($0)) }
    )
    .equatable()
  }

  private func openRoutinePanel(routineID: UUID? = nil) {
    panelRoutineID = routineID
    if showsBotRoutines {
      openWorkSurface(.routines)
      return
    }
    destination = .routines
  }

  private func routinesOwnedBy(profileID: UUID?, nodeID: UUID) -> [Routine] {
    services.routines.routines.filter { routine in
      let owner = routineOwner(routine)
      if let profileID, owner.profileID == profileID { return true }
      return owner.nodeID == nodeID
    }
  }

  private func routineOwner(_ routine: Routine) -> (profileID: UUID?, nodeID: UUID?) {
    if case .botChannel(let profileID) = routine.delivery {
      return (profileID, nil)
    }
    switch routine.target {
    case .spawnProfile(let profileID):
      return (profileID, nil)
    case .existingAgent(let nodeID):
      let profileID = allAgentNodes.first { $0.id == nodeID }?.agentDefinition?.profileID
      if let profileID, hiredProfileIDs.contains(profileID) {
        return (profileID, nodeID)
      }
      return (nil, nodeID)
    case .spawnProvider:
      return (nil, nil)
    }
  }

  private struct LibraryItem: Identifiable {
    var id: UUID { node.id }
    let node: OttoNode
    let canvas: OttoCanvas
  }

  /// Notes and media open in the user's own apps.
  private func openLibraryItem(_ item: LibraryItem) {
    switch item.node.content {
    case .markdown(let path?, _):
      NSWorkspace.shared.open(
        URL(fileURLWithPath: services.documents.rootPath).appending(path: path))
    case .media(let source):
      if let url = URL(string: source), url.scheme != nil {
        NSWorkspace.shared.open(url)
      } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: source))
      }
    default:
      break
    }
  }

  private func resourceKindLabel(_ kind: NodeKind) -> String {
    switch kind {
    case .markdown: "NOTE"
    case .media: "MEDIA"
    default: "ITEM"
    }
  }

  private func libraryItems(kinds: Set<NodeKind>) -> [LibraryItem] {
    store.snapshot.canvases.flatMap { canvas in
      canvas.nodes.compactMap { node -> LibraryItem? in
        guard kinds.contains(node.kind) else { return nil }
        return LibraryItem(node: node, canvas: canvas)
      }
    }
  }

  private func workspaceHeader(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.ottoDisplay(28).weight(.semibold))
        .foregroundStyle(palette.paper)
      Text(subtitle)
        .font(.ottoDisplay(13))
        .foregroundStyle(palette.muted)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(22)
    .background(palette.surface)
    .overlay(alignment: .bottom) { Divider().overlay(palette.paper.opacity(0.08)) }
  }

  private func agentDetails(_ node: OttoNode) -> some View {
    let entry = selectedEntry
    let notes = entry.map { services.botNotes.snapshot(for: $0.profile.id).composedBody } ?? ""
    return VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        if let entry {
          profileAvatar(entry, size: 46)
        } else {
          agentAvatar(node, size: 46)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(entry?.profile.name ?? node.displayName).font(.ottoDisplay(20).weight(.semibold))
          Text(identityLabel(node, profile: entry?.profile))
            .font(.ottoMono(8)).foregroundStyle(palette.muted)
        }
      }
      Divider()
      if let job = entry?.profile.jobTitle, !job.isEmpty {
        detailLine("PRIMARY JOB", job)
      }
      detailLine("HARNESS", providerName(node))
      if let profile = entry?.profile {
        pluginShowcase(services.harnessPlugins(for: profile.provider), provider: profile.provider)
      }
      detailLine("PERMISSIONS", permissionLabel(node))
      detailLine(
        "PRESENCE",
        entry.map { $0.needsYou ? "needs you" : $0.presence.rawValue }
          ?? (services.fleet[node.id]?.state.rawValue ?? "idle"))
      detailLine("CANVAS", store.activeCanvas.name)
      detailLine(
        "PRIVATE MEMORY",
        notes.isEmpty
          ? "Empty vault. Notes and agent-role records stay on this bot."
          : notes
      )
    }
    .foregroundStyle(palette.paper)
    .padding(18)
    .frame(width: 320)
    .background(palette.surface)
  }

  private func pluginShowcase(_ plugins: [HarnessPlugin], provider: AgentProvider) -> some View {
    let extras = plugins.filter { $0.source != HarnessPluginCatalog.ottoSource }
    return VStack(alignment: .leading, spacing: 8) {
      Text("TOOLS").font(.ottoMono(7, weight: .black)).foregroundStyle(palette.muted)
      PluginLogoRow(plugins: extras.isEmpty ? plugins : extras, palette: palette, size: 28)
      Text(pluginSummary(extrasCount: extras.count))
        .font(.ottoDisplay(12).weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      Text(HarnessPluginCatalog.addMoreHint(for: provider))
        .font(.ottoMono(8))
        .foregroundStyle(palette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func pluginSummary(extrasCount: Int) -> String {
    if extrasCount == 0 {
      return "Otto tools are included."
    }
    if extrasCount == 1 {
      return "1 app or plugin available, plus Otto tools."
    }
    return "\(extrasCount) apps and plugins available, plus Otto tools."
  }

  private func detailLine(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.ottoMono(7, weight: .black)).foregroundStyle(palette.muted)
      Text(value).font(.ottoDisplay(13).weight(.semibold))
    }
  }

  private func agentAvatar(_ node: OttoNode, size: CGFloat) -> some View {
    BotAvatarView(
      presentation: BotAvatarPresentation(
        id: node.id,
        name: node.displayName,
        state: avatarState(for: services.fleet[node.id]?.state)
      ),
      size: size
    )
  }

  private func profileAvatar(_ entry: BotRosterEntry, size: CGFloat) -> some View {
    BotAvatarView(
      presentation: avatarPresentation(entry),
      size: size
    )
  }

  private func avatarPresentation(_ entry: BotRosterEntry) -> BotAvatarPresentation {
    BotAvatarPresentation(
      id: entry.profile.id,
      name: entry.profile.name,
      appearance: entry.appearance,
      photoURL: services.botPhotoURL(entry.appearance?.photoRelativePath),
      state: entry.avatarState
    )
  }

  private func teamAvatarMembers(_ channel: BotChannel) -> [BotAvatarPresentation] {
    channel.memberProfileIDs.compactMap { id in
      roster.first(where: { $0.profile.id == id }).map(avatarPresentation)
    }
  }

  private func avatarState(for lifecycle: AgentLifecycleState?) -> BotAvatarState {
    switch lifecycle {
    case .starting, .working: .working
    case .waitingPermission, .waitingUser: .needsUser
    case .failed, .interrupted: .failed
    case .stopped: .offline
    case .created, .idle, .done, nil: .idle
    }
  }

  private func repairSelection() {
    // Keeping the selection valid must never navigate away from Dashboards or Documents.
    let page = destination
    defer { if page == .dashboards || page == .documents { destination = page } }
    if sidebarList == .sessions {
      if let selectedSessionID, sessionAgents.contains(where: { $0.id == selectedSessionID }) {
        selectedAgentID = selectedSessionID
        return
      }
      if let selected = store.activeCanvas.selectedNodeID,
        let node = sessionAgents.first(where: { $0.id == selected })
      {
        selectSession(node)
        return
      }
      if let first = sessionAgents.first {
        selectSession(first)
      } else {
        selectedSessionID = nil
        selectedAgentID = nil
      }
      return
    }

    selectedSessionID = nil
    if let selectedProfileID, roster.contains(where: { $0.profile.id == selectedProfileID }) {
      if let nodeID = roster.first(where: { $0.profile.id == selectedProfileID })?.nodeID {
        selectedAgentID = nodeID
      }
      return
    }
    if let selected = store.activeCanvas.selectedNodeID,
      let node = allAgentNodes.first(where: { $0.id == selected }),
      let profileID = node.agentDefinition?.profileID, hiredProfileIDs.contains(profileID)
    {
      selectedProfileID = profileID
      selectedAgentID = selected
      return
    }
    if let first = roster.first {
      selectedProfileID = first.profile.id
      selectedAgentID = first.nodeID
    } else {
      selectedProfileID = nil
      selectedAgentID = nil
    }
  }

  private func applyBotNavigation(_ request: BotNavigationRequest?) {
    guard let request else { return }
    destination = .conversation
    switch request.destination {
    case .bots:
      sidebarList = .bots
      selectedTeamID = nil
      selectedSessionID = nil
      repairSelection()
    case .bot(let profileID):
      sidebarList = .bots
      selectedTeamID = nil
      selectedSessionID = nil
      selectedProfileID = profileID
      selectedAgentID = roster.first(where: { $0.profile.id == profileID })?.nodeID
    case .team(let channelID):
      guard let team = teams.first(where: { $0.id == channelID }) else { return }
      sidebarList = .bots
      selectedTeamID = channelID
      selectedSessionID = nil
      selectedProfileID = team.orchestratorProfileID ?? team.memberProfileIDs.first
      selectedAgentID = selectedProfileID.flatMap { profileID in
        roster.first(where: { $0.profile.id == profileID })?.nodeID
      }
    case .session(let nodeID):
      guard
        let canvas = store.snapshot.canvases.first(where: { canvas in
          canvas.nodes.contains { $0.id == nodeID && $0.kind == .agent }
        })
      else { return }
      sessionCanvasID = canvas.id
      sidebarList = .sessions
      selectedTeamID = nil
      selectedProfileID = nil
      selectedSessionID = nodeID
      selectedAgentID = nodeID
      closeRoutineWorkTabs()
    case .sessions:
      sidebarList = .sessions
      selectedTeamID = nil
      repairSelection()
    }
  }

  /// Canvas tools (including local and conversational voice) express "open this session" as a
  /// node focus. Spatial layouts render that directly; Chat needs to mirror it into its private
  /// conversation selection because the focused canvas card is intentionally offstage here.
  private func applyFocusedAgentTarget(_ target: ChatFocusedAgentTarget) {
    if onWorkPage { return }
    // Automation runs are background work: starting one must not pull the person into it.
    if services.isStartingAutomationRun { return }
    if case .session(_, let nodeID) = target, boundHelperIDs.contains(nodeID) { return }
    destination = .conversation
    switch target {
    case .session(let canvasID, let nodeID):
      sessionCanvasID = canvasID
      sidebarList = .sessions
      selectedSessionID = nodeID
      selectedProfileID = nil
      selectedTeamID = nil
      selectedAgentID = nodeID
      closeRoutineWorkTabs()
    case .bot(let profileID, let nodeID):
      // Team conversations project their orchestrator/member's canonical node. Focusing that node
      // is an implementation detail and must not collapse the selected team into a one-to-one chat.
      if let selectedTeamID,
        services.botChannels.channel(id: selectedTeamID)?.memberProfileIDs.contains(profileID)
          == true
      {
        return
      }
      sidebarList = .bots
      selectedSessionID = nil
      selectedTeamID = nil
      selectedProfileID = profileID
      selectedAgentID = nodeID
    }
  }

  private func performDeletion(_ target: DeletionTarget) {
    pendingDeletion = nil
    switch target.kind {
    case .team:
      try? services.deleteTeam(channelID: target.id)
      if selectedTeamID == target.id {
        selectedTeamID = nil
        selectedProfileID = roster.first?.profile.id
        selectedAgentID = roster.first?.nodeID
      }
    case .bot:
      try? services.deleteAgentProfile(id: target.id)
      if let nodeID = target.nodeID {
        Task { try? await services.closeNode(nodeID: nodeID) }
      }
      if selectedProfileID == target.id {
        selectedProfileID = nil
        selectedAgentID = nil
        selectedTeamID = nil
      }
    }
    repairSelection()
  }

  private func nodes(of kind: NodeKind) -> [OttoNode] {
    store.activeCanvas.nodes.filter { $0.kind == kind }
  }

  private func providerName(_ node: OttoNode) -> String {
    node.agentDefinition?.provider.rawValue ?? "Agent"
  }

  private func identityLabel(_ node: OttoNode, profile: AgentProfile? = nil) -> String {
    let name = (profile?.name ?? node.displayName).uppercased()
    if let job = profile?.jobTitle, !job.isEmpty {
      return "\(name) · \(job.uppercased())"
    }
    return "\(name) · \(providerName(node).uppercased())"
  }

  private func permissionLabel(_ node: OttoNode) -> String {
    guard let raw = node.agentDefinition?.permissionMode else { return "WORKSPACE WRITE" }
    return raw.replacingOccurrences(of: "_", with: " ").uppercased()
  }

  private func agentPreview(_ node: OttoNode) -> String {
    if let snapshot = services.fleet[node.id] {
      if let result = snapshot.result?.trimmingCharacters(in: .whitespacesAndNewlines),
        !result.isEmpty
      {
        return result
      }
      if let prompt = snapshot.lastPrompt, !prompt.isEmpty { return prompt }
      return snapshot.state.rawValue.capitalized
    }
    return node.detail
  }

  private func resourceSymbol(_ kind: NodeKind) -> String {
    switch kind {
    case .markdown: "doc.text"
    case .media: "play.rectangle"
    default: "square.stack.3d.up"
    }
  }

  private func setPermissionMode(_ mode: AgentPermissionMode, for nodeID: UUID) {
    Task { await services.changeAgentPermissionMode(mode, agentID: nodeID) }
  }

  private func setModel(_ model: String?, effort: String?, for nodeID: UUID) {
    guard
      var definition = store.activeCanvas.nodes.first(where: { $0.id == nodeID })?
        .agentDefinition
    else { return }
    definition.model = model
    definition.effort = effort
    store.dispatch(.setAgentDefinition(id: nodeID, definition: definition))
    if let snapshot = services.fleet[nodeID], snapshot.exitCode == nil,
      snapshot.executionMode == .interactiveProvider
    {
      Task { try? await services.restart(agentID: nodeID) }
    }
  }

  private func setExecutionStrategy(_ strategy: AgentExecutionStrategy, for nodeID: UUID) {
    guard
      var definition = store.activeCanvas.nodes.first(where: { $0.id == nodeID })?
        .agentDefinition,
      strategy.isSupported(by: definition.provider)
    else { return }
    definition.executionStrategy = strategy
    store.dispatch(.setAgentDefinition(id: nodeID, definition: definition))
  }
}

private struct PluginLogoRow: View {
  let plugins: [HarnessPlugin]
  let palette: OttoPalette
  var size: CGFloat = 32
  var maxVisible: Int = 24

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hoveredIndex: Int?

  private let lift: CGFloat = -4
  private let falloff: CGFloat = 0.45
  private let activeScale: CGFloat = 1.05
  private let duration: Double = 0.32

  var body: some View {
    let visible = Array(plugins.prefix(maxVisible))
    let overflow = plugins.count - visible.count
    VStack(alignment: .leading, spacing: 6) {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: size, maximum: size + 4), spacing: 10)],
        alignment: .leading,
        spacing: 10
      ) {
        ForEach(Array(visible.enumerated()), id: \.element.id) { index, plugin in
          PluginBrandTile(plugin: plugin, palette: palette, size: size)
            .offset(y: shift(for: index))
            .scaleEffect(scale(for: index), anchor: .center)
            .zIndex(hoveredIndex == index ? 80 : Double(index))
            .onHover { hovering in
              guard hovering else { return }
              animate(entering: true) { hoveredIndex = index }
            }
        }
        if overflow > 0 {
          overflowTile(overflow)
            .offset(y: shift(for: visible.count))
            .scaleEffect(scale(for: visible.count), anchor: .center)
            .zIndex(hoveredIndex == visible.count ? 80 : Double(visible.count))
            .onHover { hovering in
              guard hovering else { return }
              animate(entering: true) { hoveredIndex = visible.count }
            }
        }
      }
      .padding(.top, 8)
      .padding(.bottom, 2)
      .onHover { hovering in
        if !hovering { animate(entering: false) { hoveredIndex = nil } }
      }
      hoverCaption(visible: visible, overflow: overflow)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(plugins.map(\.name).joined(separator: ", "))
  }

  @ViewBuilder
  private func hoverCaption(visible: [HarnessPlugin], overflow: Int) -> some View {
    if let hoveredIndex {
      let label: String = {
        if hoveredIndex < visible.count { return visible[hoveredIndex].name }
        return "\(overflow) more"
      }()
      Text(label)
        .font(.ottoMono(8, weight: .bold))
        .foregroundStyle(palette.paper)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(palette.raised, in: Capsule())
        .transition(.opacity)
    } else {
      Text(" ")
        .font(.ottoMono(8, weight: .bold))
        .frame(height: 20)
        .hidden()
    }
  }

  private func shift(for index: Int) -> CGFloat {
    guard let hoveredIndex else { return 0 }
    let distance = abs(index - hoveredIndex)
    return lift * pow(falloff, CGFloat(distance))
  }

  private func scale(for index: Int) -> CGFloat {
    hoveredIndex == index ? activeScale : 1
  }

  private func animate(entering: Bool, _ update: () -> Void) {
    if reduceMotion {
      update()
      return
    }
    let curve =
      entering
      ? Animation.timingCurve(0.22, 1, 0.36, 1, duration: duration)
      : Animation.timingCurve(0.34, 1.85, 0.64, 1, duration: duration)
    withAnimation(curve, update)
  }

  private func overflowTile(_ count: Int) -> some View {
    Text("+\(count)")
      .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
      .foregroundStyle(palette.paper)
      .frame(width: size, height: size)
      .help("\(count) more")
  }
}

private struct PluginBrandTile: View {
  let plugin: HarnessPlugin
  let palette: OttoPalette
  var size: CGFloat = 32

  var body: some View {
    // The tile has no fill of its own, so a lettermark sits on the page surface. Choosing
    // white or `ink` from the *brand* colour drew white letters on light pages, and on light
    // themes `ink` is itself near-white. The theme's text colour always reads.
    let ink = palette.paper
    let artwork = PluginLogoArtwork.artwork(for: plugin)
    ZStack {
      tileForeground(ink: ink, artwork: artwork)
    }
    .frame(width: size, height: size)
    .help(plugin.name)
    .accessibilityLabel(plugin.name)
  }

  @ViewBuilder
  private func tileForeground(ink: Color, artwork: PluginLogoArtwork) -> some View {
    switch artwork {
    case .image(let image, .original):
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
    case .image(let image, .mark):
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .padding(size * 0.06)
    case .image(let image, .template):
      Image(nsImage: image)
        .resizable()
        .renderingMode(.template)
        .scaledToFit()
        .foregroundStyle(fillColor)
        .padding(size * 0.12)
    case .mark(let mark):
      Text(mark)
        .font(.system(size: size * (mark.count > 1 ? 0.32 : 0.44), weight: .bold, design: .rounded))
        .foregroundStyle(ink)
        .minimumScaleFactor(0.6)
    }
  }

  private var fillColor: Color {
    Color(hex: plugin.colorHex) ?? palette.signal
  }
}

private struct ChatAgentSnapshotHost<Content: View>: View {
  let model: AgentRuntimeModel?
  @ViewBuilder let content: (AgentRuntimeSnapshot?) -> Content

  var body: some View {
    if let model {
      ChatObservedAgentSnapshot(model: model, content: content)
    } else {
      content(nil)
    }
  }
}

private struct ChatObservedAgentSnapshot<Content: View>: View {
  @ObservedObject var model: AgentRuntimeModel
  @ViewBuilder let content: (AgentRuntimeSnapshot?) -> Content

  var body: some View { content(model.snapshot) }
}

struct HireBotSheet: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var services: ApplicationServices
  @ObservedObject private var catalogStore = ProviderModelCatalogStore.shared
  /// When set, the sheet edits this bot instead of hiring a new one.
  let editing: AgentProfile?
  let hired: (AgentProfile) -> Void

  @State private var name = ""
  @State private var jobTitle = ""
  @State private var instructions = ""
  @State private var provider = AgentProvider.codex
  @State private var accountID: UUID?
  @State private var model = ""
  @State private var effort = ""
  @State private var permissionMode = AgentPermissionMode.workspaceWrite
  @State private var colorHex: String?
  @State private var shape = "rounded"
  /// Nil draws the bot as a member of Otto's family with an accessory suggested by its name and
  /// job; the accessory strip or the emoji grid in Advanced make an explicit choice.
  @State private var icon: String?
  @State private var pendingPhotoURL: URL?
  @State private var existingPhotoPath: String?
  @State private var availability: [AgentProviderInfo] = []
  @State private var scanningProviders = true
  @State private var saving = false
  @State private var errorMessage: String?
  @State private var showingAdvanced = false
  @State private var showingLocalModelSettings = false

  private let colors = ["#397b69", "#ad6a66", "#526b8e", "#a46e21", "#087f83"]

  init(
    services: ApplicationServices,
    editing: AgentProfile? = nil,
    hired: @escaping (AgentProfile) -> Void
  ) {
    self.services = services
    self.editing = editing
    self.hired = hired
    guard let profile = editing else { return }
    let appearance = services.botAppearance.appearance(for: profile.id)
    _name = State(initialValue: profile.name)
    _jobTitle = State(initialValue: profile.jobTitle ?? profile.role)
    _instructions = State(initialValue: profile.instructions)
    _provider = State(initialValue: profile.provider)
    _accountID = State(initialValue: profile.accountID)
    _model = State(initialValue: profile.model ?? "")
    _effort = State(initialValue: profile.effort ?? "")
    _permissionMode = State(
      initialValue: AgentPermissionMode(rawValue: profile.permissionMode) ?? .workspaceWrite)
    _colorHex = State(initialValue: appearance?.colorHex)
    _shape = State(initialValue: appearance?.shape ?? "rounded")
    _icon = State(initialValue: appearance?.avatarRef)
    _existingPhotoPath = State(initialValue: appearance?.photoRelativePath)
    _showingAdvanced = State(initialValue: true)
  }

  private var isEditing: Bool { editing != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      hireHeader
      hireIdentity
      BotCreationAccountPicker(accounts: services.providerAccounts, selection: $accountID)
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .onChange(of: accountID) { _, _ in
          model = ""
          effort = ""
        }
      hireFaceSection
      hireAdvanced
      Spacer(minLength: 0)
      hireFooter
    }
    // The sheet sizes to what it is asking for. A fixed 640pt box left the two fields
    // floating in an empty slab; Advanced is what earns the extra height.
    .frame(width: 520)
    .frame(height: showingAdvanced ? 804 : 552)
    .background(palette.surface)
    .animation(OttoMotion.moderate.enter, value: showingAdvanced)
    .task(id: catalogStore.request(for: provider, accountID: modelAccountID)) {
      await catalogStore.load(provider, accountID: modelAccountID)?.value
    }
    .task {
      scanningProviders = true
      availability = (try? await services.providerAvailability()) ?? []
      scanningProviders = false
      if !isEditing,
        availability.first(where: { $0.provider == provider })?.installed != true,
        let firstInstalled = hireableProviders.first
      {
        provider = firstInstalled
      }
      alignSelections(for: provider)
      catalogStore.load(provider, accountID: modelAccountID)
    }
    .sheet(isPresented: $showingLocalModelSettings) {
      VStack(spacing: 0) {
        HStack {
          Text("Add an OpenAI-compatible model")
            .font(.headline)
          Spacer()
          Button("Done") { showingLocalModelSettings = false }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
        Divider()
        ModelProviderSettingsView(initialProvider: .local) {
          guard let saved = LocalModelConfiguration.load() else { return }
          // Keep the bot draft intact: this chooses only its model and does
          // not save or overwrite the bot until Save changes is pressed.
          model = OttoHarnessModelSelection.persistedID(
            provider: .local, modelID: saved.modelID)
          effort = ""
          catalogStore.load(.openAI, accountID: modelAccountID)
        }
      }
      .frame(width: 625, height: 660)
      .onExitCommand { showingLocalModelSettings = false }
    }
  }

  private var modelAccountID: UUID? { accountID ?? services.providerAccounts.defaultAccountID }

  private var hireHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(isEditing ? "EDIT BOT" : "HIRE A BOT")
        .font(.ottoMono(8, weight: .black))
        .tracking(2)
        .foregroundStyle(palette.signal)
      Text(
        isEditing
          ? "Change anything about \(editing?.name ?? "this bot")."
          : "Give your teammate a name and one clear responsibility."
      )
      .font(.ottoDisplay(20).weight(.semibold))
      .foregroundStyle(palette.paper)
      .fixedSize(horizontal: false, vertical: true)
      Text(
        isEditing
          ? "Name, look, harness, model, permissions and instructions. Memory and notes are kept."
          : "Otto handles the setup: a private channel, memory, connection policy and safe defaults."
      )
      .font(.ottoDisplay(12))
      .foregroundStyle(palette.muted)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 28)
    .padding(.top, 24)
  }

  /// Identity is the part of hiring you actually feel, so it leads: the avatar reacts to
  /// the name and colour as you type instead of hiding behind Advanced.
  private var hireIdentity: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(spacing: 8) {
        hireAvatarPreview
        HStack(spacing: 5) {
          ForEach(colors, id: \.self) { hex in
            Circle()
              .fill(Color(hex: hex) ?? palette.signal)
              .frame(width: 10, height: 10)
              .overlay {
                if (colorHex ?? colors.first) == hex {
                  Circle().stroke(Color(hex: hex) ?? palette.signal, lineWidth: 1.5)
                    .padding(-3)
                }
              }
              .onTapGesture { colorHex = hex }
              .accessibilityLabel("Avatar colour \(hex)")
          }
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        hireField("SHORT NAME", text: $name, prompt: "Beck")
        hireField(
          "RESPONSIBILITY", text: $jobTitle, prompt: "e.g. Reviews every PR before it merges")
      }
    }
    .padding(.horizontal, 28)
    .padding(.top, 22)
  }

  private var hireFaceSection: some View {
    hireFacePicker
      .padding(.horizontal, 28)
      .padding(.top, 18)
  }

  private var hireTint: Color {
    Color(hex: colorHex ?? colors.first ?? "") ?? palette.signal
  }

  private var hireAccessory: BotFamily.Accessory {
    BotFamily.accessory(reference: icon, name: name, role: jobTitle)
  }

  private var hireAvatarPreview: some View {
    Group {
      if let icon, BotIconCatalog.symbols.contains(icon) {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hireTint)
          .overlay(Text(icon).font(.system(size: 26)))
      } else {
        OttoFace(bot: hireAccessory, color: hireTint, state: .idle, size: 56)
      }
    }
    .frame(width: 56, height: 56)
    .accessibilityLabel("Avatar preview, \(hireAccessory.name)")
  }

  /// Every bot is one of Otto's family: same shape, its own colour, one accessory. Picking the
  /// accessory is the moment the bot stops being a form and starts being someone.
  private var hireFacePicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("LOOK")
        .font(.ottoMono(7, weight: .black))
        .tracking(1.4)
        .foregroundStyle(palette.muted)
      HStack(spacing: 8) {
        ForEach(BotFamily.Accessory.allCases) { accessory in
          let selected =
            pendingPhotoURL == nil && !BotIconCatalog.symbols.contains(icon ?? "")
            && hireAccessory == accessory
          Button {
            icon = accessory.reference
            pendingPhotoURL = nil
            existingPhotoPath = nil
          } label: {
            OttoFace(bot: accessory, color: hireTint, state: .idle, size: 34)
              .opacity(selected ? 1 : 0.55)
              .frame(width: 42, height: 42)
              .background(
                palette.raised.opacity(selected ? 1 : 0.5),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(selected ? palette.signal : Color.clear, lineWidth: 1.5)
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(accessory.name)
          .accessibilityLabel("Look: \(accessory.name)")
          .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
        Spacer(minLength: 0)
      }
    }
  }

  /// Collapsed, Advanced still reports what it is holding, so the defaults you are agreeing
  /// to are visible without opening anything.
  private var hireAdvanced: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation(OttoMotion.moderate.enter) { showingAdvanced.toggle() }
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(palette.muted)
            .rotationEffect(.degrees(showingAdvanced ? 90 : 0))
          Text("Advanced")
            .font(.ottoDisplay(13).weight(.semibold))
            .foregroundStyle(palette.paper)
          Spacer(minLength: 8)
          if !showingAdvanced {
            HStack(spacing: 6) {
              ForEach(advancedSummary, id: \.self) { chip in
                Text(chip)
                  .font(.ottoMono(7, weight: .bold))
                  .foregroundStyle(palette.muted)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 3)
                  .background(palette.raised, in: Capsule())
                  .overlay(Capsule().stroke(palette.paper.opacity(0.08)))
              }
            }
          }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
          palette.paper.opacity(0.04),
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(palette.paper.opacity(0.06))
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if showingAdvanced {
        ScrollView {
          advancedSettings
            .padding(.bottom, 8)
        }
      }
    }
    .padding(.horizontal, 28)
    .padding(.top, 20)
  }

  private var advancedSummary: [String] {
    var chips = [providerLabel(provider)]
    if model.isEmpty {
      chips.append("Provider default")
    } else if let match = modelOptions.first(where: { $0.id == model }) {
      chips.append(match.displayName)
    }
    chips.append(permissionLabel(permissionMode))
    return chips
  }

  private var hireFooter: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let errorMessage {
        Text(errorMessage).font(.ottoMono(8)).foregroundStyle(palette.red)
      }
      HStack(spacing: 10) {
        Text(footerNote)
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button("Cancel") { dismiss() }
          .buttonStyle(.plain)
          .font(.ottoDisplay(12.5).weight(.medium))
          .foregroundStyle(palette.muted)
        Button {
          hire()
        } label: {
          Text(saving ? (isEditing ? "Saving…" : "Hiring…") : hireActionTitle)
            .font(.ottoDisplay(12.5).weight(.semibold))
            // Text matched to the fill: white on a light theme's signal was fine, but white
            // on a dark theme's pale signal (Field Notes lime) was unreadable.
            .foregroundStyle(canHire && !saving ? palette.onSignal : palette.paper)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(
              canHire && !saving ? palette.signal : palette.raised,
              in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .opacity(canHire && !saving ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(saving || !canHire)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(.horizontal, 28)
    .padding(.top, 18)
    .padding(.bottom, 22)
  }

  /// Naming the hire in the button makes the commitment concrete before you press it.
  private var hireActionTitle: String {
    if isEditing { return "Save changes" }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Hire" : "Hire \(trimmed)"
  }

  private var footerNote: String {
    guard let editing else { return "You can change any of this after hiring." }
    return editing.provider != provider
      ? "Changing the harness starts a fresh session. Memory and notes are kept."
      : "Changes apply to open sessions straight away."
  }

  private var advancedSettings: some View {
    VStack(alignment: .leading, spacing: 16) {
      advancedInstructions
      advancedHarness
      advancedModel
      advancedTools
      advancedEffort
      advancedPermissions
      advancedIcon
      advancedPhoto
      advancedColor
    }
    .padding(.top, 12)
  }

  private var advancedInstructions: some View {
    VStack(alignment: .leading, spacing: 7) {
      advancedLabel("HOW THEY WORK")
      TextEditor(text: $instructions)
        .font(.ottoMono(10.5))
        .scrollContentBackground(.hidden)
        .foregroundStyle(palette.paper)
        .padding(8)
        .frame(minHeight: 88)
        .background(palette.ink.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.paper.opacity(0.1)))
    }
  }

  private var advancedHarness: some View {
    VStack(alignment: .leading, spacing: 7) {
      advancedLabel("HARNESS")
      Picker("Harness", selection: $provider) {
        ForEach(hireableProviders, id: \.self) { option in
          Text(providerLabel(option)).tag(option)
        }
      }
      .labelsHidden()
      .onChange(of: provider) { _, next in
        catalogStore.load(next, accountID: modelAccountID)
        alignSelections(for: next)
      }
      if scanningProviders {
        HStack(spacing: 7) {
          ProgressView().controlSize(.small)
          Text("Checking installed harnesses…")
        }
        .font(.ottoMono(8))
        .foregroundStyle(palette.muted)
      } else if let remediation = providerRemediation(provider) {
        // Say why a harness is greyed out, so "not installed" is never a dead end.
        Text(remediation)
          .font(.ottoMono(8))
          .foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("bot-harness-remediation")
      }
    }
  }

  /// The adapter's own remediation for a harness that cannot start, or nil when it is ready.
  private func providerRemediation(_ provider: AgentProvider) -> String? {
    guard let info = availability.first(where: { $0.provider == provider }), !info.installed
    else { return nil }
    return info.remediation ?? "Install it, sign in, then come back."
  }

  @ViewBuilder
  private var advancedModel: some View {
    if provider == .openAI {
      VStack(alignment: .leading, spacing: 6) {
        Button {
          showingLocalModelSettings = true
        } label: {
          Label(
            LocalModelConfiguration.load() == nil
              ? "Add OpenAI-compatible local model…"
              : "Edit OpenAI-compatible local model…",
            systemImage: "plus.circle")
        }
        .accessibilityIdentifier("bot-local-model-setup")
        if LocalModelConfiguration.load() == nil {
          Text(
            "No local model is configured yet. Add the server URL and model ID here, then select it below."
          )
          .font(.ottoMono(8))
          .foregroundStyle(palette.muted)
        }
      }
    }
    if !modelOptions.isEmpty {
      VStack(alignment: .leading, spacing: 7) {
        advancedLabel("MODEL")
        Picker("Model", selection: $model) {
          Text("Provider default").tag("")
          ForEach(modelOptions, id: \.id) { option in
            Text(option.displayName).tag(option.id)
          }
        }
        .labelsHidden()
        .onChange(of: model) { _, _ in alignSelections(for: provider) }
      }
    }
  }

  private var advancedTools: some View {
    let plugins = services.harnessPlugins(for: provider)
    let extras = plugins.filter { $0.source != HarnessPluginCatalog.ottoSource }
    return VStack(alignment: .leading, spacing: 7) {
      advancedLabel("TOOLS THIS BOT CAN USE")
      PluginLogoRow(plugins: extras.isEmpty ? plugins : extras, palette: palette, size: 32)
      Text(
        extras.isEmpty
          ? "Otto tools are included."
          : "\(extras.count) additional integration\(extras.count == 1 ? "" : "s"), plus Otto tools."
      )
      .font(.ottoDisplay(13).weight(.semibold))
      .foregroundStyle(palette.paper)
      .fixedSize(horizontal: false, vertical: true)
      Text(HarnessPluginCatalog.addMoreHint(for: provider))
        .font(.ottoMono(8))
        .foregroundStyle(palette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var advancedEffort: some View {
    if !effortOptions.isEmpty {
      VStack(alignment: .leading, spacing: 7) {
        advancedLabel("REASONING")
        Picker("Reasoning", selection: $effort) {
          Text("Provider default").tag("")
          ForEach(effortOptions, id: \.self) { level in
            Text(level.capitalized).tag(level)
          }
        }
        .labelsHidden()
      }
    }
  }

  private var advancedPermissions: some View {
    VStack(alignment: .leading, spacing: 7) {
      advancedLabel("PERMISSIONS")
      Picker("Permissions", selection: $permissionMode) {
        ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
          Text(permissionLabel(mode)).tag(mode)
        }
      }
      .labelsHidden()
    }
  }

  private var advancedIcon: some View {
    VStack(alignment: .leading, spacing: 7) {
      advancedLabel("ICON")
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6
      ) {
        ForEach(BotIconCatalog.symbols, id: \.self) { symbol in
          Button {
            icon = symbol
            pendingPhotoURL = nil
            existingPhotoPath = nil
          } label: {
            Text(symbol)
              .font(.system(size: 16))
              .frame(width: 30, height: 30)
              .background(
                icon == symbol && pendingPhotoURL == nil
                  ? palette.signal.opacity(0.28) : palette.raised,
                in: RoundedRectangle(cornerRadius: 7)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 7)
                  .stroke(icon == symbol ? palette.signal : Color.clear, lineWidth: 1.5)
              )
          }
          .buttonStyle(.plain)
          .accessibilityLabel(symbol)
        }
      }
    }
  }

  private var advancedPhoto: some View {
    VStack(alignment: .leading, spacing: 7) {
      advancedLabel("PHOTO")
      HStack(spacing: 10) {
        if let photoURL = pendingPhotoURL ?? services.botPhotoURL(existingPhotoPath),
          let image = NSImage(contentsOf: photoURL)
        {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        let hasPhoto = pendingPhotoURL != nil || existingPhotoPath != nil
        Button(hasPhoto ? "Replace photo" : "Upload a photo") {
          choosePhoto()
        }
        if hasPhoto {
          Button("Use icon instead") {
            pendingPhotoURL = nil
            existingPhotoPath = nil
          }
        }
        Spacer()
      }
    }
  }

  /// Colour moved up to the identity row beside the live avatar, so only shape is left here.
  private var advancedColor: some View {
    VStack(alignment: .leading, spacing: 7) {
      advancedLabel("AVATAR SHAPE")
      Picker("Shape", selection: $shape) {
        Text("Rounded").tag("rounded")
        Text("Circle").tag("circle")
      }
      .labelsHidden()
      .frame(width: 110)
    }
  }

  private func advancedLabel(_ text: String) -> some View {
    Text(text)
      .font(.ottoMono(8, weight: .black))
      .tracking(1.2)
      .foregroundStyle(palette.muted)
  }

  private var hireableProviders: [AgentProvider] {
    AgentProvider.allCases.filter { $0 != .shell }
  }

  private var modelOptions: [AgentModel] {
    catalogStore.catalog(for: provider, accountID: modelAccountID)
      ?? (ProviderModelCatalogStore.isDiscovered(provider)
        ? [] : AgentModelCatalog.options(for: provider))
  }
  private var effortOptions: [String] {
    AgentModelCatalog.effortLevels(for: provider, modelID: model)
  }

  private var canHire: Bool {
    !scanningProviders
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !jobTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && availability.first(where: { $0.provider == provider })?.installed == true
  }

  private func hireField(
    _ label: String, text: Binding<String>, prompt: String = ""
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.ottoMono(7, weight: .black))
        .tracking(1.4)
        .foregroundStyle(palette.muted)
      TextField(
        "", text: text,
        prompt: Text(prompt).foregroundStyle(palette.muted.opacity(0.8))
      )
      .textFieldStyle(.plain)
      .font(.ottoDisplay(13))
      .foregroundStyle(palette.paper)
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(
        palette.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(palette.paper.opacity(0.1))
      )
    }
  }

  private func alignSelections(for provider: AgentProvider) {
    let models =
      catalogStore.catalog(for: provider, accountID: modelAccountID)
      ?? (ProviderModelCatalogStore.isDiscovered(provider)
        ? [] : AgentModelCatalog.options(for: provider))
    if !model.isEmpty, !models.contains(where: { $0.id == model }) { model = "" }
    let efforts = AgentModelCatalog.effortLevels(for: provider, modelID: model)
    if !efforts.contains(effort) { effort = "" }
  }

  private func providerLabel(_ provider: AgentProvider) -> String {
    let name = provider == .openAI ? "Otto Harness" : provider.rawValue
    if scanningProviders { return "\(name) · checking…" }
    let installed = availability.first { $0.provider == provider }?.installed == true
    return installed ? name : "\(name) · not installed"
  }

  private func choosePhoto() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.jpeg, .png, .webP, .heic]
    panel.prompt = "Use photo"
    if panel.runModal() == .OK { pendingPhotoURL = panel.url }
  }

  private func permissionLabel(_ mode: AgentPermissionMode) -> String {
    switch mode {
    case .readOnly: "Read only"
    case .workspaceWrite: "Workspace write"
    case .unrestricted: "Unrestricted"
    }
  }

  private func hire() {
    saving = true
    errorMessage = nil
    if let editing {
      do {
        let profile = try services.updateBot(
          BotEditRequest(
            profileID: editing.id,
            name: name,
            responsibility: jobTitle,
            instructions: instructions,
            provider: provider,
            accountID: accountID,
            model: model.isEmpty ? nil : model,
            effort: effort.isEmpty ? nil : effort,
            permissionMode: permissionMode.rawValue,
            avatarRef: icon,
            shape: shape,
            colorHex: colorHex,
            photoSourceURL: pendingPhotoURL,
            existingPhotoPath: existingPhotoPath
          ))
        hired(profile)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        saving = false
      }
      return
    }
    Task {
      do {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let responsibility = jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructionsText = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = try services.createBot(
          BotCreationRequest(
            name: trimmedName,
            responsibility: responsibility,
            instructions: instructionsText.isEmpty ? nil : instructionsText,
            provider: provider,
            accountID: accountID,
            model: model.isEmpty ? nil : model,
            effort: effort.isEmpty ? nil : effort,
            permissionMode: permissionMode.rawValue,
            avatarRef: icon,
            shape: shape,
            colorHex: colorHex,
            photoSourceURL: pendingPhotoURL
          ))
        hired(profile)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        saving = false
      }
    }
  }
}

struct CreateTeamSheet: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var services: ApplicationServices
  /// When set, the sheet edits this team instead of creating one.
  let editing: BotChannel?
  let created: (BotChannel) -> Void

  @State private var selected: Set<UUID> = []
  @State private var name = ""
  @State private var instructions = ""
  @State private var orchestratorID: UUID?
  /// Teams run unattended by default; approving every step defeats the point of a team.
  @State private var permissionMode: AgentPermissionMode? = .unrestricted
  @State private var errorMessage: String?

  init(
    services: ApplicationServices,
    editing: BotChannel? = nil,
    created: @escaping (BotChannel) -> Void
  ) {
    self.services = services
    self.editing = editing
    self.created = created
    guard let channel = editing else { return }
    _selected = State(initialValue: Set(channel.memberProfileIDs))
    _name = State(initialValue: channel.name ?? "")
    _instructions = State(initialValue: channel.instructions ?? "")
    _orchestratorID = State(initialValue: channel.orchestratorProfileID)
    _permissionMode = State(
      initialValue: channel.permissionMode.flatMap(AgentPermissionMode.init(rawValue:)))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(editing == nil ? "CREATE A TEAM" : "EDIT TEAM")
          .font(.ottoMono(10, weight: .black))
          .tracking(2)
          .foregroundStyle(palette.signal)
        Text(
          editing == nil
            ? "Name the group, say how it works, and pick who leads. @mention members in the brief."
            : "Change the name, brief, members, lead and permissions."
        )
        .font(.ottoDisplay(16))
        .foregroundStyle(palette.paper)

        teamField("TEAM NAME", text: $name, placeholder: "Staff")
        VStack(alignment: .leading, spacing: 7) {
          Text("HOW THIS TEAM WORKS")
            .font(.ottoMono(8, weight: .black))
            .tracking(1.2)
            .foregroundStyle(palette.muted)
          TextEditor(text: $instructions)
            .font(.ottoMono(10.5))
            .scrollContentBackground(.hidden)
            .foregroundStyle(palette.paper)
            .padding(8)
            .frame(minHeight: 88)
            .background(palette.ink.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.paper.opacity(0.1)))
            .onChange(of: instructions) { _, next in adoptMentionedMembers(in: next) }
          if !instructionMentionSuggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 6) {
                ForEach(instructionMentionSuggestions, id: \.id) { profile in
                  Button {
                    insertInstructionMention(profile)
                  } label: {
                    Text("@\(profile.handle)")
                      .font(.ottoMono(8, weight: .bold))
                      .padding(.horizontal, 8)
                      .frame(height: 22)
                      .foregroundStyle(palette.ink)
                      .background(palette.signal, in: Capsule())
                  }
                  .buttonStyle(.plain)
                }
              }
            }
          }
          Text("Example: @Taz is the orchestrator. @Aria implements. Taz reviews before we ship.")
            .font(.ottoMono(8))
            .foregroundStyle(palette.muted)
        }

        Text("MEMBERS")
          .font(.ottoMono(8, weight: .black))
          .tracking(1.2)
          .foregroundStyle(palette.muted)
        ForEach(services.botRoster()) { entry in
          let on = selected.contains(entry.profile.id)
          Button {
            toggle(entry.profile.id)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? palette.signal : palette.muted)
              VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.profile.name)  @\(entry.profile.handle)")
                  .font(.ottoDisplay(14).weight(.semibold))
                  .foregroundStyle(palette.paper)
                Text(entry.profile.jobTitle ?? entry.profile.provider.rawValue)
                  .font(.ottoMono(8))
                  .foregroundStyle(palette.muted)
              }
              Spacer()
            }
            .padding(10)
            .background(
              on ? palette.raised : palette.ink.opacity(0.45),
              in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 8).stroke(palette.paper.opacity(on ? 0.16 : 0.08)))
          }
          .buttonStyle(.plain)
        }

        if selectedMembers.count >= 2 {
          VStack(alignment: .leading, spacing: 7) {
            Text("ORCHESTRATOR")
              .font(.ottoMono(8, weight: .black))
              .tracking(1.2)
              .foregroundStyle(palette.muted)
            Picker(
              "Orchestrator",
              selection: Binding(
                get: { orchestratorID ?? selectedMembers[0].id },
                set: { orchestratorID = $0 }
              )
            ) {
              ForEach(selectedMembers, id: \.id) { profile in
                Text("\(profile.name) (@\(profile.handle))").tag(profile.id)
              }
            }
            .labelsHidden()
            Text("This bot decides who acts and reviews work unless you @mention someone else.")
              .font(.ottoMono(8))
              .foregroundStyle(palette.muted)
          }
        }

        VStack(alignment: .leading, spacing: 7) {
          Text("PERMISSIONS")
            .font(.ottoMono(8, weight: .black))
            .tracking(1.2)
            .foregroundStyle(palette.muted)
          Picker("Permissions", selection: $permissionMode) {
            Text("Bypass permissions").tag(Optional(AgentPermissionMode.unrestricted))
            Text("Workspace write (asks for risky actions)")
              .tag(Optional(AgentPermissionMode.workspaceWrite))
            Text("Read only").tag(Optional(AgentPermissionMode.readOnly))
            Text("Each bot's own setting").tag(AgentPermissionMode?.none)
          }
          .labelsHidden()
          Text(
            permissionMode == .unrestricted
              ? "Team turns run without asking you to approve each step."
              : "Team turns may stop and wait for your approval."
          )
          .font(.ottoMono(8))
          .foregroundStyle(palette.muted)
        }

        if let errorMessage {
          Text(errorMessage).font(.ottoMono(8)).foregroundStyle(palette.red)
        }
        HStack {
          Button("Cancel") { dismiss() }
          Spacer()
          Button(editing == nil ? "Create team" : "Save changes") { create() }
            .disabled(selected.count < 2)
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(24)
    }
    .frame(width: 520, height: 640)
    .background(palette.surface)
  }

  private var selectedMembers: [AgentProfile] {
    services.botRoster().map(\.profile).filter { selected.contains($0.id) }
  }

  private var instructionMentionSuggestions: [AgentProfile] {
    guard let at = instructions.lastIndex(of: "@") else { return [] }
    let fragment = String(instructions[instructions.index(after: at)...])
    if fragment.contains(where: { $0.isWhitespace }) { return [] }
    let needle = fragment.lowercased()
    return services.agentProfiles.activeProfiles.filter { profile in
      needle.isEmpty
        || profile.handle.hasPrefix(needle)
        || profile.name.lowercased().hasPrefix(needle)
    }.prefix(6).map { $0 }
  }

  private func insertInstructionMention(_ profile: AgentProfile) {
    if let at = instructions.lastIndex(of: "@") {
      instructions = String(instructions[..<at]) + "@\(profile.handle) "
    } else {
      instructions += "@\(profile.handle) "
    }
    adoptMentionedMembers(in: instructions)
  }

  private func teamField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(label)
        .font(.ottoMono(8, weight: .black))
        .tracking(1.2)
        .foregroundStyle(palette.muted)
      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.ottoDisplay(14))
        .foregroundStyle(palette.paper)
        .padding(10)
        .background(palette.ink.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.paper.opacity(0.1)))
    }
  }

  private func toggle(_ id: UUID) {
    if selected.contains(id) {
      selected.remove(id)
      if orchestratorID == id { orchestratorID = selected.first }
    } else {
      selected.insert(id)
      if orchestratorID == nil { orchestratorID = id }
    }
  }

  private func adoptMentionedMembers(in text: String) {
    let profiles = services.agentProfiles.activeProfiles
    for token in BotMentionResolver.mentions(in: text) {
      if case .matched(let profile) = BotMentionResolver.resolve(token, in: profiles) {
        selected.insert(profile.id)
        if orchestratorID == nil { orchestratorID = profile.id }
      }
    }
    inferOrchestrator(from: text)
  }

  private func inferOrchestrator(from text: String) {
    let lowered = text.lowercased()
    guard lowered.contains("orchestrator") || lowered.contains("chief of staff") else { return }
    let profiles = services.agentProfiles.activeProfiles
    for token in BotMentionResolver.mentions(in: text) {
      if case .matched(let profile) = BotMentionResolver.resolve(token, in: profiles) {
        let handle = "@\(profile.handle)".lowercased()
        if let range = lowered.range(of: handle) {
          let window = lowered[range.lowerBound...].prefix(64)
          if window.contains("orchestrator") || window.contains("chief of staff") {
            orchestratorID = profile.id
            return
          }
        }
      }
    }
  }

  private func create() {
    do {
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedBrief = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
      let channel: BotChannel
      if let editing {
        channel = try services.updateTeam(
          channelID: editing.id,
          name: trimmedName,
          instructions: trimmedBrief,
          memberProfileIDs: Array(selected),
          orchestratorProfileID: orchestratorID,
          permissionMode: permissionMode
        )
      } else {
        channel = try services.createTeam(
          memberProfileIDs: Array(selected),
          name: trimmedName.isEmpty ? nil : trimmedName,
          instructions: trimmedBrief.isEmpty ? nil : trimmedBrief,
          orchestratorProfileID: orchestratorID,
          permissionMode: permissionMode
        )
      }
      created(channel)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct WorkspaceTreeEntry: Identifiable {
  let url: URL
  let root: URL
  let isDirectory: Bool

  var id: String { url.path }
  var name: String { url.lastPathComponent }
  var relativePath: String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return path }
    return String(path.dropFirst(rootPath.count + 1))
  }
}

private struct WorkspaceFileTree: View {
  let rootPath: String
  @Binding var selectedPath: String?
  let palette: OttoPalette
  @State private var query = ""

  private var rootURL: URL {
    URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text(rootPath)
          .font(.ottoMono(7, weight: .bold))
          .foregroundStyle(palette.muted)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(rootPath)
        TextField("Filter files…", text: $query)
          .textFieldStyle(.roundedBorder)
          .font(.ottoDisplay(12))
      }
      .padding(10)
      Divider().overlay(palette.paper.opacity(0.08))
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1) {
          ForEach(filteredEntries(in: rootURL)) { entry in
            WorkspaceTreeRow(
              entry: entry,
              query: query,
              selectedPath: $selectedPath,
              palette: palette
            )
          }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(palette.raised.opacity(0.28))
  }

  private func filteredEntries(in directory: URL) -> [WorkspaceTreeEntry] {
    workspaceEntries(in: directory, root: rootURL).filter {
      query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
    }
  }
}

private struct WorkspaceTreeRow: View {
  let entry: WorkspaceTreeEntry
  let query: String
  @Binding var selectedPath: String?
  let palette: OttoPalette
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Button {
        if entry.isDirectory {
          withAnimation(OttoMotion.moderate.enter) { expanded.toggle() }
        } else {
          selectedPath = entry.relativePath
        }
      } label: {
        HStack(spacing: 6) {
          if entry.isDirectory {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 8, weight: .semibold))
              .frame(width: 9)
          } else {
            Color.clear.frame(width: 9, height: 1)
          }
          Image(systemName: entry.isDirectory ? "folder" : fileSymbol)
            .font(.system(size: 10, weight: .regular))
            .frame(width: 13)
            .foregroundStyle(entry.isDirectory ? palette.muted : fileColor)
          Text(entry.name)
            .font(.ottoDisplay(12))
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .foregroundStyle(selectedPath == entry.relativePath ? palette.ink : palette.paper)
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(
          selectedPath == entry.relativePath ? palette.paper.opacity(0.88) : Color.clear,
          in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if entry.isDirectory, expanded {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(filteredChildren) { child in
            WorkspaceTreeRow(
              entry: child,
              query: query,
              selectedPath: $selectedPath,
              palette: palette
            )
          }
        }
        .padding(.leading, 14)
      }
    }
  }

  private var filteredChildren: [WorkspaceTreeEntry] {
    workspaceEntries(in: entry.url, root: entry.root).filter {
      query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
    }
  }

  private var fileSymbol: String {
    switch entry.url.pathExtension.lowercased() {
    case "swift": "swift"
    case "md", "markdown": "doc.text"
    case "json", "js", "ts", "tsx", "jsx", "css", "html", "yml", "yaml":
      "chevron.left.forwardslash.chevron.right"
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": "photo"
    default: "doc"
    }
  }

  private var fileColor: Color {
    switch entry.url.pathExtension.lowercased() {
    case "swift": palette.amber
    case "md", "markdown": palette.cyan
    case "json", "js", "ts", "tsx", "jsx": palette.signal
    default: palette.muted
    }
  }
}

private func workspaceEntries(in directory: URL, root: URL) -> [WorkspaceTreeEntry] {
  let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
  let urls =
    (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: keys,
      options: []
    )) ?? []
  return urls.compactMap { url in
    let values = try? url.resourceValues(forKeys: Set(keys))
    return WorkspaceTreeEntry(
      url: url,
      root: root,
      isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true
    )
  }
  .sorted {
    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
  }
}

private struct WorkFileEditor: View {
  let path: String
  let palette: OttoPalette
  @State private var text = ""
  @State private var loadedPath: String?
  @State private var editing = false
  private var isMarkdown: Bool {
    ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
  }
  @State private var dirty = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text((path as NSString).lastPathComponent)
          .font(.ottoMono(8, weight: .bold))
        Spacer()
        if isMarkdown {
          Button(editing ? "Preview" : "Edit") { editing.toggle() }
            .font(.ottoMono(8, weight: .bold))
        }
        if dirty {
          Button("Save") { save() }
            .font(.ottoMono(8, weight: .bold))
        }
      }
      .foregroundStyle(palette.paper)
      .padding(.horizontal, 12)
      .frame(height: 28)
      if let errorMessage {
        Text(errorMessage).font(.ottoMono(7)).foregroundStyle(palette.red).padding(.horizontal, 12)
      }
      if isMarkdown && !editing {
        ScrollView {
          MarkdownMessageView(
            text: text, scale: 1, palette: palette,
            assetDirectory: URL(fileURLWithPath: path).deletingLastPathComponent()
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
        }
      } else {
        TextEditor(text: $text)
          .font(.ottoMono(10.5))
          .scrollContentBackground(.hidden)
          .foregroundStyle(palette.paper)
          .padding(8)
          .onChange(of: text) { _, _ in
            if loadedPath == path { dirty = true }
          }
      }
    }
    .onAppear(perform: load)
    .onChange(of: path) { _, _ in load() }
  }

  private func load() {
    do {
      text = try String(contentsOfFile: path, encoding: .utf8)
      loadedPath = path
      dirty = false
      errorMessage = nil
    } catch {
      text = ""
      loadedPath = path
      dirty = false
      errorMessage = "Could not read this file as text."
    }
  }

  private func save() {
    do {
      try text.write(toFile: path, atomically: true, encoding: .utf8)
      dirty = false
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

extension Color {
  init?(hex: String?) {
    guard let hex else { return nil }
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let raw = UInt64(value, radix: 16) else { return nil }
    self.init(
      red: Double((raw >> 16) & 0xFF) / 255,
      green: Double((raw >> 8) & 0xFF) / 255,
      blue: Double(raw & 0xFF) / 255
    )
  }

  static func isDarkHex(_ hex: String?) -> Bool {
    guard let hex else { return false }
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let raw = UInt64(value, radix: 16) else { return false }
    let r = Double((raw >> 16) & 0xFF) / 255
    let g = Double((raw >> 8) & 0xFF) / 255
    let b = Double(raw & 0xFF) / 255
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.35
  }
}

private struct CreateConversationProjectSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var folders: [String] = []
  @State private var errorMessage: String?
  let create: (String, [String]) throws -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("Create project").font(.title2.weight(.semibold))
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain).accessibilityLabel("Cancel project creation")
      }
      TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
      VStack(alignment: .leading, spacing: 10) {
        Text("Source folders (optional)").font(.headline)
        Text(
          "Add folders on this computer, or create a project without them. Your files stay where they are."
        )
        .font(.caption).foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(folders, id: \.self) { path in
              HStack {
                Image(systemName: "folder")
                Text(path).font(.caption).lineLimit(2).truncationMode(.middle).help(path)
                Spacer()
                Button {
                  folders.removeAll { $0 == path }
                } label: {
                  Image(systemName: "minus.circle")
                }.buttonStyle(.plain).accessibilityLabel("Remove folder \(path)")
              }
            }
            Button {
              addFolders()
            } label: {
              Label("Add folders…", systemImage: "folder.badge.plus")
            }
          }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 130)
          .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
      }
      if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Create project") {
          do {
            try create(name, folders)
            dismiss()
          } catch { errorMessage = error.localizedDescription }
        }.keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 480)
  }

  private func addFolders() {
    let panel = NSOpenPanel()
    panel.title = "Add source folders"
    panel.prompt = "Add folders"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      let path = url.standardizedFileURL.resolvingSymlinksInPath().path
      if !folders.contains(path) { folders.append(path) }
    }
  }
}

/// The rename dialog for a one-off session. A modifier rather than an inline `.alert` so the
/// chat workspace's body stays cheap for the type checker.
private struct SessionRenameAlert: ViewModifier {
  @Binding var isPresented: Bool
  @Binding var name: String
  let cancel: () -> Void
  let save: () -> Void

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func body(content: Content) -> some View {
    content.alert("Rename session", isPresented: $isPresented) {
      TextField("Business or project name", text: $name)
        .accessibilityIdentifier("session-rename-name")
      Button("Cancel", role: .cancel, action: cancel)
      Button("Rename", action: save)
        .disabled(trimmedName.isEmpty)
    } message: {
      Text("Name this conversation without changing the bot or its history.")
    }
  }
}

/// Asks for a vendor key or local server before a New session on Otto's harness, then starts it.
/// A separate modifier, because an inline sheet plus alert made Xcode 26.3 give up type-checking
/// `ChatWorkspaceView.body` in CI.
private struct HarnessKeySetupPresentation: ViewModifier {
  @Binding var request: HarnessKeySetupRequest?
  let services: ApplicationServices
  let palette: OttoPalette
  let launch: (HarnessKeySetupRequest) -> Void

  func body(content: Content) -> some View {
    content.sheet(item: $request) { pending in
      OttoHarnessKeySetupSheet(
        services: services,
        cancel: { request = nil },
        ready: {
          request = nil
          launch(pending)
        }
      )
      .environment(\.ottoPalette, palette)
    }
  }
}

/// Says why a one-off session could not start.
private struct SessionLaunchErrorAlert: ViewModifier {
  @Binding var message: String?

  func body(content: Content) -> some View {
    content.alert(
      "Couldn't start the session",
      isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    ) {
      Button("OK", role: .cancel) { message = nil }
    } message: {
      Text(message ?? "")
    }
  }
}

/// Asks before clearing a chat, since its messages cannot be brought back, then clears it.
private struct ClearChatConfirmation: ViewModifier {
  @Binding var target: ChatWorkspaceView.ClearChatTarget?
  let services: ApplicationServices
  @State private var failure: String?

  func body(content: Content) -> some View {
    content
      .alert(
        target.map { "Clear the chat with \($0.name)?" } ?? "Clear chat?",
        isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
        presenting: target
      ) { target in
        Button("Clear Chat", role: .destructive) {
          self.target = nil
          Task {
            do {
              try await services.clearChat(nodeID: target.id)
            } catch {
              failure = error.localizedDescription
            }
          }
        }
        Button("Cancel", role: .cancel) { self.target = nil }
      } message: { target in
        Text(
          "All messages in this chat are deleted and the next message starts a new conversation. "
            + (target.isBot
              ? "\(target.name) won't remember this conversation, but anything saved to its memory or notes stays, along with files and settings. "
              : "Files and settings stay. ")
            + "You won't be able to revert the agent's last file changes from this chat. "
            + "If it's working, it stops first. This can't be undone.")
      }
      .alert(
        "Couldn't clear the chat",
        isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
      ) {
        Button("OK", role: .cancel) { failure = nil }
      } message: {
        Text(failure ?? "")
      }
  }
}
