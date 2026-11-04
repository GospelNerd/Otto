import Foundation
import OttoModels
import OttoTools
#if canImport(SQLite3)
  import SQLite3
#else
  import CSQLite
#endif

public enum PersistenceError: Error, LocalizedError {
  case openDatabase(String)
  case execute(String)
  case encode(String)
  case decode(String)
  case unsupportedSchema(found: Int, supported: Int)

  public var errorDescription: String? {
    switch self {
    case .openDatabase(let message): "Could not open Otto workspace: \(message)"
    case .execute(let message): "Otto database operation failed: \(message)"
    case .encode(let message): "Could not encode workspace: \(message)"
    case .decode(let message): "Could not decode workspace: \(message)"
    case .unsupportedSchema(let found, let supported):
      "Otto workspace schema \(found) is newer than this build supports (\(supported))."
    }
  }
}

public actor SQLiteWorkspaceStore {
  private let path: String
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  // nonisolated(unsafe) solely so the nonisolated deinit can close the connection; every other
  // access happens on the actor. isolated deinit would require macOS 15.4.
  private nonisolated(unsafe) var handle: OpaquePointer?
  private var didMigrate = false

  public init(path: String) {
    self.path = path
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    self.encoder.dateEncodingStrategy = .deferredToDate
    self.decoder.dateDecodingStrategy = .deferredToDate
  }

  deinit {
    if let handle { sqlite3_close(handle) }
  }

  public static func live() throws -> SQLiteWorkspaceStore {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = support.appending(path: "Otto", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return SQLiteWorkspaceStore(path: directory.appending(path: "workspace.sqlite").path)
  }

  public func migrate() throws {
    if didMigrate { return }
    try runMigrations()
    didMigrate = true
  }

  private func runMigrations() throws {
    try withDatabase { database in
      try execute(
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
        );
        """,
        on: database
      )
      let existingVersion = try scalarInt(
        "SELECT COALESCE(MAX(version), 0) FROM schema_migrations", on: database)
      guard existingVersion <= 2 else {
        throw PersistenceError.unsupportedSchema(found: existingVersion, supported: 2)
      }
      try execute(
        """
        CREATE TABLE IF NOT EXISTS workspace_snapshots (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            payload BLOB NOT NULL,
            updated_at TEXT NOT NULL
        );
        """,
        on: database
      )
      try execute(
        "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (1, datetime('now'));",
        on: database
      )
      try execute(
        """
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS workspaces (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            root_path TEXT,
            canonical_root_path TEXT,
            git_repository_metadata TEXT,
            default_setup_command TEXT,
            permission_profile_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS canvases (
            id TEXT PRIMARY KEY,
            workspace_id TEXT,
            name TEXT NOT NULL,
            theme_id TEXT,
            layout_mode TEXT,
            viewport_json BLOB NOT NULL,
            voice_preferences_json BLOB,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_opened_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS nodes (
            id TEXT PRIMARY KEY,
            canvas_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            display_name TEXT NOT NULL,
            subtype TEXT,
            world_rect_json BLOB NOT NULL,
            z_index INTEGER NOT NULL,
            layout_metadata_json BLOB,
            configuration_json BLOB,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            closed_at REAL
        );
        CREATE INDEX IF NOT EXISTS nodes_canvas_id ON nodes(canvas_id);
        CREATE TABLE IF NOT EXISTS agent_sessions (
            id TEXT PRIMARY KEY,
            node_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            provider_session_id TEXT,
            model TEXT,
            effort TEXT,
            workspace_path TEXT NOT NULL,
            worktree_path TEXT,
            branch TEXT,
            permission_profile_id TEXT,
            process_metadata_json BLOB,
            created_at REAL NOT NULL,
            last_resumed_at REAL,
            ended_at REAL
        );
        CREATE TABLE IF NOT EXISTS agent_runs (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            prompt TEXT NOT NULL,
            status TEXT NOT NULL,
            started_at REAL NOT NULL,
            completed_at REAL,
            status_confidence REAL NOT NULL,
            result_json BLOB,
            scrollback_start_offset INTEGER NOT NULL,
            scrollback_end_offset INTEGER
        );
        CREATE TABLE IF NOT EXISTS recipes (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            version INTEGER NOT NULL,
            description TEXT NOT NULL,
            definition_json BLOB NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS audit_events (
            id TEXT PRIMARY KEY,
            request_id TEXT NOT NULL,
            canvas_id TEXT,
            node_id TEXT,
            actor_type TEXT NOT NULL,
            actor_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            risk_level TEXT NOT NULL,
            succeeded INTEGER NOT NULL,
            payload_json BLOB,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS audit_created_at ON audit_events(created_at);
        INSERT OR IGNORE INTO schema_migrations(version, applied_at)
          VALUES (2, datetime('now'));
        COMMIT;
        """,
        on: database
      )
    }
  }

  public func schemaVersion() throws -> Int {
    try migrate()
    return try withDatabase { database in
      try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations", on: database)
    }
  }

  public func load() throws -> WorkspaceSnapshot? {
    try migrate()
    return try withDatabase { database in
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          database, "SELECT payload FROM workspace_snapshots WHERE id = 1", -1, &statement, nil)
          == SQLITE_OK
      else {
        throw PersistenceError.execute(errorMessage(database))
      }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      let byteCount = Int(sqlite3_column_bytes(statement, 0))
      guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
      let data = Data(bytes: bytes, count: byteCount)
      do {
        return try decoder.decode(WorkspaceSnapshot.self, from: data)
      } catch {
        throw PersistenceError.decode(Self.decodeFailure(error))
      }
    }
  }

  /// Copies the saved snapshot, byte for byte, to a file beside the database and returns its
  /// path. Called when the snapshot cannot be read, so the original survives even if something
  /// later writes over it.
  public func preserveUnreadableSnapshot() throws -> String? {
    try migrate()
    let data: Data? = try withDatabase { database in
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          database, "SELECT payload FROM workspace_snapshots WHERE id = 1", -1, &statement, nil)
          == SQLITE_OK
      else {
        throw PersistenceError.execute(errorMessage(database))
      }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW,
        let bytes = sqlite3_column_blob(statement, 0)
      else { return nil }
      return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
    guard let data else { return nil }
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    let backup = directory.appending(path: "workspace-unreadable-\(stamp).json")
    try data.write(to: backup, options: .withoutOverwriting)
    return backup.path
  }

  public func loadForRestoration() throws -> WorkspaceSnapshot? {
    guard var snapshot = try load() else { return nil }
    for canvasIndex in snapshot.canvases.indices {
      for nodeIndex in snapshot.canvases[canvasIndex].nodes.indices {
        let state = snapshot.canvases[canvasIndex].nodes[nodeIndex].status
        if state == .starting || state == .working || state == .waiting {
          snapshot.canvases[canvasIndex].nodes[nodeIndex].status = .stopped
          snapshot.canvases[canvasIndex].nodes[nodeIndex].detail = "Stopped when Otto last exited"
        }
      }
    }
    return snapshot
  }

  public func save(_ snapshot: WorkspaceSnapshot) throws {
    try migrate()
    let data: Data
    do {
      data = try encoder.encode(snapshot)
    } catch {
      throw PersistenceError.encode(error.localizedDescription)
    }

    try withDatabase { database in
      try execute("BEGIN IMMEDIATE", on: database)
      do {
        var statement: OpaquePointer?
        let sql =
          "INSERT INTO workspace_snapshots(id, payload, updated_at) VALUES(1, ?, datetime('now')) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
          throw PersistenceError.execute(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        let result = data.withUnsafeBytes { buffer in
          sqlite3_bind_blob(
            statement, 1, buffer.baseAddress, Int32(buffer.count),
            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
          throw PersistenceError.execute(errorMessage(database))
        }
        try synchronizeNormalized(snapshot, on: database)
        try execute("COMMIT", on: database)
      } catch {
        try? execute("ROLLBACK", on: database)
        throw error
      }
    }
  }

  public func integrityCheck() throws -> Bool {
    try migrate()
    return try withDatabase { database in
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK
      else { throw PersistenceError.execute(errorMessage(database)) }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.execute(errorMessage(database))
      }
      return columnText(statement, 0) == "ok"
    }
  }

  public func normalizedCounts() throws -> (canvases: Int, nodes: Int) {
    try migrate()
    return try withDatabase { database in
      (
        try scalarInt("SELECT COUNT(*) FROM canvases", on: database),
        try scalarInt("SELECT COUNT(*) FROM nodes", on: database)
      )
    }
  }

  public func persistedAuditLog() throws -> [ToolAuditRecord] {
    try migrate()
    return try withDatabase { database in
      var statement: OpaquePointer?
      let sql =
        "SELECT id, request_id, actor_id, event_type, succeeded, risk_level, created_at FROM audit_events ORDER BY created_at, id"
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw PersistenceError.execute(errorMessage(database))
      }
      defer { sqlite3_finalize(statement) }
      var records: [ToolAuditRecord] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: columnText(statement, 0)),
          let risk = ToolRiskLevel(rawValue: columnText(statement, 5))
        else { continue }
        records.append(
          ToolAuditRecord(
            id: id,
            requestID: columnText(statement, 1),
            toolName: columnText(statement, 3),
            actorID: columnText(statement, 2),
            succeeded: sqlite3_column_int(statement, 4) != 0,
            riskLevel: risk,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
          ))
      }
      return records
    }
  }

  private func synchronizeNormalized(_ snapshot: WorkspaceSnapshot, on database: OpaquePointer)
    throws
  {
    try execute("DELETE FROM nodes", on: database)
    try execute("DELETE FROM canvases", on: database)
    for canvas in snapshot.canvases {
      try insertCanvas(canvas, on: database)
      for node in canvas.nodes {
        try insertNode(node, canvasID: canvas.id, updatedAt: canvas.updatedAt, on: database)
      }
    }
  }

  private func insertCanvas(_ canvas: OttoCanvas, on database: OpaquePointer) throws {
    let sql =
      "INSERT INTO canvases(id, name, theme_id, layout_mode, viewport_json, created_at, updated_at, last_opened_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw PersistenceError.execute(errorMessage(database))
    }
    defer { sqlite3_finalize(statement) }
    try bindText(canvas.id.uuidString, at: 1, to: statement, database: database)
    try bindText(canvas.name, at: 2, to: statement, database: database)
    try bindOptionalText(canvas.themeID, at: 3, to: statement, database: database)
    try bindOptionalText(canvas.layoutMode?.rawValue, at: 4, to: statement, database: database)
    try bindBlob(try encoder.encode(canvas.viewport), at: 5, to: statement, database: database)
    sqlite3_bind_double(statement, 6, canvas.updatedAt.timeIntervalSince1970)
    sqlite3_bind_double(statement, 7, canvas.updatedAt.timeIntervalSince1970)
    sqlite3_bind_double(statement, 8, canvas.updatedAt.timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw PersistenceError.execute(errorMessage(database))
    }
  }

  private func insertNode(
    _ node: OttoNode,
    canvasID: UUID,
    updatedAt: Date,
    on database: OpaquePointer
  ) throws {
    let sql =
      "INSERT INTO nodes(id, canvas_id, kind, display_name, subtype, world_rect_json, z_index, configuration_json, status, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw PersistenceError.execute(errorMessage(database))
    }
    defer { sqlite3_finalize(statement) }
    try bindText(node.id.uuidString, at: 1, to: statement, database: database)
    try bindText(canvasID.uuidString, at: 2, to: statement, database: database)
    try bindText(node.kind.rawValue, at: 3, to: statement, database: database)
    try bindText(node.displayName, at: 4, to: statement, database: database)
    try bindText(node.subtitle, at: 5, to: statement, database: database)
    try bindBlob(try encoder.encode(node.frame), at: 6, to: statement, database: database)
    sqlite3_bind_int64(statement, 7, Int64(node.zIndex))
    if let content = node.content {
      try bindBlob(try encoder.encode(content), at: 8, to: statement, database: database)
    } else if let unsupportedContentPayload = node.unsupportedContentPayload {
      try bindBlob(
        try encoder.encode(unsupportedContentPayload), at: 8, to: statement, database: database)
    } else {
      sqlite3_bind_null(statement, 8)
    }
    try bindText(node.status.rawValue, at: 9, to: statement, database: database)
    sqlite3_bind_double(statement, 10, node.createdAt.timeIntervalSince1970)
    sqlite3_bind_double(statement, 11, updatedAt.timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw PersistenceError.execute(errorMessage(database))
    }
  }

  private func scalarInt(_ sql: String, on database: OpaquePointer) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw PersistenceError.execute(errorMessage(database))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw PersistenceError.execute(errorMessage(database))
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func bindText(
    _ value: String,
    at index: Int32,
    to statement: OpaquePointer?,
    database: OpaquePointer
  ) throws {
    guard
      sqlite3_bind_text(
        statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        == SQLITE_OK
    else { throw PersistenceError.execute(errorMessage(database)) }
  }

  private func bindOptionalText(
    _ value: String?,
    at index: Int32,
    to statement: OpaquePointer?,
    database: OpaquePointer
  ) throws {
    if let value {
      try bindText(value, at: index, to: statement, database: database)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func bindBlob(
    _ data: Data,
    at index: Int32,
    to statement: OpaquePointer?,
    database: OpaquePointer
  ) throws {
    let result = data.withUnsafeBytes { buffer in
      sqlite3_bind_blob(
        statement, index, buffer.baseAddress, Int32(buffer.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard result == SQLITE_OK else { throw PersistenceError.execute(errorMessage(database)) }
  }

  private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
    guard let pointer = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: pointer)
  }

  private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    try body(try openedDatabase())
  }

  // One connection per store lifetime. Opening, WAL negotiation, and PRAGMA setup per call cost
  // milliseconds each and previously ran on every save — including once per canvas dispatch.
  private func openedDatabase() throws -> OpaquePointer {
    if let handle { return handle }
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let database
    else {
      let message = database.map(errorMessage) ?? "Unknown SQLite error"
      if let database { sqlite3_close(database) }
      throw PersistenceError.openDatabase(message)
    }
    do {
      guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else {
        throw PersistenceError.execute(errorMessage(database))
      }
      try execute("PRAGMA journal_mode=WAL", on: database)
      // NORMAL with WAL still guarantees database integrity on crash; FULL adds an fsync per
      // commit for durability of the very last write, which a UI snapshot does not need.
      try execute("PRAGMA synchronous=NORMAL", on: database)
    } catch {
      sqlite3_close(database)
      throw error
    }
    handle = database
    return database
  }

  private func execute(_ sql: String, on database: OpaquePointer) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw PersistenceError.execute(errorMessage(database))
    }
  }

  private func errorMessage(_ database: OpaquePointer) -> String {
    String(cString: sqlite3_errmsg(database))
  }
}

extension SQLiteWorkspaceStore {
  func auditQuery(limit: Int, actorID: String?) throws -> [PersistedAuditEvent] {
    try withDatabase { database in
      var sql =
        "SELECT id, actor_id, event_type, risk_level, succeeded, created_at FROM audit_events"
      if actorID != nil { sql += " WHERE actor_id = ?" }
      sql += " ORDER BY created_at DESC LIMIT ?"
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw PersistenceError.execute(errorMessage(database))
      }
      defer { sqlite3_finalize(statement) }
      var index: Int32 = 1
      if let actorID {
        try bindText(actorID, at: index, to: statement, database: database)
        index += 1
      }
      sqlite3_bind_int(statement, index, Int32(limit))
      var events: [PersistedAuditEvent] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
          let actor = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
          let tool = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
          let risk = sqlite3_column_text(statement, 3).map({ String(cString: $0) })
        else { continue }
        events.append(
          PersistedAuditEvent(
            id: id,
            actorID: actor,
            toolName: tool,
            riskLevel: risk,
            succeeded: sqlite3_column_int(statement, 4) == 1,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
          ))
      }
      return events
    }
  }
}

extension SQLiteWorkspaceStore: ToolAuditSink {
  public func record(_ record: ToolAuditRecord) async {
    do {
      try migrate()
      try withDatabase { database in
        let sql =
          "INSERT INTO audit_events(id, request_id, actor_type, actor_id, event_type, risk_level, succeeded, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
          throw PersistenceError.execute(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        try bindText(record.id.uuidString, at: 1, to: statement, database: database)
        try bindText(record.requestID, at: 2, to: statement, database: database)
        try bindText("tool", at: 3, to: statement, database: database)
        try bindText(record.actorID, at: 4, to: statement, database: database)
        try bindText(record.toolName, at: 5, to: statement, database: database)
        try bindText(record.riskLevel.rawValue, at: 6, to: statement, database: database)
        sqlite3_bind_int(statement, 7, record.succeeded ? 1 : 0)
        sqlite3_bind_double(statement, 8, record.timestamp.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
          throw PersistenceError.execute(errorMessage(database))
        }
      }
    } catch {
      // The in-memory audit remains available; application diagnostics surface storage failures.
    }
  }

  static func decodeFailure(_ error: Error) -> String {
    guard let decoding = error as? DecodingError else {
      return error.localizedDescription
    }
    switch decoding {
    case .typeMismatch(let type, let context):
      return "\(context.codingPathString) expected \(type) (\(context.debugDescription))"
    case .valueNotFound(let type, let context):
      return "\(context.codingPathString) missing \(type) (\(context.debugDescription))"
    case .keyNotFound(let key, let context):
      return "\(context.codingPathString).\(key.stringValue) was missing"
    case .dataCorrupted(let context):
      return "\(context.codingPathString) \(context.debugDescription)"
    @unknown default:
      return error.localizedDescription
    }
  }
}

extension DecodingError.Context {
  fileprivate var codingPathString: String {
    let path = codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
    return path.isEmpty ? "workspace" : path
  }
}
