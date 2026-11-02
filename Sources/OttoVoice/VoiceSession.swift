import Foundation
import OttoModels
import OttoTools

public actor VoiceSession {
  private let registry: ToolRegistry
  private let context: ToolContext
  private let audioTransport: (any VoiceAudioTransport)?
  private let taskPlanner: (any VoiceTaskPlanning)?
  private let permissionDefaultsSuiteName: String?
  private var provider: (any VoiceProvider)?
  private var latestContext: VoiceContext?
  private var notificationPolicy: CompletionNotificationPolicy
  private var pendingNotices: [AgentVoiceNotice] = []
  private var noticeFlushTask: Task<Void, Never>?
  private var eventTask: Task<Void, Never>?
  private var audioOutputTask: Task<Void, Never>?
  private var microphoneInputStarted = false
  private var presentationEnabled = true
  private var delegationTasks: [String: Task<Void, Never>] = [:]
  private var current = VoiceSessionSnapshot()
  private var trace: [VoiceTraceEntry] = []
  private var conversation: [VoiceConversationRecord] = []
  private var provisionalUserRecordID: UUID?
  private var activeAssistantRecordID: UUID?
  private var currentTurnID: UUID?
  private var lastTranscriptTurnID: UUID?
  private var lastFinalTranscriptText = ""
  private var lastFinalTranscriptAt = Date.distantPast
  private var userInputActive = false
  private var failedCallSignatures: Set<String> = []
  private var tracedMicrophoneStream = false
  private var tracedMicrophoneEnergy = false
  private var suppressProviderTurn = false
  private var previousRelayUtterance: String?
  private var previousRelayUtteranceAt = Date.distantPast
  private let traceLimit = 200
  private let conversationLimit = 200
  private let relayUtteranceLimit = 8_000
  private let relayUtteranceLifetime: TimeInterval = 120

  private let stateContinuation: AsyncStream<VoiceSessionSnapshot>.Continuation
  public nonisolated let updates: AsyncStream<VoiceSessionSnapshot>
  private let actionContinuation: AsyncStream<VoiceActionEvent>.Continuation
  public nonisolated let actions: AsyncStream<VoiceActionEvent>
  private let traceContinuation: AsyncStream<[VoiceTraceEntry]>.Continuation
  public nonisolated let traceUpdates: AsyncStream<[VoiceTraceEntry]>
  private let conversationContinuation: AsyncStream<[VoiceConversationRecord]>.Continuation
  public nonisolated let conversationUpdates: AsyncStream<[VoiceConversationRecord]>

  public init(
    registry: ToolRegistry,
    context: ToolContext,
    audioTransport: (any VoiceAudioTransport)? = nil,
    taskPlanner: (any VoiceTaskPlanning)? = nil,
    notificationPolicy: CompletionNotificationPolicy = CompletionNotificationPolicy(),
    permissionDefaultsSuiteName: String? = nil
  ) {
    self.registry = registry
    self.context = context
    self.audioTransport = audioTransport
    self.taskPlanner = taskPlanner
    self.notificationPolicy = notificationPolicy
    self.permissionDefaultsSuiteName = permissionDefaultsSuiteName
    var continuation: AsyncStream<VoiceSessionSnapshot>.Continuation!
    updates = AsyncStream { continuation = $0 }
    stateContinuation = continuation
    var actionContinuation: AsyncStream<VoiceActionEvent>.Continuation!
    actions = AsyncStream { actionContinuation = $0 }
    self.actionContinuation = actionContinuation
    var traceContinuation: AsyncStream<[VoiceTraceEntry]>.Continuation!
    traceUpdates = AsyncStream { traceContinuation = $0 }
    self.traceContinuation = traceContinuation
    var conversationContinuation: AsyncStream<[VoiceConversationRecord]>.Continuation!
    conversationUpdates = AsyncStream { conversationContinuation = $0 }
    self.conversationContinuation = conversationContinuation
  }

  deinit {
    eventTask?.cancel()
    audioOutputTask?.cancel()
    noticeFlushTask?.cancel()
    for task in delegationTasks.values { task.cancel() }
  }

  public func connect(provider: any VoiceProvider, microphoneEnabled: Bool = true) async {
    eventTask?.cancel()
    cancelDelegations()
    self.provider = provider
    current.lastError = nil
    current.lastConfirmation = ""
    userInputActive = false
    failedCallSignatures.removeAll()
    tracedMicrophoneStream = false
    tracedMicrophoneEnergy = false
    suppressProviderTurn = false
    previousRelayUtterance = nil
    previousRelayUtteranceAt = .distantPast
    lastTranscriptTurnID = nil
    provisionalUserRecordID = nil
    activeAssistantRecordID = nil
    appendTrace(kind: .session, title: "Voice connecting")
    transition(to: .connecting)
    eventTask = Task { [weak self] in
      for await event in provider.events {
        guard !Task.isCancelled else { break }
        await self?.handle(event)
      }
    }
    let streamingProvider = provider as? any StreamingVoiceProvider
    if let streamingProvider { startAudioOutput(provider: streamingProvider) }
    let audioStartTask: Task<Void, any Error>? =
      if let streamingProvider, microphoneEnabled {
        Task { try await self.startMicrophoneInput(provider: streamingProvider) }
      } else { nil }
    do {
      // Start the local microphone as soon as the user explicitly enables voice. Network
      // negotiation can take several seconds (or reconnect), but local signal diagnostics and
      // the privacy indicator must accurately show whether Otto can hear during that interval.
      // Audio sends made before the socket is ready are safely discarded by the provider and the
      // continuous stream takes over once the connection completes.
      var projectedTools = await registry.definitions().filter { !$0.isProviderInternal }
      if taskPlanner != nil { projectedTools.append(VoiceTaskDelegationTool.definition) }
      try await provider.connect(tools: projectedTools)
      if let latestContext { await provider.updateContext(latestContext) }
      try await audioStartTask?.value
    } catch {
      audioStartTask?.cancel()
      eventTask?.cancel()
      eventTask = nil
      audioOutputTask?.cancel()
      audioOutputTask = nil
      microphoneInputStarted = false
      await audioTransport?.stop()
      await provider.disconnect()
      self.provider = nil
      current.lastError = VoiceFailureText.message(for: error)
      appendTrace(
        kind: .error,
        title: "Voice connection failed",
        detail: VoiceFailureText.technicalDetail(for: error),
        succeeded: false
      )
      transition(to: .error)
    }
  }

  public func sleep() async {
    eventTask?.cancel()
    eventTask = nil
    audioOutputTask?.cancel()
    audioOutputTask = nil
    microphoneInputStarted = false
    cancelDelegations()
    noticeFlushTask?.cancel()
    noticeFlushTask = nil
    if !notificationPolicy.queueWhileSleeping { pendingNotices.removeAll() }
    await audioTransport?.stop()
    await provider?.disconnect()
    provider = nil
    userInputActive = false
    suppressProviderTurn = false
    previousRelayUtterance = nil
    previousRelayUtteranceAt = .distantPast
    lastTranscriptTurnID = nil
    provisionalUserRecordID = nil
    finalizeAssistantRecord()
    current.partialTranscript = ""
    transition(to: .sleeping)
  }

  public func interrupt() async {
    await audioTransport?.stopPlayback()
    await provider?.interrupt()
    appendTrace(kind: .interruption, title: "Response interrupted")
    transition(to: .interrupted)
  }

  public func updateContext(_ context: VoiceContext) async {
    latestContext = context
    await provider?.updateContext(context)
  }

  public func updateNotificationPolicy(_ policy: CompletionNotificationPolicy) {
    notificationPolicy = policy
  }

  /// Hides a background space's audio without cancelling its in-flight tool calls.
  public func setPresentationEnabled(_ enabled: Bool) async {
    presentationEnabled = enabled
    if !enabled { await audioTransport?.stopPlayback() }
  }

  public func setMicrophoneEnabled(_ enabled: Bool) async {
    guard let streamingProvider = provider as? any StreamingVoiceProvider else { return }
    if enabled, !microphoneInputStarted {
      do {
        try await startMicrophoneInput(provider: streamingProvider)
      } catch {
        current.lastError = VoiceFailureText.message(for: error)
        appendTrace(
          kind: .error,
          title: "Microphone failed",
          detail: VoiceFailureText.technicalDetail(for: error),
          succeeded: false
        )
        transition(to: .error)
      }
      return
    }
    await audioTransport?.setInputEnabled(enabled)
  }

  public func notify(_ notice: AgentVoiceNotice) async {
    guard presentationEnabled, shouldAnnounce(notice) else { return }
    // Before the first connection the session is technically `disconnected`, not `sleeping`.
    // Treat every inactive state the same so enabling voice cannot replay the whole workday.
    if !notificationPolicy.queueWhileSleeping,
      provider == nil || [.sleeping, .disconnected, .error].contains(current.state)
    {
      return
    }
    if let index = pendingNotices.firstIndex(where: { $0.agentID == notice.agentID }) {
      pendingNotices[index] = notice
    } else {
      pendingNotices.append(notice)
    }
    schedulePendingNoticeFlush()
  }

  public func snapshot() -> VoiceSessionSnapshot { current }

  public func conversationTrace() -> [VoiceTraceEntry] { trace }

  public func conversationRecords() -> [VoiceConversationRecord] { conversation }

  public func clearConversationTrace() {
    trace.removeAll()
    conversation.removeAll()
    currentTurnID = nil
    provisionalUserRecordID = nil
    activeAssistantRecordID = nil
    traceContinuation.yield(trace)
    conversationContinuation.yield(conversation)
  }

  private func handle(_ event: VoiceProviderEvent) async {
    switch event {
    case .connected:
      appendTrace(kind: .session, title: "Voice connected")
      transition(to: .listening)
      schedulePendingNoticeFlush()
    case .reconnecting:
      transition(to: .connecting)
    case .speechStarted:
      suppressProviderTurn = false
      userInputActive = true
      failedCallSignatures.removeAll()
      currentTurnID = UUID()
      // A new request supersedes whatever went wrong last time.
      current.lastError = nil
      provisionalUserRecordID = nil
      if [.speaking, .thinking, .callingTool].contains(current.state), !allowsOverlappingAudio {
        await audioTransport?.stopPlayback()
        appendTrace(
          kind: .interruption,
          title: "User barged in",
          detail: "Stopped assistant playback and returned to microphone input."
        )
      }
      transition(to: .userSpeaking)
    case .speechStopped:
      transition(to: .endOfTurn)
    case .partialTranscript(let text):
      suppressProviderTurn = false
      userInputActive = true
      current.partialTranscript = text
      upsertUserRecord(text: text, authority: .speculative)
      transition(to: .userSpeaking)
    case .finalTranscript(let text):
      userInputActive = false
      failedCallSignatures.removeAll()
      current.partialTranscript = ""
      // A committed turn with no usable words — a stray push-to-talk tap, a turn spanning only
      // gated silence, or a failed transcription — must fully release the turn. Leaving the
      // session parked in endOfTurn (or, before this check existed, with userInputActive latched)
      // silently dropped every later assistant audio buffer and queued completion notice.
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        discardProvisionalUserRecord()
        transition(to: .listening)
        schedulePendingNoticeFlush()
        return
      }
      // Resumption reconnects can replay the last committed utterance; a second identical
      // transcript within a few seconds is a replay, not the user repeating themselves.
      let isReplay =
        text == lastFinalTranscriptText
        && Date.now.timeIntervalSince(lastFinalTranscriptAt) < 5
      // Server VAD can finalize mid-sentence; the continuation then arrives as a second
      // "final" that extends the first. Treat it as the same utterance: the trace shows one
      // growing row instead of a stack of truncated ones.
      let extendsPrevious =
        !lastFinalTranscriptText.isEmpty
        && text.hasPrefix(lastFinalTranscriptText)
        && text != lastFinalTranscriptText
        && Date.now.timeIntervalSince(lastFinalTranscriptAt) < 8
      lastFinalTranscriptText = text
      lastFinalTranscriptAt = .now
      guard !isReplay else { return }
      current.lastTranscript = text
      current.lastError = nil
      if currentTurnID == nil { currentTurnID = UUID() }
      upsertUserRecord(text: text, authority: .authoritative)
      provisionalUserRecordID = nil
      lastTranscriptTurnID = currentTurnID
      if extendsPrevious, replaceLastTrace(kind: .user, detail: text) {
        // Coalesced into the previous row.
      } else {
        appendTrace(kind: .user, title: "User", detail: text)
      }
      if SpokenVoiceLifecycle.isSleepCommand(text) {
        current.lastConfirmation = "Going to sleep"
        appendTrace(
          kind: .session,
          title: "Voice sleeping",
          detail: "Handled locally from the final transcript."
        )
        await sleep()
        return
      }
      if await handleVerbatimRelay(text) { return }
      rememberRelayUtterance(text)
      transition(to: .endOfTurn)
    case .thinking:
      guard !suppressProviderTurn else { return }
      current.lastConfirmation = ""
      transition(to: .thinking)
    case .toolCall(let id, let name, let arguments):
      guard !suppressProviderTurn else { return }
      scheduleDelegation(id: id, name: name, arguments: arguments)
    case .speaking(let text):
      guard !suppressProviderTurn else { return }
      guard !userInputActive || allowsOverlappingAudio else { return }
      if current.state == .speaking {
        current.lastConfirmation += text
      } else {
        current.lastConfirmation = text
      }
      appendAssistantDelta(text)
      appendAssistantRecordDelta(text)
      transition(to: .speaking)
    case .speechFinished:
      finalizeAssistantRecord()
      if suppressProviderTurn {
        transition(to: .listening)
        return
      }
      guard !userInputActive else { return }
      transition(to: .listening)
      schedulePendingNoticeFlush()
    case .interrupted:
      finalizeAssistantRecord()
      transition(
        to: suppressProviderTurn ? .listening : (userInputActive ? .userSpeaking : .interrupted))
    case .failed(let message):
      cancelDelegations()
      await audioTransport?.stop()
      current.lastError = message
      appendTrace(kind: .error, title: "Voice provider error", detail: message, succeeded: false)
      transition(to: .error)
    case .disconnected:
      cancelDelegations()
      await audioTransport?.stop()
      transition(to: .disconnected)
    }
  }

  private var allowsOverlappingAudio: Bool {
    provider?.capabilities.fullDuplexAudio == true
  }

  /// Runs application work independently from the serial provider event loop. Audio and transcript
  /// events can therefore continue while a slow agent or tool is executing.
  private func scheduleDelegation(id: String, name: String, arguments: JSONValue) {
    guard delegationTasks[id] == nil else { return }
    let callSignature = "\(name):\(traceString(arguments))"
    let turnID = currentTurnID
    guard !failedCallSignatures.contains(callSignature) else {
      let message = "Repeated failed action suppressed. Wait for a new user request."
      appendTrace(kind: .toolResult, title: name, detail: message, succeeded: false)
      let provider = self.provider
      delegationTasks[id] = Task { [weak self] in
        await provider?.sendToolResult(
          VoiceToolResult(
            callID: id,
            result: .object(["error": .string(message)]),
            isError: true
          ))
        await provider?.interrupt()
        await self?.finishDelegation(id: id, turnID: turnID, nextState: .interrupted)
      }
      return
    }

    appendTrace(kind: .toolRequest, title: name, detail: traceString(arguments))
    transition(to: .callingTool)
    let provider = self.provider
    delegationTasks[id] = Task { [weak self] in
      if name == VoiceTaskDelegationTool.name {
        await self?.executeTaskDelegation(
          id: id,
          arguments: arguments,
          turnID: turnID,
          provider: provider
        )
        return
      }
      await self?.executeDelegation(
        id: id,
        name: name,
        arguments: arguments,
        callSignature: callSignature,
        turnID: turnID,
        provider: provider
      )
    }
  }

  /// Acknowledges the handoff before doing any slower reasoning or process startup. The Realtime
  /// model can therefore finish its spoken turn and accept another request while the planner and
  /// workers operate on this independent path.
  private func executeTaskDelegation(
    id: String,
    arguments: JSONValue,
    turnID: UUID?,
    provider: (any VoiceProvider)?
  ) async {
    guard let planner = taskPlanner else {
      await sendTaskDelegationFailure(
        id: id,
        message: "The multi-task reasoning path is not configured",
        turnID: turnID,
        provider: provider
      )
      return
    }
    let objective =
      arguments["objective"]?.stringValue?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !objective.isEmpty else {
      await sendTaskDelegationFailure(
        id: id,
        message: "The delegated objective is empty",
        turnID: turnID,
        provider: provider
      )
      return
    }

    await provider?.sendToolResult(
      VoiceToolResult(
        callID: id,
        result: .object(["accepted": .bool(true)]),
        isError: false,
        responseInstruction: """
          The handoff is accepted and is running asynchronously. Say only: I'm starting those now. \
          Then keep listening; do not wait for results.
          """
      ))
    finishDelegation(id: id, turnID: turnID, nextState: .thinking)

    do {
      let availableProviders = await availableAgentProviders()
      let plan = try await planner.plan(
        objective: objective,
        context: latestContext,
        availableProviders: availableProviders
      )
      let output = await launch(plan: plan)
      actionContinuation.yield(
        VoiceActionEvent(
          callID: id,
          toolName: VoiceTaskDelegationTool.name,
          output: output
        ))
      current.lastError = nil
      appendTrace(
        kind: .toolResult,
        title: VoiceTaskDelegationTool.name,
        detail: traceString(output),
        succeeded: true
      )
    } catch {
      let message = VoiceFailureText.message(for: error)
      current.lastError = message
      appendTrace(
        kind: .toolResult,
        title: VoiceTaskDelegationTool.name,
        detail: VoiceFailureText.technicalDetail(for: error),
        succeeded: false
      )
      if current.state == .listening {
        await provider?.sendNotification("The delegated work could not start: \(message)")
      }
    }
    delegationTasks[id] = nil
  }

  private func sendTaskDelegationFailure(
    id: String,
    message: String,
    turnID: UUID?,
    provider: (any VoiceProvider)?
  ) async {
    current.lastError = message
    appendTrace(
      kind: .toolResult,
      title: VoiceTaskDelegationTool.name,
      detail: message,
      succeeded: false
    )
    await provider?.sendToolResult(
      VoiceToolResult(
        callID: id,
        result: .object(["error": .string(message)]),
        isError: true
      ))
    finishDelegation(id: id, turnID: turnID, nextState: .thinking)
  }

  /// The launch sheet, palette quick actions, and voice spawns all read the same per-provider
  /// defaults from OttoPreferenceKey; falling back to workspace write mirrors the sheet.
  static func defaultPermissionMode(
    forProvider provider: String,
    defaults: UserDefaults = .standard
  ) -> String {
    let key: String? =
      switch provider {
      case "Claude Code": OttoPreferenceKey.claudePermissionMode
      case "Codex": OttoPreferenceKey.codexPermissionMode
      case "Hermes": OttoPreferenceKey.hermesPermissionMode
      case "Cursor": OttoPreferenceKey.cursorPermissionMode
      case "Kimi": OttoPreferenceKey.kimiPermissionMode
      case "OpenCode": OttoPreferenceKey.openCodePermissionMode
      case "Grok": OttoPreferenceKey.grokPermissionMode
      case "Shell": OttoPreferenceKey.shellPermissionMode
      default: nil
      }
    guard let key, let stored = defaults.string(forKey: key), !stored.isEmpty else {
      return "workspaceWrite"
    }
    return stored
  }

  /// Permission mode is a product preference, not a choice for the realtime voice model. Direct
  /// voice calls still have to include the schema-required field, so replace that generated value
  /// with the same per-provider default used by every other new-agent launch path.
  static func applyingPermissionDefault(
    toAgentSpawnArguments arguments: JSONValue,
    defaults: UserDefaults = .standard
  ) -> JSONValue {
    guard case .object(var input) = arguments,
      let provider = input["provider"]?.stringValue
    else { return arguments }
    input["permissionMode"] = .string(
      defaultPermissionMode(forProvider: provider, defaults: defaults))
    return .object(input)
  }

  private var permissionDefaults: UserDefaults {
    permissionDefaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  private func availableAgentProviders() async -> [String] {
    guard
      let value = try? await registry.call(
        name: "agent.providers",
        input: .object([:]),
        context: executionContext(for: "agent.providers")
      ),
      case .array(let entries) = value
    else { return ["Codex"] }
    let providers = entries.compactMap { entry -> String? in
      guard entry["provider"]?.stringValue != "Shell",
        case .bool(true) = entry["installed"]
      else { return nil }
      return entry["provider"]?.stringValue
    }
    return providers.isEmpty ? ["Codex"] : providers
  }

  private func launch(plan: VoiceTaskPlan) async -> JSONValue {
    let registry = self.registry
    let context = executionContext(for: "agent.spawn")
    let promptContext = executionContext(for: "agent.send_prompt")
    let workspace = latestContext?.activeCanvas.workspace
    let permissionDefaults = self.permissionDefaults
    let count = plan.tasks.count
    let permissionModes = plan.tasks.map {
      Self.defaultPermissionMode(forProvider: $0.provider, defaults: permissionDefaults)
    }
    var results = [JSONValue?](repeating: nil, count: count)

    await withTaskGroup(of: (Int, JSONValue).self) { group in
      for (index, task) in plan.tasks.enumerated() {
        group.addTask {
          let combinedPrompt = "\(task.prompt)\n\nExpected output: \(task.expectedOutput)"
          // Reuse before spawning: when the planner matched an existing canvas agent, the task
          // goes to that agent instead of creating a lookalike twin beside it.
          if let existing = task.existingAgentID, let agentID = UUID(uuidString: existing) {
            do {
              let output = try await registry.call(
                name: "agent.send_prompt",
                input: .object([
                  "agentID": .string(agentID.uuidString),
                  "prompt": .string(combinedPrompt),
                ]),
                context: promptContext,
                requestID: "voice-delegation-\(UUID().uuidString)"
              )
              return (
                index,
                .object([
                  "title": .string(task.title),
                  "provider": .string(task.provider),
                  "started": .bool(true),
                  "reusedExistingAgent": .bool(true),
                  "agentID": output["agentID"] ?? .string(agentID.uuidString),
                ])
              )
            } catch {
              return (
                index,
                .object([
                  "title": .string(task.title),
                  "provider": .string(task.provider),
                  "started": .bool(false),
                  "reusedExistingAgent": .bool(true),
                  "error": .string(error.localizedDescription),
                ])
              )
            }
          }
          let x = Double(index % 3) * 620
          let y = Double(index / 3) * 480
          var input: [String: JSONValue] = [
            "provider": .string(task.provider),
            "displayName": .string(task.title),
            "prompt": .string(combinedPrompt),
            "x": .number(x),
            "y": .number(y),
            // Voice-delegated workers honor the same per-provider defaults the launch sheet
            // uses; a hardcoded mode here silently overrode the user's settings.
            "permissionMode": .string(permissionModes[index]),
            "isolatedWorktree": .bool(count > 1),
          ]
          if let workspace { input["workingDirectory"] = .string(workspace) }
          do {
            let output = try await registry.call(
              name: "agent.spawn",
              input: .object(input),
              context: context,
              requestID: "voice-delegation-\(UUID().uuidString)"
            )
            return (
              index,
              .object([
                "title": .string(task.title),
                "provider": .string(task.provider),
                "started": .bool(true),
                "agentID": output["agentID"] ?? .null,
              ])
            )
          } catch {
            return (
              index,
              .object([
                "title": .string(task.title),
                "provider": .string(task.provider),
                "started": .bool(false),
                "error": .string(error.localizedDescription),
              ])
            )
          }
        }
      }
      for await (index, result) in group { results[index] = result }
    }

    let launched = results.compactMap { $0 }
    return .object([
      "summary": .string(plan.summary),
      "taskCount": .number(Double(count)),
      "tasks": .array(launched),
    ])
  }

  private func executeDelegation(
    id: String,
    name: String,
    arguments: JSONValue,
    callSignature: String,
    turnID: UUID?,
    provider: (any VoiceProvider)?
  ) async {
    do {
      let resolvedArguments =
        name == "agent.spawn"
        ? Self.applyingPermissionDefault(
          toAgentSpawnArguments: arguments,
          defaults: permissionDefaults
        )
        : arguments
      let output = try await callDelegatedTool(
        name: name,
        arguments: resolvedArguments,
        requestID: id
      )
      guard !Task.isCancelled else {
        finishDelegation(id: id, turnID: turnID)
        return
      }
      actionContinuation.yield(VoiceActionEvent(callID: id, toolName: name, output: output))
      if currentTurnID == turnID {
        current.lastError = nil
        current.lastConfirmation = confirmation(for: name, output: output)
      }
      appendTrace(kind: .toolResult, title: name, detail: traceString(output), succeeded: true)
      let responseInstruction = successResponseInstruction(for: name)
      await provider?.sendToolResult(
        VoiceToolResult(
          callID: id,
          result: output,
          isError: false,
          responseInstruction: responseInstruction
        ))
    } catch {
      guard !Task.isCancelled else {
        finishDelegation(id: id, turnID: turnID)
        return
      }
      let message = VoiceFailureText.message(for: error)
      if currentTurnID == turnID {
        failedCallSignatures.insert(callSignature)
        current.lastError = message
      }
      appendTrace(
        kind: .toolResult,
        title: name,
        detail: VoiceFailureText.technicalDetail(for: error),
        succeeded: false
      )
      // The realtime model repeats tool errors aloud, so it gets the same wording the person sees.
      await provider?.sendToolResult(
        VoiceToolResult(
          callID: id,
          result: .object(["error": .string(message)]),
          isError: true
        ))
    }
    finishDelegation(id: id, turnID: turnID, nextState: .thinking)
  }

  /// Runs a tool the realtime model asked for. Spoken input for an agent goes through the relay
  /// so an agent that had just exited is continued rather than reported as a closed transport.
  private func callDelegatedTool(
    name: String,
    arguments: JSONValue,
    requestID: String
  ) async throws -> JSONValue {
    if name == VoiceAgentRelay.inputToolName,
      let agentID = arguments["agentID"]?.stringValue.flatMap(UUID.init(uuidString:)),
      let text = arguments["text"]?.stringValue
    {
      // The model chose send_input without telling us why. Read the state first so an answer
      // to a permission prompt is never replayed as a new turn if the agent has gone.
      let status = try? await registry.call(
        name: VoiceAgentRelay.statusToolName,
        input: .object(["agentID": .string(agentID.uuidString)]),
        context: executionContext(for: VoiceAgentRelay.statusToolName)
      )
      let delivery = try await VoiceAgentRelay.send(
        toolName: name,
        agentID: agentID,
        text: text,
        lastKnownState: status?["state"]?.stringValue,
        registry: registry,
        context: executionContext(for: name),
        requestID: requestID
      )
      if delivery.continuedAfterExit {
        appendTrace(
          kind: .session,
          title: "Agent had exited; continued as a prompt",
          detail: "agent.send_input found the agent's process gone, so the text was sent with "
            + "agent.send_prompt instead."
        )
      }
      return delivery.output
    }
    return try await registry.call(
      name: name,
      input: arguments,
      context: executionContext(for: name),
      requestID: requestID
    )
  }

  private func finishDelegation(
    id: String,
    turnID: UUID?,
    nextState: VoiceState? = nil
  ) {
    delegationTasks[id] = nil
    guard let nextState, currentTurnID == turnID, !userInputActive else { return }
    guard current.state == .callingTool || nextState == .interrupted else { return }
    transition(to: nextState)
  }

  private func cancelDelegations() {
    for task in delegationTasks.values { task.cancel() }
    delegationTasks.removeAll()
  }

  private func upsertUserRecord(
    text: String,
    authority: VoiceConversationAuthority
  ) {
    guard !text.isEmpty else { return }
    let turnID = currentTurnID ?? UUID()
    currentTurnID = turnID
    if let id = provisionalUserRecordID,
      let index = conversation.firstIndex(where: { $0.id == id })
    {
      conversation[index].text = text
      conversation[index].authority = authority
    } else {
      let record = VoiceConversationRecord(
        turnID: turnID,
        role: .user,
        text: text,
        authority: authority
      )
      conversation.append(record)
      if authority == .speculative { provisionalUserRecordID = record.id }
    }
    publishConversation()
  }

  private func appendAssistantRecordDelta(_ text: String) {
    guard !text.isEmpty else { return }
    if let id = activeAssistantRecordID,
      let index = conversation.firstIndex(where: { $0.id == id })
    {
      conversation[index].text += text
    } else {
      let turnID = currentTurnID ?? UUID()
      currentTurnID = turnID
      let record = VoiceConversationRecord(
        turnID: turnID,
        role: .assistant,
        text: text,
        authority: .speculative
      )
      conversation.append(record)
      activeAssistantRecordID = record.id
    }
    publishConversation()
  }

  private func discardProvisionalUserRecord() {
    if let id = provisionalUserRecordID,
      let index = conversation.firstIndex(where: { $0.id == id })
    {
      conversation.remove(at: index)
      publishConversation()
    }
    provisionalUserRecordID = nil
  }

  private func finalizeAssistantRecord() {
    guard let id = activeAssistantRecordID,
      let index = conversation.firstIndex(where: { $0.id == id })
    else { return }
    conversation[index].authority = .authoritative
    activeAssistantRecordID = nil
    publishConversation()
  }

  private func publishConversation() {
    if conversation.count > conversationLimit {
      conversation.removeFirst(conversation.count - conversationLimit)
    }
    conversationContinuation.yield(conversation)
  }

  private func shouldAnnounce(_ notice: AgentVoiceNotice) -> Bool {
    switch notice.status {
    case .done: notificationPolicy.announceCompletions
    case .failed: notificationPolicy.announceFailures
    case .waiting: notificationPolicy.announceWaiting
    default: false
    }
  }

  private func flushPendingNotices() async {
    guard !pendingNotices.isEmpty else { return }
    // Background updates never pre-empt the person: while the user is speaking or an exchange
    // is mid-flight, keep the digest queued and try again shortly. It arrives as an aside once
    // the conversation is quiet, not as a topic change.
    guard current.state == .listening, !userInputActive else {
      noticeFlushTask?.cancel()
      noticeFlushTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(900))
        guard !Task.isCancelled else { return }
        await self?.flushPendingNotices()
      }
      return
    }
    noticeFlushTask?.cancel()
    noticeFlushTask = nil
    let notices = pendingNotices
    pendingNotices.removeAll()
    // Deference to the user's own request is enforced structurally by the guard above — notices
    // only flush while the session is listening and quiet. The prompt must never restate that
    // policy: realtime models paraphrase meta-instructions aloud ("you've got an open request,
    // finish that first…") before the useful part. The contract is only: open with the aside,
    // state the outcome.
    let aside =
      "Speak one brief aside that begins with \"By the way\" and immediately states the useful "
      + "outcome, with enough context to identify which agent and which task. "
    let text: String
    if notices.count == 1 {
      text =
        aside
        + "Use one or two conversational sentences. Summarize; never read the notes verbatim. "
        + render(notices[0])
    } else {
      let visible = notices.prefix(20)
      let remainder = notices.count - visible.count
      text =
        aside
        + "\(notices.count) agent updates arrived together. Give one short grouped digest, prioritizing failures and agents needing input; do not narrate each tool action. "
        + visible.map(render).joined(separator: "; ")
        + (remainder > 0 ? "; plus \(remainder) more completed updates" : "")
    }
    await provider?.sendNotification(text)
  }

  private func schedulePendingNoticeFlush() {
    guard current.state == .listening, !pendingNotices.isEmpty else { return }
    noticeFlushTask?.cancel()
    noticeFlushTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(650))
      guard !Task.isCancelled else { return }
      await self?.flushPendingNotices()
    }
  }

  private func render(_ notice: AgentVoiceNotice) -> String {
    let summary = compactNoticeSummary(notice.summary, preferTail: notice.status == .done)
    return switch notice.status {
    case .done: "\(notice.name) finished. Notes: \(summary)"
    case .failed: "\(notice.name) failed. Notes: \(summary)"
    case .waiting: "\(notice.name) needs attention. Notes: \(summary)"
    default: "\(notice.name). Notes: \(summary)"
    }
  }

  private func compactNoticeSummary(_ summary: String, preferTail: Bool) -> String {
    let lines =
      summary
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let compact = lines.joined(separator: " ")
    return preferTail ? String(compact.suffix(800)) : String(compact.prefix(800))
  }

  private func startMicrophoneInput(provider: any StreamingVoiceProvider) async throws {
    guard let audioTransport else { return }
    await audioTransport.setInputEnabled(true)
    await audioTransport.setSpeechActivityHandler { [weak self] in
      Task { await self?.handleLocalSpeechActivity() }
    }
    await audioTransport.setInputMetricsHandler { [weak self] metrics in
      Task { await self?.handleInputMetrics(metrics) }
    }
    try await audioTransport.startInput { data in
      Task { try? await provider.sendAudio(data) }
    }
    microphoneInputStarted = true
  }

  private func startAudioOutput(provider: any StreamingVoiceProvider) {
    guard let audioTransport else { return }
    audioOutputTask?.cancel()
    audioOutputTask = Task {
      for await data in provider.audioOutput {
        guard !Task.isCancelled else { break }
        guard presentationEnabled, shouldPlayProviderAudio else { continue }
        try? await audioTransport.play(data)
      }
    }
  }

  private func handleLocalSpeechActivity() async {
    guard [.speaking, .thinking, .callingTool].contains(current.state) else { return }
    userInputActive = true
    currentTurnID = UUID()
    current.lastError = nil
    failedCallSignatures.removeAll()
    if allowsOverlappingAudio {
      provisionalUserRecordID = nil
      transition(to: .userSpeaking)
      return
    }
    await audioTransport?.stopPlayback()
    appendTrace(
      kind: .interruption,
      title: "Local barge-in",
      detail: "Microphone speech stopped playback before provider VAD completed."
    )
    transition(to: .userSpeaking)
    await provider?.interrupt()
  }

  private func handleInputMetrics(_ metrics: VoiceAudioInputMetrics) {
    current.inputDiagnostic = LocalSpeechInputDiagnostic(
      inputName: metrics.inputName,
      sampleRate: metrics.sampleRate,
      channelCount: metrics.channelCount,
      rootMeanSquare: metrics.rootMeanSquare
    )
    stateContinuation.yield(current)
    if !tracedMicrophoneStream {
      tracedMicrophoneStream = true
      appendTrace(
        kind: .session,
        title: "Microphone streaming",
        detail: String(
          format: "%d input frames; %d PCM bytes; input RMS %.4f.",
          metrics.inputFrames,
          metrics.outputBytes,
          metrics.rootMeanSquare
        )
      )
    }
    if !tracedMicrophoneEnergy, metrics.rootMeanSquare >= 0.008 {
      tracedMicrophoneEnergy = true
      appendTrace(
        kind: .session,
        title: "Microphone signal detected",
        detail: String(format: "RMS %.4f after voice processing.", metrics.rootMeanSquare)
      )
    }
  }

  private var shouldPlayProviderAudio: Bool {
    VoicePlaybackPolicy.shouldPlayProviderAudio(
      suppressProviderTurn: suppressProviderTurn,
      userInputActive: userInputActive,
      state: current.state,
      capabilities: provider?.capabilities ?? .turnBased
    )
  }

  private func handleVerbatimRelay(_ transcript: String) async -> Bool {
    switch VerbatimRelayParser.parse(
      transcript,
      context: latestContext,
      previousUtterance: recentRelayUtterance()
    ) {
    case .noMatch:
      return false
    case .rejected(let message):
      suppressProviderTurn = true
      await provider?.interrupt()
      current.lastError = message
      current.lastConfirmation = ""
      appendTrace(
        kind: .error,
        title: "Verbatim relay not sent",
        detail: message,
        succeeded: false
      )
      transition(to: .listening)
      return true
    case .relay(let intent):
      suppressProviderTurn = true
      await provider?.interrupt()
      transition(to: .callingTool)

      do {
        if intent.source == .previousUtterance {
          appendTrace(
            kind: .session,
            title: "Using previous utterance verbatim",
            detail: intent.prompt
          )
        }
        let status = try await registry.call(
          name: "agent.get_status",
          input: .object(["agentID": .string(intent.targetID.uuidString)]),
          context: context
        )
        let waitingStates = ["WAITING_PERMISSION", "WAITING_USER"]
        let toolName =
          waitingStates.contains(status["state"]?.stringValue ?? "")
          ? VoiceAgentRelay.inputToolName
          : VoiceAgentRelay.promptToolName
        let arguments = VoiceAgentRelay.arguments(
          for: toolName, agentID: intent.targetID, text: intent.prompt)

        appendTrace(kind: .toolRequest, title: toolName, detail: traceString(arguments))
        let delivery = try await VoiceAgentRelay.send(
          toolName: toolName,
          agentID: intent.targetID,
          text: intent.prompt,
          lastKnownState: status["state"]?.stringValue,
          registry: registry,
          context: context
        )
        if delivery.continuedAfterExit {
          appendTrace(
            kind: .session,
            title: "Agent had exited; continued as a prompt",
            detail: "agent.send_input found the agent's process gone, so the text was sent with "
              + "agent.send_prompt instead."
          )
        }
        actionContinuation.yield(
          VoiceActionEvent(
            callID: "local-verbatim-\(UUID().uuidString)",
            toolName: delivery.toolName,
            output: delivery.output
          )
        )
        current.lastError = nil
        current.lastConfirmation = "Sent verbatim to \(intent.targetName)"
        appendTrace(
          kind: .toolResult,
          title: delivery.toolName,
          detail: traceString(delivery.output),
          succeeded: true
        )
      } catch {
        current.lastError = VoiceFailureText.message(for: error)
        current.lastConfirmation = ""
        appendTrace(
          kind: .toolResult,
          title: "Verbatim relay",
          detail: VoiceFailureText.technicalDetail(for: error),
          succeeded: false
        )
      }
      transition(to: .listening)
      return true
    }
  }

  private func rememberRelayUtterance(_ transcript: String) {
    let candidate = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty, candidate.count <= relayUtteranceLimit else {
      previousRelayUtterance = nil
      previousRelayUtteranceAt = .distantPast
      return
    }
    previousRelayUtterance = candidate
    previousRelayUtteranceAt = .now
  }

  private func recentRelayUtterance() -> String? {
    guard Date.now.timeIntervalSince(previousRelayUtteranceAt) <= relayUtteranceLifetime else {
      previousRelayUtterance = nil
      previousRelayUtteranceAt = .distantPast
      return nil
    }
    return previousRelayUtterance
  }

  private func transition(to state: VoiceState) {
    current.state = state
    stateContinuation.yield(current)
  }

  private func confirmation(for name: String, output: JSONValue) -> String {
    switch name {
    case "node.close_all":
      return output["message"]?.stringValue ?? "Closed the requested nodes"
    case "agent.spawn_mock":
      return "Agent created"
    case "agent.send_prompt":
      return ""
    case "agent.send_input":
      return ""
    default:
      return "Completed \(name)"
    }
  }

  private func successResponseInstruction(for toolName: String) -> String? {
    if toolName == "agent.send_prompt" || toolName == "agent.send_input" {
      return """
        Do not speak or acknowledge this tool call. The agent is working; wait for its completion \
        notification.
        """
    }

    let queryNames: Set<String> = [
      "get", "list", "read", "search", "status", "providers", "get_selection",
    ]
    let leaf = toolName.split(separator: ".").last.map(String.init) ?? toolName
    if queryNames.contains(leaf) { return nil }

    let visibleMutationPrefixes = [
      "node.", "document.", "browser.", "recording.",
    ]
    if visibleMutationPrefixes.contains(where: { toolName.hasPrefix($0) })
      || toolName == "agent.spawn" || toolName == "agent.spawn_mock"
    {
      return """
        Do not speak or acknowledge success. The user can already see the completed action on the \
        app.
        """
    }
    return nil
  }

  private func executionContext(for toolName: String) -> ToolContext {
    var executionContext = context
    if toolName == "node.close_all", currentTurnAuthorizesDestructiveAction() {
      executionContext.confirmed = true
    }
    return executionContext
  }

  private func currentTurnAuthorizesDestructiveAction() -> Bool {
    guard lastTranscriptTurnID == currentTurnID else { return false }
    let normalized = current.lastTranscript
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !normalized.isEmpty else { return false }

    // xAI's selected tool is the semantic intent decision. This local layer only rejects clear
    // non-action language so natural requests and contextual pronouns do not depend on a phrase list.
    let blockedPhrases = [
      "don't", "do not", "dont", "never", "not yet", "stop", "cancel", "without actually",
      "hypothetically", "pretend", "what if", "what would happen", "should i", "should we",
      "explain", "describe", "tell me about",
    ]
    return !blockedPhrases.contains(where: normalized.contains)
  }

  private func appendAssistantDelta(_ delta: String) {
    guard !delta.isEmpty else { return }
    if let index = trace.indices.last,
      trace[index].kind == .assistant,
      trace[index].turnID == currentTurnID
    {
      trace[index].detail = String((trace[index].detail + delta).prefix(4_000))
      traceContinuation.yield(trace)
    } else {
      appendTrace(kind: .assistant, title: "Otto", detail: delta)
    }
  }

  private func appendTrace(
    kind: VoiceTraceKind,
    title: String,
    detail: String = "",
    succeeded: Bool? = nil
  ) {
    trace.append(
      VoiceTraceEntry(
        turnID: currentTurnID,
        kind: kind,
        title: title,
        detail: String(detail.prefix(4_000)),
        succeeded: succeeded
      ))
    trace = Array(trace.suffix(traceLimit))
    traceContinuation.yield(trace)
  }

  /// Rewrites the most recent trace row of the given kind in place — used to coalesce
  /// progressive VAD finals into one growing utterance instead of a stack of truncated rows.
  private func replaceLastTrace(kind: VoiceTraceKind, detail: String) -> Bool {
    guard let index = trace.lastIndex(where: { $0.kind == kind }) else { return false }
    trace[index].detail = String(detail.prefix(4_000))
    trace[index].timestamp = .now
    traceContinuation.yield(trace)
    return true
  }

  private func traceString(_ value: JSONValue) -> String {
    if case .array(let elements)? = value["elements"] {
      let url = value["url"]?.stringValue ?? "current page"
      return "\(url) — \(elements.count) interactive elements"
    }
    if let url = value["url"]?.stringValue,
      let action = value["requestedAction"]?.stringValue
    {
      let title = value["title"]?.stringValue
      return [url, title, action].compactMap { $0 }.joined(separator: " — ")
    }
    guard let data = try? JSONEncoder().encode(value) else { return "<unavailable>" }
    guard data.count > 800 else { return String(decoding: data, as: UTF8.self) }
    return "\(String(decoding: data.prefix(720), as: UTF8.self))… (\(data.count) bytes)"
  }
}
