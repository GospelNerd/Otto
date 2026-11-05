import Foundation
import OttoBrowser
import OttoCore
import OttoDocuments
import OttoMedia
import OttoMemory
import OttoModels
import OttoRuntime
import OttoTools
import OttoWorktrees

#if canImport(AppKit)
  import AppKit
#endif

public enum ApplicationToolBootstrap {
  public static func register(
    in registry: ToolRegistry,
    store: CanvasStore,
    supervisor: AgentSupervisor,
    documents: WorkspaceDocumentStore? = nil,
    browserRuntime: BrowserRuntime = BrowserRuntime(),
    mediaRuntime: MediaRuntime = MediaRuntime(),
    workspacePath: String = FileManager.default.currentDirectoryPath,
    canvasRecorder: CanvasRecorder? = nil,
    worktrees: GitWorktreeManager? = nil,
    worktreeSessions: WorktreeSessionStore = WorktreeSessionStore(),
    orchestration: OrchestrationRunStore? = nil,
    externalOpener: ExternalURLOpener? = nil,
    agentBrowserOpenHandler: AgentBrowserOpenHandler? = nil,
    brain: ProjectBrainStore? = nil,
    projectContext: (@Sendable (ToolContext) async -> ConversationProjectContext?)? = nil,
    projectDocumentPath: ProjectDocumentPathResolver? = nil,
    brainResolver: (@Sendable (ToolContext) async throws -> ProjectBrainStore)? = nil,
    personalMemory: CompactMemoryStore? = nil,
    operatingMemory: CompactMemoryStore? = nil,
    memoryInbox: CompactMemoryInbox? = nil,
    subagentResolver: BotSubagentResolver? = nil,
    accountBoundary: AgentAccountBoundary? = nil,
    emailOriginal: EmailApprovalSummary.OriginalLookup? = nil,
    desktopControl: (any DesktopCommandRunning)? = nil
  ) async throws {
    let worktreeManager = worktrees ?? GitWorktreeManager(repositoryPath: workspacePath)
    let orchestration = orchestration ?? .live(workspacePath: workspacePath)
    try await registry.register(NodeListTool(store: store))
    try await registry.register(NodeGetTool(store: store))
    try await registry.register(NodeFocusTool(store: store))
    try await registry.register(NodeExpandTool(store: store))
    try await registry.register(NodeCreateTool(store: store))
    try await registry.register(NodeCloseTool(store: store, supervisor: supervisor))
    try await registry.register(NodeCloseAllTool(store: store, supervisor: supervisor))
    try await registry.register(AgentSpawnMockTool(store: store, supervisor: supervisor))
    try await registry.register(AgentProvidersTool())
    // One shared throttle so agent-initiated spawning and prompting is bounded across all
    // three entry points, not per tool instance.
    let agentControlThrottle = AgentControlThrottle()
    try await registry.register(
      AgentSpawnTool(
        store: store,
        supervisor: supervisor,
        workspacePath: workspacePath,
        worktrees: worktreeManager,
        worktreeSessions: worktreeSessions,
        throttle: agentControlThrottle,
        accountBoundary: accountBoundary,
        subagentResolver: subagentResolver
      ))
    try await registry.register(
      AgentResumeTool(
        supervisor: supervisor,
        store: store,
        workspacePath: workspacePath,
        worktreeSessions: worktreeSessions,
        throttle: agentControlThrottle
      ))
    try await registry.register(
      AgentSendPromptTool(
        supervisor: supervisor,
        store: store,
        workspacePath: workspacePath,
        worktreeSessions: worktreeSessions,
        throttle: agentControlThrottle,
        accountBoundary: accountBoundary
      ))
    try await registry.register(AgentSendInputTool(supervisor: supervisor))
    try await registry.register(AgentInterruptTool(supervisor: supervisor))
    try await registry.register(AgentStopTool(supervisor: supervisor))
    try await registry.register(
      AgentRestartTool(
        store: store,
        supervisor: supervisor,
        worktreeSessions: worktreeSessions
      ))
    try await registry.register(AgentGetStatusTool(supervisor: supervisor))
    try await registry.register(
      AgentRequestPermissionTool(supervisor: supervisor, emailOriginal: emailOriginal))
    try await registry.register(AgentAskUserTool(supervisor: supervisor))
    try await registry.register(AgentGetOutputTool(supervisor: supervisor))
    try await registry.register(AgentSetModelTool(store: store))
    try await registry.register(AgentSetExecutionStrategyTool(store: store))
    // Phase 6 memory layer: the Project Brain and compact stores default to the workspace's
    // .otto/ locations so a bare register() call (tests, ottod) still gets working memory tools.
    let brainStore: ProjectBrainStore?
    if let brain {
      brainStore = brain
    } else {
      brainStore = try ProjectBrainStore(
        rootPath: (workspacePath as NSString).appendingPathComponent(".otto/brain"),
        project: (workspacePath as NSString).lastPathComponent)
    }
    // Registered here rather than with its sibling agent tools: reading a delegated result is
    // what completes a handoff, so this tool needs the brain to record one.
    try await registry.register(
      ContextualTool { context in
        AgentGetResultTool(
          supervisor: supervisor,
          brain: brainResolver == nil ? brainStore : (try? await brainResolver?(context)))
      })
    if let brainStore {
      // Writes maintain the existing index. An unconditional background rebuild still holds
      // the Brain actor while reading cloud files, blocking startup's memory migration and
      // every bot bootstrap behind it. Missing/outdated indexes rebuild on the first search.
      let personal =
        personalMemory
        ?? CompactMemoryStore(
          filePath: (workspacePath as NSString).appendingPathComponent(".otto/user.md"),
          title: "User context", budget: .personal)
      let operating =
        operatingMemory
        ?? CompactMemoryStore(
          filePath: (workspacePath as NSString).appendingPathComponent(".otto/memory.md"),
          title: "Operating memory", budget: .operating)
      let inbox =
        memoryInbox
        ?? CompactMemoryInbox(
          filePath: (workspacePath as NSString).appendingPathComponent(".otto/memory-inbox.json"))
      try await registry.register(
        ContextualTool { context in
          MemorySearchTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        ContextualTool { context in
          MemoryFetchTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        ContextualTool { context in
          MemoryContextPackTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        ContextualTool { context in
          BrainListTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        ContextualTool { context in
          BrainAppendLogTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        ContextualTool { context in
          BrainWriteRecordTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        ContextualTool { context in
          MemoryConfirmTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        ContextualTool { context in
          MemoryArchiveTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        ContextualTool { context in
          MemorySupersedeTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        ContextualTool { context in
          MemoryFeedbackTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        ContextualTool { context in
          MemoryDeleteTool(brain: try await brainResolver?(context) ?? brainStore)
        })
      try await registry.register(
        MemoryProposeTool(inbox: inbox, personal: personal, operating: operating))
      try await registry.register(MemoryBudgetTool(personal: personal, operating: operating))
      try await registry.register(
        ContextualTool { context in
          ReportCompleteTool(brain: try await brainResolver?(context) ?? brainStore)
        })
    }
    try await registry.register(OrchestrationReadTool(store: orchestration))
    try await registry.register(
      OrchestrationCreateTool(store: orchestration, projectContext: projectContext))
    try await registry.register(OrchestrationBeginWorkersTool(store: orchestration))
    try await registry.register(OrchestrationClaimAssignmentTool(store: orchestration))
    try await registry.register(OrchestrationReportAssignmentTool(store: orchestration))
    try await registry.register(OrchestrationSubmitReviewTool(store: orchestration))
    try await registry.register(OrchestrationCancelTool(store: orchestration))
    try await registry.register(OrchestrationReportQuotaTool(store: orchestration))
    try await registry.register(OrchestrationRecordSpendTool(store: orchestration))
    try await registry.register(OrchestrationAuthorizeTool(store: orchestration))
    try await registry.register(OrchestrationBindWorktreeTool(store: orchestration))
    try await registry.register(OrchestrationClaimMergeOwnerTool(store: orchestration))
    try await registry.register(
      TerminalOpenTool(
        store: store,
        supervisor: supervisor,
        workspacePath: workspacePath
      ))
    try await registry.register(
      TerminalRunTool(
        store: store,
        supervisor: supervisor,
        workspacePath: workspacePath
      ))
    try await registry.register(TerminalSendInputTool(supervisor: supervisor))
    try await registry.register(TerminalSendBytesTool(supervisor: supervisor))
    try await registry.register(TerminalResizeTool(supervisor: supervisor))
    try await registry.register(TerminalReadOutputTool(supervisor: supervisor))
    try await registry.register(TerminalWaitTool(supervisor: supervisor))
    try await registry.register(TerminalStopProcessTool(supervisor: supervisor))
    let browserOpenGate = BrowserOpenGate()
    try await registry.register(
      BrowserOpenTool(
        store: store,
        runtime: browserRuntime,
        gate: browserOpenGate,
        agentOpenHandler: agentBrowserOpenHandler
      ))
    try await registry.register(
      BrowserOpenTabTool(
        store: store,
        runtime: browserRuntime,
        gate: browserOpenGate,
        agentOpenHandler: agentBrowserOpenHandler
      ))
    try await registry.register(BrowserGetSelectionTool(store: store, runtime: browserRuntime))
    try await registry.register(BrowserNavigateTool(store: store, runtime: browserRuntime))
    try await registry.register(BrowserRefreshTool(store: store, runtime: browserRuntime))
    try await registry.register(BrowserBackTool(store: store, runtime: browserRuntime))
    try await registry.register(BrowserForwardTool(store: store, runtime: browserRuntime))
    try await registry.register(BrowserGetStateTool(store: store, runtime: browserRuntime))
    try await registry.register(BrowserInspectTool(store: store, runtime: browserRuntime))
    try await registry.register(BrowserClickTool(store: store, runtime: browserRuntime))
    try await registry.register(BrowserTypeTool(store: store, runtime: browserRuntime))
    try await registry.register(BrowserScrollTool(store: store, runtime: browserRuntime))
    try await registry.register(
      BrowserScreenshotTool(store: store, runtime: browserRuntime, workspacePath: workspacePath))
    try await registry.register(
      BrowserOpenExternalTool(opener: externalOpener ?? defaultExternalOpener))
    let desktop: any DesktopCommandRunning = desktopControl ?? AgentDesktopRunner()
    try await registry.register(DesktopStatusTool(runner: desktop))
    try await registry.register(DesktopAppsTool(runner: desktop))
    try await registry.register(DesktopLaunchTool(runner: desktop))
    try await registry.register(DesktopSnapshotTool(runner: desktop))
    try await registry.register(DesktopFindTool(runner: desktop))
    try await registry.register(DesktopGetTool(runner: desktop))
    try await registry.register(DesktopClickTool(runner: desktop))
    try await registry.register(DesktopTypeTool(runner: desktop))
    try await registry.register(DesktopActTool(runner: desktop))
    try await registry.register(DesktopScrollTool(runner: desktop))
    try await registry.register(DesktopPressTool(runner: desktop))
    try await registry.register(DesktopWaitTool(runner: desktop))
    try await registry.register(DesktopScreenshotTool(runner: desktop, workspacePath: workspacePath))
    try await registry.register(WorkspaceSurfaceSetTool(store: store))
    try await registry.register(ThemeListTool())
    try await registry.register(ThemeSetTool(store: store))
    try await registry.register(ThemeSetFontScaleTool())
    try await registry.register(ThemeSetMatteOpacityTool())
    try await registry.register(AgentSetNamingTool())
    try await registry.register(AgentSetPermissionDefaultTool())
    try await registry.register(AgentSetDefaultViewTool())
    try await registry.register(
      MediaOpenTool(
        store: store,
        runtime: mediaRuntime,
        workspacePath: workspacePath
      ))
    try await registry.register(MediaPlayTool(store: store, runtime: mediaRuntime))
    try await registry.register(MediaPauseTool(store: store, runtime: mediaRuntime))
    try await registry.register(MediaStopTool(store: store, runtime: mediaRuntime))
    try await registry.register(MediaSetVolumeTool(store: store, runtime: mediaRuntime))
    try await registry.register(MediaSeekTool(store: store, runtime: mediaRuntime))
    if let canvasRecorder {
      try await registry.register(
        RecordingStartTool(recorder: canvasRecorder, workspacePath: workspacePath))
      try await registry.register(
        RecordingStopTool(recorder: canvasRecorder, store: store, mediaRuntime: mediaRuntime))
      try await registry.register(RecordingStatusTool(recorder: canvasRecorder))
    }
    try await registry.register(EventWaitTool(bus: supervisor.eventBus, supervisor: supervisor))
    try await registry.register(DiagnosticsRunTool(workspacePath: workspacePath))
    try await registry.register(
      WorktreeStatusTool(manager: worktreeManager, sessions: worktreeSessions))
    try await registry.register(
      WorktreeDiffTool(manager: worktreeManager, sessions: worktreeSessions))
    try await registry.register(
      WorktreeIntegrateTool(manager: worktreeManager, sessions: worktreeSessions))
    try await registry.register(
      WorktreeCleanupTool(manager: worktreeManager, sessions: worktreeSessions))
    if let documents {
      try await registry.register(
        DocumentCreateTool(store: store, documents: documents, projectPath: projectDocumentPath))
      try await registry.register(
        DocumentOpenTool(store: store, documents: documents, projectPath: projectDocumentPath))
      try await registry.register(
        DocumentReplaceTool(store: store, documents: documents, projectPath: projectDocumentPath))
      try await registry.register(
        DocumentReadTool(store: store, documents: documents, projectPath: projectDocumentPath))
      try await registry.register(
        DocumentAppendTool(store: store, documents: documents, projectPath: projectDocumentPath))
      try await registry.register(
        DocumentUpdateChecklistItemTool(
          store: store, documents: documents, projectPath: projectDocumentPath))
    }
  }

  private static let defaultExternalOpener: ExternalURLOpener = { url in
    #if canImport(AppKit)
      return await MainActor.run { NSWorkspace.shared.open(url) }
    #else
      return false
    #endif
  }
}
