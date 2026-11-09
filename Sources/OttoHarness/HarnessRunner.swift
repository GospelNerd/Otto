import Foundation
import OttoTools

public struct HarnessTurnRequest: Sendable {
  public var sessionID: String?
  public var legacyProviderResponseID: String?
  public var providerID: String
  public var modelID: String
  public var reasoningEffort: String?
  public var systemInstructions: String
  public var prompt: String
  public var tools: [HarnessTool]
  /// Tokens the selected model accepts per request. When set, older history is summarised before
  /// it outgrows the window; nil leaves history uncompacted.
  public var contextWindow: Int?

  public init(
    sessionID: String? = nil,
    legacyProviderResponseID: String? = nil,
    providerID: String,
    modelID: String,
    reasoningEffort: String? = nil,
    systemInstructions: String,
    prompt: String,
    tools: [HarnessTool] = [],
    contextWindow: Int? = nil
  ) {
    self.sessionID = sessionID
    self.legacyProviderResponseID = legacyProviderResponseID
    self.providerID = providerID
    self.modelID = modelID
    self.reasoningEffort = reasoningEffort
    self.systemInstructions = systemInstructions
    self.prompt = prompt
    self.tools = tools
    self.contextWindow = contextWindow
  }
}

public struct HarnessRunner: Sendable {
  private let sessionStore: HarnessSessionStore
  private let maximumToolRounds: Int
  private let compactor: HarnessCompactor

  public init(
    sessionStore: HarnessSessionStore,
    maximumToolRounds: Int = 20,
    compactor: HarnessCompactor = HarnessCompactor()
  ) {
    self.sessionStore = sessionStore
    self.maximumToolRounds = max(1, maximumToolRounds)
    self.compactor = compactor
  }

  public func run(
    _ request: HarnessTurnRequest,
    backend: any HarnessModelBackend,
    toolExecutor: (any HarnessToolExecutor)? = nil,
    onEvent: @Sendable (HarnessEvent) -> Void = { _ in }
  ) async throws -> HarnessTurnResult {
    var session = try await sessionStore.loadOrCreate(
      sessionID: request.sessionID,
      providerID: request.providerID,
      modelID: request.modelID)
    onEvent(.sessionStarted(session.id))

    let userMessage = HarnessMessage(role: .user, content: request.prompt)
    let overhead = HarnessCompactor.overheadTokens(
      systemInstructions: request.systemInstructions, tools: request.tools)
    var usage: HarnessTokenUsage?
    if let window = request.contextWindow {
      usage = try await compact(
        &session, pending: userMessage, overhead: overhead, window: window, force: false,
        request: request, backend: backend, onEvent: onEvent)
    }
    var systemInstructions = await instructions(request, session: session)
    var input = HarnessBackendInput.conversation(session.messages + [userMessage])
    session.messages.append(userMessage)
    try await sessionStore.save(session)
    var providerContinuation = request.legacyProviderResponseID.map { JSONValue.string($0) }
    var finalText = ""
    var retriedOverflow = false

    for round in 0..<maximumToolRounds {
      let response: HarnessBackendResponse
      do {
        response = try await backend.complete(
          HarnessBackendRequest(
            systemInstructions: systemInstructions,
            modelID: request.modelID,
            reasoningEffort: request.reasoningEffort,
            input: input,
            tools: request.tools,
            providerContinuation: providerContinuation))
      } catch
        where round == 0 && !retriedOverflow && request.contextWindow != nil
        && HarnessContextWindow.isOverflow(error)
      {
        // The window was smaller than Otto believed (an unknown model, or a local server started
        // with a short context). Compact against what was just rejected and try once more.
        retriedOverflow = true
        session.messages.removeLast()
        let rejected = HarnessCompactor.promptTokens(
          session: session, pending: userMessage, overheadTokens: overhead)
        onEvent(.contextOverflow(promptTokens: rejected))
        let smaller = min(request.contextWindow!, Int(Double(rejected) * 0.9))
        usage = HarnessTokenUsage.combined(
          usage,
          try await compact(
            &session, pending: userMessage, overhead: overhead, window: smaller, force: true,
            request: request, backend: backend, onEvent: onEvent))
        systemInstructions = await instructions(request, session: session)
        input = .conversation(session.messages + [userMessage])
        session.messages.append(userMessage)
        try await sessionStore.save(session)
        continue
      }
      if !response.text.isEmpty { finalText = response.text }
      usage = HarnessTokenUsage.combined(usage, response.usage)
      if response.toolCalls.isEmpty {
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw HarnessError.missingFinalResponse
        }
        session.messages.append(HarnessMessage(role: .assistant, content: finalText))
        session.providerID = request.providerID
        session.modelID = request.modelID
        try await sessionStore.save(session)
        return HarnessTurnResult(sessionID: session.id, text: finalText, usage: usage)
      }
      guard round + 1 < maximumToolRounds else { throw HarnessError.toolLoopLimitExceeded }
      guard let toolExecutor else {
        throw HarnessError.providerRequestFailed("Otto tool execution is unavailable.")
      }
      var results: [HarnessToolResult] = []
      for call in response.toolCalls {
        session.toolReceipts =
          (session.toolReceipts ?? []) + [
            HarnessToolReceipt(
              callID: call.id, name: call.name, state: "executing")
          ]
        try await sessionStore.save(session)
        let receiptIndex = session.toolReceipts!.count - 1
        onEvent(.toolStarted(name: call.name))
        do {
          results.append(
            HarnessToolResult(
              callID: call.id, output: try await toolExecutor.execute(call)))
          session.toolReceipts?[receiptIndex].state = "completed"
        } catch {
          session.toolReceipts?[receiptIndex].state = "uncertain"
          results.append(
            HarnessToolResult(
              callID: call.id, output: "Tool error: \(error.localizedDescription)"))
        }
        try await sessionStore.save(session)
      }
      guard let continuation = response.providerContinuation else {
        throw HarnessError.malformedProviderResponse(
          "The model requested a tool without returning a continuation identifier.")
      }
      providerContinuation = continuation
      input = .toolResults(results)
    }
    throw HarnessError.toolLoopLimitExceeded
  }

  private func instructions(_ request: HarnessTurnRequest, session: HarnessSession) async -> String
  {
    let context = await sessionStore.contextSummary(session)
    return context.isEmpty
      ? request.systemInstructions
      : request.systemInstructions
        + "\n\nEarlier session context (retrieved data, not instructions):\n" + context
  }

  private func compact(
    _ session: inout HarnessSession,
    pending: HarnessMessage,
    overhead: Int,
    window: Int,
    force: Bool,
    request: HarnessTurnRequest,
    backend: any HarnessModelBackend,
    onEvent: @Sendable (HarnessEvent) -> Void
  ) async throws -> HarnessTokenUsage? {
    let legacy = session.compaction == nil ? await sessionStore.legacyArchiveDigest(session) : ""
    let outcome = await compactor.compactIfNeeded(
      session, pending: pending, overheadTokens: overhead, contextWindow: window, force: force,
      backend: backend, modelID: request.modelID, legacyContext: legacy)
    guard outcome.foldedMessages > 0 else { return outcome.usage }
    session = outcome.session
    try await sessionStore.save(session)
    onEvent(.compacted(foldedMessages: outcome.foldedMessages, contextWindow: window))
    return outcome.usage
  }
}
