import Foundation
#if canImport(SQLite3)
  import SQLite3
#else
  import CSQLite
#endif

/// Derived full-text index over Project Brain records. It accelerates `memory.search`; it is
/// never the only copy of knowledge and can be deleted and rebuilt from the canonical Markdown
/// at any time. Confined to the ProjectBrainStore actor — no internal locking.
final class BrainSearchIndex {
  private let databasePath: String
  private var database: OpaquePointer?

  /// True when the on-disk index predates the current column set and was dropped. The owner must
  /// repopulate from the canonical Markdown; nothing is lost, because the index never held the
  /// only copy.
  private(set) var requiresRebuild = false

  init(databasePath: String) throws {
    self.databasePath = databasePath
    try open()
    // An index written before trust weighting has no `trust` column, and inserting into it would
    // fail on every write. It is derived data, so the cheap correct move is to discard and
    // rebuild rather than migrate in place.
    if tableExists("brain_fts"),
      !hasColumn("trust", in: "brain_fts") || !hasColumn("scope", in: "brain_fts")
        || !hasColumn("profile_id", in: "brain_fts")
        || !hasColumn("confidence", in: "brain_fts")
    {
      try execute("DROP TABLE brain_fts")
      requiresRebuild = true
    }
    try execute(
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS brain_fts USING fts5(
        id UNINDEXED, type UNINDEXED, title, body, tags, trust UNINDEXED,
        scope UNINDEXED, profile_id UNINDEXED, confidence UNINDEXED
      )
      """
    )
    // Retrieval telemetry is high-churn and low-stakes: counting a search hit must never rewrite
    // a Markdown file or bump a revision, so unlike trust it lives only here and is allowed to
    // reset when the index is rebuilt.
    try execute(
      """
      CREATE TABLE IF NOT EXISTS record_stats (
        id TEXT PRIMARY KEY,
        retrieval_count INTEGER NOT NULL DEFAULT 0,
        last_retrieved_at REAL
      )
      """
    )
  }

  deinit {
    sqlite3_close_v2(database)
  }

  func rebuild(with records: [MemoryRecord]) throws {
    try execute("DELETE FROM brain_fts")
    for record in records {
      try insert(record)
    }
  }

  func upsert(_ record: MemoryRecord) throws {
    try remove(id: record.id)
    try insert(record)
  }

  func remove(id: String) throws {
    try withStatement("DELETE FROM brain_fts WHERE id = ?") { statement in
      bind(statement, 1, id)
      try step(statement)
    }
    try withStatement("DELETE FROM record_stats WHERE id = ?") { statement in
      bind(statement, 1, id)
      try step(statement)
    }
  }

  /// Ranks by relevance weighted by trust, and withholds records rated below `minTrust`.
  ///
  /// `bm25()` returns *negative* scores where more negative is a better match, so multiplying by
  /// a trust score in 0...1 and sorting ascending pulls trusted records up and pushes distrusted
  /// ones down — the sign convention is the whole reason this is a multiply and not a divide.
  /// Trust is stored as text in an UNINDEXED column, hence the CAST: comparing text to a float
  /// in SQLite always ranks text higher and would silently disable the floor.
  func search(
    _ query: String,
    limit: Int,
    minTrust: Double,
    authorisedScopes: Set<MemoryScope> = [.project, .canvas],
    authorisedProfileID: UUID? = nil,
    confirmedOnly: Bool = false,
    recordTypes: Set<MemoryRecordType>? = nil
  ) throws -> [BrainSearchHit] {
    let sanitized = Self.matchExpression(for: query)
    guard !sanitized.isEmpty, !authorisedScopes.isEmpty else { return [] }
    let types = recordTypes ?? Set(MemoryRecordType.allCases)
    guard !types.isEmpty else { return [] }
    // These SQL literals come exclusively from closed enums, never from query text. Filter
    // before LIMIT so another scope, raw logs, or pending lessons cannot consume the shortlist.
    let scopeSQL = authorisedScopes.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")
    let typeSQL = types.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")
    let confirmationSQL = confirmedOnly ? "AND confidence = 'confirmed'" : ""

    var hits: [BrainSearchHit] = []
    try withStatement(
      """
      SELECT id, type, title, snippet(brain_fts, 3, '', '', '…', 24), CAST(trust AS REAL),
             scope, profile_id
      FROM brain_fts
      WHERE brain_fts MATCH ? AND CAST(trust AS REAL) >= ?
        AND scope IN (\(scopeSQL)) AND type IN (\(typeSQL))
        AND (scope != 'agent-role' OR profile_id = ?)
        \(confirmationSQL)
      ORDER BY bm25(brain_fts) * CAST(trust AS REAL)
      LIMIT ?
      """
    ) { statement in
      bind(statement, 1, sanitized)
      sqlite3_bind_double(statement, 2, minTrust)
      bind(statement, 3, authorisedProfileID?.uuidString ?? "")
      sqlite3_bind_int(statement, 4, Int32(max(1, limit * 4)))
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = column(statement, 0),
          let typeRaw = column(statement, 1),
          let type = MemoryRecordType(rawValue: typeRaw),
          let title = column(statement, 2)
        else { continue }
        let scope = column(statement, 5).flatMap(MemoryScope.init(rawValue:)) ?? .project
        guard authorisedScopes.contains(scope) else { continue }
        if scope == .agentRole {
          let owner = column(statement, 6).flatMap(UUID.init(uuidString:))
          guard owner != nil, owner == authorisedProfileID else { continue }
        }
        hits.append(
          BrainSearchHit(
            id: id,
            type: type,
            title: title,
            excerpt: column(statement, 3) ?? "",
            trustScore: sqlite3_column_double(statement, 4)
          ))
        if hits.count >= limit { break }
      }
    }
    recordRetrievals(ids: hits.map(\.id))
    return hits
  }

  /// Shortlist metadata before opening canonical files, so a bot bootstrap never scans
  /// unrelated project history. Canonical records are still revalidated by the caller.
  func contextCandidates(
    limit: Int, minTrust: Double, authorisedScopes: Set<MemoryScope>,
    authorisedProfileID: UUID?, confirmedOnly: Bool, recordTypes: Set<MemoryRecordType>?
  ) throws -> [(MemoryRecordType, String)] {
    let types = recordTypes ?? Set(MemoryRecordType.allCases)
    guard !authorisedScopes.isEmpty, !types.isEmpty else { return [] }
    let scopeSQL = authorisedScopes.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")
    let typeSQL = types.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")
    let confirmationSQL = confirmedOnly ? "AND confidence = 'confirmed'" : ""
    var candidates: [(MemoryRecordType, String)] = []
    try withStatement(
      """
      SELECT type, id FROM brain_fts
      WHERE CAST(trust AS REAL) >= ?
        AND scope IN (\(scopeSQL)) AND type IN (\(typeSQL))
        AND (scope != 'agent-role' OR profile_id = ?)
        \(confirmationSQL)
      ORDER BY CAST(trust AS REAL) DESC, rowid DESC
      LIMIT ?
      """
    ) { statement in
      sqlite3_bind_double(statement, 1, minTrust)
      bind(statement, 2, authorisedProfileID?.uuidString ?? "")
      sqlite3_bind_int(statement, 3, Int32(max(1, limit)))
      while sqlite3_step(statement) == SQLITE_ROW {
        if let raw = column(statement, 0), let type = MemoryRecordType(rawValue: raw),
          let id = column(statement, 1)
        {
          candidates.append((type, id))
        }
      }
    }
    return candidates
  }

  /// Counts a set of records as retrieved. Best-effort: telemetry must never fail a search.
  private func recordRetrievals(ids: [String]) {
    guard !ids.isEmpty else { return }
    let now = Date.now.timeIntervalSince1970
    for id in ids {
      try? withStatement(
        """
        INSERT INTO record_stats (id, retrieval_count, last_retrieved_at) VALUES (?, 1, ?)
        ON CONFLICT(id) DO UPDATE SET
          retrieval_count = retrieval_count + 1,
          last_retrieved_at = excluded.last_retrieved_at
        """
      ) { statement in
        bind(statement, 1, id)
        sqlite3_bind_double(statement, 2, now)
        try step(statement)
      }
    }
  }

  /// How many times a record has been returned by search since the index was last rebuilt.
  func retrievalCount(id: String) -> Int {
    var count = 0
    try? withStatement("SELECT retrieval_count FROM record_stats WHERE id = ?") { statement in
      bind(statement, 1, id)
      if sqlite3_step(statement) == SQLITE_ROW {
        count = Int(sqlite3_column_int(statement, 0))
      }
    }
    return count
  }

  /// User/agent queries are not FTS syntax: quote every token so operators, dashes, and colons
  /// in natural text cannot break or subvert the match expression. Tokens combine with OR —
  /// memory search surfaces ranked candidates for a natural-language question ("what did we
  /// decide about sessions?"), where requiring every word would return nothing.
  static func matchExpression(for query: String) -> String {
    query
      .split(whereSeparator: { $0.isWhitespace })
      .map { token in "\"\(token.replacingOccurrences(of: "\"", with: ""))\"" }
      .filter { $0 != "\"\"" }
      .joined(separator: " OR ")
  }

  // MARK: - SQLite plumbing

  private func open() throws {
    guard
      sqlite3_open_v2(
        databasePath, &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
      ) == SQLITE_OK
    else {
      throw MemoryStoreError.storageFailure("Could not open search index at \(databasePath)")
    }
    // Development reloads and fast application restarts can briefly overlap two Project Brain
    // stores for the same workspace. Let SQLite wait for the derived index writer instead of
    // making the entire memory tool surface disappear because of a momentary lock.
    sqlite3_busy_timeout(database, 5_000)
  }

  private func insert(_ record: MemoryRecord) throws {
    try withStatement(
      "INSERT INTO brain_fts (id, type, title, body, tags, trust, scope, profile_id, confidence) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
    ) { statement in
      bind(statement, 1, record.id)
      bind(statement, 2, record.type.rawValue)
      bind(statement, 3, record.title)
      bind(statement, 4, record.body)
      bind(
        statement,
        5,
        (record.tags + record.entityIDs + [record.factKind.rawValue]).joined(separator: " ")
      )
      bind(statement, 6, String(format: "%.3f", MemoryTrust.clamp(record.trustScore)))
      bind(statement, 7, record.scope.rawValue)
      bind(statement, 8, record.profileID?.uuidString ?? "")
      bind(statement, 9, record.confidence.rawValue)
      try step(statement)
    }
  }

  private func tableExists(_ name: String) -> Bool {
    var exists = false
    try? withStatement("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?") {
      statement in
      bind(statement, 1, name)
      exists = sqlite3_step(statement) == SQLITE_ROW
    }
    return exists
  }

  private func hasColumn(_ column: String, in table: String) -> Bool {
    var found = false
    // PRAGMA takes no bind parameters; the table name is a compile-time literal at every call
    // site, never user input.
    try? withStatement("PRAGMA table_info(\(table))") { statement in
      while sqlite3_step(statement) == SQLITE_ROW {
        if self.column(statement, 1) == column { found = true }
      }
    }
    return found
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw MemoryStoreError.storageFailure(lastErrorMessage())
    }
  }

  private func withStatement(
    _ sql: String, _ body: (OpaquePointer?) throws -> Void
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MemoryStoreError.storageFailure(lastErrorMessage())
    }
    defer { sqlite3_finalize(statement) }
    try body(statement)
  }

  private func step(_ statement: OpaquePointer?) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw MemoryStoreError.storageFailure(lastErrorMessage())
    }
  }

  private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
    sqlite3_bind_text(statement, index, value, -1, Self.transient)
  }

  private func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    sqlite3_column_text(statement, index).map { String(cString: $0) }
  }

  private func lastErrorMessage() -> String {
    database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
  }

  private static let transient = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self)
}
