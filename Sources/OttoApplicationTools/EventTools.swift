import Foundation
import OttoRuntime
import OttoTools

public struct EventWaitInput: Codable, Sendable {
  public var types: [OttoEventType]?
  public var nodeID: UUID?
  public var afterSequence: Int?
  public var timeoutMilliseconds: Int?

  public init(
    types: [OttoEventType]? = nil,
    nodeID: UUID? = nil,
    afterSequence: Int? = nil,
    timeoutMilliseconds: Int? = nil
  ) {
    self.types = types
    self.nodeID = nodeID
    self.afterSequence = afterSequence
    self.timeoutMilliseconds = timeoutMilliseconds
  }
}

public enum EventWaitError: Error, LocalizedError, Sendable {
  case timedOut(Int)

  public var errorDescription: String? {
    switch self {
    case .timedOut(let milliseconds):
      "No matching event arrived within \(milliseconds) milliseconds"
    }
  }
}

public struct EventWaitTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "event.wait",
    description: "Waits for the next matching typed runtime event without polling.",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "types": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "nodeID": .object(["type": .string("string"), "format": .string("uuid")]),
        "afterSequence": .object(["type": .string("integer"), "minimum": .number(0)]),
        "timeoutMilliseconds": .object([
          "type": .string("integer"), "minimum": .number(1), "maximum": .number(30_000),
        ]),
      ]),
      "additionalProperties": .bool(false),
    ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read
  )

  private let bus: OttoEventBus
  private let supervisor: AgentSupervisor?
  /// With a supervisor, a returned completion event for an agent or command the caller started
  /// counts as seen, so Otto does not also send a background completion notice for it.
  public init(bus: OttoEventBus, supervisor: AgentSupervisor? = nil) {
    self.bus = bus
    self.supervisor = supervisor
  }

  public func call(_ input: EventWaitInput, context: ToolContext) async throws -> OttoEvent {
    guard input.afterSequence.map({ $0 >= 0 }) ?? true else {
      throw ToolRegistryError.invalidInput("Event sequence cannot be negative")
    }
    let timeout = input.timeoutMilliseconds ?? 30_000
    guard (1...30_000).contains(timeout) else {
      throw ToolRegistryError.invalidInput("Event timeout must be between 1 and 30000 milliseconds")
    }
    let acceptedTypes = Set(input.types ?? [])
    let afterSequence = input.afterSequence ?? bus.latestSequence
    let stream = bus.stream(afterSequence: afterSequence)
    let event = try await withThrowingTaskGroup(of: OttoEvent.self) { group in
      group.addTask {
        for await event in stream {
          let typeMatches = acceptedTypes.isEmpty || acceptedTypes.contains(event.type)
          let nodeMatches = input.nodeID == nil || input.nodeID == event.nodeID
          if typeMatches, nodeMatches { return event }
        }
        throw CancellationError()
      }
      group.addTask {
        try await Task.sleep(for: .milliseconds(timeout))
        throw EventWaitError.timedOut(timeout)
      }
      defer { group.cancelAll() }
      guard let event = try await group.next() else { throw CancellationError() }
      return event
    }
    if let supervisor, let nodeID = event.nodeID, Self.reportsCompletion(event) {
      await supervisor.markDelegatedCompletionConsumed(childID: nodeID, by: context.sourceNodeID)
    }
    return event
  }

  static func reportsCompletion(_ event: OttoEvent) -> Bool {
    switch event.type {
    case .agentRunCompleted, .agentRunFailed, .agentExited: true
    case .agentStatusChanged:
      event.state == .done || event.state == .failed || event.state == .stopped
        || event.state == .interrupted
    default: false
    }
  }
}
