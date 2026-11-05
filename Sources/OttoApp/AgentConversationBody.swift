import AppKit
import OttoModels
import OttoRuntime
import OttoServices
import OttoWorktrees
import SwiftUI
import UniformTypeIdentifiers

/// Another agent node a message can be handed off to as a fresh prompt.
struct AgentHandoffTarget: Identifiable {
  let id: UUID
  let name: String
}

/// A readable conversation surface over the supervised PTY. The provider process and complete
/// terminal scrollback remain untouched; this view projects prompts and structured results into a
/// calm chat layout and keeps the raw terminal one click away.
// CHAT_LAYOUT_BOUNDARY_BEGIN
struct AgentConversationBody: View {
  @EnvironmentObject private var messageQueue: AgentMessageQueue
  @Environment(\.ottoPalette) private var palette
  @Environment(\.providerAccounts) private var providerAccountContext
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.ottoMotion) private var motion
  let node: OttoNode
  let snapshot: AgentRuntimeSnapshot?
  /// File changes of the most recent completed turn, diffed between hidden-ref checkpoints.
  let turnChanges: TurnChangeSummary?
  /// Unified diff for the completed turn, optionally scoped to one file.
  let turnDiff: (String?) async -> String?
  /// Safely restores the baseline checkpoint when no later workspace edits would be lost.
  let revertTurn: () async throws -> Void
  let history: [AgentRunRecord]
  let scale: Double
  let isSelected: Bool
  let presentation: NodePresentationMode
  let isStageMode: Bool
  /// The Chat surface keeps Chat / Terminal / Files on the work panel, not as a second toolbar.
  var hidesSurfaceBar: Bool = false
  var responseInspectorAllowed: Bool = true
  var onInspectResponse: () -> Void = {}
  /// Chat owns link destinations in its trailing work panel; canvas keeps its native inspector.
  var onOpenLink: ((URL) -> OpenURLAction.Result)? = nil
  /// Otto's own workspace. Image attachments for providers that may run in a project's source
  /// folder are staged here instead, so Otto never writes into the user's repository.
  var ottoWorkspacePath: String? = nil
  /// Promotes this node into the canvas' full-width stage before showing an artifact inspector.
  let enterStage: () -> Void
  /// Selects the owning canvas node. Child buttons consume the card's outer tap gesture, so
  /// surface navigation must focus explicitly before it changes the visible surface.
  let focus: () -> Void
  let setPresentation: (NodePresentationMode) -> Void
  let send: (String, Bool) -> Void
  let sendBytes: (Data) -> Void
  let resize: (UInt16, UInt16) -> Void
  let interrupt: () -> Void
  let stop: () -> Void
  let restart: () -> Void
  let resolvePermission: (Bool) -> Void
  let alwaysAllowPermission: () -> Void
  let resolveChoice: (String) -> Void
  let setPermissionMode: (AgentPermissionMode) -> Void
  /// Persists a model id and effort onto the node's launch configuration; nil returns to the
  /// provider default. Applies from the next run, since every chat message launches fresh.
  let setModel: (String?, String?) -> Void
  /// Persists whether future runs stay direct, use native subagents, or use Claude workflows.
  let setExecutionStrategy: (AgentExecutionStrategy) -> Void
  /// Other agent nodes on the canvas, evaluated lazily when the handoff menu opens so the list
  /// is always current without participating in card equality.
  let handoffTargets: () -> [AgentHandoffTarget]
  let handoff: (UUID, String) -> Void
  let openBrowser: (String) -> Void
  /// Bots the composer can @mention. Empty hides suggestions.
  var mentionProfiles: [AgentProfile] = []
  /// Each mentionable bot's look, so the welcome's crew row shows its real face and colour.
  var mentionAppearance: (UUID) -> BotAppearance? = { _ in nil }
  /// Terminals this conversation started that are waiting on the person.
  var waitingTerminals: [ChatTerminalNotice] = []
  var openTerminal: (UUID) -> Void = { _ in }
  /// Speech from the voice button that was not a command, added to the composer to review.
  var voiceInsertion: ChatVoiceInsertion? = nil
  /// Called once an insertion has been handled, so a later re-selection cannot paste it again.
  var consumeVoiceInsertion: (UUID) -> Void = { _ in }

  @State private var input = ""
  @State private var selectedRunID: UUID?
  @State private var expandedReasoning: Set<UUID> = []
  @State private var collapsedThinkingGroups: Set<UUID> = []
  @State private var hoveredMessageID: UUID?
  @State private var workingStepsExpanded = true
  @State private var selectedFile: String?
  @State private var inspectedResponse: AgentTranscriptEntry?
  @State private var exploredResponse: AgentTranscriptEntry?
  @State private var artifactPath: String?
  @State private var showingBootstrap = false
  @State private var pendingImages: [PendingChatImage] = []
  @State private var pendingPastes: [ChatPastedText] = []
  @State private var expandedPasteIDs: Set<String> = []
  @State private var attachmentError: String?
  @State private var showsAllChangedFiles = false
  @State private var showingTurnReview = false
  @State private var replyBridgeDeadline: Date?
  @State private var workingStart: Date?
  @State private var visibleTranscriptLimit = ConversationRenderPolicy.initialRowLimit
  @State private var showingModelPicker = false
  @State private var requestedLiveSession = false
  @State private var toastNotice: OttoToastNotice?
  @State private var showingRevertConfirmation = false
  @State private var showingChildRuns = false
  @State private var composerFocusTask: Task<Void, Never>?
  @State private var selectedMentionIndex = 0
  @State private var welcomePointer: CGPoint?
  @State private var welcomeBlinking = false
  @Namespace private var surfaceSelection
  @FocusState private var composerFocused: Bool

  typealias PendingChatImage = ChatImageAttachment

  private var conversationLayout: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        if !hidesSurfaceBar {
          surfaceBar
        }
        Group {
          switch presentation {
          case .conversation:
            if showsWelcome { welcomeSurface } else { conversationSurface }
          case .terminal: terminalSurface
          case .files: filesSurface
          case .compact, .hidden: EmptyView()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The terminal surface IS the input — the live TUI takes keystrokes directly, so a chat
        // composer underneath would just be a second, dead text box.
        if presentation != .terminal, !(presentation == .conversation && showsWelcome) {
          composer()
        }
      }

      if isStageMode, inspectedResponse == nil, showsArtifactInspector {
        Divider().overlay(palette.paper.opacity(0.08))
        artifactInspector
          .frame(minWidth: 360 * scale, idealWidth: 560 * scale, maxWidth: .infinity)
          .transition(
            reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
          )
      }
    }
    .background(palette.workspaceSurface)
  }

  // Split out of `body` so every Swift toolchain can type-check the view in reasonable time.
  private var conversationWithInspector: some View {
    conversationLayout
      .overlay(alignment: .trailing) {
        if inspectedResponse != nil, isStageMode || hidesSurfaceBar {
          artifactInspector
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(maxWidth: 420 * scale)
            .background(palette.raised)
            .overlay(alignment: .leading) { Divider() }
            .shadow(color: .black.opacity(0.08), radius: 16, x: -6)
        }
      }
      .sheet(isPresented: inspectorSheetPresented) { inspectorSheet }
  }

  private var inspectorSheetPresented: Binding<Bool> {
    Binding(
      get: {
        exploredResponse != nil
          || (inspectedResponse != nil && !isStageMode && !hidesSurfaceBar)
      },
      set: {
        if !$0 {
          exploredResponse = nil
          closeArtifactInspector()
        }
      }
    )
  }

  @ViewBuilder private var inspectorSheet: some View {
    Group {
      if let entry = exploredResponse {
        VStack(spacing: 0) {
          HStack {
            Text("Visual explanation").font(.ottoDisplay(15).weight(.semibold))
            Spacer()
            Button("Done") { exploredResponse = nil }.keyboardShortcut(.cancelAction)
          }.padding(20)
          Divider()
          ScrollView {
            MarkdownMessageView(
              text: entry.text, scale: 1.2, palette: palette,
              assetDirectory: URL(fileURLWithPath: resolvedFilePath(".")),
              presentedBlocks: AssistantResponsePresentation(entry.text).preview,
              resultScope: entry.id.uuidString
            ).padding(24)
          }
        }
      } else {
        artifactInspector
      }
    }
    .frame(minWidth: 760, idealWidth: 1000, minHeight: 560, idealHeight: 720)
    .background(palette.workspaceSurface)
    .environment(\.ottoPalette, palette)
  }

  var body: some View {
    conversationWithDrafts
      // Wake up when the bridge expires; reply arrival itself re-renders via the transcript.
      .task(id: replyBridgeDeadline) {
        guard let deadline = replyBridgeDeadline else { return }
        try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 0.1))
        replyBridgeDeadline = nil
      }
  }

  // The modifier chain is split across several properties so every Swift toolchain (including the
  // Xcode 26 one used by CI) can type-check it in reasonable time.
  private var conversationWithLinks: some View {
    conversationWithInspector
      .ottoToast(
        $toastNotice,
        scale: scale,
        bottomPadding: presentation == .terminal ? 14 : 76
      )
      // Web links open as browser nodes. Workspace files stay inside this agent and slide into an
      // artifact inspector, matching the native Codex review/document interaction.
      .environment(
        \.openURL,
        OpenURLAction { url in
          handleLink(url)
        }
      )
  }

  private var conversationWithFocus: some View {
    conversationWithLinks
      // A spawned or clicked agent should be ready to type into immediately — no extra click on
      // the composer. Focus follows card selection, and re-arms once the runtime accepts input.
      .onAppear { focusComposerIfPrimary() }
      .onChange(of: isSelected) { _, _ in focusComposerIfPrimary() }
      .onChange(of: responseInspectorAllowed) { _, allowed in
        if !allowed, inspectedResponse != nil { closeArtifactInspector() }
      }
      .onChange(of: presentation) { _, _ in focusComposerIfPrimary() }
      .onChange(of: acceptsComposerInput) { _, _ in focusComposerIfPrimary() }
      // The TERMINAL surface hosts the provider's real TUI without a click: launch on tab entry,
      // or as soon as an in-flight run completes while the tab is showing.
      .onAppear { autoLaunchLiveSession() }
      .onChange(of: presentation) { _, value in
        if value != .terminal { requestedLiveSession = false }
        autoLaunchLiveSession()
      }
      .onChange(of: snapshot?.state) { _, _ in autoLaunchLiveSession() }
  }

  private var conversationWithRevert: some View {
    conversationWithFocus
      .confirmationDialog(
        "Revert the last turn?", isPresented: $showingRevertConfirmation,
        titleVisibility: .visible
      ) {
        Button("Revert Workspace Changes", role: .destructive) { performTurnRevert() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Otto will restore the exact pre-turn checkpoint. It will stop if later changes exist.")
      }
      .onChange(of: snapshot?.executionMode) { _, mode in
        if mode == .interactiveProvider { requestedLiveSession = false }
      }
      // When the runtime flips out of working before the reply is projected, arm the bridge so
      // the thinking indicator holds until the text lands (bounded, in case no text ever comes).
      .onChange(of: isWorking) { _, working in
        replyBridgeDeadline =
          !working && lastTurnAwaitsReply ? Date.now.addingTimeInterval(12) : nil
      }
  }

  private var conversationWithDrafts: some View {
    conversationWithRevert
      .onChange(of: transcript.count) { _, count in
        if count < visibleTranscriptLimit {
          visibleTranscriptLimit = max(ConversationRenderPolicy.initialRowLimit, count)
        }
      }
      .onDisappear {
        composerFocusTask?.cancel()
      }
      // Unsent text, screenshots and pastes stay with this chat when the person goes elsewhere
      // and comes back.
      .onChange(of: node.id, initial: true) { old, new in
        if old != new {
          ComposerDrafts.save(input, for: ComposerDrafts.agentKey(old))
          ComposerDrafts.saveAttachments(draftAttachments, for: ComposerDrafts.agentKey(old))
          input = ""
          pendingImages.removeAll()
          pendingPastes.removeAll()
        }
        if input.isEmpty { input = ComposerDrafts.text(for: ComposerDrafts.agentKey(new)) }
        if !hasPendingAttachments {
          let saved = ComposerDrafts.attachments(for: ComposerDrafts.agentKey(new))
          pendingImages = saved.imagePaths.map {
            PendingChatImage(path: $0, name: ($0 as NSString).lastPathComponent)
          }
          pendingPastes = saved.pastes.map(ChatPastedText.init)
        }
      }
      .onChange(of: input) { _, text in
        ComposerDrafts.save(text, for: ComposerDrafts.agentKey(node.id))
      }
      .onChange(of: voiceInsertion) { _, insertion in
        guard let insertion else { return }
        consumeVoiceInsertion(insertion.id)
        guard acceptsComposerInput else { return }
        input = input.isEmpty ? insertion.text : input + " " + insertion.text
        composerFocused = true
      }
      .onChange(of: draftAttachments) { _, attachments in
        ComposerDrafts.saveAttachments(attachments, for: ComposerDrafts.agentKey(node.id))
      }
  }

  private var showsArtifactInspector: Bool {
    inspectedResponse != nil || showingTurnReview || artifactPath != nil
  }

  @ViewBuilder private var artifactInspector: some View {
    if let entry = inspectedResponse {
      let response = AssistantResponsePresentation(entry.text)
      VStack(spacing: 0) {
        artifactHeader(title: "Full explanation")
        ScrollView {
          MarkdownMessageView(
            text: response.fullText, scale: max(1.15, scale), palette: palette,
            assetDirectory: URL(fileURLWithPath: resolvedFilePath(".")),
            presentedBlocks: response.supportingBlocks,
            resultScope: entry.id.uuidString
          )
          .padding(24 * scale)
        }
      }
    } else if showingTurnReview, let summary = turnChanges {
      TurnReviewSheet(
        summary: summary,
        turnDiff: turnDiff,
        initialPath: artifactPath,
        close: closeArtifactInspector
      )
    } else if let artifactPath {
      VStack(spacing: 0) {
        artifactHeader(title: (artifactPath as NSString).lastPathComponent)
        AgentFileViewer(
          path: resolvedFilePath(artifactPath),
          scale: scale,
          refreshKey: transcript.count
        )
      }
    }
  }

  private func artifactHeader(title: String) -> some View {
    HStack(spacing: 10 * scale) {
      Image(systemName: "doc.text")
        .foregroundStyle(palette.signal)
      Text(title)
        .font(.ottoLabel(max(7.5, 9 * scale), weight: .bold))
        .foregroundStyle(palette.paper)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Button(action: closeArtifactInspector) {
        Image(systemName: "xmark")
          .font(.system(size: max(7, 8 * scale), weight: .bold))
          .frame(width: 24 * scale, height: 24 * scale)
      }
      .buttonStyle(.plain)
      .foregroundStyle(palette.muted)
      .accessibilityLabel(inspectedResponse == nil ? "Close file preview" : "Close response")
    }
    .padding(.horizontal, 12 * scale)
    .frame(height: 42 * scale)
    .background(palette.raised)
  }

  private func closeArtifactInspector() {
    inspectedResponse = nil
    showingTurnReview = false
    artifactPath = nil
  }

  private func openArtifact(path: String, review: Bool = false) {
    let decoded = path.removingPercentEncoding ?? path
    let withoutFragment =
      decoded.split(separator: "#", maxSplits: 1).first.map(String.init) ?? decoded
    let reference = ArtifactReference.parse(withoutFragment)
    guard !reference.path.isEmpty else { return }
    inspectedResponse = nil
    artifactPath = reference.path
    showingTurnReview = review
    if !isStageMode { enterStage() }
  }

  private func handleLink(_ url: URL) -> OpenURLAction.Result {
    if let onOpenLink { return onOpenLink(url) }
    if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
      openBrowser(url.absoluteString)
      return .handled
    }
    if url.isFileURL {
      openArtifact(path: url.path)
      return .handled
    }
    if url.scheme != nil { return .systemAction }
    openArtifact(path: url.relativeString)
    return .handled
  }

  private func focusComposerIfPrimary() {
    composerFocusTask?.cancel()
    // Working agents still accept typed Otto commands. Selecting one must focus the composer just
    // like selecting an idle agent; otherwise the window remains first responder and keystrokes
    // disappear even though the field is visibly enabled.
    guard isSelected, presentation == .conversation, acceptsComposerInput else { return }
    // A newly launched agent can appear while its launch sheet is still resigning key-window
    // status. The first FocusState assignment is then remembered by SwiftUI without making the
    // field editor first responder, so typing still goes nowhere. Re-arm focus just after the
    // dismissal transition; cancelling above prevents a stale agent from stealing it if the user
    // selects another card in the meantime.
    composerFocused = true
    composerFocusTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      composerFocused = false
      await Task.yield()
      guard !Task.isCancelled else { return }
      composerFocused = true
    }
  }

  private var surfaceBar: some View {
    HStack(spacing: 5 * scale) {
      OttoFluidHover(
        axis: .horizontal,
        style: OttoFluidHoverStyle(fill: palette.paper.opacity(0.07), cornerRadius: 11 * scale)
      ) {
        HStack(spacing: 5 * scale) {
          surfaceButton(.conversation, title: "CHAT", symbol: "text.bubble")
          surfaceButton(.terminal, title: "TERMINAL", symbol: "terminal")
          surfaceButton(.files, title: "FILES", symbol: "folder")
        }
      }
      Spacer()
      if snapshot?.bootstrapHash != nil {
        Button {
          showingBootstrap = true
        } label: {
          Image(systemName: "brain")
            .font(.system(size: max(7, 8 * scale), weight: .medium))
            .foregroundStyle(palette.muted)
        }
        .buttonStyle(.plain)
        .help("Inspect the memory bootstrap this run received")
        .accessibilityLabel("Inspect memory bootstrap")
        .popover(isPresented: $showingBootstrap) { bootstrapInspector }
      }
      if let childRuns = snapshot?.childRuns, !childRuns.isEmpty {
        Button {
          showingChildRuns.toggle()
        } label: {
          Label("\(childRuns.count)", systemImage: "point.3.connected.trianglepath.dotted")
            .font(.ottoLabel(max(6, 7 * scale), weight: .bold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.muted)
        .help("Inspect native subagents")
        .popover(isPresented: $showingChildRuns) { childRunInspector(childRuns) }
      }
      if presentation == .terminal, !history.isEmpty {
        Menu {
          Button("Live session") { selectedRunID = nil }
          Divider()
          ForEach(history.reversed()) { run in
            Button(runLabel(run)) { selectedRunID = run.id }
          }
        } label: {
          Label("\(history.count)", systemImage: "clock.arrow.circlepath")
            .font(.ottoLabel(max(6, 7 * scale), weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(palette.muted)
        .help("Review earlier terminal runs")
      }
      HStack(spacing: 5 * scale) {
        Image(systemName: statusSymbol)
          .font(.system(size: max(5, 6 * scale), weight: .bold))
          .frame(width: 7 * scale, height: 7 * scale)
          .id(statusSymbol)
          .transition(.scale(scale: 0.72).combined(with: .opacity))
        ZStack(alignment: .leading) {
          Text(statusLabel)
            .font(.ottoLabel(max(5.5, 6.5 * scale), weight: .black))
            .id(statusLabel)
            .transition(reduceMotion ? .opacity : .ottoStatusSwap)
        }
      }
      .foregroundStyle(statusColor)
      .animation(motion.enter(.moderate), value: statusLabel)
    }
    .padding(.horizontal, 10 * scale)
    .frame(height: 30 * scale)
    .background(palette.raised.opacity(0.78))
    .overlay(alignment: .bottom) { Divider().overlay(palette.paper.opacity(0.08)) }
  }

  private func surfaceButton(
    _ target: NodePresentationMode, title: String, symbol: String
  ) -> some View {
    Button {
      focus()
      withAnimation(motion.enter(.moderate)) {
        setPresentation(target)
      }
    } label: {
      Label(title, systemImage: symbol)
        .font(.ottoLabel(max(5.5, 6.5 * scale), weight: .black))
        .padding(.horizontal, 8 * scale)
        .frame(height: 21 * scale)
        .foregroundStyle(target == presentation ? palette.ink : palette.muted)
        .animation(motion.tint, value: target == presentation)
        .background {
          if target == presentation {
            Capsule()
              .fill(palette.paper.opacity(0.88))
              .matchedGeometryEffect(id: "agent-surface-selection", in: surfaceSelection)
          }
        }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .ottoHoverItem(target)
    .accessibilityLabel("Show \(title.lowercased())")
  }

  private var conversationSurface: some View {
    // Grouping walks the whole transcript, so do it once per render rather than per use.
    let rows = transcriptRows
    let range = ConversationRenderPolicy.visibleRange(
      totalCount: rows.count, limit: visibleTranscriptLimit)
    let hiddenRowCount = max(0, rows.count - visibleTranscriptLimit)
    return ScrollViewReader { proxy in
      ScrollView {
        // Keep transcript rows mounted. LazyVStack can temporarily evict every visible row when
        // a rapidly changing agent snapshot and an automatic scroll land in the same layout pass;
        // nudging the scroll position makes them reappear, which is especially disruptive during
        // long-running turns. Conversation cards already have bounded projected transcripts, so
        // stable rendering is worth the modest eager-layout cost here.
        VStack(alignment: .leading, spacing: 18 * scale) {
          if transcript.isEmpty {
            emptyConversation
          } else {
            if hiddenRowCount > 0 {
              Button {
                visibleTranscriptLimit = ConversationRenderPolicy.expandedLimit(
                  current: visibleTranscriptLimit,
                  totalCount: rows.count
                )
              } label: {
                Label(
                  "Show \(min(ConversationRenderPolicy.rowPageSize, hiddenRowCount)) earlier items",
                  systemImage: "clock.arrow.circlepath"
                )
                .font(.ottoLabel(max(6.5, 7.5 * scale), weight: .semibold))
                .foregroundStyle(palette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6 * scale)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Show earlier conversation items")
            }
            ForEach(rows[range]) { row in
              StableTranscriptRow(
                entry: row.entry,
                groupedEntries: row.thinkingEntries,
                showsProviderHeader: row.showsProviderHeader,
                isExpanded: row.thinkingEntries.isEmpty
                  ? expandedReasoning.contains(row.id)
                  : !collapsedThinkingGroups.contains(row.id),
                isStreaming: isWorking,
                isHovered: hoveredMessageID == row.id,
                provider: snapshot?.provider,
                scale: scale,
                palette: palette
              ) {
                transcriptRow(row)
              }
              .equatable()
              .id(row.id)
              .transition(chatMessageTransition(for: row))
            }
          }
          if selectedRunID == nil, let children = snapshot?.childRuns, !children.isEmpty {
            AgentChildrenPanel(children: children, parentName: "Agent").id("agent-children")
          }
          if selectedRunID == nil {
            ForEach(waitingTerminals) { notice in
              TerminalWaitingCard(notice: notice) { openTerminal(notice.id) }
                .id("terminal-waiting-\(notice.id.uuidString)")
            }
          }
          if showsWorkingRow {
            workingRow.id("agent-working")
          }
          if let turnChanges, !turnChanges.isEmpty, !showsWorkingRow {
            turnChangesCard(turnChanges).id("turn-changes")
          }
          if let choice = pendingChoice {
            attentionRow(choice.question).id("agent-attention")
          } else if let attention = snapshot?.attentionReason, !attention.isEmpty {
            attentionRow(attention).id("agent-attention")
          }
          Color.clear.frame(height: 1).id("conversation-end")
        }
        .padding(.horizontal, 18 * scale)
        .padding(.vertical, 20 * scale)
      }
      // The transcript no longer hides that there is more above: a quiet overlay thumb and an
      // edge fade say so without the grey system bar.
      .ottoScrollChrome(fade: 28)
      .background(
        LinearGradient(
          colors: [palette.conversationTop, palette.conversationBottom],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .onAppear { proxy.scrollTo("conversation-end", anchor: .bottom) }
      .onChange(of: transcript.last?.id) { _, _ in
        withAnimation(motion.enter(.slow)) {
          proxy.scrollTo("conversation-end", anchor: .bottom)
        }
      }
      .onChange(of: snapshot?.state) { _, _ in
        withAnimation(motion.enter(.slow)) {
          proxy.scrollTo("conversation-end", anchor: .bottom)
        }
      }
    }
  }

  /// A conversation whose transcript is still empty while a run starts shows nothing extra; the
  /// working row carries the state.
  @ViewBuilder private var emptyConversation: some View {
    Color.clear.frame(height: 1)
  }

  /// The blank chat ("Halo"): with no history and nothing running, the composer moves to the
  /// middle under a live Otto and a greeting, with suggestions and the bots that can be
  /// @mentioned. The first message turns it back into the normal transcript layout.
  private var showsWelcome: Bool {
    guard transcript.isEmpty, messageQueue.messages[node.id, default: []].isEmpty else {
      return false
    }
    switch snapshot?.state {
    case .working, .starting, .waitingPermission, .waitingUser: return false
    default: return !isAwaitingSignIn && !isAwaitingChoice
    }
  }

  private var welcomeSuggestions: [WelcomeSuggestion] {
    WelcomeSuggestion.forDirectory(node.agentDefinition?.workingDirectory)
  }

  private var welcomeSurface: some View {
    GeometryReader { proxy in
      let size = proxy.size
      ZStack {
        // A faint wash of light from the top; Otto's sparks stay the only colour on screen.
        LinearGradient(
          colors: [palette.paper.opacity(0.035), .clear],
          startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.58)
        )
        .allowsHitTesting(false)
        ViewThatFits(in: .vertical) {
          welcomeColumn(size: size, compact: false, zoom: welcomeZoom(for: size))
          welcomeColumn(size: size, compact: true, zoom: welcomeZoom(for: size))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .contentShape(Rectangle())
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case .active(let location): welcomePointer = location
        case .ended: welcomePointer = nil
        }
      }
    }
    .task(id: node.id) { await runWelcomeBlinks() }
  }

  /// The welcome is designed for a pane of roughly 820×640; larger panes enlarge it (up to
  /// 1.45×) so it never looks zoomed out on a big window. Smaller panes keep the base size and
  /// fall back to the compact layout instead.
  private func welcomeZoom(for size: CGSize) -> Double {
    let fit = min(size.width / (820 * scale), size.height / (640 * scale))
    return scale * min(1.45, max(1, fit))
  }

  private func welcomeColumn(size: CGSize, compact: Bool, zoom: Double) -> some View {
    let scale = zoom
    return VStack(spacing: 0) {
      if !compact {
        let face = 42 * scale
        // Otto looks toward the pointer; his centre sits a little above the composer.
        let center = CGPoint(x: size.width / 2, y: size.height * 0.5 - 120 * scale)
        OttoFace(
          size: face,
          look: welcomeLook(from: center),
          blinking: welcomeBlinking
        )
        .padding(.bottom, 14 * scale)
      }
      VStack(spacing: 5 * scale) {
        Text(WelcomeGreeting.text())
          .font(.ottoSerif(max(20, 27 * scale)))
          .tracking(-0.2)
          .foregroundStyle(palette.paper)
        Text("What are we getting into?")
          .font(.ottoDisplay(max(9, 11.5 * scale)))
          .foregroundStyle(palette.muted)
      }
      .multilineTextAlignment(.center)
      .padding(.bottom, 20 * scale)
      composer(centered: true, zoom: zoom)
        .frame(maxWidth: 480 * scale)
      if !compact {
        WelcomeChipFlow(spacing: 0) {
          ForEach(Array(welcomeSuggestions.enumerated()), id: \.element.id) { index, suggestion in
            WelcomeLink(label: suggestion.label, leadingDot: index > 0, scale: scale) {
              input = suggestion.seed
              composerFocused = true
            }
          }
        }
        .frame(maxWidth: 560 * scale)
        .padding(.top, 12 * scale)
        if !mentionProfiles.isEmpty {
          welcomeCrew(scale: scale).padding(.top, 34 * scale)
        }
      }
    }
    .padding(.horizontal, 24 * scale)
    .padding(.top, 16 * scale)
    // Sit just above centre, where the eye rests.
    .padding(.bottom, 56 * scale)
  }

  /// The bots this chat can @mention, as small faces; clicking one starts a mention.
  private func welcomeCrew(scale: Double) -> some View {
    HStack(spacing: 8 * scale) {
      Text("Bring in")
        .font(.ottoDisplay(max(8, 9.5 * scale)))
        .foregroundStyle(palette.muted.opacity(0.8))
      HStack(spacing: 4 * scale) {
        ForEach(mentionProfiles.prefix(6)) { profile in
          WelcomeCrewFace(
            profile: profile, appearance: mentionAppearance(profile.id), scale: scale
          ) {
            input = "@\(profile.handle) "
            composerFocused = true
          }
        }
      }
    }
  }

  private func welcomeLook(from center: CGPoint) -> CGSize {
    guard let pointer = welcomePointer else { return .zero }
    let dx = pointer.x - center.x
    let dy = pointer.y - center.y
    let distance = max(1, (dx * dx + dy * dy).squareRoot())
    let reach = min(1, distance / 240)
    return CGSize(width: dx / distance * reach, height: dy / distance * reach)
  }

  /// Otto blinks every few seconds; skipped under Reduce Motion.
  private func runWelcomeBlinks() async {
    guard !reduceMotion else { return }
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(Double.random(in: 3.5...6)))
      guard !Task.isCancelled else { return }
      welcomeBlinking = true
      try? await Task.sleep(for: .milliseconds(140))
      welcomeBlinking = false
    }
  }

  /// Summary of what the completed turn changed on disk — the reviewable receipt of the run.
  /// A compact header states the scale ("Edited 7 files · +259 −60"), the first few files show
  /// their per-file counts, and Review opens the full diff.
  @ViewBuilder
  private func turnChangesCard(_ summary: TurnChangeSummary) -> some View {
    let visibleFiles = showsAllChangedFiles ? summary.files : Array(summary.files.prefix(3))
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10 * scale) {
        Image(systemName: "plus.forwardslash.minus")
          .font(.system(size: max(9, 11 * scale), weight: .semibold))
          .foregroundStyle(palette.paper)
          .frame(width: 26 * scale, height: 26 * scale)
          .background(palette.ink.opacity(0.5), in: RoundedRectangle(cornerRadius: 7 * scale))
        VStack(alignment: .leading, spacing: 2 * scale) {
          Text("Edited \(summary.files.count) file\(summary.files.count == 1 ? "" : "s")")
            .font(.ottoLabel(max(7, 8 * scale), weight: .semibold))
            .foregroundStyle(palette.paper)
          changeCounts(
            additions: summary.totalAdditions, deletions: summary.totalDeletions)
        }
        Spacer(minLength: 8 * scale)
        Button {
          inspectedResponse = nil
          artifactPath = nil
          showingTurnReview = true
          if !isStageMode { enterStage() }
        } label: {
          Text("Review")
            .font(.ottoLabel(max(6.5, 7.5 * scale), weight: .black))
            .padding(.horizontal, 11 * scale)
            .frame(height: 22 * scale)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.paper)
        .overlay(Capsule().stroke(palette.paper.opacity(0.25), lineWidth: 1))
        .help("Open the full diff of this run")
        Button {
          showingRevertConfirmation = true
        } label: {
          Image(systemName: "arrow.uturn.backward")
            .font(.system(size: max(7, 8 * scale), weight: .bold))
            .frame(width: 22 * scale, height: 22 * scale)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.red)
        .help("Revert this turn's workspace changes")
        .accessibilityLabel("Revert this turn")
      }
      .padding(10 * scale)
      ForEach(visibleFiles) { file in
        Button {
          openArtifact(path: file.path, review: true)
        } label: {
          HStack(spacing: 8 * scale) {
            changedFileName(file.path)
            Spacer(minLength: 8 * scale)
            changeCounts(additions: file.additions ?? 0, deletions: file.deletions ?? 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 5 * scale)
        .overlay(alignment: .top) { Divider().opacity(0.35) }
      }
      if summary.files.count > 3 {
        Button {
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            showsAllChangedFiles.toggle()
          }
        } label: {
          Label(
            showsAllChangedFiles
              ? "Show fewer files" : "Show \(summary.files.count - 3) more files",
            systemImage: showsAllChangedFiles ? "chevron.up" : "chevron.down"
          )
          .font(.ottoLabel(max(6.5, 7.5 * scale), weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 7 * scale)
        .overlay(alignment: .top) { Divider().opacity(0.35) }
      }
    }
    .background(palette.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 10 * scale))
    .overlay(
      RoundedRectangle(cornerRadius: 10 * scale).stroke(palette.paper.opacity(0.08), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "Edited \(summary.files.count) files, \(summary.totalAdditions) additions, \(summary.totalDeletions) deletions"
    )
  }

  private func performTurnRevert() {
    Task {
      do {
        try await revertTurn()
        toastNotice = OttoToastNotice(message: "Last turn reverted")
      } catch {
        toastNotice = OttoToastNotice(message: error.localizedDescription)
      }
    }
  }

  private func childRunInspector(_ children: [AgentChildRun]) -> some View {
    ScrollView { AgentChildrenPanel(children: children, parentName: "Agent").padding(16) }
      .frame(width: 620, height: 480)
      .background(palette.surface)
  }

  private func changeCounts(additions: Int, deletions: Int) -> some View {
    HStack(spacing: 5 * scale) {
      Text("+\(additions)")
        .foregroundStyle(palette.signal)
      Text("−\(deletions)")
        .foregroundStyle(palette.red)
    }
    .font(.ottoLabel(max(6.5, 7.5 * scale), weight: .semibold))
  }

  /// Directory muted, filename bright — the filename is what the eye scans for.
  private func changedFileName(_ path: String) -> some View {
    let name = (path as NSString).lastPathComponent
    let directory = (path as NSString).deletingLastPathComponent
    return
      (Text(directory.isEmpty ? "" : directory + "/").foregroundStyle(palette.muted)
      + Text(name).foregroundStyle(palette.paper))
      .font(.ottoMono(max(6.5, 7.5 * scale)))
      .lineLimit(1)
      .truncationMode(.head)
  }

  private struct TranscriptRowModel: Identifiable {
    let entry: AgentTranscriptEntry
    let showsProviderHeader: Bool
    let thinkingEntries: [AgentTranscriptEntry]
    var id: UUID { entry.id }
  }

  /// SwiftUI may revisit the transcript container for status, focus, or composer changes. This
  /// boundary proves completed rows unchanged, so their markdown, images, and nested layout are
  /// not rebuilt unless that specific entry or its presentation inputs changed. The content is
  /// kept as a closure and only built in `body`: building it in `init` re-parsed every visible
  /// message's markdown on each composer keystroke, even when equality then skipped the row.
  private struct StableTranscriptRow<Content: View>: View, Equatable {
    let entry: AgentTranscriptEntry
    let groupedEntries: [AgentTranscriptEntry]
    let showsProviderHeader: Bool
    let isExpanded: Bool
    let isStreaming: Bool
    let isHovered: Bool
    let provider: AgentProvider?
    let scale: Double
    let palette: OttoPalette
    let content: () -> Content

    init(
      entry: AgentTranscriptEntry,
      groupedEntries: [AgentTranscriptEntry],
      showsProviderHeader: Bool,
      isExpanded: Bool,
      isStreaming: Bool,
      isHovered: Bool,
      provider: AgentProvider?,
      scale: Double,
      palette: OttoPalette,
      @ViewBuilder content: @escaping () -> Content
    ) {
      self.entry = entry
      self.groupedEntries = groupedEntries
      self.showsProviderHeader = showsProviderHeader
      self.isStreaming = isStreaming
      self.isExpanded = isExpanded
      self.isHovered = isHovered
      self.provider = provider
      self.scale = scale
      self.palette = palette
      self.content = content
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.entry == rhs.entry
        && lhs.groupedEntries == rhs.groupedEntries
        && lhs.showsProviderHeader == rhs.showsProviderHeader
        && lhs.isExpanded == rhs.isExpanded
        && lhs.isStreaming == rhs.isStreaming
        && lhs.isHovered == rhs.isHovered
        && lhs.provider == rhs.provider
        && lhs.scale == rhs.scale
        && lhs.palette == rhs.palette
    }

    // Selection lives on completed, equatable rows rather than the rapidly-changing live row.
    // This preserves native macOS drag/shift/keyboard selection across rendered message blocks
    // without bringing back the layout loop caused by selection overlays on streaming content.
    var body: some View {
      content().modifier(StableTranscriptSelectionModifier())
    }
  }

  /// The provider chip marks the start of each assistant turn rather than repeating on every
  /// message, so multi-step runs read as one continuous reply.
  private var transcriptRows: [TranscriptRowModel] {
    var rows: [TranscriptRowModel] = []
    var headerPending = true
    var index = transcript.startIndex
    while index < transcript.endIndex {
      let entry = transcript[index]
      if entry.role == .user {
        // Provider set-up text (AGENTS.md, environment blocks) and Otto context packets are
        // not something the person said; show only their own words, or nothing.
        let spoken = ChatWorkspaceView.humanRequest(entry.text)
        index += 1
        guard !spoken.isEmpty else { continue }
        var shown = entry
        shown.text = spoken
        headerPending = true
        rows.append(
          TranscriptRowModel(
            entry: shown, showsProviderHeader: false, thinkingEntries: []))
        continue
      }

      if entry.kind == .reasoning || entry.kind == .toolCall {
        var thinkingEntries: [AgentTranscriptEntry] = []
        var cursor = index
        while cursor < transcript.endIndex {
          let candidate = transcript[cursor]
          guard candidate.kind == .reasoning || candidate.kind == .toolCall else { break }
          thinkingEntries.append(candidate)
          cursor += 1
        }
        // The live ThinkingSteps block below owns the unfinished tail. Rendering the same tool
        // events here as a settled group would make every active step appear twice.
        if showsWorkingRow, cursor == transcript.endIndex {
          index = cursor
          continue
        }
        rows.append(
          TranscriptRowModel(
            entry: entry, showsProviderHeader: false, thinkingEntries: thinkingEntries))
        index = cursor
        continue
      }

      let showsHeader = headerPending && entry.role == .assistant && entry.kind == .text
      if showsHeader { headerPending = false }
      rows.append(
        TranscriptRowModel(
          entry: entry, showsProviderHeader: showsHeader, thinkingEntries: []))
      index += 1
    }
    return rows
  }

  private func chatMessageTransition(for row: TranscriptRowModel) -> AnyTransition {
    guard !reduceMotion else { return .opacity }
    let anchor: UnitPoint = row.entry.role == .user ? .bottomTrailing : .bottomLeading
    return .opacity.combined(with: .scale(scale: 0.96, anchor: anchor))
  }

  /// Pasted blocks render collapsed so a huge paste does not lay out thousands of lines in the
  /// transcript; expanding shows the text in a bounded scroll view.
  private func transcriptPaste(_ text: String, id: String) -> some View {
    let paste = ChatPastedText(text)
    let isExpanded = expandedPasteIDs.contains(id)
    return VStack(alignment: .leading, spacing: 6 * scale) {
      Button {
        if isExpanded { expandedPasteIDs.remove(id) } else { expandedPasteIDs.insert(id) }
      } label: {
        HStack(spacing: 5 * scale) {
          Image(systemName: "doc.plaintext")
          Text(paste.label)
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: max(5.5, 6.5 * scale), weight: .bold))
        }
        .font(.ottoLabel(max(6.5, 7.5 * scale)))
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 4 * scale)
        .background(palette.raised.opacity(0.8), in: Capsule())
      }
      .buttonStyle(.plain)
      .help(isExpanded ? "Collapse pasted text" : paste.preview)
      if isExpanded {
        ScrollView {
          Text(text)
            .font(.ottoMono(max(7, 8.5 * scale)))
            .foregroundStyle(palette.paper.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220 * scale)
      }
    }
  }

  @ViewBuilder
  private func transcriptRow(_ row: TranscriptRowModel) -> some View {
    let entry = row.entry
    if !row.thinkingEntries.isEmpty {
      completedThinkingSteps(row.thinkingEntries, id: row.id)
    } else {
      switch (entry.role, entry.kind) {
      case (.user, _):
        let prompt = ChatPromptContent(entry.text)
        HStack {
          Spacer(minLength: 40 * scale)
          VStack(alignment: .trailing, spacing: 6 * scale) {
            VStack(alignment: .leading, spacing: 7 * scale) {
              if !prompt.imagePaths.isEmpty {
                ScrollView(.horizontal) {
                  HStack(spacing: 7 * scale) {
                    ForEach(prompt.imagePaths, id: \.self) { path in
                      transcriptImage(path)
                    }
                  }
                }
                .scrollIndicators(.hidden)
              }
              if !prompt.text.isEmpty {
                Text(prompt.text)
                  .font(.ottoDisplay(max(9, 11.5 * scale)))
                  .foregroundStyle(palette.paper)
                  .lineSpacing(3 * scale)
              }
              ForEach(Array(prompt.pastes.enumerated()), id: \.offset) { index, paste in
                transcriptPaste(paste, id: "\(entry.id)-\(index)")
              }
            }
            .padding(.horizontal, 13 * scale)
            .padding(.vertical, 9 * scale)
            .background(
              palette.signal.opacity(0.14),
              in: RoundedRectangle(cornerRadius: 13 * scale, style: .continuous)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 13 * scale, style: .continuous)
                .stroke(palette.signal.opacity(0.12), lineWidth: 1)
            )

            HStack(spacing: 9 * scale) {
              Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
              Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                toastNotice = OttoToastNotice(message: "Prompt copied")
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.plain)
              .help("Copy prompt")
            }
            .frame(height: 12 * scale)
            .opacity(hoveredMessageID == entry.id ? 1 : 0)
            .allowsHitTesting(hoveredMessageID == entry.id)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hoveredMessageID)
            .textSelection(.disabled)
            .font(.ottoLabel(max(5.5, 6.5 * scale), weight: .medium))
            .foregroundStyle(palette.muted.opacity(0.72))
          }
          .frame(maxWidth: min(720, 680 * scale), alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering in
          hoveredMessageID =
            hovering ? entry.id : (hoveredMessageID == entry.id ? nil : hoveredMessageID)
        }

      case (.assistant, .reasoning):
        reasoningRow(entry)

      case (.assistant, _):
        VStack(alignment: .leading, spacing: 8 * scale) {
          if row.showsProviderHeader {
            HStack(spacing: 7 * scale) {
              AgentProviderLogo(
                provider: snapshot?.provider,
                size: max(8, 9 * scale),
                color: palette.signal
              )
              Text(providerName)
                .font(.ottoLabel(max(5.5, 6.5 * scale), weight: .black))
                .foregroundStyle(palette.muted)
            }
          }
          assistantBody(entry)
          HStack(spacing: 9 * scale) {
            // The turn's time and tokens appear on hover with the actions, in the same row.
            if let stats = entry.turnStats {
              Text(TurnStatsText.summary(stats))
                .monospacedDigit()
                .help(TurnStatsText.detail(stats))
                .accessibilityLabel(TurnStatsText.detail(stats))
            }
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(entry.text, forType: .string)
              toastNotice = OttoToastNotice(message: "Response copied")
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .help("Copy response")
            handoffMenu(for: entry)
          }
          .frame(height: 12 * scale)
          .opacity(hoveredMessageID == entry.id ? 1 : 0)
          .allowsHitTesting(hoveredMessageID == entry.id)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hoveredMessageID)
          .textSelection(.disabled)
          .buttonStyle(.plain)
          .font(.ottoLabel(max(5.5, 6.5 * scale), weight: .medium))
          .foregroundStyle(palette.muted.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
          hoveredMessageID =
            hovering ? entry.id : (hoveredMessageID == entry.id ? nil : hoveredMessageID)
        }

      case (.activity, .toolCall):
        toolCallRow(entry)

      case (.activity, _):
        HStack(alignment: .top, spacing: 8 * scale) {
          Image(systemName: entry.kind == .notice ? "info.circle" : "bolt.horizontal.circle")
            .foregroundStyle(palette.cyan)
          Text(entry.text)
            .font(.ottoMono(max(6.5, 8 * scale), weight: .medium))
            .foregroundStyle(palette.muted)
        }
        .padding(.vertical, 2 * scale)
        .accessibilityLabel("Agent activity: \(entry.text)")
      }
    }
  }

  /// Keep the explanatory visual visible; detail opens beside the selected response.
  @ViewBuilder
  private func assistantBody(_ entry: AgentTranscriptEntry) -> some View {
    let response = AssistantResponsePresentation(entry.text)
    let streaming = isWorking && entry.id == transcript.last?.id
    VStack(alignment: .leading, spacing: 10 * scale) {
      MarkdownMessageView(
        text: response.fullText, scale: scale, palette: palette,
        assetDirectory: URL(fileURLWithPath: resolvedFilePath(".")),
        presentedBlocks: streaming ? nil : response.preview,
        resultScope: entry.id.uuidString
      )
      .equatable()
      if !streaming, response.hasVisual || response.hasDetails {
        HStack(spacing: 16 * scale) {
          if response.hasVisual {
            Button {
              exploredResponse = entry
            } label: {
              Label("Explore", systemImage: "arrow.up.left.and.arrow.down.right")
            }
          }
          if response.hasDetails {
            Button {
              openResponse(entry)
            } label: {
              Label("Full explanation", systemImage: "doc.text")
            }
          }
        }
        .buttonStyle(.plain)
        .font(.ottoDisplay(max(10, 11.5 * scale)))
        .foregroundStyle(palette.cyan)
      }
    }
  }

  private func openResponse(_ entry: AgentTranscriptEntry) {
    onInspectResponse()
    showingTurnReview = false
    artifactPath = nil
    inspectedResponse = entry
  }

  @ViewBuilder
  private func transcriptImage(_ path: String) -> some View {
    if let image = NSImage(contentsOfFile: path) {
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 220 * scale, maxHeight: 160 * scale)
        .clipShape(RoundedRectangle(cornerRadius: 9 * scale))
        .overlay(
          RoundedRectangle(cornerRadius: 9 * scale)
            .stroke(palette.paper.opacity(0.1), lineWidth: 1)
        )
        .accessibilityLabel("Attached image \((path as NSString).lastPathComponent)")
    } else {
      Label((path as NSString).lastPathComponent, systemImage: "photo")
        .font(.ottoMono(max(6, 7 * scale)))
        .foregroundStyle(palette.muted)
        .padding(8 * scale)
        .background(palette.ink.opacity(0.35), in: RoundedRectangle(cornerRadius: 8 * scale))
        .accessibilityLabel("Attached image unavailable")
    }
  }

  /// Sends this message to another agent as a fresh prompt — "make a plan" here, "implement
  /// this plan" there — with a short preamble naming its origin so the receiving agent has
  /// context. The chain lives in plain prompts, so any provider can pick it up.
  private func handoffMenu(for entry: AgentTranscriptEntry) -> some View {
    Menu {
      let targets = handoffTargets()
      if targets.isEmpty {
        Text("No other agents on this canvas")
      } else {
        ForEach(targets) { target in
          Button(target.name) {
            handoff(target.id, handoffPrompt(for: entry))
          }
        }
      }
    } label: {
      Image(systemName: "arrowshape.turn.up.right")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Hand this message to another agent")
    .accessibilityLabel("Hand off to another agent")
  }

  private func handoffPrompt(for entry: AgentTranscriptEntry) -> String {
    """
    Handed off from the agent "\(node.displayName)" (\(providerName)) on this canvas. Act on the \
    following — if it is a plan, carry it out; if it is work, review it:

    \(entry.text)
    """
  }

  private func reasoningRow(_ entry: AgentTranscriptEntry) -> some View {
    let expanded = expandedReasoning.contains(entry.id)
    return VStack(alignment: .leading, spacing: 5 * scale) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
          if expanded {
            expandedReasoning.remove(entry.id)
          } else {
            expandedReasoning.insert(entry.id)
          }
        }
      } label: {
        HStack(spacing: 6 * scale) {
          Image(systemName: "brain")
            .font(.system(size: max(6.5, 7.5 * scale), weight: .medium))
          Text("Reasoned")
            .font(.ottoLabel(max(5.5, 6.5 * scale), weight: .black))
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: max(5.5, 6 * scale), weight: .bold))
        }
        .foregroundStyle(palette.muted.opacity(0.85))
      }
      .buttonStyle(.plain)
      .textSelection(.disabled)
      .accessibilityLabel(expanded ? "Collapse reasoning" : "Expand reasoning")
      Text(entry.text)
        .font(.ottoDisplay(max(8.5, 10 * scale)).italic())
        .foregroundStyle(palette.muted)
        .lineSpacing(3 * scale)
        .lineLimit(expanded ? nil : 2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.leading, 2 * scale)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Fluid Functionalism's ThinkingSteps, adapted to the native transcript: reasoning and tool
  /// activity from one stretch of work become a single disclosure instead of unrelated rows.
  private func completedThinkingSteps(_ entries: [AgentTranscriptEntry], id: UUID) -> some View {
    let isOpen = !collapsedThinkingGroups.contains(id)
    return VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(motion.enter(.moderate)) {
          if isOpen {
            collapsedThinkingGroups.insert(id)
          } else {
            collapsedThinkingGroups.remove(id)
          }
        }
      } label: {
        HStack(spacing: 7 * scale) {
          Image(systemName: "chevron.right")
            .font(.system(size: max(6, 7 * scale), weight: .semibold))
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .animation(motion.enter(.fast), value: isOpen)
          Text("Thought through \(entries.count) step\(entries.count == 1 ? "" : "s")")
            .font(.ottoDisplay(max(8.5, 10.5 * scale)).weight(.medium))
          Spacer(minLength: 0)
        }
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 8 * scale)
        .frame(height: 30 * scale)
        .contentShape(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isOpen ? "Collapse thinking steps" : "Expand thinking steps")

      if isOpen {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            thinkingStepRow(
              entry,
              isActive: false,
              showsConnector: index < entries.count - 1
            )
            .transition(staggeredStepTransition(index))
          }
        }
        .padding(.leading, 8 * scale)
        .padding(.bottom, 6 * scale)
        .transition(.ottoUnfold(reduceMotion: reduceMotion))
      }
    }
    .frame(maxWidth: min(760, 700 * scale), alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  /// Steps land one after another: the block makes room on the moderate spring while each row
  /// fades in 0.08s after the one above, so a list reads as a sequence rather than a slab.
  private func staggeredStepTransition(_ index: Int) -> AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .opacity.animation(
        .easeOut(duration: OttoMotion.slow.duration).delay(Double(index) * 0.08)),
      removal: .opacity.animation(OttoMotion.fast.exit)
    )
  }

  /// A settled step. It keeps the working block's vocabulary — tick, name, muted detail —
  /// so a finished run reads back as the checklist you watched it work through, rather than
  /// as a stack of chips.
  private func toolCallRow(_ entry: AgentTranscriptEntry) -> some View {
    let name = toolDisplayName(entry.detail ?? "Tool")
    return HStack(alignment: .top, spacing: 9 * scale) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: max(9, 11 * scale)))
        .foregroundStyle(palette.signal.opacity(0.85))
        .frame(width: 14 * scale, height: 15 * scale)
      VStack(alignment: .leading, spacing: 2 * scale) {
        Text(name)
          .font(.ottoDisplay(max(8.5, 11 * scale)).weight(.medium))
          .foregroundStyle(palette.paper.opacity(0.92))
          .lineLimit(1)
        if entry.text != (entry.detail ?? ""), !entry.text.isEmpty {
          Text(entry.text)
            .font(.ottoMono(max(6, 7 * scale)))
            .foregroundStyle(palette.muted)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 2 * scale)
    .accessibilityLabel("Step: \(name), \(entry.text)")
  }

  private func toolDisplayName(_ raw: String) -> String {
    // MCP tools arrive as mcp__server__tool_name; surface them as "server · tool name".
    if raw.hasPrefix("mcp__") {
      let parts = raw.dropFirst(5).components(separatedBy: "__")
      if parts.count >= 2 {
        // Otto's own server (`otto`, or `muse` in transcripts from before the rename) reads
        // as "Otto".
        let server = ["otto", "muse"].contains(parts[0]) ? "Otto" : parts[0]
        return "\(server) · \(parts.dropFirst().joined(separator: "__"))"
      }
    }
    return raw
  }

  private func toolSymbol(_ name: String) -> String {
    switch name {
    case "Bash", "Shell": "terminal"
    case "Edit", "Write", "NotebookEdit": "pencil.line"
    case "Read": "doc.text"
    case "Glob", "Grep": "magnifyingglass"
    case "WebFetch", "WebSearch": "globe"
    case "Task", "Agent": "person.2"
    case "TodoWrite": "checklist"
    case "MCP": "puzzlepiece.extension"
    default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
    }
  }

  /// The steps this turn has taken so far: the trailing run of tool calls since the agent
  /// last said something. This is what the working block reports, so the loading state
  /// tells you *what it is doing* rather than only that it is busy.
  private var liveSteps: [AgentTranscriptEntry] {
    var steps: [AgentTranscriptEntry] = []
    for entry in transcript.reversed() {
      if entry.role == .user { break }
      if entry.role == .assistant, entry.kind == .text, !entry.text.isEmpty { break }
      if entry.kind == .toolCall { steps.append(entry) }
      if steps.count >= 5 { break }
    }
    return steps.reversed()
  }

  /// Design's working state: a steps block rather than a lone spinner. Completed steps carry
  /// a tick and their own detail line, the running one shimmers, and the elapsed counter sits
  /// in the header so the transcript keeps one status line instead of many.
  private var workingRow: some View {
    let steps = liveSteps
    return VStack(alignment: .leading, spacing: 0) {
      ThinkingIndicator(scale: max(0.5, 0.65 * scale), color: palette.signal)
        .padding(.leading, 4 * scale)
        .padding(.bottom, 6 * scale)
      Button {
        withAnimation(motion.enter(.moderate)) {
          workingStepsExpanded.toggle()
        }
      } label: {
        HStack(spacing: 7 * scale) {
          Image(systemName: "chevron.right")
            .font(.system(size: max(6, 7 * scale), weight: .semibold))
            .rotationEffect(.degrees(workingStepsExpanded ? 90 : 0))
            .animation(motion.enter(.fast), value: workingStepsExpanded)
          ShimmerWord(
            text: liveText == nil ? "Thinking" : "Responding",
            size: max(8.5, 10.5 * scale)
          )
          WorkingElapsedLabel(
            startedAt: workingStart ?? .now,
            providerName: steps.isEmpty ? providerName : "\(steps.count) steps",
            size: max(5.5, 7 * scale),
            color: palette.muted
          )
          .frame(width: max(92, 150 * scale), alignment: .leading)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 8 * scale)
        .frame(height: 30 * scale)
        .contentShape(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        workingStepsExpanded ? "Collapse thinking steps" : "Expand thinking steps")

      if workingStepsExpanded, !steps.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
            thinkingStepRow(
              step,
              isActive: step.id == steps.last?.id,
              showsConnector: index < steps.count - 1
            )
            .transition(staggeredStepTransition(index))
          }
        }
        .padding(.leading, 8 * scale)
        .padding(.bottom, 6 * scale)
        .transition(.ottoUnfold(reduceMotion: reduceMotion))
        // A step that lands while the block is open makes room on the slow spring.
        .animation(motion.enter(.slow), value: steps.map(\.id))
      }

      if workingStepsExpanded, let liveText {
        Text(liveText)
          .font(.ottoDisplay(max(8, 9.5 * scale)))
          .foregroundStyle(palette.muted)
          .lineLimit(6)
          .padding(.leading, 31 * scale)
          .padding(.trailing, 8 * scale)
          .padding(.bottom, 7 * scale)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: min(760, 700 * scale), alignment: .leading)
    .onAppear { workingStart = workingStart ?? .now }
    .onDisappear { workingStart = nil }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Working, \(steps.count) steps so far")
  }

  /// One line of the working block. The step that is still running shows a hollow ring and
  /// muted text; everything above it has already landed.
  private func thinkingStepRow(
    _ entry: AgentTranscriptEntry, isActive: Bool, showsConnector: Bool
  ) -> some View {
    let isReasoning = entry.kind == .reasoning
    let name = isReasoning ? "Reasoning" : toolDisplayName(entry.detail ?? "Tool")
    return HStack(alignment: .top, spacing: 9 * scale) {
      ZStack(alignment: .top) {
        if showsConnector {
          Rectangle()
            .fill(palette.paper.opacity(0.12))
            .frame(width: 1, height: 30 * scale)
            .offset(y: 11 * scale)
        }
        Image(systemName: isReasoning ? "brain" : toolSymbol(entry.detail ?? ""))
          .font(.system(size: max(7.5, 9 * scale), weight: .medium))
          .foregroundStyle(isActive ? palette.signal : palette.muted)
          .frame(width: 16 * scale, height: 16 * scale)
          .background(palette.conversationBottom, in: Circle())
      }
      .frame(width: 16 * scale)
      VStack(alignment: .leading, spacing: 2 * scale) {
        if isActive {
          ShimmerWord(text: name, size: max(8.5, 10.5 * scale))
        } else {
          Text(name)
            .font(.ottoDisplay(max(8.5, 10.5 * scale)).weight(.medium))
            .foregroundStyle(palette.paper.opacity(0.88))
            .lineLimit(1)
        }
        if !entry.text.isEmpty, entry.text != (entry.detail ?? "") {
          Text(entry.text)
            .font(.ottoDisplay(max(7.5, 9 * scale)))
            .foregroundStyle(palette.muted)
            .lineLimit(isReasoning ? 3 : 2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 5 * scale)
  }

  @ViewBuilder
  private func attentionRow(_ attention: String) -> some View {
    if let choice = pendingChoice {
      AgentChoiceCard(
        prompt: choice, agentName: node.displayName, scale: scale, palette: palette,
        answer: answerChoice)
    } else {
      attentionNotice(attention)
    }
  }

  private func attentionNotice(_ attention: String) -> some View {
    VStack(alignment: .leading, spacing: 9 * scale) {
      HStack(alignment: .top, spacing: 9 * scale) {
        Image(systemName: attentionSymbol)
          .foregroundStyle(palette.amber)
        VStack(alignment: .leading, spacing: 3 * scale) {
          Text(attentionTitle)
            .font(.ottoLabel(max(6, 7 * scale), weight: .black))
            .foregroundStyle(palette.amber)
          // A permission request can carry a whole email; it scrolls rather than pushing
          // Approve out of view, and all of it stays readable.
          Text(attention)
            .font(.ottoDisplay(max(8.5, 10.5 * scale)))
            .foregroundStyle(palette.paper)
            .cappedScroll(maxHeight: 320 * scale)
        }
      }
      if isAwaitingSignIn {
        HStack(spacing: 8 * scale) {
          Button(action: startProviderSignIn) {
            Label("Start sign-in", systemImage: "person.crop.circle.badge.checkmark")
              .font(.ottoLabel(max(6.5, 7.5 * scale), weight: .black))
              .padding(.horizontal, 11 * scale)
              .frame(height: 22 * scale)
          }
          .buttonStyle(.plain)
          .foregroundStyle(palette.ink)
          .background(palette.signal, in: Capsule())
          .help("Confirm the provider's sign-in prompt; this may open your browser")
          openTerminalButton
          Text("finish signing in there, then chat as normal")
            .font(.ottoLabel(max(5.5, 6.5 * scale)))
            .foregroundStyle(palette.muted)
        }
      } else if isAwaitingChoice {
        Text("type your answer below")
          .font(.ottoLabel(max(5.5, 6.5 * scale)))
          .foregroundStyle(palette.muted)
      } else if snapshot?.state == .waitingUser {
        HStack(spacing: 8 * scale) {
          openTerminalButton
          Text("or reply below")
            .font(.ottoLabel(max(5.5, 6.5 * scale)))
            .foregroundStyle(palette.muted)
        }
      }
      if isAwaitingPermission {
        HStack(spacing: 8 * scale) {
          Button(action: approvePermission) {
            Label("Approve", systemImage: "checkmark")
              .font(.ottoLabel(max(6.5, 7.5 * scale), weight: .black))
              .padding(.horizontal, 11 * scale)
              .frame(height: 22 * scale)
          }
          .buttonStyle(.plain)
          .foregroundStyle(palette.ink)
          .background(palette.signal, in: Capsule())
          .help(
            isOneShotRun
              ? "Allow the requested tool call"
              : "Send the provider's confirm keystroke (Return)"
          )
          Button(action: denyPermission) {
            Label("Deny", systemImage: "xmark")
              .font(.ottoLabel(max(6.5, 7.5 * scale), weight: .black))
              .padding(.horizontal, 11 * scale)
              .frame(height: 22 * scale)
          }
          .buttonStyle(.plain)
          .foregroundStyle(palette.paper)
          .overlay(Capsule().stroke(palette.paper.opacity(0.25), lineWidth: 1))
          .help(
            isOneShotRun
              ? "Deny the requested tool call"
              : "Send the provider's cancel keystroke (Esc)"
          )
          Text("or reply below to steer the agent")
            .font(.ottoLabel(max(5.5, 6.5 * scale)))
            .foregroundStyle(palette.muted)
        }
        Button(action: alwaysAllowPermission) {
          Text(
            isOneShotRun
              ? "Always allow — switch \(node.displayName) to bypass permissions"
              : "Approve and use bypass permissions from the next run"
          )
          .font(.ottoLabel(max(5.5, 6.5 * scale), weight: .medium))
          .underline()
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.muted)
        .help(
          "Approves this request and saves bypass permissions on \(node.displayName), so future runs stop asking"
        )
      }
    }
    .padding(10 * scale)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.amber.opacity(0.09), in: RoundedRectangle(cornerRadius: 9 * scale))
    .overlay(
      RoundedRectangle(cornerRadius: 9 * scale)
        .stroke(palette.amber.opacity(0.22), lineWidth: 1)
    )
  }

  /// "Why does this agent know what it knows?" — the exact packet delivered at launch, straight
  /// from the inspection copy the supervisor wrote beside the workspace.
  private var bootstrapInspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("Memory bootstrap")
          .font(.ottoLabel(7, weight: .black))
          .foregroundStyle(palette.signal)
        if let hash = snapshot?.bootstrapHash {
          Text("Packet \(hash.prefix(12))")
            .font(.ottoMono(8))
            .foregroundStyle(palette.muted)
        }
        MarkdownMessageView(text: bootstrapPacketText, scale: 1, palette: palette)
          .equatable()
      }
      .padding(14)
      .frame(width: 430, alignment: .leading)
    }
    .frame(width: 460, height: 420)
    .background(palette.surface)
  }

  private var bootstrapPacketText: String {
    let workspace =
      node.agentDefinition?.workingDirectory ?? FileManager.default.currentDirectoryPath
    let path = (workspace as NSString)
      .appendingPathComponent(".otto/bootstrap/\(node.id.uuidString).md")
    guard let data = FileManager.default.contents(atPath: path) else {
      return "The bootstrap inspection copy is not on disk (expected at \(path))."
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// Model chip for switchable providers: shows the active model and effort, opening a
  /// canvas-styled picker. Picks persist on the node's saved configuration; one-shot chat
  /// agents use them from the next message, and a live interactive terminal is relaunched on
  /// the same session so it reflects the new configuration immediately.
  /// The account whose model catalog applies: the one this agent's next run bills to.
  private var modelAccountID: UUID? {
    providerAccountContext?.effectiveAccountID(node.id)
  }

  private func modelMenu(_ definition: AgentDefinition, zoom: Double? = nil) -> some View {
    let scale = zoom ?? self.scale
    return Button {
      showingModelPicker = true
    } label: {
      HStack(spacing: 4 * scale) {
        Image(systemName: "cpu")
          .font(.system(size: max(6.5, 7.5 * scale)))
        Text(modelChipTitle(definition))
          .font(.ottoLabel(max(6, 7 * scale), weight: .bold))
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: max(5, 5.5 * scale), weight: .bold))
      }
      .foregroundStyle(palette.muted)
      .padding(.horizontal, 7 * scale)
      .frame(height: 17 * scale)
      .background(palette.raised.opacity(0.75), in: Capsule())
    }
    .buttonStyle(.plain)
    .help("Choose which model and effort this agent uses")
    .accessibilityLabel("Model: \(modelChipTitle(definition)). Change model")
    .popover(isPresented: $showingModelPicker, arrowEdge: .bottom) {
      ModelPickerPopover(
        provider: definition.provider,
        accountID: { providerAccountContext?.effectiveAccountID(node.id) },
        model: definition.model,
        effort: definition.effort,
        setModel: setModel
      )
    }
  }

  @ViewBuilder
  private func menuLabel(_ title: String, checked: Bool) -> some View {
    if checked {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }

  private func modelChipTitle(_ definition: AgentDefinition) -> String {
    let name =
      definition.model.map {
        AgentModelCatalog.displayName(forModelID: $0, provider: definition.provider)
      } ?? "Default"
    if let effort = definition.effort, !effort.isEmpty {
      return "\(name) · \(effort.capitalized)"
    }
    return name
  }

  private var isAwaitingPermission: Bool { snapshot?.state == .waitingPermission }

  private var isAwaitingSignIn: Bool {
    snapshot?.state == .waitingUser && snapshot?.attentionToken == "provider-authentication"
  }

  /// The agent asked a structured question (Hermes clarify or the otto ask_user tool); the
  /// card renders its choices as buttons and the composer answers it instead of prompting.
  private var pendingChoice: AgentChoicePrompt? {
    guard snapshot?.state == .waitingUser, snapshot?.attentionToken == "agent-choice" else {
      return nil
    }
    return snapshot?.pendingChoice
  }

  private var isAwaitingChoice: Bool {
    snapshot?.state == .waitingUser && snapshot?.attentionToken == "agent-choice"
  }

  private var attentionTitle: String {
    if isAwaitingPermission { return "Permission required" }
    if isAwaitingSignIn { return "Sign-in required" }
    if let choice = pendingChoice, choice.multiSelect { return "Pick one or more" }
    if pendingChoice != nil { return "Pick an option" }
    return "Needs your response"
  }

  private var attentionSymbol: String {
    if isAwaitingPermission { return "lock.shield" }
    if isAwaitingSignIn { return "person.crop.circle.badge.exclamationmark" }
    if pendingChoice != nil { return "list.bullet.circle" }
    return "questionmark.bubble.fill"
  }

  private func answerChoice(_ answer: String) {
    resolveChoice(answer)
  }

  private var openTerminalButton: some View {
    Button {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
        setPresentation(.terminal)
      }
    } label: {
      Label("Open Terminal", systemImage: "terminal")
        .font(.ottoLabel(max(6.5, 7.5 * scale), weight: .black))
        .padding(.horizontal, 11 * scale)
        .frame(height: 22 * scale)
    }
    .buttonStyle(.plain)
    .foregroundStyle(palette.paper)
    .overlay(Capsule().stroke(palette.paper.opacity(0.25), lineWidth: 1))
    .help("See the full provider screen to answer directly")
  }

  /// Confirms the provider's sign-in prompt (Return selects the default sign-in choice) and
  /// brings the terminal forward so the user can watch the browser hand-off complete.
  private func startProviderSignIn() {
    sendBytes(Data("\r".utf8))
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
      setPresentation(.terminal)
    }
  }

  private var isOneShotRun: Bool { snapshot?.executionMode == .oneShotProvider }

  /// The services layer decides how to answer: a request parked on the supervisor (one-shot
  /// provider approvals, and Otto tool confirmations from interactive runs too) gets a structured
  /// allow/deny; a prompt only the interactive TUI is painting gets Return or Esc. Sending a
  /// keystroke for a parked request would leave the agent blocked with no card left to answer.
  private func approvePermission() {
    resolvePermission(true)
  }

  private func denyPermission() {
    resolvePermission(false)
  }

  /// Files this agent has created or edited, gathered from the tool calls the parsers already
  /// project into the transcript plus the structured run result. Most recent first.
  private var touchedFiles: [String] {
    let fromTranscript =
      transcript
      .filter { entry in
        entry.kind == .toolCall && ["Edit", "Write", "NotebookEdit"].contains(entry.detail ?? "")
      }
      .flatMap { $0.text.components(separatedBy: ", ") }
    let all = fromTranscript + (snapshot?.structuredResult?.filesChanged ?? [])
    var seen = Set<String>()
    var ordered: [String] = []
    for path in all.reversed() {
      let trimmed = path.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
      ordered.append(trimmed)
    }
    return ordered
  }

  private var filesSurface: some View {
    let files = touchedFiles
    let active = selectedFile.flatMap { files.contains($0) ? $0 : nil } ?? files.first
    return Group {
      if files.isEmpty {
        VStack(alignment: .leading, spacing: 9 * scale) {
          Image(systemName: "folder")
            .font(.system(size: max(14, 20 * scale), weight: .medium))
            .foregroundStyle(palette.signal)
          Text("No files yet")
            .font(.ottoDisplay(max(14, 19 * scale)))
            .foregroundStyle(palette.paper)
          Text("Files this agent creates or edits will appear here, rendered and up to date.")
            .font(.ottoDisplay(max(9, 11 * scale)))
            .foregroundStyle(palette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        HStack(spacing: 0) {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 2 * scale) {
              ForEach(files, id: \.self) { path in
                fileRow(path, isActive: path == active)
              }
            }
            .padding(7 * scale)
          }
          .frame(width: 168 * scale)
          Divider().overlay(palette.paper.opacity(0.08))
          if let active {
            AgentFileViewer(
              path: resolvedFilePath(active),
              scale: scale,
              refreshKey: transcript.count
            )
          }
        }
      }
    }
    .background(
      LinearGradient(
        colors: [palette.surface, palette.ink.opacity(0.36)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func fileRow(_ path: String, isActive: Bool) -> some View {
    let name = (path as NSString).lastPathComponent
    let parent = (path as NSString).deletingLastPathComponent
    return Button {
      selectedFile = path
    } label: {
      VStack(alignment: .leading, spacing: 1.5 * scale) {
        Text(name)
          .font(.ottoMono(max(7, 8.5 * scale), weight: isActive ? .bold : .medium))
          .foregroundStyle(isActive ? palette.ink : palette.paper)
          .lineLimit(1)
          .truncationMode(.middle)
        if !parent.isEmpty {
          Text(parent)
            .font(.ottoMono(max(5.5, 6.5 * scale)))
            .foregroundStyle(isActive ? palette.ink.opacity(0.66) : palette.muted)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8 * scale)
      .padding(.vertical, 6 * scale)
      .background(
        isActive ? palette.signal : Color.clear, in: RoundedRectangle(cornerRadius: 7 * scale)
      )
      .contentShape(RoundedRectangle(cornerRadius: 7 * scale))
    }
    .buttonStyle(.plain)
    .help(path)
  }

  private func resolvedFilePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    let base =
      node.agentDefinition?.workingDirectory ?? FileManager.default.currentDirectoryPath
    return (base as NSString).appendingPathComponent(path)
  }

  private var terminalSurface: some View {
    VStack(spacing: 0) {
      if offersLiveSession, isRunBusy {
        HStack(spacing: 7 * scale) {
          ProgressView()
            .controlSize(.small)
            .tint(palette.signal)
            .frame(width: 14 * scale, height: 14 * scale)
          Text("Run in progress — the live \(providerName) session opens when it finishes")
            .font(.ottoLabel(max(5.5, 6.5 * scale)))
            .foregroundStyle(palette.muted)
          Spacer()
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 6 * scale)
        .background(palette.raised.opacity(0.6))
      }
      EmulatedTerminalView(
        output: reviewedOutput,
        outputStartOffset: reviewedOffsets.start,
        outputEndOffset: reviewedOffsets.end,
        sessionKey: selectedRunID?.uuidString ?? "raw-\(node.id.uuidString)",
        acceptsInput: rawAcceptsInput && selectedRunID == nil,
        replayExistingOutput: selectedRunID != nil
          || snapshot?.executionMode != .interactiveProvider,
        send: sendBytes,
        resize: resize
      )
      .padding(6 * scale)
    }
    .background(palette.ink)
    .accessibilityLabel("Raw provider terminal")
  }

  /// Chat runs are headless stream-JSON processes, so their terminal is the raw transport, not
  /// the provider's real TUI. Claude Code and Codex both support resuming the same session in
  /// their interactive terminal, so opening the TERMINAL surface relaunches that automatically.
  private var offersLiveSession: Bool {
    selectedRunID == nil
      && snapshot?.executionMode == .oneShotProvider
      && [.claudeCode, .codex].contains(node.agentDefinition?.provider)
  }

  private var isRunBusy: Bool {
    [.starting, .working].contains(snapshot?.state)
  }

  /// Opening the TERMINAL surface on a chat agent should feel like the provider's own CLI, not
  /// a JSON transport dump — relaunch the interactive TUI resumed on this conversation as soon
  /// as no run is in flight. `requestedLiveSession` stops repeat triggers while the restart is
  /// spawning; it re-arms once the interactive session is up (or the surface is left).
  private func autoLaunchLiveSession() {
    guard presentation == .terminal, offersLiveSession, !isRunBusy, !requestedLiveSession
    else { return }
    requestedLiveSession = true
    restart()
  }

  @ViewBuilder private var queuedMessages: some View {
    let pending = messageQueue.visibleMessages(agentID: node.id)
    if !pending.isEmpty {
      VStack(alignment: .leading, spacing: 6 * scale) {
        HStack {
          Text(
            "\(pending.count) queued\(messageQueue.paused.contains(node.id) ? " · Paused" : " · Sends after this run")"
          )
          .font(.system(size: max(10, 11 * scale), weight: .medium))
          Spacer()
          if messageQueue.paused.contains(node.id) {
            Button("Resume queue") { messageQueue.resume(node.id) }
              .buttonStyle(.plain)
              .foregroundStyle(palette.signal)
          }
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(pending) { message in
              HStack {
                Text(message.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                  messageQueue.remove(agentID: node.id, messageID: message.id)
                } label: {
                  Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Remove queued message")
                .accessibilityLabel("Remove queued message")
              }
            }
          }
        }
        .frame(
          maxHeight: min(CGFloat(pending.count) * (36 as CGFloat) * scale, (144 as CGFloat) * scale)
        )
        if let error = messageQueue.errors[node.id] {
          Text(error).foregroundStyle(palette.amber)
        }
      }
      .font(.system(size: max(10, 11 * scale)))
      .foregroundStyle(palette.muted)
      .padding(10 * scale)
      .background(palette.raised, in: RoundedRectangle(cornerRadius: 10 * scale))
      .padding(.bottom, 6 * scale)
    }
  }

  /// `zoom` overrides the card scale for the centered welcome composer, which grows with the pane.
  private func composer(centered: Bool = false, zoom: Double? = nil) -> some View {
    let scale = zoom ?? self.scale
    return VStack(spacing: 0) {
      queuedMessages
      AgentUsageLimitCard(nodeID: node.id, scale: scale)
      // The context tray tucks 6pt behind the composer field so the two read as one
      // surface: where this agent works (project · execution location · branch), then
      // the input itself.
      ComposerContextChips(
        processID: snapshot?.processID,
        launchDirectory: node.agentDefinition?.workingDirectory,
        hermesProfileID: node.agentDefinition?.environmentProfileID,
        scale: scale,
        didCopy: { toastNotice = OttoToastNotice(message: $0) }
      )
      .padding(.horizontal, 12 * scale)
      .padding(.top, 9 * scale)
      // Tuck behind the composer field, unless the pending-attachment row sits between them.
      .padding(.bottom, hasPendingAttachments ? 0 : -6 * scale)
      if hasPendingAttachments {
        HStack(spacing: 7 * scale) {
          ForEach(pendingPastes) { paste in
            pendingPasteChip(paste)
          }
          ForEach(pendingImages) { image in
            HStack(spacing: 5 * scale) {
              if let thumbnail = NSImage(contentsOfFile: image.path) {
                Image(nsImage: thumbnail)
                  .resizable()
                  .scaledToFill()
                  .frame(width: 26 * scale, height: 26 * scale)
                  .clipShape(RoundedRectangle(cornerRadius: 5 * scale))
              } else {
                Image(systemName: "photo")
                  .foregroundStyle(palette.muted)
              }
              Text(image.name)
                .font(.ottoMono(max(6, 7 * scale)))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
              Button {
                pendingImages.removeAll { $0.id == image.id }
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .font(.system(size: max(7, 8 * scale)))
                  .foregroundStyle(palette.muted)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Remove \(image.name)")
            }
            .padding(.horizontal, 7 * scale)
            .padding(.vertical, 4 * scale)
            .background(palette.raised.opacity(0.8), in: Capsule())
          }
          Spacer()
        }
        .padding(.horizontal, 14 * scale)
        .padding(.top, 8 * scale)
      }
      if let attachmentError {
        HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(palette.amber)
          Text(attachmentError)
            .font(.ottoLabel(max(6, 7 * scale)))
            .foregroundStyle(palette.amber)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4 * scale)
          Button {
            self.attachmentError = nil
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .foregroundStyle(palette.muted)
          .accessibilityLabel("Dismiss attachment error")
        }
        .padding(.horizontal, 14 * scale)
        .padding(.top, 7 * scale)
        .accessibilityLabel("Image attachment failed: \(attachmentError)")
      }
      // Center-aligned like the design's composer row: the vertical-axis text field carries
      // extra bottom inset, so bottom-anchoring the icons made a single line sit visibly
      // off-center in the field.
      if !mentionSuggestions.isEmpty {
        mentionPicker
          .padding(.horizontal, 14 * scale)
          .padding(.top, 8 * scale)
      }
      HStack(alignment: .center, spacing: 8 * scale) {
        Button(action: pickImages) {
          Image(systemName: "paperclip")
            .font(.system(size: max(8, 9 * scale), weight: .medium))
            .frame(width: 20 * scale, height: 24 * scale)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.muted)
        .disabled(!acceptsComposerInput)
        .help("Attach images (or paste them directly)")
        .accessibilityLabel("Attach images")
        TextField(inputPrompt, text: $input, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.ottoDisplay(max(9, 11 * scale)))
          .foregroundStyle(palette.paper)
          .lineLimit(1...)
          .composerScroll(maxHeight: 170 * scale)
          .submitLabel(.send)
          .focused($composerFocused)
          .onSubmit(submitOrInsertMention)
          .onKeyPress(.upArrow) {
            moveMentionSelection(-1)
          }
          .onKeyPress(.downArrow) {
            moveMentionSelection(1)
          }
          .onChange(of: input) { _, _ in selectedMentionIndex = 0 }
          .disabled(!acceptsComposerInput)
          .accessibilityLabel(inputPrompt)
          .accessibilityHint("Press Return to send or Shift-Return for a new line")
          // SwiftUI's field editor consumes Command-V and treats every Return variant as submit.
          // Observe the key event first so image paste and Shift-Return get native chat behavior.
          .background {
            ChatComposerKeyMonitor(
              isEnabled: composerFocused && acceptsComposerInput,
              onPasteImage: attachImagesFromPasteboard,
              onPasteLargeText: attachTextFromPasteboard
            )
          }
        if isWorking {
          if inputIsOttoCommand {
            Button(action: submit) {
              Image(systemName: "arrow.up")
                .font(.system(size: max(7, 8 * scale), weight: .bold))
                .frame(width: 24 * scale, height: 24 * scale)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSubmit ? palette.ink : palette.muted)
            .background(canSubmit ? palette.signal : palette.raised, in: Circle())
            .disabled(!canSubmit)
            .help("Run Otto command")
          }
          if !inputIsOttoCommand {
            Button(action: submit) {
              Label("Add to queue", systemImage: "text.badge.plus")
                .font(.system(size: max(10, 11 * scale), weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSubmit ? palette.signal : palette.muted)
            .disabled(!canSubmit)
            .help("Send after the current run finishes (Return)")
          }
          Button(action: interrupt) {
            Image(systemName: "stop.fill")
              .font(.system(size: max(6, 7 * scale), weight: .bold))
              .frame(width: 24 * scale, height: 24 * scale)
          }
          .buttonStyle(.plain)
          .foregroundStyle(palette.ink)
          .background(palette.amber, in: Circle())
          .help("Stop current run and pause queued messages")
        } else {
          Button(action: submit) {
            Image(systemName: "arrow.up")
              .font(.system(size: max(7, 8 * scale), weight: .bold))
              .frame(width: 24 * scale, height: 24 * scale)
          }
          .buttonStyle(.plain)
          .foregroundStyle(canSubmit ? palette.ink : palette.muted)
          .background(canSubmit ? palette.signal : palette.raised, in: Circle())
          .disabled(!canSubmit)
          .help("Send prompt")
        }
      }
      .padding(.horizontal, 11 * scale)
      .padding(.vertical, 9 * scale)
      .contentShape(RoundedRectangle(cornerRadius: 12 * scale))
      .onTapGesture {
        guard acceptsComposerInput else { return }
        composerFocused = true
      }
      .padding(.vertical, centered ? 5 * scale : 0)
      .background(
        palette.raised.opacity(centered ? 0.96 : 0.92),
        in: RoundedRectangle(cornerRadius: (centered ? 15 : 12) * scale)
      )
      .overlay {
        if centered {
          RoundedRectangle(cornerRadius: 15 * scale)
            .stroke(palette.paper.opacity(composerFocused ? 0.16 : 0.07), lineWidth: 1)
        } else {
          RoundedRectangle(cornerRadius: 12 * scale)
            .stroke(
              composerFocused ? palette.signal.opacity(0.7) : palette.paper.opacity(0.08),
              lineWidth: 1
            )
        }
      }
      .shadow(color: .black.opacity(centered ? 0.22 : 0), radius: 16, y: 8)
      .padding(.horizontal, centered ? 0 : 10 * scale)
      .padding(.top, 9 * scale)
      .background(centered ? Color.clear : palette.paneSurface)
      composerStatusRow(centered: centered, zoom: zoom)
    }
  }

  /// The strip under the composer, mirroring the provider CLIs' own footer: permission mode on
  /// the left, model and effort on the right. Both are live menus, so the agent's operating
  /// setup is adjustable exactly where the eye already checks it.
  private func composerStatusRow(centered: Bool = false, zoom: Double? = nil) -> some View {
    let scale = zoom ?? self.scale
    return HStack(spacing: 8 * scale) {
      if let definition = node.agentDefinition, definition.provider != .shell {
        permissionMenu(definition, zoom: zoom)
      }
      if let definition = node.agentDefinition,
        definition.provider == .claudeCode || definition.provider == .codex
      {
        executionStrategyMenu(definition, zoom: zoom)
      }
      AgentAccountChip(node: node, scale: scale)
      Spacer()
      if let definition = node.agentDefinition,
        AgentModelCatalog.supportsModelSelection(for: definition.provider)
      {
        modelMenu(definition, zoom: zoom)
          // Warming here rather than in the popover means the CLI has usually answered long
          // before the chip is clicked, so the list is there on the first frame.
          // Keyed by account so switching Work ↔ Personal loads that account's catalog.
          .task(
            id: ProviderModelCatalogStore.Key(
              provider: definition.provider, accountID: modelAccountID)
          ) {
            ProviderModelCatalogStore.shared.load(definition.provider, accountID: modelAccountID)
          }
      }
    }
    .padding(.horizontal, centered ? 4 * scale : 12 * scale)
    .padding(.top, 5 * scale)
    .padding(.bottom, 7 * scale)
    .background(centered ? Color.clear : palette.paneSurface)
  }

  private func executionStrategyMenu(_ definition: AgentDefinition, zoom: Double? = nil)
    -> some View
  {
    let scale = zoom ?? self.scale
    let current = definition.effectiveExecutionStrategy
    return Menu {
      ForEach(
        AgentExecutionStrategy.allCases.filter { $0.isSupported(by: definition.provider) },
        id: \.self
      ) { strategy in
        Button {
          setExecutionStrategy(strategy)
        } label: {
          menuLabel(executionStrategyLabel(strategy), checked: strategy == current)
        }
      }
    } label: {
      HStack(spacing: 4 * scale) {
        Image(systemName: executionStrategySymbol(current))
          .font(.system(size: max(6.5, 7.5 * scale)))
        Text(executionStrategyLabel(current))
          .font(.ottoLabel(max(6, 7 * scale), weight: .bold))
          .lineLimit(1)
      }
      .foregroundStyle(current == .scriptedWorkflow ? palette.signal : palette.muted)
      .padding(.horizontal, 7 * scale)
      .frame(height: 17 * scale)
      .background(palette.raised.opacity(0.75), in: Capsule())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Choose how this agent structures future work")
    .accessibilityLabel("Execution strategy: \(executionStrategyLabel(current))")
  }

  private func executionStrategyLabel(_ strategy: AgentExecutionStrategy) -> String {
    switch strategy {
    case .direct: "Direct"
    case .delegated: "Delegated"
    case .scriptedWorkflow: "Workflow"
    }
  }

  private func executionStrategySymbol(_ strategy: AgentExecutionStrategy) -> String {
    switch strategy {
    case .direct: "person"
    case .delegated: "person.2"
    case .scriptedWorkflow: "point.3.connected.trianglepath.dotted"
    }
  }

  private func permissionMenu(_ definition: AgentDefinition, zoom: Double? = nil) -> some View {
    let scale = zoom ?? self.scale
    let mode = AgentPermissionMode(rawValue: definition.permissionMode) ?? .workspaceWrite
    return Menu {
      ForEach(AgentPermissionMode.allCases, id: \.self) { candidate in
        Button {
          setPermissionMode(candidate)
        } label: {
          menuLabel(permissionModeLabel(candidate), checked: candidate == mode)
        }
      }
    } label: {
      Text(permissionModeLabel(mode))
        .font(.ottoLabel(max(6, 7 * scale), weight: .bold))
        .lineLimit(1)
        .foregroundStyle(mode == .unrestricted ? palette.amber : palette.muted)
        .padding(.horizontal, 7 * scale)
        .frame(height: 17 * scale)
        .background(
          (mode == .unrestricted ? palette.amber.opacity(0.14) : palette.raised.opacity(0.75)),
          in: Capsule()
        )
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Change this agent's permission mode; applies from its next run")
    .accessibilityLabel("Permissions: \(permissionModeLabel(mode)). Change permission mode")
  }

  private func permissionModeLabel(_ mode: AgentPermissionMode) -> String {
    switch mode {
    case .readOnly: "Read only"
    case .workspaceWrite: "Ask to approve"
    case .unrestricted: "Bypass permissions"
    }
  }

  // MARK: - Pasted text attachments

  private var hasPendingAttachments: Bool {
    !pendingImages.isEmpty || !pendingPastes.isEmpty
  }

  private var draftAttachments: ComposerDrafts.Attachments {
    ComposerDrafts.Attachments(
      imagePaths: pendingImages.map(\.path), pastes: pendingPastes.map(\.text))
  }

  private func attachTextFromPasteboard() {
    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
    attachmentError = nil
    pendingPastes.append(ChatPastedText(text))
  }

  private func pendingPasteChip(_ paste: ChatPastedText) -> some View {
    ChatPastedTextChip(
      paste: paste, scale: scale, foreground: palette.muted,
      background: palette.raised.opacity(0.8)
    ) {
      pendingPastes.removeAll { $0.id == paste.id }
    }
  }

  // MARK: - Image attachments

  /// Pasted and picked images are copied beside the agent's workspace so the provider's own
  /// file/image tools can open them; the prompt then references the paths. This works across
  /// Claude Code, Codex, and Hermes without provider-specific upload plumbing.
  private var chatAttachmentsDirectory: String {
    let definition = node.agentDefinition
    let workspace =
      (definition?.provider.startsInProjectFolder == true ? ottoWorkspacePath : nil)
      ?? definition?.workingDirectory ?? FileManager.default.currentDirectoryPath
    return (workspace as NSString).appendingPathComponent(".otto/chat-attachments")
  }

  private func attachImagesFromPasteboard() {
    attachmentError = nil
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
      let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "webp", "heic"]
      let images = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
      if !images.isEmpty {
        for url in images { attachImageFile(url) }
        return
      }
    }
    if let image = NSImage(pasteboard: pasteboard) {
      attachImage(image)
    } else {
      attachmentError = "The clipboard does not contain a supported image."
    }
  }

  private func pickImages() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.image]
    panel.prompt = "Attach"
    guard panel.runModal() == .OK else { return }
    attachmentError = nil
    for url in panel.urls { attachImageFile(url) }
  }

  private func attachImageFile(_ url: URL) {
    do {
      pendingImages.append(try imageAttachmentStore.saveFile(url))
    } catch {
      attachmentError = "Couldn’t attach \(url.lastPathComponent): \(error.localizedDescription)"
    }
  }

  private func attachImage(_ image: NSImage) {
    do {
      pendingImages.append(try imageAttachmentStore.saveImage(image))
    } catch {
      attachmentError = "Couldn’t save the pasted image: \(error.localizedDescription)"
    }
  }

  private var imageAttachmentStore: ChatImageAttachmentStore {
    ChatImageAttachmentStore(directory: chatAttachmentsDirectory)
  }

  static func promptText(_ text: String, referencing imagePaths: [String]) -> String {
    ChatAttachmentPrompt.text(text, referencing: imagePaths)
  }

  private var transcript: [AgentTranscriptEntry] { snapshot?.transcript ?? [] }

  private var liveText: String? {
    guard let snapshot else { return nil }
    let text = ProviderConversationProjection.liveText(
      from: snapshot.output,
      provider: snapshot.provider
    )
    // Completed messages already live in the transcript; only surface text that is still ahead
    // of it so the working row never repeats the last reply.
    let lastMessage = transcript.last { $0.role == .assistant && $0.kind == .text }?.text
    return text == lastMessage ? nil : text
  }

  private var reviewedOutput: String {
    guard let selectedRunID,
      let record = history.first(where: { $0.id == selectedRunID })
    else { return snapshot?.output ?? "Starting provider session…" }
    return record.output
  }

  private var reviewedOffsets: (start: Int, end: Int) {
    guard let selectedRunID,
      let record = history.first(where: { $0.id == selectedRunID })
    else {
      return (
        snapshot?.outputStartOffset ?? 0,
        snapshot?.outputEndOffset ?? (snapshot?.output.utf8.count ?? 0)
      )
    }
    return (record.outputStartOffset, record.outputEndOffset)
  }

  private var providerName: String {
    switch snapshot?.provider ?? .shell {
    case .claudeCode: "Claude"
    case .codex: "Codex"
    case .openAI: "Otto Harness"
    case .hermes: "Hermes"
    case .cursor: "Cursor"
    case .kimi: "Kimi"
    case .openCode: "OpenCode"
    case .pi: "Pi"
    case .grok: "Grok"
    case .shell: node.displayName
    }
  }

  private var statusLabel: String {
    switch snapshot?.state {
    case .waitingPermission, .waitingUser: "NEEDS YOU"
    case .working, .starting: "WORKING"
    case .done: "READY"
    case .failed: "FAILED"
    case .interrupted: "PAUSED"
    case .stopped: "STOPPED"
    default: "READY"
    }
  }

  private var statusSymbol: String {
    switch snapshot?.state {
    case .working, .starting: "circle.dotted"
    case .waitingPermission, .waitingUser: "exclamationmark.circle.fill"
    case .done: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .interrupted, .stopped: "pause.circle.fill"
    default: "circle.fill"
    }
  }

  private var statusColor: Color {
    switch snapshot?.state {
    case .waitingPermission, .waitingUser, .working, .starting: palette.amber
    case .failed: palette.red
    case .interrupted, .stopped: palette.muted
    default: palette.signal
    }
  }

  private var isWorking: Bool {
    snapshot?.state == .working || snapshot?.state == .starting
  }

  /// The last prompt has no assistant text after it yet — the reply is still being projected
  /// into the transcript (turn-end checkpoints and diff computation can lag the state flip
  /// by a few seconds).
  private var lastTurnAwaitsReply: Bool {
    guard let lastUserIndex = transcript.lastIndex(where: { $0.role == .user }) else {
      return false
    }
    return !transcript[transcript.index(after: lastUserIndex)...].contains {
      $0.role == .assistant && $0.kind == .text
    }
  }

  /// The thinking indicator stays up from prompt until the reply actually exists — not just
  /// until the runtime state flips. Without the bridge the indicator vanishes at `.done`
  /// and the projected text lands as a blob seconds later. `replyBridgeDeadline` bounds the
  /// bridge so a turn that legitimately produced no text cannot strand the indicator.
  private var showsWorkingRow: Bool {
    if isWorking { return true }
    guard snapshot?.state == .done, lastTurnAwaitsReply, let replyBridgeDeadline else {
      return false
    }
    return Date.now < replyBridgeDeadline
  }

  private var acceptsPrompt: Bool {
    switch snapshot?.state {
    // nil: the runtime has no snapshot — a node restored from a previous session. It must
    // stay promptable; agent.send_prompt revives it from the persisted configuration. A
    // disabled composer here bricks the node with no visible recovery.
    case nil, .idle, .done, .failed, .interrupted, .stopped, .waitingPermission, .waitingUser:
      true
    default:
      false
    }
  }

  private var rawAcceptsInput: Bool {
    switch snapshot?.state {
    case .starting, .idle, .working, .waitingPermission, .waitingUser, .done: true
    default: false
    }
  }

  private var mentionSuggestions: [AgentProfile] {
    guard let at = input.lastIndex(of: "@") else { return [] }
    let fragment = String(input[input.index(after: at)...])
    if fragment.contains(where: { $0.isWhitespace }) { return [] }
    let needle = fragment.lowercased()
    return mentionProfiles.filter { profile in
      needle.isEmpty
        || profile.handle.hasPrefix(needle)
        || profile.name.lowercased().hasPrefix(needle)
    }.prefix(6).map { $0 }
  }

  private var mentionPicker: some View {
    VStack(spacing: 0) {
      ForEach(Array(mentionSuggestions.enumerated()), id: \.element.id) { index, profile in
        Button {
          insertMention(profile)
        } label: {
          HStack(spacing: 9 * scale) {
            ZStack {
              Circle().fill(
                index == selectedMentionIndex ? palette.ink.opacity(0.12) : palette.raised)
              Text(String(profile.name.prefix(1)).uppercased())
                .font(.ottoLabel(max(6.5, 7.5 * scale), weight: .black))
            }
            .frame(width: 24 * scale, height: 24 * scale)
            VStack(alignment: .leading, spacing: 1 * scale) {
              Text(profile.name)
                .font(.ottoDisplay(max(8, 10 * scale)).weight(.semibold))
              HStack(spacing: 5 * scale) {
                Text("@\(profile.handle)")
                if let jobTitle = profile.jobTitle, !jobTitle.isEmpty {
                  Text("· \(jobTitle)")
                }
              }
              .font(.ottoLabel(max(5.5, 6.5 * scale)))
              .foregroundStyle(
                index == selectedMentionIndex ? palette.ink.opacity(0.64) : palette.muted)
            }
            Spacer(minLength: 8 * scale)
            if index == selectedMentionIndex {
              Text("↵")
                .font(.ottoMono(max(6, 7 * scale), weight: .black))
                .foregroundStyle(palette.ink.opacity(0.58))
            }
          }
          .foregroundStyle(index == selectedMentionIndex ? palette.ink : palette.paper)
          .padding(.horizontal, 9 * scale)
          .frame(height: 38 * scale)
          .background(index == selectedMentionIndex ? palette.signal : Color.clear)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mention \(profile.name), @\(profile.handle)")
        if index < mentionSuggestions.count - 1 {
          Rectangle().fill(palette.paper.opacity(0.06)).frame(height: 1)
        }
      }
      HStack(spacing: 5 * scale) {
        Text("↑↓")
        Text("choose")
        Text("·")
        Text("↵")
        Text("insert")
        Spacer()
      }
      .font(.ottoLabel(max(5.5, 6.5 * scale), weight: .bold))
      .foregroundStyle(palette.muted)
      .padding(.horizontal, 10 * scale)
      .frame(height: 24 * scale)
      .background(palette.ink.opacity(0.22))
    }
    .background(palette.raised, in: RoundedRectangle(cornerRadius: 10 * scale))
    .clipShape(RoundedRectangle(cornerRadius: 10 * scale))
    .overlay(
      RoundedRectangle(cornerRadius: 10 * scale)
        .stroke(palette.paper.opacity(0.1), lineWidth: 1)
    )
    .shadow(color: palette.ink.opacity(0.28), radius: 14 * scale, y: 6 * scale)
  }

  private func insertMention(_ profile: AgentProfile) {
    if let at = input.lastIndex(of: "@") {
      input = String(input[..<at]) + "@\(profile.handle) "
    } else {
      input += "@\(profile.handle) "
    }
  }

  private func moveMentionSelection(_ delta: Int) -> KeyPress.Result {
    let count = mentionSuggestions.count
    guard count > 0 else { return .ignored }
    selectedMentionIndex = MentionPickerPolicy.movedIndex(
      from: selectedMentionIndex, delta: delta, count: count)
    return .handled
  }

  private func submitOrInsertMention() {
    let suggestions = mentionSuggestions
    if !suggestions.isEmpty {
      insertMention(suggestions[min(selectedMentionIndex, suggestions.count - 1)])
      return
    }
    submit()
  }

  private var inputPrompt: String {
    if isAwaitingSignIn { return "Finish signing in above, then message \(providerName)…" }
    if isAwaitingChoice { return "Pick an option above, or type your own answer…" }
    switch snapshot?.state {
    case .waitingPermission: return "Approve or explain what to do…"
    case .waitingUser: return "Reply to the agent…"
    case .failed, .stopped: return "Message \(providerName) to restart…"
    case .working, .starting: return "Add a message to the queue…"
    default: return "Message \(providerName)…"
    }
  }

  private var canSubmit: Bool {
    (acceptsPrompt || isWorking)
      && (PromptSubmission.verbatimText(from: input) != nil || hasPendingAttachments)
  }

  private var inputIsOttoCommand: Bool {
    !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && AgentSlashCommandParser.isCommand(input)
  }

  private var acceptsComposerInput: Bool {
    acceptsPrompt || isWorking
  }

  private func submit() {
    guard acceptsPrompt || isWorking else { return }
    let typed = ChatPastedText.compose(
      typed: PromptSubmission.verbatimText(from: input), pastes: pendingPastes)
    guard typed != nil || !pendingImages.isEmpty else { return }
    // A pending question owns the composer: typed text answers it through the choice channel
    // (parked ask_user call or the provider's clarify bridge), never as a fresh prompt.
    if isAwaitingChoice, let typed, !inputIsOttoCommand {
      answerChoice(typed)
      input = ""
      pendingPastes.removeAll()
      return
    }
    let base = typed ?? "Please look at the attached image\(pendingImages.count == 1 ? "" : "s")."
    let text = Self.promptText(base, referencing: pendingImages.map(\.path))
    let isInput = snapshot?.state == .waitingPermission || snapshot?.state == .waitingUser
    if isWorking && !inputIsOttoCommand {
      messageQueue.enqueue(agentID: node.id, text: text)
    } else {
      send(text, isInput)
    }
    input = ""
    pendingImages.removeAll()
    pendingPastes.removeAll()
  }

  private func runLabel(_ run: AgentRunRecord) -> String {
    "\(run.completedAt.formatted(date: .omitted, time: .shortened)) · \(run.state.rawValue)"
  }
}

/// Coding agents commonly cite local files as `path:line` or `path:line:column`. Those suffixes
/// are navigation metadata, not part of the filesystem path. Keep parsing deliberately narrow:
/// only trailing positive integers are removed, so ordinary colons inside filenames survive.
struct ArtifactReference: Equatable {
  let path: String
  let line: Int?
  let column: Int?

  static func parse(_ source: String) -> ArtifactReference {
    var path = source
    var trailingNumbers: [Int] = []
    for _ in 0..<2 {
      guard let colon = path.lastIndex(of: ":") else { break }
      let suffix = path[path.index(after: colon)...]
      guard let number = Int(suffix), number > 0 else { break }
      trailingNumbers.append(number)
      path = String(path[..<colon])
    }
    switch trailingNumbers.count {
    case 2:
      return ArtifactReference(path: path, line: trailingNumbers[1], column: trailingNumbers[0])
    case 1:
      return ArtifactReference(path: path, line: trailingNumbers[0], column: nil)
    default:
      return ArtifactReference(path: source, line: nil, column: nil)
    }
  }
}
// CHAT_LAYOUT_BOUNDARY_END

/// Enables native macOS text selection only for immutable transcript rows. Keeping this outside
/// the dynamic chat layout boundary is intentional: live streaming text must not install SwiftUI
/// selection overlays because those overlays can feed back into layout while content is changing.
private struct StableTranscriptSelectionModifier: ViewModifier {
  func body(content: Content) -> some View {
    content.textSelection(.enabled)
  }
}

/// Canvas-styled model and effort picker, mirroring the provider CLIs' own selector: a model
/// list plus a Faster ↔ Smarter effort slider over the provider's documented levels.
private struct ModelPickerPopover: View {
  @Environment(\.ottoPalette) private var palette
  let provider: AgentProvider
  let accountID: () -> UUID?
  private var resolvedAccountID: UUID? { accountID() }
  let model: String?
  let effort: String?
  let setModel: (String?, String?) -> Void

  /// Providers whose catalog is account-specific report it from their own CLI, which takes a
  /// process launch and so cannot be read synchronously while the popover builds. The cache is
  /// shared and usually already warm, so this normally renders the full list immediately.
  @ObservedObject private var catalogStore = ProviderModelCatalogStore.shared

  private var isDiscovering: Bool {
    ProviderModelCatalogStore.isDiscovered(provider)
      && catalogStore.catalog(for: provider, accountID: resolvedAccountID) == nil
  }

  private var options: [AgentModel] {
    catalogStore.catalog(for: provider, accountID: resolvedAccountID)
      ?? (ProviderModelCatalogStore.isDiscovered(provider)
        ? [] : AgentModelCatalog.options(for: provider))
  }
  private var efforts: [String] { AgentModelCatalog.effortLevels(for: provider, modelID: model) }

  @State private var query = ""
  @FocusState private var searchFocused: Bool

  /// A short catalog reads at a glance; past this, OpenCode-sized lists need a search box.
  private static let searchThreshold = 8
  private var showsSearch: Bool { options.count > Self.searchThreshold }
  private var visibleOptions: [AgentModel] { AgentModelCatalog.matching(options, query: query) }
  private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Model")
        .font(.ottoLabel(7, weight: .black))
        .foregroundStyle(palette.signal)
      if showsSearch {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(palette.muted)
          TextField("Search \(options.count) models", text: $query)
            .textFieldStyle(.plain)
            .font(.ottoLabel(8.5))
            .foregroundStyle(palette.paper)
            .focused($searchFocused)
            .onSubmit {
              // Return picks the top match, so typing a name and pressing Return is enough.
              if isFiltering, let first = visibleOptions.first { select(first.id) }
            }
            .accessibilityIdentifier("modelPicker.search")
          if isFiltering {
            Button {
              query = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(palette.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear model search")
          }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(palette.paper.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { searchFocused = true }
      }
      // Discovered catalogs run to dozens of entries, so the list scrolls rather than growing a
      // popover taller than the screen. Short catalogs keep their natural height.
      ScrollView {
        OttoFluidHover(
          axis: .vertical,
          style: OttoFluidHoverStyle(
            fill: palette.paper.opacity(0.06),
            selectedFill: palette.raised.opacity(0.9),
            cornerRadius: 6),
          selected: model ?? ModelPickerPopover.defaultRowID
        ) {
          VStack(alignment: .leading, spacing: 2) {
            if !isFiltering { modelRow(title: "Provider default", id: nil) }
            ForEach(visibleOptions, id: \.id) { option in
              modelRow(title: option.displayName, id: option.id)
            }
            if !isDiscovering && options.isEmpty {
              Text("No model catalog available for this account yet.")
                .font(.ottoLabel(8))
                .foregroundStyle(palette.muted)
            }
            if isFiltering && visibleOptions.isEmpty {
              Text("No models match “\(query)”.")
                .font(.ottoLabel(8))
                .foregroundStyle(palette.muted)
            }
            if ProviderModelCatalogStore.isDiscovered(provider) && !isFiltering {
              Button("Refresh models") {
                catalogStore.load(provider, accountID: resolvedAccountID, force: true)
              }
            }
            // A slug set by voice or the set_model tool may not be in the catalog; keep it
            // visible and selected rather than showing nothing checked.
            if let current = model, !isFiltering, !options.contains(where: { $0.id == current }) {
              modelRow(title: current, id: current)
            }
            // Saying so beats showing a short fallback list that looks like the whole catalog.
            if isDiscovering {
              HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Loading \(provider.rawValue) models…")
                  .font(.ottoLabel(8))
                  .foregroundStyle(palette.muted)
              }
              .padding(.vertical, 3)
            }
          }
          // A discovered catalog arrives after the popover has been sized. Reserving the height up
          // front stops it staying as tall as the handful of fallback rows it opened with.
          .frame(
            maxWidth: .infinity, minHeight: isDiscovering ? 200 : nil, alignment: .leading)
        }
      }
      .ottoScrollChrome(fade: 16)
      .frame(maxHeight: 280)
      .scrollBounceBehavior(.basedOnSize)
      .task(id: catalogStore.request(for: provider, accountID: resolvedAccountID)) {
        await catalogStore.load(provider, accountID: resolvedAccountID, force: true)?.value
      }
      if !efforts.isEmpty {
        Divider().overlay(palette.paper.opacity(0.1))
        HStack {
          Text("Effort")
            .font(.ottoLabel(7, weight: .black))
            .foregroundStyle(palette.signal)
          Spacer()
          Text(effort?.capitalized ?? "Default")
            .font(.ottoLabel(8, weight: .bold))
            .foregroundStyle(palette.paper)
        }
        Slider(
          value: Binding(
            get: {
              Double(effort.flatMap(efforts.firstIndex(of:)) ?? defaultEffortIndex)
            },
            set: { value in
              let index = min(efforts.count - 1, max(0, Int(value.rounded())))
              setModel(model, efforts[index])
            }
          ),
          in: 0...Double(efforts.count - 1),
          step: 1
        )
        HStack {
          Text("Faster")
            .font(.ottoLabel(7))
            .foregroundStyle(palette.muted)
          Spacer()
          if effort != nil {
            Button("Use default") {
              setModel(model, nil)
            }
            .buttonStyle(.plain)
            .font(.ottoLabel(7, weight: .medium))
            .foregroundStyle(palette.muted)
            .underline()
          }
          Spacer()
          Text("Smarter")
            .font(.ottoLabel(7))
            .foregroundStyle(palette.muted)
        }
      }
      Text("Applies from the next run; a live terminal session relaunches with it.")
        .font(.ottoLabel(6.5))
        .foregroundStyle(palette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(width: 240)
    .background(palette.surface)
  }

  /// Where the slider rests while no explicit effort is stored (the provider default).
  private var defaultEffortIndex: Int {
    efforts.firstIndex(of: "medium") ?? efforts.count / 2
  }

  /// The "Provider default" row's hover identity; the selected fill sits on it when no
  /// explicit model is stored.
  fileprivate static let defaultRowID = "otto.model.default"

  private func select(_ id: String?) {
    let nextEfforts = AgentModelCatalog.effortLevels(for: provider, modelID: id)
    setModel(id, effort.flatMap { nextEfforts.contains($0) ? $0 : nil })
  }

  private func modelRow(title: String, id: String?) -> some View {
    Button {
      select(id)
    } label: {
      HStack {
        Text(title)
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.paper)
        Spacer()
        if model == id {
          Image(systemName: "checkmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(palette.signal)
            .transition(.scale(scale: 0.3).combined(with: .opacity))
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .contentShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .ottoHoverItem(id ?? Self.defaultRowID)
  }
}

/// Read-only rendered view of one file the agent touched. Markdown renders through the shared
/// block renderer; everything else shows as monospace source. Reloads whenever the transcript
/// grows so edits the agent just made appear without manual refresh.
private struct AgentFileViewer: View {
  @Environment(\.ottoPalette) private var palette
  let path: String
  let scale: Double
  let refreshKey: Int
  @State private var content: String?
  @State private var failure: String?

  private static let markdownExtensions: Set<String> = ["md", "markdown", "mdx", "txt", ""]
  private static let byteLimit = 262_144

  var body: some View {
    ScrollView {
      Group {
        if let failure {
          Text(failure)
            .font(.ottoMono(max(7, 8.5 * scale)))
            .foregroundStyle(palette.muted)
        } else if let content {
          if Self.markdownExtensions.contains((path as NSString).pathExtension.lowercased()) {
            MarkdownMessageView(text: content, scale: scale, palette: palette)
              .equatable()
          } else {
            Text(content)
              .font(.ottoMono(max(7.5, 9 * scale)))
              .foregroundStyle(palette.paper.opacity(0.92))
              .lineSpacing(2.5 * scale)
              .textSelection(.enabled)
          }
        } else {
          Text("Loading…")
            .font(.ottoMono(max(7, 8.5 * scale)))
            .foregroundStyle(palette.muted)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(14 * scale)
    }
    .scrollIndicators(.hidden)
    .task(id: "\(path)|\(refreshKey)") { load() }
  }

  private func load() {
    failure = nil
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      content = nil
      failure = isDirectory.boolValue ? "This path is a directory." : "File not found: \(path)"
      return
    }
    guard let data = FileManager.default.contents(atPath: path) else {
      content = nil
      failure = "Could not read \(path)"
      return
    }
    let bounded = data.prefix(Self.byteLimit)
    var text = String(decoding: bounded, as: UTF8.self)
    if data.count > Self.byteLimit {
      text += "\n\n… truncated (\(data.count) bytes total)"
    }
    content = text
  }
}

/// Separates the user's visible message from Otto's provider-only attachment instruction. The
/// latter stays in the runtime prompt so coding agents can open the local files, while the chat
/// transcript renders the files as images instead of leaking implementation text.
private struct ChatPromptContent {
  let text: String
  let imagePaths: [String]
  let pastes: [String]

  init(_ source: String) {
    let images = Self.splitImages(source)
    let split = ChatPastedText.decompose(images.text)
    text = split.text
    imagePaths = images.imagePaths
    pastes = split.pastes
  }

  private static func splitImages(_ source: String) -> (text: String, imagePaths: [String]) {
    let marker = "[The user attached "
    guard let markerRange = source.range(of: marker, options: .backwards) else {
      return (source, [])
    }
    let metadata = source[markerRange.lowerBound...]
    guard metadata.hasSuffix("]"),
      metadata.contains("View each one with your image or file reading tool before answering:"),
      let firstLineEnd = metadata.firstIndex(of: "\n")
    else {
      return (source, [])
    }
    let listingStart = metadata.index(after: firstLineEnd)
    let listingEnd = metadata.index(before: metadata.endIndex)
    let paths = metadata[listingStart..<listingEnd]
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> String? in
        guard line.hasPrefix("- ") else { return nil }
        return String(line.dropFirst(2))
      }
    guard !paths.isEmpty else {
      return (source, [])
    }
    let text = String(source[..<markerRange.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (text, paths)
  }
}

enum ChatComposerKeyAction: Equatable {
  case pasteImage
  case pasteLargeText
  case insertLineBreak
}

enum MentionPickerPolicy {
  static func movedIndex(from index: Int, delta: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return (index + delta % count + count) % count
  }
}

enum ChatComposerKeyPolicy {
  static func action(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifiers: NSEvent.ModifierFlags,
    pasteboardContainsImage: Bool,
    pasteboardContainsLargeText: Bool = false
  ) -> ChatComposerKeyAction? {
    let significantModifiers = modifiers.intersection([.command, .option, .control, .shift])
    let isReturn = keyCode == 36 || keyCode == 76 || charactersIgnoringModifiers == "\r"
    if isReturn, significantModifiers == [.shift] { return .insertLineBreak }

    let isPaste =
      significantModifiers == [.command]
      && charactersIgnoringModifiers?.lowercased() == "v"
    if isPaste, pasteboardContainsImage { return .pasteImage }
    if isPaste, pasteboardContainsLargeText { return .pasteLargeText }
    return nil
  }
}

/// Intercepts composer shortcuts before AppKit's private field editor consumes them. Every
/// composer owns one monitor, but only the focused composer's instance is enabled. Unhandled
/// events pass through untouched, preserving ordinary editing and plain-Return submission. A nil
/// `onPasteImage` leaves image paste to the field, for composers that do not accept images.
struct ChatComposerKeyMonitor: NSViewRepresentable {
  @Environment(\.ottoSpaceVisible) private var spaceVisible
  let isEnabled: Bool
  var onPasteImage: (() -> Void)? = nil
  let onPasteLargeText: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.update(
      isEnabled: isEnabled && spaceVisible, onPasteImage: onPasteImage,
      onPasteLargeText: onPasteLargeText)
    context.coordinator.install()
    return NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.update(
      isEnabled: isEnabled && spaceVisible, onPasteImage: onPasteImage,
      onPasteLargeText: onPasteLargeText)
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator: NSObject {
    private var monitor: Any?
    private var isEnabled = false
    private var onPasteImage: (() -> Void)?
    private var onPasteLargeText: (() -> Void)?

    func update(
      isEnabled: Bool, onPasteImage: (() -> Void)?, onPasteLargeText: @escaping () -> Void
    ) {
      self.isEnabled = isEnabled
      self.onPasteImage = onPasteImage
      self.onPasteLargeText = onPasteLargeText
    }

    func install() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, self.isEnabled, let action = self.action(for: event) else { return event }
        switch action {
        case .pasteImage:
          guard let onPaste = self.onPasteImage else { return event }
          DispatchQueue.main.async { onPaste() }
          return nil
        case .pasteLargeText:
          let onPaste = self.onPasteLargeText
          DispatchQueue.main.async { onPaste?() }
          return nil
        case .insertLineBreak:
          guard let editor = event.window?.firstResponder as? NSTextView else { return event }
          editor.insertNewlineIgnoringFieldEditor(nil)
          return nil
        }
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    private func action(for event: NSEvent) -> ChatComposerKeyAction? {
      // Only Command-V pays for a pasteboard read; every other key passes straight through.
      let isCommandV =
        event.modifierFlags.contains(.command)
        && event.charactersIgnoringModifiers?.lowercased() == "v"
      let isImagePaste = isCommandV && Self.pasteboardContainsImage()
      let isLargeTextPaste =
        isCommandV && !isImagePaste
        && (NSPasteboard.general.string(forType: .string).map(ChatPastedText.shouldAttach) ?? false)
      return ChatComposerKeyPolicy.action(
        keyCode: event.keyCode,
        charactersIgnoringModifiers: event.charactersIgnoringModifiers,
        modifiers: event.modifierFlags,
        pasteboardContainsImage: isImagePaste,
        pasteboardContainsLargeText: isLargeTextPaste
      )
    }

    private static func pasteboardContainsImage() -> Bool {
      let pasteboard = NSPasteboard.general
      if NSImage(pasteboard: pasteboard) != nil { return true }
      guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
        return false
      }
      let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "webp", "heic"]
      return urls.contains { imageExtensions.contains($0.pathExtension.lowercased()) }
    }
  }
}

/// Native SwiftUI adaptation of Thinking Orbs' `composing` state: a softly tilted dotted sphere
/// crossed by several ribbon lanes whose waves travel in opposite directions. This is the state
/// labelled “Thinking…” in the reference. Reduce Motion renders one representative still frame.
private struct ThinkingIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.ottoWindowIsActive) private var windowIsActive
  let scale: Double
  let color: Color

  private var diameter: Double { 64 * scale }

  var body: some View {
    CompositorThinkingOrb(color: color, isAnimating: windowIsActive && !reduceMotion)
      .frame(width: diameter, height: diameter)
      .accessibilityLabel("Agent is thinking")
  }
}

/// Pre-renders one seamless cycle and lets Core Animation swap those textures on the render
/// server. Unlike a SwiftUI TimelineView, this never invalidates the conversation layout per
/// frame, so the organic ribbon motion can remain without waking GeometryReader/LazyVStack.
private struct CompositorThinkingOrb: NSViewRepresentable {
  let color: Color
  let isAnimating: Bool

  func makeNSView(context: Context) -> ThinkingOrbNSView {
    let view = ThinkingOrbNSView()
    view.configure(color: NSColor(color), isAnimating: isAnimating)
    return view
  }

  func updateNSView(_ view: ThinkingOrbNSView, context: Context) {
    view.configure(color: NSColor(color), isAnimating: isAnimating)
  }

  static func dismantleNSView(_ view: ThinkingOrbNSView, coordinator: Void) {
    view.stopAnimating()
  }
}

private final class ThinkingOrbNSView: NSView {
  private struct Dot {
    let point: CGPoint
    let depth: Double
    let radius: Double
    let opacity: Double
  }

  private static let frameCount = 72
  private static let cycleDuration = 3.0
  private var orbColor = NSColor.white
  private var requestedAnimation = false
  private var renderedPixelSize = 0
  private var renderedColor: [CGFloat] = []
  private var frames: [CGImage] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    layer?.contentsGravity = .resizeAspect
    layer?.minificationFilter = .linear
    layer?.magnificationFilter = .linear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var isOpaque: Bool { false }

  override func layout() {
    super.layout()
    rebuildFramesIfNeeded()
  }

  func configure(color: NSColor, isAnimating: Bool) {
    let resolved = color.usingColorSpace(.deviceRGB) ?? color
    let components = [
      resolved.redComponent, resolved.greenComponent, resolved.blueComponent,
      resolved.alphaComponent,
    ]
    if components != renderedColor {
      orbColor = resolved
      renderedPixelSize = 0
    }
    requestedAnimation = isAnimating
    rebuildFramesIfNeeded()
    applyAnimationState()
  }

  func stopAnimating() {
    requestedAnimation = false
    layer?.removeAnimation(forKey: "thinking-orb-frames")
  }

  private func rebuildFramesIfNeeded() {
    guard bounds.width > 0, bounds.height > 0, let layer else { return }
    let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let pointSize = min(bounds.width, bounds.height)
    let pixelSize = max(1, Int(ceil(pointSize * backingScale)))
    let components = [
      orbColor.redComponent, orbColor.greenComponent, orbColor.blueComponent,
      orbColor.alphaComponent,
    ]
    guard pixelSize != renderedPixelSize || components != renderedColor else { return }

    frames = (0..<Self.frameCount).compactMap { index in
      let phase = Double(index) / Double(Self.frameCount) * 2 * Double.pi
      return renderFrame(pointSize: pointSize, pixelSize: pixelSize, phase: phase)
    }
    renderedPixelSize = pixelSize
    renderedColor = components
    layer.contentsScale = backingScale
    layer.contents = frames.first
    applyAnimationState()
  }

  private func applyAnimationState() {
    guard let layer, !frames.isEmpty else { return }
    if requestedAnimation {
      guard layer.animation(forKey: "thinking-orb-frames") == nil else { return }
      let animation = CAKeyframeAnimation(keyPath: "contents")
      animation.values = frames
      animation.calculationMode = .discrete
      animation.duration = Self.cycleDuration
      animation.repeatCount = .infinity
      animation.isRemovedOnCompletion = false
      layer.add(animation, forKey: "thinking-orb-frames")
    } else {
      layer.removeAnimation(forKey: "thinking-orb-frames")
      layer.contents = frames.first
    }
  }

  private func renderFrame(pointSize: Double, pixelSize: Int, phase: Double) -> CGImage? {
    guard
      let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    let pixelScale = Double(pixelSize) / pointSize
    context.scaleBy(x: pixelScale, y: pixelScale)
    for dot in makeDots(size: pointSize, phase: phase).sorted(by: { $0.depth < $1.depth }) {
      context.setFillColor(orbColor.withAlphaComponent(dot.opacity).cgColor)
      context.fillEllipse(
        in: CGRect(
          x: dot.point.x - dot.radius,
          y: dot.point.y - dot.radius,
          width: dot.radius * 2,
          height: dot.radius * 2
        ))
    }
    return context.makeImage()
  }

  private func makeDots(size: Double, phase: Double) -> [Dot] {
    let center = size / 2
    let sphereRadius = center * 0.78
    let cameraTilt = 0.3
    let sinTilt = sin(cameraTilt)
    let cosTilt = cos(cameraTilt)
    let bandTilt = 0.55
    let sinBand = sin(bandTilt)
    let cosBand = cos(bandTilt)
    let radiusScale = pow(size / 300, 0.6)
    var dots: [Dot] = []

    func project(_ x: Double, _ y: Double, _ z: Double) -> (CGPoint, Double) {
      let projectedY = y * cosTilt - z * sinTilt
      let projectedZ = y * sinTilt + z * cosTilt
      return (CGPoint(x: center + x, y: center - projectedY), projectedZ)
    }

    // A sparse ghost sphere gives the moving ribbons a quiet volume without becoming a spinner.
    let ghostCount = 38
    let goldenAngle = Double.pi * (3 - sqrt(5))
    for index in 0..<ghostCount {
      let y = 1 - (2 * (Double(index) + 0.5)) / Double(ghostCount)
      let radial = sqrt(max(0, 1 - y * y))
      let angle = Double(index) * goldenAngle
      let (point, depthZ) = project(
        radial * cos(angle) * sphereRadius,
        y * sphereRadius,
        radial * sin(angle) * sphereRadius
      )
      let depth = min(1, max(0, (depthZ / sphereRadius + 1) / 2))
      dots.append(
        Dot(
          point: point,
          depth: depthZ,
          radius: max(0.3, 0.8 * radiusScale),
          opacity: 0.1 + 0.22 * depth
        ))
    }

    // Parallel lanes form the characteristic Thinking/Composing sash. Two travelling waves
    // keep the silhouette organic while the sphere's orientation itself remains calm.
    let laneCount = 12
    let segmentCount = 44
    for lane in 0..<laneCount {
      let lanePosition = Double(lane) - Double(laneCount - 1) / 2
      let laneOffset = lanePosition * 0.075
      let edge = abs(lanePosition) / max(1, Double(laneCount - 1) / 2)
      for segment in 0..<segmentCount {
        let angle = Double(segment) / Double(segmentCount) * 2 * Double.pi
        let wobble =
          0.16 * sin(angle * 3 - phase + Double(lane) * 0.22)
          + 0.07 * sin(angle * 5 + phase * 2)
        let offset = laneOffset + wobble

        // Fixed band basis: u=(1,0,0), v=(0,cos(tilt),sin(tilt)),
        // n=(0,-sin(tilt),cos(tilt)).
        let x = cos(angle)
        let y = cosBand * sin(angle) - sinBand * offset
        let z = sinBand * sin(angle) + cosBand * offset
        let length = max(0.000_001, sqrt(x * x + y * y + z * z))
        let (point, depthZ) = project(
          x / length * sphereRadius,
          y / length * sphereRadius,
          z / length * sphereRadius
        )
        let depth = min(1, max(0, (depthZ / sphereRadius + 1) / 2))
        dots.append(
          Dot(
            point: point,
            depth: depthZ,
            radius: max(0.3, (0.935 + 1.445 * depth) * (1 - 0.25 * edge) * radiusScale),
            opacity: (0.4 + 0.6 * depth) * (1 - 0.12 * edge)
          ))
      }
    }

    return dots
  }
}

/// Full-diff review for one completed turn: every changed file as a disclosure row whose
/// unified diff loads on first expansion. Colouring follows the diff itself — additions in
/// signal, deletions in red, hunk headers muted — over the theme's opaque surfaces.
/// Full review surface, per the design's ReviewPanel: header with turn scope and totals, a
/// changed-files rail, and a diff pane with collapsed unmodified-line bars, line numbers, and
/// signal/red tinted change rows. Diffs load lazily for the selected file.
struct TurnReviewSheet: View {
  @Environment(\.ottoPalette) private var palette
  let summary: TurnChangeSummary
  let turnDiff: (String?) async -> String?
  let initialPath: String?
  let close: () -> Void

  @State private var selectedPath: String?
  @State private var diffs: [String: String] = [:]

  private var activePath: String? {
    selectedPath
      ?? initialPath.flatMap { initial in
        summary.files.contains(where: { $0.path == initial }) ? initial : nil
      }
      ?? summary.files.first?.path
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(palette.paper.opacity(0.06))
      HStack(spacing: 0) {
        fileRail
        Divider().overlay(palette.paper.opacity(0.06))
        diffPane
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.surface)
  }

  private var header: some View {
    HStack(spacing: 14) {
      Text("Review").font(.ottoDisplay(15)).foregroundStyle(palette.paper)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Last turn")
          .font(.ottoLabel(8, weight: .black))
          .foregroundStyle(palette.muted)
        diffStat(summary.totalAdditions, summary.totalDeletions, size: 10)
      }
      Spacer()
      Button {
        close()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(palette.muted)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .accessibilityLabel("Close review")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  private func diffStat(_ adds: Int, _ dels: Int, size: Double) -> some View {
    HStack(spacing: 6) {
      Text("+\(adds)").font(.ottoMono(size, weight: .bold)).foregroundStyle(palette.signal)
      Text("−\(dels)").font(.ottoMono(size, weight: .bold)).foregroundStyle(palette.red)
    }
  }

  private var fileRail: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 1) {
        Text("Changed files")
          .font(.ottoLabel(6.5, weight: .black))
          .foregroundStyle(palette.muted)
          .padding(.horizontal, 8)
          .padding(.top, 4)
          .padding(.bottom, 6)
        ForEach(summary.files) { file in
          fileRow(file)
        }
      }
      .padding(8)
    }
    .frame(width: 230)
  }

  private func fileRow(_ file: TurnFileChange) -> some View {
    let isActive = file.path == activePath
    let base = (file.path as NSString).lastPathComponent
    return Button {
      selectedPath = file.path
    } label: {
      HStack(spacing: 8) {
        Text(base)
          .font(.ottoMono(9, weight: isActive ? .bold : .regular))
          .foregroundStyle(isActive ? palette.paper : palette.muted)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 6)
        diffStat(file.additions ?? 0, file.deletions ?? 0, size: 8)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        palette.paper.opacity(isActive ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7)
      )
      .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .help(file.path)
    .accessibilityLabel("Show diff for \(file.path)")
  }

  @ViewBuilder private var diffPane: some View {
    if let path = activePath {
      Group {
        if let diff = diffs[path] {
          if diff.isEmpty {
            Text("Diff unavailable — the checkpoint refs may have been pruned.")
              .font(.ottoMono(8.5))
              .foregroundStyle(palette.muted)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView([.vertical, .horizontal]) {
              LazyVStack(alignment: .leading, spacing: 0) {
                Text(path)
                  .font(.ottoMono(9.5, weight: .bold))
                  .foregroundStyle(palette.muted)
                  .padding(.horizontal, 16)
                  .padding(.vertical, 6)
                ForEach(Self.parse(diff)) { element in
                  diffElementRow(element)
                }
              }
              .padding(.vertical, 8)
              .textSelection(.enabled)
            }
          }
        } else {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading diff…").font(.ottoMono(8.5)).foregroundStyle(palette.muted)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(palette.raised.opacity(0.55))
      .task(id: path) {
        if diffs[path] == nil { diffs[path] = await turnDiff(path) ?? "" }
      }
    } else {
      Text("No changed files in this turn.")
        .font(.ottoMono(9))
        .foregroundStyle(palette.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.raised.opacity(0.55))
    }
  }

  @ViewBuilder private func diffElementRow(_ element: DiffElement) -> some View {
    switch element {
    case .collapse(_, let count):
      Text("\(count) unmodified line\(count == 1 ? "" : "s")")
        .font(.ottoMono(8.5))
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .frame(minWidth: 620, maxWidth: .infinity, alignment: .leading)
        .background(palette.ink.opacity(0.35))
        .padding(.vertical, 4)
    case .row(let row):
      HStack(alignment: .top, spacing: 14) {
        Text(row.number > 0 ? "\(row.number)" : "")
          .font(.ottoMono(9))
          .foregroundStyle(palette.muted)
          .frame(width: 34, alignment: .trailing)
        Text(row.text.isEmpty ? " " : row.text)
          .font(.ottoMono(9.5))
          .foregroundStyle(palette.paper)
          .strikethrough(row.kind == .del)
          .opacity(row.kind == .del ? 0.65 : 1)
          .fixedSize(horizontal: true, vertical: false)
      }
      .padding(.leading, 14)
      .padding(.trailing, 16)
      .padding(.vertical, 1.5)
      .frame(minWidth: 620, maxWidth: .infinity, alignment: .leading)
      .background(rowFill(row.kind))
      .overlay(alignment: .leading) {
        Rectangle().fill(rowEdge(row.kind)).frame(width: 2)
      }
    }
  }

  private func rowFill(_ kind: DiffRowKind) -> Color {
    switch kind {
    case .add: palette.signal.opacity(0.09)
    case .del: palette.red.opacity(0.08)
    case .ctx: .clear
    }
  }

  private func rowEdge(_ kind: DiffRowKind) -> Color {
    switch kind {
    case .add: palette.signal
    case .del: palette.red
    case .ctx: .clear
    }
  }

  private enum DiffRowKind { case add, del, ctx }

  private struct DiffRow {
    let kind: DiffRowKind
    let number: Int
    let text: String
  }

  private enum DiffElement: Identifiable {
    case row(DiffRow)
    case collapse(Int, Int)

    var id: Int {
      switch self {
      case .row(let row): row.number * 4 + rawKind(row.kind)
      case .collapse(let id, _): -id - 1
      }
    }

    private func rawKind(_ kind: DiffRowKind) -> Int {
      switch kind {
      case .add: 0
      case .del: 1
      case .ctx: 2
      }
    }
  }

  /// Renders a unified diff as numbered rows with collapse bars for the unmodified spans
  /// between hunks. Adds and context carry new-file numbers; deletions carry old-file numbers.
  private static func parse(_ diff: String) -> [DiffElement] {
    var elements: [DiffElement] = []
    var oldLine = 0
    var newLine = 0
    var sawHunk = false
    var index = 0
    var lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    for raw in lines {
      index += 1
      let line = String(raw)
      if line.hasPrefix("@@") {
        let parts = line.split(separator: " ")
        let newStart =
          parts.first { $0.hasPrefix("+") }
          .flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 1
        let oldStart =
          parts.first { $0.hasPrefix("-") }
          .flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 1
        let gap = newStart - (sawHunk ? newLine : 1)
        if gap > 0 { elements.append(.collapse(index, gap)) }
        oldLine = oldStart
        newLine = newStart
        sawHunk = true
        continue
      }
      if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ")
        || line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted")
        || line.hasPrefix("\\")
      {
        continue
      }
      guard sawHunk else { continue }
      if line.hasPrefix("+") {
        elements.append(.row(DiffRow(kind: .add, number: newLine, text: String(line.dropFirst()))))
        newLine += 1
      } else if line.hasPrefix("-") {
        elements.append(.row(DiffRow(kind: .del, number: oldLine, text: String(line.dropFirst()))))
        oldLine += 1
      } else {
        let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
        elements.append(.row(DiffRow(kind: .ctx, number: newLine, text: text)))
        oldLine += 1
        newLine += 1
      }
    }
    return elements
  }
}

/// One suggested opener for a blank agent card.
/// Pulses on its AppKit backing layer so the working label never publishes SwiftUI state.
private struct ShimmerWord: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let text: String
  let size: Double

  var body: some View {
    PulsingTextLabel(
      text: text,
      size: size,
      color: palette.paper,
      isAnimating: !reduceMotion
    )
    .fixedSize()
  }
}

private struct PulsingTextLabel: NSViewRepresentable {
  let text: String
  let size: Double
  let color: Color
  let isAnimating: Bool

  func makeNSView(context: Context) -> PulsingTextField {
    let field = PulsingTextField(labelWithString: text)
    field.configure(text: text, size: size, color: NSColor(color), isAnimating: isAnimating)
    return field
  }

  func updateNSView(_ field: PulsingTextField, context: Context) {
    field.configure(text: text, size: size, color: NSColor(color), isAnimating: isAnimating)
  }

  static func dismantleNSView(_ field: PulsingTextField, coordinator: Void) {
    field.layer?.removeAnimation(forKey: "working-pulse")
  }
}

private final class PulsingTextField: NSTextField {
  private var animationRequested = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isEditable = false
    isSelectable = false
    isBordered = false
    drawsBackground = false
    wantsLayer = true
    lineBreakMode = .byClipping
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func configure(text: String, size: Double, color: NSColor, isAnimating: Bool) {
    stringValue = text
    textColor = color
    _ = OttoFonts.registered
    font = NSFont(name: "Inter Variable", size: size) ?? NSFont.systemFont(ofSize: size)
    animationRequested = isAnimating
    applyAnimationState()
  }

  private func applyAnimationState() {
    guard let layer else { return }
    if animationRequested {
      guard layer.animation(forKey: "working-pulse") == nil else { return }
      let animation = CABasicAnimation(keyPath: "opacity")
      animation.fromValue = 0.28
      animation.toValue = 0.92
      animation.duration = 1.2
      animation.autoreverses = true
      animation.repeatCount = .infinity
      animation.isRemovedOnCompletion = false
      layer.add(animation, forKey: "working-pulse")
    } else {
      layer.removeAnimation(forKey: "working-pulse")
      layer.opacity = 0.72
    }
  }
}

/// Owns its one-second timer inside AppKit. Updating the string redraws this fixed-width native
/// field only; it cannot invalidate or remeasure the SwiftUI transcript.
private struct WorkingElapsedLabel: NSViewRepresentable {
  let startedAt: Date
  let providerName: String
  let size: Double
  let color: Color

  func makeNSView(context: Context) -> WorkingElapsedTextField {
    let field = WorkingElapsedTextField(labelWithString: "")
    field.configure(
      startedAt: startedAt,
      providerName: providerName,
      size: size,
      color: NSColor(color)
    )
    return field
  }

  func updateNSView(_ field: WorkingElapsedTextField, context: Context) {
    field.configure(
      startedAt: startedAt,
      providerName: providerName,
      size: size,
      color: NSColor(color)
    )
  }

  static func dismantleNSView(_ field: WorkingElapsedTextField, coordinator: Void) {
    field.stopTimer()
  }
}

private final class WorkingElapsedTextField: NSTextField {
  private var timer: Timer?
  private var startedAt = Date.now
  private var providerName = ""

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isEditable = false
    isSelectable = false
    isBordered = false
    drawsBackground = false
    lineBreakMode = .byTruncatingTail
    maximumNumberOfLines = 1
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func configure(startedAt: Date, providerName: String, size: Double, color: NSColor) {
    let timerInputsChanged = self.startedAt != startedAt || self.providerName != providerName
    self.startedAt = startedAt
    self.providerName = providerName
    font = .monospacedSystemFont(ofSize: size, weight: .regular)
    textColor = color
    updateText()
    if timer == nil || timerInputsChanged { startTimer() }
  }

  func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func startTimer() {
    stopTimer()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateText() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func updateText() {
    let seconds = max(0, Int(Date.now.timeIntervalSince(startedAt)))
    stringValue = "\(seconds)s · \(providerName)"
  }
}
