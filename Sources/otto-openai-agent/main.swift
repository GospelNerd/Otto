import Foundation
import OttoControl
import OttoHarness
import OttoModels
import OttoTools

private enum DirectRuntimeError: Error, LocalizedError {
  case invalidArguments(String)
  case missingAPIKey(String)

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let detail): detail
    case .missingAPIKey(let provider):
      "\(provider) API key is missing. Add it in Otto Settings → Models, then retry."
    }
  }
}

private struct Options {
  var idle = false
  var prompt = ""
  var system = ""
  var backend = "openai"
  var model = "gpt-5.6"
  var effort: String?
  var resumeID: String?

  init(arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      switch flag {
      case "--idle": idle = true
      case "--prompt-base64": prompt = try Self.decode(Self.value(after: &index, in: arguments))
      case "--system-base64": system = try Self.decode(Self.value(after: &index, in: arguments))
      case "--backend": backend = try Self.value(after: &index, in: arguments)
      case "--model": model = try Self.value(after: &index, in: arguments)
      case "--effort": effort = try Self.value(after: &index, in: arguments)
      // Keep the old spelling so sessions created by the 0.1.22 direct runtime migrate cleanly.
      case "--session-id", "--previous-response-id":
        resumeID = try Self.value(after: &index, in: arguments)
      default: throw DirectRuntimeError.invalidArguments("Unknown option: \(flag)")
      }
      index += 1
    }
    if !idle, prompt.isEmpty {
      throw DirectRuntimeError.invalidArguments("A prompt is required")
    }
  }

  private static func value(after index: inout Int, in arguments: [String]) throws -> String {
    index += 1
    guard index < arguments.count else {
      throw DirectRuntimeError.invalidArguments("Missing value for \(arguments[index - 1])")
    }
    return arguments[index]
  }

  private static func decode(_ encoded: String) throws -> String {
    guard let data = Data(base64Encoded: encoded), let value = String(data: data, encoding: .utf8)
    else { throw DirectRuntimeError.invalidArguments("Invalid base64 argument") }
    return value
  }
}

private struct ControlToolExecutor: HarnessToolExecutor {
  let client: ControlClient
  let actualNames: [String: String]

  func execute(_ call: HarnessToolCall) async throws -> String {
    guard let actualName = actualNames[call.name] else {
      throw DirectRuntimeError.invalidArguments("Unknown Otto tool: \(call.name)")
    }
    let result: JSONValue
    do {
      result = try await client.callAsync(
        actualName,
        arguments: call.arguments,
        requestID: call.id,
        timeoutMilliseconds: 3_600_000)
    } catch ControlProtocolError.remote(let failure)
      where failure.code == "tool_error"
      && failure.message == ToolRegistryError.confirmationRequired(actualName).localizedDescription
    {
      // Like Claude Code and Codex through the otto-mcp bridge: ask on Otto's approval card (and
      // Telegram, when allowed), then run the exact same call only if the person approves.
      let approval = try await client.callAsync(
        AgentPermissionPrompt.toolName,
        arguments: .object(["tool_name": .string(actualName), "input": call.arguments]),
        timeoutMilliseconds: actualName == "browser.click"
          ? AgentPermissionPrompt.browserResponseTimeoutMilliseconds
          : AgentPermissionPrompt.responseTimeoutMilliseconds)
      guard approval["behavior"]?.stringValue == "allow" else {
        let reason = approval["message"]?.stringValue ?? "The user denied \(actualName) in Otto"
        return "Not done: \(reason). Do not retry this action unless the user asks again."
      }
      // The approval can take minutes; a turn stopped meanwhile must not still run the action.
      try Task.checkCancellation()
      result = try await client.callAsync(
        actualName,
        arguments: call.arguments,
        confirmed: true,
        requestID: "\(call.id)-approved",
        timeoutMilliseconds: 3_600_000)
    }
    guard let data = try? JSONEncoder().encode(result) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}

@main
private enum OttoOpenAIAgent {
  static func main() async {
    if CommandLine.arguments.dropFirst().contains("--version") {
      print("otto-openai-agent 3.0.0")
      return
    }
    do {
      let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
      if options.idle {
        emit(["type": "thread.started", "thread_id": HarnessSession.makeID()])
        while readLine() != nil {}
        return
      }
      try await run(options)
    } catch {
      emit(["type": "turn.failed", "message": error.localizedDescription])
      Foundation.exit(1)
    }
  }

  private static func run(_ options: Options) async throws {
    let providerName = providerDisplayName(options.backend)
    let apiKey =
      (options.backend == "local"
      ? OttoEnvironment.value("MODEL_API_KEY")
      : (OttoEnvironment.value("MODEL_API_KEY") ?? OttoEnvironment.value("OPENAI_API_KEY")))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard options.backend == "local" || !apiKey.isEmpty else {
      throw DirectRuntimeError.missingAPIKey(providerName)
    }

    let client = controlClient()
    let definitions = (try? await client?.listToolsAsync()) ?? []
    // Tools that need confirmation are offered too; ControlToolExecutor asks the person first.
    let callable = definitions.filter { !$0.isProviderInternal }
    let rawTools = callable.map {
      HarnessTool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
    }
    let backend = try modelBackend(id: options.backend, apiKey: apiKey)
    let nameMap = HarnessToolNaming.safeNames(rawTools)
    let definitionByName = Dictionary(uniqueKeysWithValues: rawTools.map { ($0.name, $0) })
    // Sorted so every turn offers the tools in the same order and the prompt start stays reusable.
    let tools = nameMap.compactMap { exposedName, actualName -> HarnessTool? in
      guard let definition = definitionByName[actualName] else { return nil }
      return HarnessTool(
        name: exposedName,
        description: definition.description,
        inputSchema: definition.inputSchema)
    }
    .sorted { $0.name < $1.name }
    let executor = client.map { ControlToolExecutor(client: $0, actualNames: nameMap) }
    let isOttoSession = options.resumeID.map(HarnessSession.isOttoID) == true
    // Only the retired OpenAI-only helper emitted raw Responses API ids. Such an id is opaque to
    // every other provider, so switching model vendor must begin from Otto's canonical history.
    let legacyOpenAIResponseID =
      backend.providerID == "openai" && !isOttoSession
      ? options.resumeID : nil
    // Size compaction to the model actually picked: its provider listing first, then Otto's table.
    let windowResolver = HarnessContextWindowResolver()
    let contextWindow = await windowResolver.resolve(
      providerID: backend.providerID, modelID: options.model,
      modelsURL: modelsURL(backendID: options.backend), apiKey: apiKey)
    let request = HarnessTurnRequest(
      sessionID: isOttoSession ? options.resumeID : nil,
      legacyProviderResponseID: legacyOpenAIResponseID,
      providerID: backend.providerID,
      modelID: options.model,
      reasoningEffort: options.effort,
      systemInstructions: options.system,
      prompt: options.prompt,
      tools: tools,
      contextWindow: contextWindow.tokens)
    let runner = HarnessRunner(sessionStore: HarnessSessionStore())
    let result = try await runner.run(
      request,
      backend: backend,
      toolExecutor: executor,
      onEvent: { event in
        switch event {
        case .sessionStarted(let sessionID):
          emit(["type": "thread.started", "thread_id": sessionID])
          emit(["type": "turn.started"])
        case .toolStarted(let name):
          emit([
            "type": "item.completed",
            "item": [
              "type": "mcp_tool_call", "server": "otto", "tool": nameMap[name] ?? name,
            ],
          ])
        case .compacted(let folded, let window):
          emit([
            "type": "item.completed",
            "item": [
              "type": "reasoning",
              "text":
                "Compacted \(folded) earlier messages into a summary to stay within "
                + "\(options.model)'s \(formattedTokens(window))-token context window.",
            ],
          ])
        case .contextOverflow(let promptTokens):
          windowResolver.learnOverflow(
            providerID: backend.providerID, modelID: options.model, promptTokens: promptTokens)
        }
      })
    emit(["type": "item.completed", "item": ["type": "agent_message", "text": result.text]])
    var completed: [String: Any] = ["type": "turn.completed"]
    if let usage = result.usage {
      completed["usage"] = [
        "input_tokens": usage.inputTokens, "output_tokens": usage.outputTokens,
      ]
    }
    emit(completed)
  }

  private static func modelBackend(id: String, apiKey: String) throws -> any HarnessModelBackend {
    switch id {
    case "openai":
      return OpenAIResponsesBackend(apiKey: apiKey)
    case "anthropic":
      return AnthropicMessagesBackend(apiKey: apiKey)
    case "xai":
      return OpenAIResponsesBackend(
        apiKey: apiKey,
        providerID: "xai",
        providerDisplayName: "xAI",
        endpoint: URL(string: "https://api.x.ai/v1/responses")!)
    case "local":
      guard let rawURL = OttoEnvironment.value("MODEL_BASE_URL") else {
        throw DirectRuntimeError.invalidArguments(
          "Configure the local server URL in Otto Settings → Models.")
      }
      let config = try LocalModelConfiguration(baseURL: rawURL, modelID: "local-model")
      return OpenAIChatCompletionsBackend(
        apiKey: apiKey, providerID: "local", providerDisplayName: "Local model",
        endpoint: config.completionsURL)
    default:
      // Moonshot, DeepSeek, Mistral, Groq, Gemini and OpenRouter share one compatible API.
      guard let vendor = OttoHarnessCompatibleVendor(rawValue: id) else {
        throw DirectRuntimeError.invalidArguments("Unknown model backend: \(id)")
      }
      return OpenAIChatCompletionsBackend(
        apiKey: apiKey, providerID: id, providerDisplayName: vendor.displayName,
        endpoint: vendor.chatCompletionsURL)
    }
  }

  /// Listings that report context sizes. OpenAI and xAI listings do not, so their windows come
  /// from Otto's table.
  private static func modelsURL(backendID: String) -> URL? {
    switch backendID {
    case "openai", "xai": return nil
    case "anthropic": return URL(string: "https://api.anthropic.com/v1/models?limit=1000")
    case "local":
      return OttoEnvironment.value("MODEL_BASE_URL").flatMap {
        try? LocalModelConfiguration(baseURL: $0, modelID: "local-model").modelsURL
      }
    default: return OttoHarnessCompatibleVendor(rawValue: backendID)?.modelsURL
    }
  }

  private static func formattedTokens(_ tokens: Int) -> String {
    tokens >= 1_000_000
      ? String(format: "%gM", (Double(tokens) / 100_000).rounded() / 10)
      : "\(Int((Double(tokens) / 1_000).rounded()))k"
  }

  private static func providerDisplayName(_ id: String) -> String {
    switch id {
    case "anthropic": "Anthropic"
    case "xai": "xAI"
    case "local": "Local model"
    default: OttoHarnessCompatibleVendor(rawValue: id)?.displayName ?? "OpenAI"
    }
  }

  private static func controlClient() -> ControlClient? {
    let environment = ProcessInfo.processInfo.environment
    guard let socket = OttoEnvironment.value("CONTROL_SOCKET", in: environment),
      let token = OttoEnvironment.value("CONTROL_TOKEN", in: environment)
    else { return nil }
    return ControlClient(
      socketPath: socket,
      token: token,
      sourceNodeID: OttoEnvironment.value("NODE_ID", in: environment).flatMap(
        UUID.init(uuidString:)),
      sourceCanvasID: OttoEnvironment.value("CANVAS_ID", in: environment).flatMap(
        UUID.init(uuidString:)))
  }

  private static func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
      var line = String(data: data, encoding: .utf8)
    else { return }
    line.append("\n")
    FileHandle.standardOutput.write(Data(line.utf8))
  }
}
