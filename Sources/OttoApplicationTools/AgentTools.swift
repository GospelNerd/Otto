import Foundation
import OttoCore
import OttoMemory
import OttoModels
import OttoRuntime
import OttoTools
import OttoWorktrees

public struct AgentSpawnInput: Codable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct AgentSpawnOutput: Codable, Sendable, Equatable {
  public var agentID: UUID
  public var displayName: String
  public var state: AgentLifecycleState
  public var branch: String? = nil
  public var worktreePath: String? = nil
}

public struct AgentProviderInfo: Codable, Sendable, Equatable {
  public var provider: AgentProvider
  public var installed: Bool
  public var version: String?
  public var remediation: String?
  public var compatibility: ProviderCompatibilityState?
  public var compatibilityDetail: String?
}

public struct AgentProvidersInput: Codable, Sendable {
  public init() {}
}

public struct AgentSpawnProviderInput: Codable, Sendable {
  public var provider: AgentProvider
  public var displayName: String?
  public var prompt: String?
  public var workingDirectory: String?
  public var x: Double
  public var y: Double
  public var model: String?
  public var effort: String?
  public var executionStrategy: AgentExecutionStrategy?
  public var permissionMode: AgentPermissionMode
  public var isolatedWorktree: Bool?
  public var profileID: UUID?
  public var profileRevision: Int?
  public var profileInstructions: String?
  /// Provider account to run on (from `account.manage` list). Nil uses the project or global
  /// default account, then the Mac's existing provider login.
  public var accountID: UUID?
  /// Required from agent callers when `accountID` differs from the caller's own account.
  public var subagentID: UUID? = nil
  public var allowCrossAccount: Bool?

  public init(
    provider: AgentProvider,
    displayName: String? = nil,
    prompt: String? = nil,
    workingDirectory: String? = nil,
    x: Double,
    y: Double,
    model: String? = nil,
    effort: String? = nil,
    executionStrategy: AgentExecutionStrategy? = nil,
    permissionMode: AgentPermissionMode = .workspaceWrite,
    isolatedWorktree: Bool? = nil,
    profileID: UUID? = nil,
    profileRevision: Int? = nil,
    profileInstructions: String? = nil,
    accountID: UUID? = nil,
    allowCrossAccount: Bool? = nil
  ) {
    self.provider = provider
    self.displayName = displayName
    self.prompt = prompt
    self.workingDirectory = workingDirectory
    self.x = x
    self.y = y
    self.model = model
    self.effort = effort
    self.executionStrategy = executionStrategy
    self.permissionMode = permissionMode
    self.isolatedWorktree = isolatedWorktree
    self.profileID = profileID
    self.profileRevision = profileRevision
    self.profileInstructions = profileInstructions
    self.accountID = accountID
    self.allowCrossAccount = allowCrossAccount
  }
}

public struct AgentProvidersTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.providers",
    description: "Lists supported local agent providers and their installation status.",
    inputSchema: .objectSchema(),
    outputSchema: .object(["type": .string("array")]),
    requiredScopes: [.agentRead],
    riskLevel: .read
  )
  public init() {}

  public func call(_ input: AgentProvidersInput, context: ToolContext) async throws
    -> [AgentProviderInfo]
  {
    var results: [AgentProviderInfo] = []
    for adapter in providerAdapters() {
      switch await adapter.detectInstallation() {
      case .installed(_, let version):
        let compatibility = ProviderCompatibilityPolicy.evaluate(
          provider: adapter.provider,
          reportedVersion: version
        )
        results.append(
          AgentProviderInfo(
            provider: adapter.provider,
            installed: true,
            version: version,
            remediation: compatibility.state == .unsupported ? compatibility.detail : nil,
            compatibility: compatibility.state,
            compatibilityDetail: compatibility.detail
          ))
      case .missing(let remediation):
        results.append(
          AgentProviderInfo(
            provider: adapter.provider,
            installed: false,
            version: nil,
            remediation: remediation,
            compatibility: nil,
            compatibilityDetail: nil
          ))
      }
    }
    return results
  }
}

public struct AgentSpawnTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.spawn",
    description:
      "Opens a Claude Code, Codex, Hermes, Kimi, or shell agent in a workspace resource. Coding-agent prompts use a structured conversation session; the raw provider terminal remains available separately.",
    inputSchema: .objectSchema(
      properties: [
        "provider": .stringSchema(
          description: "Agent provider: Claude Code, Codex, Hermes, Kimi, or Shell"),
        "displayName": .stringSchema(description: "Stable user-facing name for the agent"),
        "prompt": .stringSchema(description: "Task for the agent to complete"),
        "workingDirectory": .stringSchema(
          description: "Optional absolute repository or directory path for the agent"),
        "x": .numberSchema(description: "Internal resource X position"),
        "y": .numberSchema(description: "Internal resource Y position"),
        "model": .stringSchema(description: "Optional provider model identifier"),
        "effort": .stringSchema(description: "Optional reasoning effort"),
        "executionStrategy": .stringSchema(
          description:
            "Internal execution strategy: direct, delegated, or scriptedWorkflow. Delegated supports every AI harness; scriptedWorkflow is Claude Code only."
        ),
        "permissionMode": .stringSchema(
          description: "Permission mode: readOnly, workspaceWrite, or unrestricted"),
        "isolatedWorktree": .booleanSchema(
          description:
            "Whether to run in a new isolated Git worktree. Defaults to false so the agent works directly in the selected directory."
        ),
        "profileID": .stringSchema(
          description: "Otto-internal saved profile identifier; user-interface calls only"),
        "profileRevision": .integerSchema(
          description: "Otto-internal saved profile revision; user-interface calls only"),
        "profileInstructions": .stringSchema(
          description: "Otto-internal saved profile instructions; user-interface calls only"),
        "subagentID": .stringSchema(
          description:
            "ID of a configured helper from your bot instructions. Otto uses its saved provider, account and model; pass the task in prompt."
        ),
        "accountID": .stringSchema(
          description:
            "Optional provider account ID from account.manage (e.g. a work or personal subscription). Omit to use the project or global default."
        ),
        "allowCrossAccount": .booleanSchema(
          description:
            "Set only after the user approved starting work on a different provider account than yours"
        ),
      ],
      required: ["provider", "x", "y", "permissionMode"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite, .agentControl],
    riskLevel: .consequential
  )
  private let store: CanvasStore
  private let supervisor: AgentSupervisor
  private let workspacePath: String
  private let worktrees: GitWorktreeManager?
  private let worktreeSessions: WorktreeSessionStore
  private let throttle: AgentControlThrottle
  private let defaultsSuiteName: String?
  private let subagentResolver: BotSubagentResolver?
  private let accountBoundary: AgentAccountBoundary?

  public init(
    store: CanvasStore,
    supervisor: AgentSupervisor,
    workspacePath: String,
    worktrees: GitWorktreeManager? = nil,
    worktreeSessions: WorktreeSessionStore = WorktreeSessionStore(),
    throttle: AgentControlThrottle = AgentControlThrottle(),
    defaultsSuiteName: String? = nil,
    accountBoundary: AgentAccountBoundary? = nil,
    subagentResolver: BotSubagentResolver? = nil
  ) {
    self.store = store
    self.supervisor = supervisor
    self.workspacePath = workspacePath
    self.worktrees = worktrees
    self.worktreeSessions = worktreeSessions
    self.throttle = throttle
    self.defaultsSuiteName = defaultsSuiteName
    self.subagentResolver = subagentResolver
    self.accountBoundary = accountBoundary
  }

  public func call(_ input: AgentSpawnProviderInput, context: ToolContext) async throws
    -> AgentSpawnOutput
  {
    try await throttle.authorizeSpawn(context)
    var input = input
    if let subagentID = input.subagentID {
      guard let subagentResolver else {
        throw ToolRegistryError.invalidInput("Configured subagents are unavailable")
      }
      input = try await subagentResolver(input, subagentID, context)
    }
    if let accountID = input.accountID {
      _ = try await enforceAccountBoundary(
        accountBoundary, context: context, targetNode: nil, targetAccountID: accountID,
        allowed: input.allowCrossAccount)
    }
    if input.profileID != nil, context.source == .agent || context.source == .automation {
      throw ToolRegistryError.invalidInput(
        "Saved profile identity can only be resolved by Otto's user-facing control plane")
    }
    let executionStrategy = input.executionStrategy ?? .direct
    try validateExecutionStrategy(executionStrategy, provider: input.provider)
    let prompt = input.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let prompt, !prompt.isEmpty {
      try validateProviderPrompt(prompt, emptyMessage: "A provider task prompt is required")
    }
    // Capture Hermes configuration once so the node metadata and the process launch cannot
    // disagree if preferences change while the asynchronous spawn is being prepared.
    let hermesConfiguration =
      input.provider == .hermes ? HermesConnectionConfiguration.load() : nil
    let adapter: any AgentAdapter
    if let hermesConfiguration {
      adapter = HermesAdapter(configurationProvider: { hermesConfiguration })
    } else if let providerAdapter = providerAdapters().first(where: {
      $0.provider == input.provider
    }) {
      adapter = providerAdapter
    } else {
      throw ToolRegistryError.invalidInput("Unsupported provider: \(input.provider.rawValue)")
    }
    let targetCanvasID = try await store.resolvedCanvasID(for: context)
    let receipt = try await store.dispatch(
      .createNode(
        kind: .agent, at: WorldPoint(x: input.x, y: input.y),
        parentAgentID: context.source == .agent ? context.sourceNodeID : nil),
      context: context
    )
    guard let nodeID = receipt.affectedNodeIDs.first,
      var node = try await store.canvas(for: context).nodes.first(where: { $0.id == nodeID })
    else {
      throw ToolRegistryError.invalidInput("Agent node creation produced no node")
    }
    _ = try await store.dispatch(
      .setNodeContent(id: nodeID, content: .agent(provider: input.provider)),
      context: context
    )
    if let hermesConfiguration {
      _ = try await store.dispatch(
        .setNodeSubtitle(
          id: nodeID,
          subtitle: "HERMES · \(hermesConfiguration.mode.rawValue.uppercased())"
        ),
        context: context
      )
    }
    if let displayName = input.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !displayName.isEmpty
    {
      _ = try await store.dispatch(.renameNode(id: nodeID, name: displayName), context: context)
      node.displayName = String(displayName.prefix(80))
    }
    let requestedWorkspace = try resolvedWorkingDirectory(
      input.workingDirectory,
      fallback: workspacePath
    )
    let remoteHermes = hermesConfiguration?.mode == .remote
    let isolate =
      remoteHermes
      ? false
      : input.isolatedWorktree ?? false
    _ = try await store.dispatch(
      .setAgentDefinition(
        id: nodeID,
        definition: AgentDefinition(
          provider: input.provider,
          repositoryPath: isGitRepository(requestedWorkspace) ? requestedWorkspace : nil,
          workingDirectory: requestedWorkspace,
          launchCommand: launchCommand(for: input.provider),
          environmentProfileID: hermesConfiguration.map {
            "hermes.\($0.mode.rawValue)"
          },
          permissionMode: input.permissionMode.rawValue,
          model: input.provider == .hermes ? nil : input.model,
          effort: input.provider == .hermes ? nil : input.effort,
          executionStrategy: executionStrategy,
          profileID: input.profileID,
          profileRevision: input.profileRevision,
          profileInstructions: input.profileInstructions,
          accountID: input.accountID,
          requiresExplicitAccount: input.subagentID == nil ? nil : true
        )
      ),
      context: context
    )
    // Seed the per-agent restore target before a prompted run is compacted into the rail. This
    // makes the preference apply equally to launch-sheet, quick-launch, voice, and tool spawns,
    // while later manual Chat/Terminal choices remain specific to this node.
    _ = try await store.dispatch(
      .setNodePresentation(
        id: nodeID,
        presentation: node.parentAgentID == nil
          ? AgentDefaultView.load(from: defaults).presentationMode : .compact
      ),
      context: context
    )
    if prompt?.isEmpty == false {
      _ = try await store.dispatch(
        .setNodePresentation(id: nodeID, presentation: .compact),
        context: context
      )
      _ = try await store.dispatch(
        .setNodeStatus(id: nodeID, status: .starting, detail: "Queued for worker capacity"),
        context: context
      )
    }
    var worktree: WorktreeHandle?
    do {
      if isolate {
        guard requestedWorkspace == workspacePath else {
          throw ToolRegistryError.invalidInput(
            "Isolated worktrees are only available for the active Otto workspace")
        }
        guard let worktrees else {
          throw ToolRegistryError.invalidInput(
            "Isolated worktrees are unavailable for this workspace")
        }
        worktree = try await worktrees.create(name: node.displayName)
        if let worktree {
          await worktreeSessions.set(worktree, for: nodeID)
          _ = try await store.dispatch(
            .setNodeSubtitle(
              id: nodeID, subtitle: "\(input.provider.rawValue.uppercased()) · \(worktree.branch)"),
            context: context
          )
        }
      }
      let request = AgentLaunchRequest(
        workspacePath: worktree?.path ?? requestedWorkspace,
        prompt: prompt.flatMap { $0.isEmpty ? nil : $0 },
        model: input.model,
        effort: input.effort,
        executionStrategy: executionStrategy,
        permissionMode: input.permissionMode,
        profileInstructions: input.profileInstructions
      )
      if request.prompt != nil {
        _ = try await supervisor.spawnOneShot(
          adapter: adapter,
          request: request,
          id: nodeID,
          canvasID: targetCanvasID
        )
      } else {
        _ = try await supervisor.spawnInteractive(
          adapter: adapter,
          request: request,
          id: nodeID,
          canvasID: targetCanvasID
        )
      }
    } catch {
      if let worktree { try? await worktrees?.cleanup(worktree) }
      await worktreeSessions.remove(nodeID: nodeID)
      _ = try? await store.dispatch(.closeNode(nodeID), context: context)
      throw error
    }
    if context.source == .agent, let parentID = context.sourceNodeID {
      await supervisor.registerDelegatedChild(
        parentID: parentID, childID: nodeID, name: node.displayName)
    }
    return AgentSpawnOutput(
      agentID: nodeID,
      displayName: node.displayName,
      state: prompt?.isEmpty == false ? .starting : .idle,
      branch: worktree?.branch,
      worktreePath: worktree?.path
    )
  }

  private var defaults: UserDefaults {
    defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }
}

public struct AgentRestartTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.restart",
    description:
      "Restarts an agent from its persisted provider, directory, model, and permission configuration.",
    inputSchema: .objectSchema(
      properties: ["agentID": .stringSchema(description: "Stable agent node UUID")],
      required: ["agentID"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential
  )

  private let store: CanvasStore
  private let supervisor: AgentSupervisor
  private let worktreeSessions: WorktreeSessionStore
  private let adapters: [any AgentAdapter]

  public init(
    store: CanvasStore,
    supervisor: AgentSupervisor,
    worktreeSessions: WorktreeSessionStore,
    adapters: [any AgentAdapter]? = nil
  ) {
    self.store = store
    self.supervisor = supervisor
    self.worktreeSessions = worktreeSessions
    self.adapters = adapters ?? providerAdapters()
  }

  public func call(_ input: AgentStatusInput, context: ToolContext) async throws
    -> AgentStatusOutput
  {
    guard
      let configuration = try await store.requiredNode(input.agentID, context: context)
        .agentDefinition
    else {
      throw ToolRegistryError.invalidInput("This agent has no saved launch configuration")
    }
    guard let adapter = adapters.first(where: { $0.provider == configuration.provider }) else {
      throw ToolRegistryError.invalidInput("Saved provider is unavailable")
    }
    if (try? await supervisor.stopIfPresent(agentID: input.agentID)) == true {
      let deadline = ContinuousClock.now + .seconds(2)
      while ContinuousClock.now < deadline {
        if let snapshot = try? await supervisor.snapshot(agentID: input.agentID),
          snapshot.exitCode != nil
        {
          break
        }
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    let permissionMode =
      AgentPermissionMode(rawValue: configuration.permissionMode) ?? .workspaceWrite
    let workingDirectory =
      await worktreeSessions.handle(for: input.agentID)?.path ?? configuration.workingDirectory
    _ = try await store.dispatch(
      .setNodeStatus(id: input.agentID, status: .starting, detail: "Restarting local runtime…"),
      context: context
    )
    let canvasID = try await store.resolvedCanvasID(for: context)
    let providerHome = await supervisor.accountProviderHome(
      agentID: input.agentID, provider: configuration.provider)
    let restored = configuration.resumeSessionID.map {
      ProviderSessionStore.restore(
        provider: configuration.provider,
        workingDirectory: workingDirectory,
        sessionID: $0,
        providerHome: providerHome
      )
    }
    _ = try await supervisor.spawnInteractive(
      adapter: adapter,
      request: AgentLaunchRequest(
        workspacePath: workingDirectory,
        model: configuration.model,
        effort: configuration.effort,
        executionStrategy: configuration.effectiveExecutionStrategy,
        permissionMode: permissionMode,
        resumeSessionID: configuration.resumeSessionID,
        profileInstructions: configuration.profileInstructions
      ),
      id: input.agentID,
      canvasID: canvasID
    )
    try await supervisor.restoreTranscript(
      agentID: input.agentID,
      turns: restored?.turns ?? []
    )
    return try await output(for: input.agentID, supervisor: supervisor)
  }
}

public struct AgentSpawnMockTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.spawn_mock",
    description: "Spawns a deterministic local mock agent for diagnostics and acceptance testing.",
    inputSchema: .objectSchema(
      properties: ["x": .numberSchema(), "y": .numberSchema()],
      required: ["x", "y"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite, .agentControl],
    riskLevel: .reversible
  )

  private let store: CanvasStore
  private let supervisor: AgentSupervisor

  public init(store: CanvasStore, supervisor: AgentSupervisor) {
    self.store = store
    self.supervisor = supervisor
  }

  public func call(_ input: AgentSpawnInput, context: ToolContext) async throws -> AgentSpawnOutput
  {
    let canvasID = try await store.resolvedCanvasID(for: context)
    let receipt = try await store.dispatch(
      .createNode(kind: .agent, at: WorldPoint(x: input.x, y: input.y)),
      context: context
    )
    guard let nodeID = receipt.affectedNodeIDs.first,
      let node = try await store.canvas(for: context).nodes.first(where: { $0.id == nodeID })
    else {
      throw ToolRegistryError.invalidInput("Agent node creation produced no node")
    }
    _ = try await supervisor.spawnDeterministicMock(id: nodeID, canvasID: canvasID)
    return AgentSpawnOutput(agentID: nodeID, displayName: node.displayName, state: .starting)
  }
}

public struct AgentPromptInput: Codable, Sendable {
  public var agentID: UUID
  public var prompt: String
  public var workingDirectory: String?
  /// Required from agent callers when the target runs on a different provider account.
  public var allowCrossAccount: Bool?

  public init(
    agentID: UUID, prompt: String, workingDirectory: String? = nil, allowCrossAccount: Bool? = nil
  ) {
    self.agentID = agentID
    self.prompt = prompt
    self.workingDirectory = workingDirectory
    self.allowCrossAccount = allowCrossAccount
  }
}

/// Two agents on different provider accounts (e.g. work and personal subscriptions).
public struct AgentAccountCrossing: Sendable, Equatable {
  public var sourceAccount: String
  public var targetAccount: String
  public init(sourceAccount: String, targetAccount: String) {
    self.sourceAccount = sourceAccount
    self.targetAccount = targetAccount
  }
}

/// Reports whether work sent from `source` to the target would cross provider accounts. The
/// target is an existing node, or — for a new agent — the account it was explicitly given.
public typealias AgentAccountBoundary =
  @Sendable (_ source: UUID, _ targetNode: UUID?, _ targetAccountID: UUID?) async ->
  AgentAccountCrossing?

/// Agent-initiated work that crosses accounts must be deliberate: the caller confirms with the
/// user and retries with `allowCrossAccount`. User-interface sends are never blocked.
func enforceAccountBoundary(
  _ boundary: AgentAccountBoundary?, context: ToolContext, targetNode: UUID?,
  targetAccountID: UUID?, allowed: Bool?
) async throws -> AgentAccountCrossing? {
  guard context.source == .agent || context.source == .automation,
    let source = context.sourceNodeID, source != targetNode,
    let crossing = await boundary?(source, targetNode, targetAccountID)
  else { return nil }
  guard allowed == true else {
    throw ToolRegistryError.invalidInput(
      "That agent runs on the \(crossing.targetAccount) account and you run on \(crossing.sourceAccount). Ask the user before moving work across accounts (agent.ask_user), send only a brief without \(crossing.sourceAccount) data, then retry with allowCrossAccount: true."
    )
  }
  return crossing
}

public struct AgentSetModelInput: Codable, Sendable {
  public var agentID: UUID
  /// Model identifier for the agent's provider; omit or pass "default" to return to the
  /// provider's own default.
  public var model: String?
  /// Reasoning effort for providers that support one; valid values follow the selected model.
  public var effort: String?

  public init(agentID: UUID, model: String? = nil, effort: String? = nil) {
    self.agentID = agentID
    self.model = model
    self.effort = effort
  }
}

public struct AgentSetModelOutput: Codable, Sendable, Equatable {
  public var agentID: UUID
  public var model: String?
  public var effort: String?
  public var message: String

  public init(agentID: UUID, model: String?, effort: String?, message: String) {
    self.agentID = agentID
    self.model = model
    self.effort = effort
    self.message = message
  }
}

public struct AgentSetExecutionStrategyInput: Codable, Sendable {
  public var agentID: UUID
  public var executionStrategy: AgentExecutionStrategy

  public init(agentID: UUID, executionStrategy: AgentExecutionStrategy) {
    self.agentID = agentID
    self.executionStrategy = executionStrategy
  }
}

public struct AgentSetExecutionStrategyOutput: Codable, Sendable, Equatable {
  public var agentID: UUID
  public var executionStrategy: AgentExecutionStrategy
  public var message: String
}

/// Persists how one agent structures future work. This does not change Otto's cross-provider
/// orchestration contract; it controls only native delegation inside the selected provider.
public struct AgentSetExecutionStrategyTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.set_execution_strategy",
    description:
      "Sets how an agent handles future prompts: direct uses the main conversation; delegated allows native subagents for Claude Code or Codex; scriptedWorkflow uses Claude Code dynamic workflows. The current run is unaffected.",
    inputSchema: .objectSchema(
      properties: [
        "agentID": .stringSchema(description: "Stable agent node UUID"),
        "executionStrategy": .stringSchema(
          description: "direct, delegated, or scriptedWorkflow"),
      ],
      required: ["agentID", "executionStrategy"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .reversible
  )

  private let store: CanvasStore

  public init(store: CanvasStore) {
    self.store = store
  }

  public func call(_ input: AgentSetExecutionStrategyInput, context: ToolContext) async throws
    -> AgentSetExecutionStrategyOutput
  {
    guard
      var definition = try await store.requiredNode(input.agentID, context: context)
        .agentDefinition
    else {
      throw ToolRegistryError.invalidInput("This agent has no saved launch configuration")
    }
    try validateExecutionStrategy(input.executionStrategy, provider: definition.provider)
    definition.executionStrategy = input.executionStrategy
    _ = try await store.dispatch(
      .setAgentDefinition(id: input.agentID, definition: definition),
      context: context
    )
    return AgentSetExecutionStrategyOutput(
      agentID: input.agentID,
      executionStrategy: input.executionStrategy,
      message:
        "Next runs use the \(input.executionStrategy.rawValue) execution strategy. The current run is unaffected."
    )
  }
}

/// Persists a model (and optional reasoning effort) onto an agent's saved launch configuration.
/// Chat messages each start a fresh provider run from that configuration, so the switch takes
/// effect on the very next message without restarting the agent.
public struct AgentSetModelTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.set_model",
    description:
      "Switches which model and reasoning effort an agent uses from its next run onward. Otto Harness accepts provider-prefixed ids such as openai/gpt-5.6, anthropic/claude-sonnet-5, xai/grok-4.6, moonshot/kimi-k2.5, deepseek/deepseek-chat, mistral/mistral-large-latest, groq/<model>, gemini/<model>, openrouter/<vendor>/<model>, and local/<model>. Claude Code, Codex, Cursor, Grok, Kimi, OpenCode, and Pi accept ids from their live model catalogs (Pi ids are provider/model). Pass model \"default\" to return to the provider default. Hermes and shell sessions do not expose model switching here.",
    inputSchema: .objectSchema(
      properties: [
        "agentID": .stringSchema(description: "Stable agent node UUID"),
        "model": .stringSchema(
          description: "Model id for the agent's provider, or \"default\" to clear"),
        "effort": .stringSchema(
          description: "Reasoning effort where supported; valid levels depend on the model"),
      ],
      required: ["agentID"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .reversible
  )

  private let store: CanvasStore

  public init(store: CanvasStore) {
    self.store = store
  }

  public func call(_ input: AgentSetModelInput, context: ToolContext) async throws
    -> AgentSetModelOutput
  {
    guard
      var definition = try await store.requiredNode(input.agentID, context: context)
        .agentDefinition
    else {
      throw ToolRegistryError.invalidInput("This agent has no saved launch configuration")
    }
    let provider = definition.provider
    guard AgentModelCatalog.supportsModelSelection(for: provider) else {
      throw ToolRegistryError.invalidInput(
        "\(provider.rawValue) agents own their model configuration and cannot be switched from Otto"
      )
    }
    if let rawModel = input.model {
      let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
      definition.model =
        trimmed.isEmpty || trimmed.lowercased() == "default" ? nil : trimmed
      if let effort = definition.effort,
        !AgentModelCatalog.effortLevels(for: provider, modelID: definition.model).contains(effort)
      {
        definition.effort = nil
      }
    }
    if let rawEffort = input.effort {
      let trimmed = rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if trimmed.isEmpty || trimmed == "default" {
        definition.effort = nil
      } else {
        let levels = AgentModelCatalog.effortLevels(for: provider, modelID: definition.model)
        guard levels.contains(trimmed) else {
          throw ToolRegistryError.invalidInput(
            levels.isEmpty
              ? "\(provider.rawValue) does not support a reasoning effort setting"
              : "Effort must be one of: \(levels.joined(separator: ", "))"
          )
        }
        definition.effort = trimmed
      }
    }
    _ = try await store.dispatch(
      .setAgentDefinition(id: input.agentID, definition: definition),
      context: context
    )
    let modelLabel =
      definition.model.map { AgentModelCatalog.displayName(forModelID: $0, provider: provider) }
      ?? "the provider default"
    let effortLabel = definition.effort.map { " at \($0) effort" } ?? ""
    return AgentSetModelOutput(
      agentID: input.agentID,
      model: definition.model,
      effort: definition.effort,
      message: "Next runs use \(modelLabel)\(effortLabel). The current run is unaffected."
    )
  }
}

public struct AgentStatusInput: Codable, Sendable {
  public var agentID: UUID
  public init(agentID: UUID) { self.agentID = agentID }
}

public struct AgentInputInput: Codable, Sendable {
  public var agentID: UUID
  public var text: String
  public init(agentID: UUID, text: String) {
    self.agentID = agentID
    self.text = text
  }
}

public struct AgentStatusOutput: Codable, Sendable, Equatable {
  public var agentID: UUID
  public var state: AgentLifecycleState
  public var confidence: Double
  public var providerSessionID: String?
  public var result: String?
  public var attentionReason: String?
  public var boundedOutput: String
}

public struct AgentResumeInput: Codable, Sendable {
  public var agentID: UUID
  public var prompt: String
  public var model: String?
  public var effort: String?
  public var executionStrategy: AgentExecutionStrategy?
  public var permissionMode: AgentPermissionMode

  public init(
    agentID: UUID,
    prompt: String,
    model: String? = nil,
    effort: String? = nil,
    executionStrategy: AgentExecutionStrategy? = nil,
    permissionMode: AgentPermissionMode = .workspaceWrite
  ) {
    self.agentID = agentID
    self.prompt = prompt
    self.model = model
    self.effort = effort
    self.executionStrategy = executionStrategy
    self.permissionMode = permissionMode
  }
}

public struct AgentGetOutputInput: Codable, Sendable {
  public var agentID: UUID
  public var sinceOffset: Int?
  public var limit: Int?

  public init(agentID: UUID, sinceOffset: Int? = nil, limit: Int? = nil) {
    self.agentID = agentID
    self.sinceOffset = sinceOffset
    self.limit = limit
  }
}

public struct AgentOutputPage: Codable, Sendable, Equatable {
  public var agentID: UUID
  public var text: String
  public var startOffset: Int
  public var endOffset: Int
  public var retainedStartOffset: Int
  public var streamEndOffset: Int
  public var truncated: Bool
}

public struct AgentSendPromptTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.send_prompt",
    description:
      "Sends a prompt to a stable agent. Interactive agents receive it directly; completed Codex or Claude runs continue automatically in the same node.",
    inputSchema: agentPromptSchema(promptDescription: "Prompt to send"),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential
  )

  private let supervisor: AgentSupervisor
  private let store: CanvasStore?
  private let workspacePath: String
  private let worktreeSessions: WorktreeSessionStore
  private let adapters: [any AgentAdapter]
  private let throttle: AgentControlThrottle
  private let accountBoundary: AgentAccountBoundary?

  public init(
    supervisor: AgentSupervisor,
    store: CanvasStore? = nil,
    workspacePath: String = FileManager.default.currentDirectoryPath,
    worktreeSessions: WorktreeSessionStore = WorktreeSessionStore(),
    adapters: [any AgentAdapter]? = nil,
    throttle: AgentControlThrottle = AgentControlThrottle(),
    accountBoundary: AgentAccountBoundary? = nil
  ) {
    self.supervisor = supervisor
    self.store = store
    self.workspacePath = workspacePath
    self.worktreeSessions = worktreeSessions
    self.adapters = adapters ?? providerAdapters()
    self.throttle = throttle
    self.accountBoundary = accountBoundary
  }

  public func call(_ input: AgentPromptInput, context: ToolContext) async throws
    -> AgentStatusOutput
  {
    try await throttle.authorizePrompt(context)
    try validateProviderPrompt(input.prompt, emptyMessage: "A prompt is required")
    if let crossing = try await enforceAccountBoundary(
      accountBoundary, context: context, targetNode: input.agentID, targetAccountID: nil,
      allowed: input.allowCrossAccount)
    {
      try? await supervisor.appendLocalTranscript(
        agentID: input.agentID, role: .activity, kind: .notice,
        text:
          "Handed over from an agent on \(crossing.sourceAccount). This agent runs on \(crossing.targetAccount)."
      )
    }
    let initial: AgentRuntimeSnapshot
    do {
      initial = try await supervisor.snapshot(agentID: input.agentID)
    } catch {
      // The supervisor has never seen this agent — a node restored from a previous app
      // session. Without this path the node is a brick: the composer errors on every prompt
      // and the only recovery is closing the node. Revive it from the persisted definition,
      // resuming the recorded provider session so the conversation continues.
      return try await reviveFromPersistedDefinition(input: input, context: context)
    }
    if initial.executionMode == .interactiveProvider {
      guard initial.provider != .shell,
        let adapter = adapters.first(where: { $0.provider == initial.provider })
      else {
        try await supervisor.sendInput(agentID: input.agentID, text: input.prompt)
        return try await output(for: input.agentID, supervisor: supervisor)
      }

      // Agent chat uses provider JSON, not a painted native TUI. A newly opened agent keeps its
      // native harness available in Terminal until the first chat message; submitting that message
      // replaces it with a structured, resumable run whose deltas and tool calls can be projected.
      _ = try await supervisor.stopIfPresent(agentID: input.agentID)
      let deadline = ContinuousClock.now + .seconds(2)
      while ContinuousClock.now < deadline {
        if let snapshot = try? await supervisor.snapshot(agentID: input.agentID),
          snapshot.exitCode != nil
        {
          break
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      let definition: AgentDefinition?
      if let store {
        definition = try await store.requiredNode(input.agentID, context: context).agentDefinition
      } else {
        definition = nil
      }
      let worktree = await worktreeSessions.handle(for: input.agentID)
      let workingDirectory = worktree?.path ?? definition?.workingDirectory ?? workspacePath
      let permissionMode =
        definition.flatMap { AgentPermissionMode(rawValue: $0.permissionMode) }
        ?? .workspaceWrite
      let canvasID = context.targetCanvasID ?? context.sourceCanvasID
      _ = try await supervisor.spawnOneShot(
        adapter: adapter,
        request: AgentLaunchRequest(
          workspacePath: workingDirectory,
          prompt: input.prompt,
          model: definition?.model,
          effort: definition?.effort,
          executionStrategy: definition?.effectiveExecutionStrategy ?? .direct,
          permissionMode: permissionMode,
          resumeSessionID: (try? await supervisor.snapshot(agentID: input.agentID))?
            .providerSessionID ?? definition?.resumeSessionID,
          profileInstructions: definition?.profileInstructions
        ),
        id: input.agentID,
        canvasID: canvasID
      )
      return try await output(for: input.agentID, supervisor: supervisor)
    }
    if initial.provider == .shell {
      try await supervisor.sendPrompt(agentID: input.agentID, prompt: input.prompt)
      return try await output(for: input.agentID, supervisor: supervisor)
    }

    if initial.exitCode == nil,
      ![.done, .failed, .interrupted, .stopped].contains(initial.state)
    {
      do {
        try await supervisor.sendPrompt(agentID: input.agentID, prompt: input.prompt)
        return try await output(for: input.agentID, supervisor: supervisor)
      } catch RuntimeError.transportClosed {
        // One-shot provider CLIs close the PTY just before their exit event arrives.
      }
    }

    let completed = try await completedAgentSnapshot(
      agentID: input.agentID,
      supervisor: supervisor
    )
    guard let adapter = adapters.first(where: { $0.provider == completed.provider }) else {
      throw ToolRegistryError.invalidInput("Provider cannot continue this agent")
    }
    let fallback = await worktreeSessions.handle(for: input.agentID)?.path ?? workspacePath
    let workingDirectory = try resolvedWorkingDirectory(input.workingDirectory, fallback: fallback)
    // Continuations must keep the node's configured permission mode, model, and effort — a
    // bypass-permissions agent should not silently fall back to approval prompts mid-thread.
    let savedDefinition: AgentDefinition?
    if let store {
      savedDefinition = try? await store.requiredNode(input.agentID, context: context)
        .agentDefinition
    } else {
      savedDefinition = nil
    }
    let request = AgentLaunchRequest(
      workspacePath: workingDirectory,
      prompt: input.prompt,
      model: savedDefinition?.model,
      effort: savedDefinition?.effort,
      executionStrategy: savedDefinition?.effectiveExecutionStrategy ?? .direct,
      permissionMode: savedDefinition.flatMap {
        AgentPermissionMode(rawValue: $0.permissionMode)
      } ?? .workspaceWrite,
      profileInstructions: savedDefinition?.profileInstructions
    )
    if let sessionID = completed.providerSessionID, !sessionID.isEmpty {
      let canvasID = context.targetCanvasID ?? context.sourceCanvasID
      _ = try await supervisor.resumeOneShot(
        adapter: adapter,
        request: request,
        sessionID: sessionID,
        id: input.agentID,
        canvasID: canvasID
      )
    } else {
      let canvasID = context.targetCanvasID ?? context.sourceCanvasID
      _ = try await supervisor.spawnOneShot(
        adapter: adapter,
        request: request,
        id: input.agentID,
        canvasID: canvasID
      )
    }
    return try await output(for: input.agentID, supervisor: supervisor)
  }

  /// Launches a run for a node the supervisor does not know, from the node's persisted
  /// provider configuration — resuming the recorded provider session when one exists so a
  /// restored node picks up its old conversation instead of starting cold.
  private func reviveFromPersistedDefinition(
    input: AgentPromptInput, context: ToolContext
  ) async throws -> AgentStatusOutput {
    guard let store,
      let definition = try await store.requiredNode(input.agentID, context: context)
        .agentDefinition
    else {
      throw ToolRegistryError.invalidInput(
        "This agent is not running and has no saved launch configuration")
    }
    guard definition.provider != .shell else {
      throw ToolRegistryError.invalidInput("Restart this terminal to continue using it")
    }
    guard let adapter = adapters.first(where: { $0.provider == definition.provider }) else {
      throw ToolRegistryError.invalidInput("Saved provider is unavailable")
    }
    let worktree = await worktreeSessions.handle(for: input.agentID)
    let workingDirectory = try resolvedWorkingDirectory(
      input.workingDirectory, fallback: worktree?.path ?? definition.workingDirectory)
    let request = AgentLaunchRequest(
      workspacePath: workingDirectory,
      prompt: input.prompt,
      model: definition.model,
      effort: definition.effort,
      executionStrategy: definition.effectiveExecutionStrategy,
      permissionMode: AgentPermissionMode(rawValue: definition.permissionMode)
        ?? .workspaceWrite,
      profileInstructions: definition.profileInstructions
    )
    let canvasID = context.targetCanvasID ?? context.sourceCanvasID
    if let sessionID = definition.resumeSessionID, !sessionID.isEmpty {
      let restored = ProviderSessionStore.restore(
        provider: definition.provider,
        workingDirectory: workingDirectory,
        sessionID: sessionID,
        providerHome: await supervisor.accountProviderHome(
          agentID: input.agentID, provider: definition.provider)
      )
      _ = try await supervisor.resumeOneShot(
        adapter: adapter,
        request: request,
        sessionID: sessionID,
        id: input.agentID,
        canvasID: canvasID
      )
      try await supervisor.restoreTranscript(agentID: input.agentID, turns: restored.turns)
    } else {
      _ = try await supervisor.spawnOneShot(
        adapter: adapter,
        request: request,
        id: input.agentID,
        canvasID: canvasID
      )
    }
    return try await output(for: input.agentID, supervisor: supervisor)
  }
}

public struct AgentResumeTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.resume",
    description: "Resumes a completed provider session in its existing stable agent node.",
    inputSchema: .objectSchema(
      properties: [
        "agentID": .stringSchema(description: "Stable agent node UUID"),
        "prompt": .stringSchema(description: "Task to continue with"),
        "model": .stringSchema(description: "Optional provider model identifier"),
        "effort": .stringSchema(description: "Optional reasoning effort"),
        "executionStrategy": .stringSchema(
          description: "Optional direct, delegated, or scriptedWorkflow strategy"),
        "permissionMode": .stringSchema(
          description: "Permission mode: readOnly, workspaceWrite, or unrestricted"),
      ],
      required: ["agentID", "prompt", "permissionMode"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential
  )

  private let supervisor: AgentSupervisor
  private let store: CanvasStore?
  private let workspacePath: String
  private let worktreeSessions: WorktreeSessionStore
  private let adapters: [any AgentAdapter]
  private let throttle: AgentControlThrottle

  public init(
    supervisor: AgentSupervisor,
    store: CanvasStore? = nil,
    workspacePath: String,
    worktreeSessions: WorktreeSessionStore,
    adapters: [any AgentAdapter]? = nil,
    throttle: AgentControlThrottle = AgentControlThrottle()
  ) {
    self.supervisor = supervisor
    self.store = store
    self.workspacePath = workspacePath
    self.worktreeSessions = worktreeSessions
    self.adapters = adapters ?? providerAdapters()
    self.throttle = throttle
  }

  public func call(_ input: AgentResumeInput, context: ToolContext) async throws
    -> AgentStatusOutput
  {
    try await throttle.authorizePrompt(context)
    try validateProviderPrompt(input.prompt, emptyMessage: "A resume prompt is required")
    let snapshot: AgentRuntimeSnapshot?
    do {
      snapshot = try await completedSnapshot(agentID: input.agentID)
    } catch RuntimeError.agentNotFound {
      // The runtime session died with an app restart, but the node and its provider session ID
      // persist. Revive from the saved launch configuration instead of telling the user their
      // agent is gone.
      return try await resumeFromPersistedDefinition(input, context: context)
    }
    guard let snapshot else {
      throw ToolRegistryError.invalidInput("Agent state is unavailable")
    }
    guard let sessionID = snapshot.providerSessionID, !sessionID.isEmpty else {
      return try await resumeFromPersistedDefinition(input, context: context)
    }
    guard snapshot.provider != .shell,
      let adapter = adapters.first(where: { $0.provider == snapshot.provider })
    else {
      throw ToolRegistryError.invalidInput("Provider does not support session resume")
    }
    let workingDirectory = await worktreeSessions.handle(for: input.agentID)?.path ?? workspacePath
    let savedDefinition = try? await store?.requiredNode(input.agentID, context: context)
      .agentDefinition
    let restored = ProviderSessionStore.restore(
      provider: snapshot.provider,
      workingDirectory: workingDirectory,
      sessionID: sessionID,
      providerHome: await supervisor.accountProviderHome(
        agentID: input.agentID, provider: snapshot.provider)
    )
    _ = try await supervisor.resumeOneShot(
      adapter: adapter,
      request: AgentLaunchRequest(
        workspacePath: workingDirectory,
        prompt: input.prompt,
        model: input.model,
        effort: input.effort,
        executionStrategy: input.executionStrategy
          ?? savedDefinition?.effectiveExecutionStrategy ?? .direct,
        permissionMode: input.permissionMode,
        profileInstructions: savedDefinition?.profileInstructions
      ),
      sessionID: sessionID,
      id: input.agentID
    )
    try await supervisor.restoreTranscript(agentID: input.agentID, turns: restored.turns)
    return try await output(for: input.agentID, supervisor: supervisor)
  }

  private func resumeFromPersistedDefinition(
    _ input: AgentResumeInput, context: ToolContext
  ) async throws -> AgentStatusOutput {
    guard let store,
      let definition = try? await store.requiredNode(input.agentID, context: context)
        .agentDefinition
    else {
      throw ToolRegistryError.invalidInput(
        "Agent \(input.agentID.uuidString) has no live session and no saved configuration to revive"
      )
    }
    guard let sessionID = definition.resumeSessionID, !sessionID.isEmpty else {
      throw ToolRegistryError.invalidInput(
        "Agent \(input.agentID.uuidString) has no resumable provider session; use agent.send_prompt to start a fresh run in the same node"
      )
    }
    guard definition.provider != .shell,
      let adapter = adapters.first(where: { $0.provider == definition.provider })
    else {
      throw ToolRegistryError.invalidInput("Saved provider does not support session resume")
    }
    let workingDirectory =
      await worktreeSessions.handle(for: input.agentID)?.path ?? definition.workingDirectory
    let restored = ProviderSessionStore.restore(
      provider: definition.provider,
      workingDirectory: workingDirectory,
      sessionID: sessionID,
      providerHome: await supervisor.accountProviderHome(
        agentID: input.agentID, provider: definition.provider)
    )
    _ = try await supervisor.resumeOneShot(
      adapter: adapter,
      request: AgentLaunchRequest(
        workspacePath: workingDirectory,
        prompt: input.prompt,
        model: input.model ?? definition.model,
        effort: input.effort ?? definition.effort,
        executionStrategy: definition.effectiveExecutionStrategy,
        permissionMode: AgentPermissionMode(rawValue: definition.permissionMode)
          ?? input.permissionMode,
        profileInstructions: definition.profileInstructions
      ),
      sessionID: sessionID,
      id: input.agentID
    )
    try await supervisor.restoreTranscript(agentID: input.agentID, turns: restored.turns)
    return try await output(for: input.agentID, supervisor: supervisor)
  }

  private func completedSnapshot(agentID: UUID) async throws -> AgentRuntimeSnapshot {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      let snapshot = try await supervisor.snapshot(agentID: agentID)
      if snapshot.exitCode != nil {
        guard [.done, .failed, .interrupted, .stopped].contains(snapshot.state) else {
          throw ToolRegistryError.invalidInput("Only completed agent runs can be resumed")
        }
        return snapshot
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ToolRegistryError.invalidInput("Agent process has not finished exiting")
  }
}

public struct AgentGetStatusTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.get_status",
    description: "Returns normalized state, confidence, bounded output, and final result.",
    inputSchema: agentIDSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read
  )

  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }

  public func call(_ input: AgentStatusInput, context: ToolContext) async throws
    -> AgentStatusOutput
  {
    try await output(for: input.agentID, supervisor: supervisor)
  }
}

public struct AgentGetOutputTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.get_output",
    description: "Reads a bounded page of agent output using stable absolute byte offsets.",
    inputSchema: .object([
      "type": .string("object"),
      "required": .array([.string("agentID")]),
      "properties": .object([
        "agentID": .object(["type": .string("string"), "format": .string("uuid")]),
        "sinceOffset": .object(["type": .string("integer"), "minimum": .number(0)]),
        "limit": .object([
          "type": .string("integer"), "minimum": .number(1), "maximum": .number(65_536),
        ]),
      ]),
      "additionalProperties": .bool(false),
    ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read
  )

  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }

  public func call(_ input: AgentGetOutputInput, context: ToolContext) async throws
    -> AgentOutputPage
  {
    guard input.sinceOffset.map({ $0 >= 0 }) ?? true else {
      throw ToolRegistryError.invalidInput("Output offset cannot be negative")
    }
    let limit = input.limit ?? 16_384
    guard (1...65_536).contains(limit) else {
      throw ToolRegistryError.invalidInput("Output limit must be between 1 and 65536 bytes")
    }
    let snapshot = try await supervisor.snapshot(agentID: input.agentID)
    let requestedOffset = input.sinceOffset ?? snapshot.outputStartOffset
    let startOffset = min(
      max(requestedOffset, snapshot.outputStartOffset), snapshot.outputEndOffset)
    let retained = Data(snapshot.output.utf8)
    let relativeStart = min(
      max(0, startOffset - snapshot.outputStartOffset), retained.count)
    let count = min(limit, retained.count - relativeStart)
    let page = retained.subdata(in: relativeStart..<(relativeStart + count))
    return AgentOutputPage(
      agentID: input.agentID,
      text: String(decoding: page, as: UTF8.self),
      startOffset: startOffset,
      endOffset: startOffset + count,
      retainedStartOffset: snapshot.outputStartOffset,
      streamEndOffset: snapshot.outputEndOffset,
      truncated: requestedOffset < snapshot.outputStartOffset
    )
  }
}

public struct AgentSendInputTool: OttoTool {
  public static let definition = agentControlDefinition(
    name: "agent.send_input",
    description: "Sends approval or interactive input to an existing agent PTY."
  )
  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }
  public func call(_ input: AgentInputInput, context: ToolContext) async throws
    -> AgentStatusOutput
  {
    try await supervisor.sendInput(agentID: input.agentID, text: input.text)
    return try await output(for: input.agentID, supervisor: supervisor)
  }
}

public struct AgentInterruptTool: OttoTool {
  public static let definition = agentControlDefinition(
    name: "agent.interrupt", description: "Interrupts the foreground agent process with SIGINT.")
  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }
  public func call(_ input: AgentStatusInput, context: ToolContext) async throws
    -> AgentStatusOutput
  {
    try await supervisor.interrupt(agentID: input.agentID)
    // A parent that stops its own child already knows how it ended.
    await supervisor.markDelegatedCompletionConsumed(
      childID: input.agentID, by: context.sourceNodeID)
    return try await output(for: input.agentID, supervisor: supervisor)
  }
}

public struct AgentStopTool: OttoTool {
  public static let definition = agentControlDefinition(
    name: "agent.stop", description: "Stops an existing agent process with SIGTERM.")
  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }
  public func call(_ input: AgentStatusInput, context: ToolContext) async throws
    -> AgentStatusOutput
  {
    try await supervisor.stop(agentID: input.agentID)
    await supervisor.markDelegatedCompletionConsumed(
      childID: input.agentID, by: context.sourceNodeID)
    return try await output(for: input.agentID, supervisor: supervisor)
  }
}

public struct AgentGetResultTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.get_result",
    description: "Returns a bounded structured final result for an agent run.",
    inputSchema: agentIDSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read
  )
  private let supervisor: AgentSupervisor
  private let brain: ProjectBrainStore?

  public init(supervisor: AgentSupervisor, brain: ProjectBrainStore? = nil) {
    self.supervisor = supervisor
    self.brain = brain
  }

  public func call(_ input: AgentStatusInput, context: ToolContext) async throws
    -> AgentStatusOutput
  {
    let result = try await output(for: input.agentID, supervisor: supervisor)
    // Reading a finished child's result inside the turn replaces the background notice.
    await supervisor.markDelegatedCompletionConsumed(
      childID: input.agentID, by: context.sourceNodeID)
    await recordHandoffIfDelegated(targetID: input.agentID, context: context)
    return result
  }

  /// When one agent reads another's finished result, that read is the completion of a handoff —
  /// the only moment where requester, task, and outcome are all known at once. Recording it is
  /// best-effort: a brain failure must never turn a successful result read into a tool error.
  private func recordHandoffIfDelegated(targetID: UUID, context: ToolContext) async {
    guard let brain,
      context.source == .agent,
      let requesterID = context.sourceNodeID,
      requesterID != targetID,
      let snapshot = try? await supervisor.snapshot(agentID: targetID),
      snapshot.state == .done,
      let structured = snapshot.structuredResult
    else { return }
    _ = try? await brain.recordDelegationHandoff(
      requesterID: requesterID.uuidString,
      targetID: targetID.uuidString,
      task: snapshot.lastPrompt ?? "",
      outcome: structured.summaryCandidate,
      sourceIDs: ["agent:\(targetID.uuidString)", "agent:\(requesterID.uuidString)"]
    )
  }
}

private func agentControlDefinition(name: String, description: String) -> ToolDefinition {
  let inputSchema: JSONValue
  if name == "agent.send_input" {
    inputSchema = .objectSchema(
      properties: [
        "agentID": .stringSchema(description: "Stable agent node UUID"),
        "text": .stringSchema(description: "Approval or interactive text to type"),
      ],
      required: ["agentID", "text"]
    )
  } else {
    inputSchema = agentIDSchema()
  }
  return ToolDefinition(
    name: name,
    description: description,
    inputSchema: inputSchema,
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential
  )
}

private func agentIDSchema() -> JSONValue {
  .objectSchema(
    properties: ["agentID": .stringSchema(description: "Stable agent node UUID")],
    required: ["agentID"]
  )
}

private func agentPromptSchema(promptDescription: String) -> JSONValue {
  .objectSchema(
    properties: [
      "agentID": .stringSchema(description: "Stable agent node UUID"),
      "prompt": .stringSchema(description: promptDescription),
      "workingDirectory": .stringSchema(
        description: "Optional absolute repository or directory path for this run"),
      "allowCrossAccount": .booleanSchema(
        description:
          "Set only after the user approved handing work to an agent on a different provider account"
      ),
    ],
    required: ["agentID", "prompt"]
  )
}

private func output(for id: UUID, supervisor: AgentSupervisor) async throws -> AgentStatusOutput {
  let snapshot = try await supervisor.snapshot(agentID: id)
  return AgentStatusOutput(
    agentID: id,
    state: snapshot.state,
    confidence: snapshot.confidence,
    providerSessionID: snapshot.providerSessionID,
    result: snapshot.result,
    attentionReason: snapshot.attentionReason,
    boundedOutput: boundedConversationalOutput(snapshot)
  )
}

/// Structured provider runs stream JSON wire format through the PTY — dumping that at a model
/// (or a person) buries the useful content in kilobytes of protocol noise and once flooded a
/// voice session badly enough to lose the user's request. Project the readable transcript
/// instead; raw bytes stay available through agent.get_output and the Terminal surface.
func boundedConversationalOutput(_ snapshot: AgentRuntimeSnapshot) -> String {
  guard snapshot.executionMode != .terminal, snapshot.provider != .shell else {
    return TerminalOutputSearch.sanitizedExcerpt(snapshot.output)
  }
  let lines = snapshot.transcript.suffix(14).map { entry -> String in
    let text = String(entry.text.prefix(400))
    return switch (entry.role, entry.kind) {
    case (.user, _): "User: \(text)"
    case (.assistant, .reasoning): "Reasoned: \(String(text.prefix(160)))"
    case (.assistant, _): "\(snapshot.provider.rawValue): \(text)"
    case (.activity, .toolCall): "Tool \(entry.detail ?? "call"): \(text)"
    case (.activity, _): "Note: \(text)"
    }
  }
  var projected = lines.joined(separator: "\n")
  if let result = snapshot.result, !result.isEmpty, !projected.contains(String(result.prefix(120)))
  {
    projected += (projected.isEmpty ? "" : "\n") + "Result: \(String(result.prefix(600)))"
  }
  if projected.isEmpty {
    projected = "No conversation yet."
  }
  return String(projected.suffix(4_096))
}

private func launchCommand(for provider: AgentProvider) -> String {
  switch provider {
  case .claudeCode: "claude"
  case .codex: "codex"
  case .openAI: "otto-openai-agent"
  case .hermes: "hermes"
  case .cursor: "cursor-agent"
  case .kimi: "kimi"
  case .openCode: "opencode"
  case .pi: "pi"
  case .grok: "grok"
  case .shell: "shell"
  }
}

private func providerAdapters() -> [any AgentAdapter] {
  [
    ClaudeCodeAdapter(), CodexAdapter(), OpenAIDirectAdapter(), CursorAdapter(), GrokAdapter(),
    HermesAdapter(),
    KimiAdapter(), OpenCodeAdapter(), PiAdapter(), ShellAdapter(),
  ]
}

private func validateProviderPrompt(_ prompt: String, emptyMessage: String) throws {
  guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw ToolRegistryError.invalidInput(emptyMessage)
  }
  guard prompt.utf8.count <= 262_144 else {
    throw ToolRegistryError.invalidInput("Provider prompts cannot exceed 256 KiB")
  }
  guard !prompt.unicodeScalars.contains(where: { $0.value == 0 }) else {
    throw ToolRegistryError.invalidInput("Provider prompts cannot contain NUL characters")
  }
}

private func validateExecutionStrategy(
  _ strategy: AgentExecutionStrategy, provider: AgentProvider
) throws {
  guard strategy.isSupported(by: provider) else {
    let supported = AgentExecutionStrategy.allCases
      .filter { $0.isSupported(by: provider) }
      .map(\.rawValue)
      .joined(separator: ", ")
    throw ToolRegistryError.invalidInput(
      "\(provider.rawValue) supports these execution strategies: \(supported)")
  }
}

private func isGitRepository(_ path: String) -> Bool {
  FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: path, isDirectory: true).appending(path: ".git").path)
}

private func resolvedWorkingDirectory(_ requested: String?, fallback: String) throws -> String {
  let value = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
  let path = (value?.isEmpty == false ? value! : fallback)
  guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
    throw ToolRegistryError.invalidInput("Agent working directory must be an absolute local path")
  }
  let resolved = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
    isDirectory.boolValue
  else {
    throw ToolRegistryError.invalidInput("Agent working directory does not exist: \(resolved)")
  }
  return resolved
}

private func completedAgentSnapshot(
  agentID: UUID,
  supervisor: AgentSupervisor
) async throws -> AgentRuntimeSnapshot {
  let deadline = ContinuousClock.now + .seconds(3)
  while ContinuousClock.now < deadline {
    let snapshot = try await supervisor.snapshot(agentID: agentID)
    if snapshot.exitCode != nil { return snapshot }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw ToolRegistryError.invalidInput("Agent process has not finished exiting")
}

public typealias BotSubagentResolver =
  @Sendable (
    AgentSpawnProviderInput, UUID, ToolContext
  ) async throws -> AgentSpawnProviderInput
