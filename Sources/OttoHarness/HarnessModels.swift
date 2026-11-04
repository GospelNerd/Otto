import Foundation
import OttoTools

public enum HarnessMessageRole: String, Codable, Sendable {
  case user
  case assistant
}

public struct HarnessMessage: Codable, Equatable, Sendable {
  public var id: UUID
  public var role: HarnessMessageRole
  public var content: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    role: HarnessMessageRole,
    content: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.createdAt = createdAt
  }
}

public struct HarnessToolReceipt: Codable, Equatable, Sendable {
  public var callID: String
  public var name: String
  public var state: String
}

public struct HarnessSession: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var id: String
  public var providerID: String
  public var modelID: String
  public var createdAt: Date
  public var updatedAt: Date
  public var messages: [HarnessMessage]
  public var archivedMessages: [HarnessMessage]?
  public var toolReceipts: [HarnessToolReceipt]?
  /// Summary of messages folded out of `messages` to fit the model's context window.
  public var compaction: HarnessCompaction?

  public init(
    id: String = HarnessSession.makeID(),
    providerID: String,
    modelID: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    messages: [HarnessMessage] = []
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.providerID = providerID
    self.modelID = modelID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.messages = messages
  }

  public static func makeID() -> String {
    "otto_\(UUID().uuidString.lowercased())"
  }

  public static func isOttoID(_ value: String) -> Bool {
    // Sessions created before the rename carry a `muse_` prefix.
    guard value.hasPrefix("otto_") || value.hasPrefix("muse_") else { return false }
    return UUID(uuidString: String(value.dropFirst(5))) != nil
  }
}

public struct HarnessTool: Equatable, Sendable {
  public var name: String
  public var description: String
  public var inputSchema: JSONValue

  public init(name: String, description: String, inputSchema: JSONValue) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}

public struct HarnessToolCall: Equatable, Sendable {
  public var id: String
  public var name: String
  public var arguments: JSONValue

  public init(id: String, name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

public struct HarnessToolResult: Equatable, Sendable {
  public var callID: String
  public var output: String

  public init(callID: String, output: String) {
    self.callID = callID
    self.output = output
  }
}

public enum HarnessBackendInput: Equatable, Sendable {
  case conversation([HarnessMessage])
  case toolResults([HarnessToolResult])
}

public struct HarnessBackendRequest: Equatable, Sendable {
  public var systemInstructions: String
  public var modelID: String
  public var reasoningEffort: String?
  public var input: HarnessBackendInput
  public var tools: [HarnessTool]
  /// Opaque, turn-local continuation state owned by the selected model backend. Otto never
  /// persists this value as conversation memory.
  public var providerContinuation: JSONValue?

  public init(
    systemInstructions: String,
    modelID: String,
    reasoningEffort: String? = nil,
    input: HarnessBackendInput,
    tools: [HarnessTool] = [],
    providerContinuation: JSONValue? = nil
  ) {
    self.systemInstructions = systemInstructions
    self.modelID = modelID
    self.reasoningEffort = reasoningEffort
    self.input = input
    self.tools = tools
    self.providerContinuation = providerContinuation
  }
}

public struct HarnessBackendResponse: Equatable, Sendable {
  /// Opaque continuation data returned to the same backend for the next tool round. A Responses
  /// API backend can use an ID; a Messages backend can carry its assistant tool-use content.
  public var providerContinuation: JSONValue?
  public var text: String
  public var toolCalls: [HarnessToolCall]
  /// Tokens the provider billed for this one request, when it reported them.
  public var usage: HarnessTokenUsage?

  public init(
    providerContinuation: JSONValue? = nil,
    text: String = "",
    toolCalls: [HarnessToolCall] = [],
    usage: HarnessTokenUsage? = nil
  ) {
    self.providerContinuation = providerContinuation
    self.text = text
    self.toolCalls = toolCalls
    self.usage = usage
  }
}

public protocol HarnessModelBackend: Sendable {
  var providerID: String { get }
  func complete(_ request: HarnessBackendRequest) async throws -> HarnessBackendResponse
}

public protocol HarnessToolExecutor: Sendable {
  func execute(_ call: HarnessToolCall) async throws -> String
}

public enum HarnessEvent: Equatable, Sendable {
  case sessionStarted(String)
  case toolStarted(name: String)
  /// Older messages were summarised so the conversation fits `contextWindow` tokens.
  case compacted(foldedMessages: Int, contextWindow: Int)
  /// The provider rejected a prompt of about `promptTokens` as too long for the model.
  case contextOverflow(promptTokens: Int)
}

public struct HarnessTurnResult: Equatable, Sendable {
  public var sessionID: String
  public var text: String
  /// Summed over every model request in the turn, tool rounds included.
  public var usage: HarnessTokenUsage?

  public init(sessionID: String, text: String, usage: HarnessTokenUsage? = nil) {
    self.sessionID = sessionID
    self.text = text
    self.usage = usage
  }
}

public struct HarnessTokenUsage: Equatable, Sendable {
  public var inputTokens: Int
  public var outputTokens: Int

  public init(inputTokens: Int, outputTokens: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }

  /// Reads `usage` from a Chat Completions, Responses or Messages reply. Cached input counts as
  /// input; Anthropic reports it apart from `input_tokens`.
  static func parse(_ object: Any?) -> Self? {
    guard let usage = object as? [String: Any] else { return nil }
    func int(_ key: String) -> Int? { (usage[key] as? NSNumber)?.intValue }
    guard
      let input = int("prompt_tokens") ?? int("input_tokens"),
      let output = int("completion_tokens") ?? int("output_tokens")
    else { return nil }
    let cached = (int("cache_read_input_tokens") ?? 0) + (int("cache_creation_input_tokens") ?? 0)
    return Self(inputTokens: input + cached, outputTokens: output)
  }

  static func combined(_ lhs: Self?, _ rhs: Self?) -> Self? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return Self(
      inputTokens: lhs.inputTokens + rhs.inputTokens,
      outputTokens: lhs.outputTokens + rhs.outputTokens)
  }
}

public enum HarnessError: Error, LocalizedError, Equatable {
  case invalidSessionID
  case missingFinalResponse
  case toolLoopLimitExceeded
  case malformedProviderResponse(String)
  case providerRequestFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidSessionID: "The Otto agent session identifier is invalid."
    case .missingFinalResponse: "The model completed without a final response."
    case .toolLoopLimitExceeded: "The agent exceeded the maximum number of tool-call rounds."
    case .malformedProviderResponse(let detail): detail
    case .providerRequestFailed(let detail): detail
    }
  }
}

public struct HarnessBackendRegistry: Sendable {
  private var backends: [String: any HarnessModelBackend] = [:]

  public init() {}

  public mutating func register(_ backend: any HarnessModelBackend) {
    backends[backend.providerID] = backend
  }

  public func backend(for providerID: String) -> (any HarnessModelBackend)? {
    backends[providerID]
  }
}
