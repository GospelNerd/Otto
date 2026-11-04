import Foundation
import OttoTools
#if canImport(SQLite3)
  import SQLite3
#else
  import CSQLite
#endif

/// One row of the append-only audit chain. Every tool action by every actor — agents, voice,
/// the app itself — lands here permanently, so "who did what" survives restarts and is
/// queryable by both the user and coordinating agents. (Pattern borrowed from block/buzz:
/// the event log as the shared source of accountability.)
public struct PersistedAuditEvent: Codable, Sendable, Equatable {
  public var id: String
  public var actorID: String
  public var toolName: String
  public var riskLevel: String
  public var succeeded: Bool
  public var timestamp: Date

  public init(
    id: String, actorID: String, toolName: String, riskLevel: String, succeeded: Bool,
    timestamp: Date
  ) {
    self.id = id
    self.actorID = actorID
    self.toolName = toolName
    self.riskLevel = riskLevel
    self.succeeded = succeeded
    self.timestamp = timestamp
  }
}

extension SQLiteWorkspaceStore {
  /// Newest-first slice of the audit chain, optionally filtered to one actor
  /// (e.g. "otto-agent-<uuid>").
  public func recentAuditEvents(
    limit: Int = 50, actorID: String? = nil
  ) throws -> [PersistedAuditEvent] {
    try migrate()
    return try auditQuery(limit: max(1, min(limit, 500)), actorID: actorID)
  }
}

/// Exposes the audit chain to the tool surface. Read-only by construction; records carry tool
/// names and outcomes, never payloads, so cross-agent visibility leaks no content.
public struct AuditRecentInput: Codable, Sendable {
  public var limit: Int?
  public var actorID: String?

  public init(limit: Int? = nil, actorID: String? = nil) {
    self.limit = limit
    self.actorID = actorID
  }
}

public struct AuditRecentTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "audit.recent",
    description:
      "Reads the append-only audit chain: recent tool actions by every actor (agents, voice, the app), newest first. Use to see what other agents actually did — names and outcomes only, never payloads.",
    inputSchema: .objectSchema(
      properties: [
        "limit": .numberSchema(description: "Maximum events (default 50, max 500)"),
        "actorID": .stringSchema(
          description: "Optional filter, e.g. otto-agent-<node uuid>"),
      ],
      required: []
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  private let store: SQLiteWorkspaceStore
  public init(store: SQLiteWorkspaceStore) { self.store = store }

  public func call(_ input: AuditRecentInput, context: ToolContext) async throws
    -> [PersistedAuditEvent]
  {
    try await store.recentAuditEvents(limit: input.limit ?? 50, actorID: input.actorID)
  }
}
