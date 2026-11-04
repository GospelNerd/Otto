import Foundation
import OttoMemory
import Testing

#if canImport(SQLite3)
  import SQLite3
#else
  import CSQLite
#endif

@Suite("Project Brain canonical storage")
struct ProjectBrainStoreTests {
  @Test("A missing index is rebuilt lazily from existing canonical records")
  func missingIndexRecovery() async throws {
    let root = temporaryRoot()
    let source = try ProjectBrainStore(rootPath: root, project: "fixture")
    _ = try await source.write(
      MemoryRecord(
        id: "recover-note", type: .wiki, project: "fixture", title: "Recovery",
        body: "Recovered canonical knowledge", author: "user"), expectedRevision: nil)
    let recoveredRoot = temporaryRoot()
    let directory = URL(fileURLWithPath: recoveredRoot).appending(path: "wiki")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: root).appending(path: "wiki/recover-note.md"),
      to: directory.appending(path: "recover-note.md"))
    let recovered = try ProjectBrainStore(rootPath: recoveredRoot, project: "fixture")
    let automatic = try await recovered.contextPack(localFilesOnly: true)
    #expect(automatic.recordIDs.isEmpty, "Automatic memory must not trigger a cloud-backed rebuild")
    let automaticSearch = try await recovered.contextPack(query: "Recovered", localFilesOnly: true)
    #expect(automaticSearch.recordIDs.isEmpty)
    let hits = try await recovered.search("Recovered canonical")
    #expect(hits.contains { $0.id == "recover-note" })
    let restored = try await recovered.contextPack(localFilesOnly: true)
    #expect(restored.recordIDs == ["recover-note"])
  }

  @Test("Bot context loads only indexed records owned by that bot")
  func botContextAvoidsUnrelatedHistory() async throws {
    let root = temporaryRoot()
    let store = try ProjectBrainStore(rootPath: root, project: "fixture")
    let profileID = UUID()
    let record = try await store.write(
      MemoryRecord(
        id: "bot-note", type: .wiki, scope: .agentRole,
        project: "fixture", title: "Bot note", body: "Use concise replies.",
        author: "user", confidence: .confirmed, sourceIDs: ["user-request"], profileID: profileID
      ), expectedRevision: nil)
    // The old allRecords path opened and quarantined even unrelated malformed history.
    let unrelated = URL(fileURLWithPath: root).appending(path: "log/unrelated.md")
    try Data("not a brain record".utf8).write(to: unrelated)
    let pack = try await store.contextPack(
      authorisedScopes: [.agentRole], authorisedProfileID: profileID, confirmedOnly: true)
    #expect(pack.text.contains(record.body))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    let other = try await store.contextPack(
      authorisedScopes: [.agentRole], authorisedProfileID: UUID(), confirmedOnly: true)
    #expect(!other.text.contains(record.body))
  }

  @Test("Records round-trip through canonical Markdown with frontmatter intact")
  func serializerRoundTrip() throws {
    let record = MemoryRecord(
      id: "decision-app-surfaces-001",
      type: .decision,
      scope: .project,
      project: "muse",
      title: "Agent chat replaces raw TUI: structured runs only",
      body: """
        # Decision

        Chat prompts swap the interactive harness for a structured run.

        ---

        | Option | Outcome |
        |---|---|
        | TUI scrape | rejected |
        """,
      author: "agent:reviewer",
      createdAt: Date(timeIntervalSince1970: 1_754_300_000),
      updatedAt: Date(timeIntervalSince1970: 1_754_300_500),
      revision: 3,
      confidence: .confirmed,
      status: .active,
      sourceIDs: ["session:abc123/message:42", "session:abc123/message:57"],
      supersedes: ["decision-app-surfaces-000"],
      tags: ["canvas", "integrations"],
      entityIDs: ["project/muse", "feature/agent-chat"],
      factKind: .commitment,
      expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let serialized = MemoryRecordSerializer.serialize(record)
    let parsed = try MemoryRecordSerializer.parse(serialized)
    #expect(parsed == record)
    // Deterministic output: serializing again yields byte-identical content.
    #expect(MemoryRecordSerializer.serialize(parsed) == serialized)
  }

  @Test("Write, read back, and list from the canonical store")
  func writeReadList() async throws {
    let store = try makeStore()
    let written = try await store.write(
      MemoryRecord(
        id: "auth-uses-signed-sessions",
        type: .wiki,
        project: "fixture",
        title: "Auth uses signed sessions",
        body: "Sessions are signed with the workspace key.",
        author: "agent:worker"
      ),
      expectedRevision: nil
    )
    #expect(written.revision == 1)
    let read = try await store.read(type: .wiki, id: "auth-uses-signed-sessions")
    #expect(read.title == "Auth uses signed sessions")
    #expect(read.revision == 1)
    let byID = try await store.read(id: "auth-uses-signed-sessions")
    #expect(byID == read)
    let listed = try await store.list(type: .wiki)
    #expect(listed.records.map(\.id) == ["auth-uses-signed-sessions"])
    #expect(listed.quarantined.isEmpty)
  }

  @Test("Optimistic revisions: stale writers conflict instead of overwriting")
  func revisionConflicts() async throws {
    let store = try makeStore()
    var record = try await store.write(
      MemoryRecord(
        id: "deploy-policy", type: .decision, project: "fixture",
        title: "Deploy policy", body: "v1", author: "agent:a"),
      expectedRevision: nil
    )
    record.body = "v2"
    let second = try await store.write(record, expectedRevision: 1)
    #expect(second.revision == 2)

    // A writer still holding revision 1 must conflict, not overwrite.
    record.body = "stale"
    await #expect(
      throws: MemoryStoreError.revisionConflict(id: "deploy-policy", currentRevision: 2)
    ) {
      try await store.write(record, expectedRevision: 1)
    }
    // Creating over an existing record without reading it first also conflicts.
    await #expect(throws: MemoryStoreError.self) {
      try await store.write(
        MemoryRecord(
          id: "deploy-policy", type: .decision, project: "fixture",
          title: "Deploy policy", body: "blind create", author: "agent:b"),
        expectedRevision: nil
      )
    }
    // The superseded revision remains on disk for history.
    let root = await store.rootPath
    let retained = "\(root)/decisions/.revisions/deploy-policy.r1.md"
    #expect(FileManager.default.fileExists(atPath: retained))
  }

  @Test("Corrupt records are quarantined visibly, not skipped or trusted")
  func quarantine() async throws {
    let store = try makeStore()
    _ = try await store.write(
      MemoryRecord(
        id: "healthy", type: .log, project: "fixture",
        title: "Healthy entry", body: "fine", author: "agent:a"),
      expectedRevision: nil
    )
    let root = await store.rootPath
    let corruptPath = "\(root)/log/corrupt.md"
    try Data("not a memory record".utf8).write(to: URL(fileURLWithPath: corruptPath))

    let listed = try await store.list(type: .log)
    #expect(listed.records.map(\.id) == ["healthy"])
    #expect(listed.quarantined.count == 1)
    #expect(!FileManager.default.fileExists(atPath: corruptPath))
    #expect(
      FileManager.default.fileExists(atPath: listed.quarantined[0].quarantinePath))
  }

  @Test("Secrets are rejected before persistence")
  func secretRejection() async throws {
    let store = try makeStore()
    await #expect(throws: MemoryStoreError.self) {
      try await store.write(
        MemoryRecord(
          id: "leaky", type: .wiki, project: "fixture",
          title: "Config notes",
          body: "Use ghp_0123456789abcdefghijklmnop for the deploy job.",
          author: "agent:a"),
        expectedRevision: nil
      )
    }
  }

  @Test("Record IDs cannot traverse outside the brain")
  func idValidation() async throws {
    let store = try makeStore()
    for invalid in ["../escape", "UPPER", "a/b", "", "space name", ".hidden"] {
      await #expect(throws: MemoryStoreError.self) {
        try await store.write(
          MemoryRecord(
            id: invalid, type: .wiki, project: "fixture",
            title: "x", body: "x", author: "agent:a"),
          expectedRevision: nil
        )
      }
    }
  }

  @Test("The FTS index rebuilds from canonical files and stays project-isolated")
  func searchIndexRebuild() async throws {
    let store = try makeStore()
    _ = try await store.write(
      MemoryRecord(
        id: "auth-decision", type: .decision, project: "fixture",
        title: "Authentication decision",
        body: "We chose signed sessions over rotating API keys for the control socket.",
        author: "agent:a", tags: ["auth"]),
      expectedRevision: nil
    )
    _ = try await store.appendLog(
      title: "Fixed the PTY drain bug", body: "Drain before closing the slave fd.",
      author: "agent:b")

    try await store.rebuildSearchIndex()
    let hits = try await store.search("signed sessions")
    #expect(hits.map(\.id) == ["auth-decision"])
    #expect(hits[0].type == .decision)
    // Natural-language queries with operator characters must not break the match syntax.
    let messyQueryHits = try await store.search("what did we decide: auth-\"keys\" (sessions)?")
    #expect(!messyQueryHits.isEmpty)

    // A second brain sees none of it.
    let other = try makeStore()
    try await other.rebuildSearchIndex()
    let isolatedHits = try await other.search("signed sessions")
    #expect(isolatedHits.isEmpty)
  }

  @Test("Manifest is created once and survives reopening; newer schemas fail closed")
  func manifestLifecycle() async throws {
    let root = temporaryRoot()
    let store = try ProjectBrainStore(rootPath: root, project: "fixture")
    let created = await store.manifest
    #expect(created.schemaVersion == BrainManifest.currentSchemaVersion)

    let reopened = try ProjectBrainStore(rootPath: root, project: "renamed")
    let manifest = await reopened.manifest
    #expect(manifest.project == "fixture")
    // ISO-8601 persistence rounds to whole seconds; identity is what matters here.
    #expect(abs(manifest.createdAt.timeIntervalSince(created.createdAt)) < 1)

    let futuristic = BrainManifest(
      schemaVersion: BrainManifest.currentSchemaVersion + 1, project: "future")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(futuristic).write(
      to: URL(fileURLWithPath: "\(root)/manifest.json"), options: .atomic)
    #expect(throws: MemoryStoreError.self) {
      _ = try ProjectBrainStore(rootPath: root, project: "fixture")
    }
  }

  @Test("Log appends derive dated, collision-free ids")
  func logIDDerivation() async throws {
    let store = try makeStore()
    let first = try await store.appendLog(
      title: "Shipped the FILES tab!", body: "a", author: "agent:a")
    let second = try await store.appendLog(
      title: "Shipped the FILES tab!", body: "b", author: "agent:a")
    #expect(first.id.hasSuffix("shipped-the-files-tab"))
    #expect(second.id == "\(first.id)-2")
    let startsWithYear = first.id.prefix(4).allSatisfy { $0.isNumber }
    #expect(startsWithYear)
  }

  @Test("Records written before trust weighting parse at the neutral score")
  func trustDefaultsForLegacyRecords() throws {
    // Byte-for-byte the frontmatter shape shipped before trust existed: no trust_score,
    // helpful_count, or unhelpful_count. These must load, not quarantine.
    let legacy = """
      ---
      id: 2026-08-05-legacy-entry
      type: log
      scope: project
      project: fixture
      title: Legacy entry
      author: muse:auto-log
      created_at: 2026-08-05T10:32:00Z
      updated_at: 2026-08-05T10:32:00Z
      revision: 1
      confidence: confirmed
      status: active
      source_ids: []
      supersedes: []
      tags: []
      ---

      Objective: something real
      """
    let parsed = try MemoryRecordSerializer.parse(legacy)
    #expect(parsed.trustScore == MemoryTrust.initial)
    #expect(parsed.helpfulCount == 0)
    #expect(parsed.unhelpfulCount == 0)
  }

  @Test("Feedback moves trust, and unhelpful outweighs helpful")
  func feedbackAdjustsTrust() async throws {
    let store = try makeStore()
    let record = try await store.appendLog(
      title: "Widget runtime plan", body: "details", author: "agent:a")
    #expect(record.trustScore == MemoryTrust.initial)

    let up = try await store.recordFeedback(id: record.id, helpful: true)
    #expect(abs(up.trustScore - 0.55) < 0.0001)
    #expect(up.helpfulCount == 1)

    let down = try await store.recordFeedback(id: record.id, helpful: false)
    #expect(abs(down.trustScore - 0.45) < 0.0001)
    #expect(down.unhelpfulCount == 1)
    // Trust survives the round trip through canonical Markdown, not just memory.
    let reread = try await store.read(id: record.id)
    #expect(abs(reread.trustScore - 0.45) < 0.0001)
  }

  @Test("Trust is clamped to 0...1 no matter how much feedback lands")
  func trustClamps() async throws {
    let store = try makeStore()
    let record = try await store.appendLog(title: "Clamp me", body: "x", author: "agent:a")
    for _ in 0..<20 { _ = try await store.recordFeedback(id: record.id, helpful: false) }
    #expect(try await store.read(id: record.id).trustScore == MemoryTrust.minimum)
    for _ in 0..<40 { _ = try await store.recordFeedback(id: record.id, helpful: true) }
    #expect(try await store.read(id: record.id).trustScore == MemoryTrust.maximum)
  }

  @Test("Search ranks by trust and withholds records below the floor")
  func searchAppliesTrust() async throws {
    let store = try makeStore()
    let trusted = try await store.appendLog(
      title: "Sessions decision alpha", body: "session handling", author: "agent:a")
    let distrusted = try await store.appendLog(
      title: "Sessions decision beta", body: "session handling", author: "agent:a")

    _ = try await store.recordFeedback(id: trusted.id, helpful: true)
    // Three unhelpful ratings put this one under the 0.3 default floor.
    for _ in 0..<3 { _ = try await store.recordFeedback(id: distrusted.id, helpful: false) }

    let defaultHits = try await store.search("sessions", limit: 10)
    #expect(defaultHits.map(\.id) == [trusted.id])

    // Nothing is deleted — dropping the floor still surfaces it, ranked last.
    let allHits = try await store.search("sessions", limit: 10, minTrust: 0)
    #expect(allHits.count == 2)
    #expect(allHits.last?.id == distrusted.id)
  }

  @Test("Search counts retrievals without rewriting the canonical record")
  func searchCountsRetrievals() async throws {
    let store = try makeStore()
    let record = try await store.appendLog(
      title: "Retrieval counting", body: "telemetry", author: "agent:a")
    let revisionBefore = try await store.read(id: record.id).revision

    _ = try await store.search("retrieval", limit: 5)
    _ = try await store.search("retrieval", limit: 5)

    #expect(await store.retrievalCount(id: record.id) == 2)
    #expect(try await store.read(id: record.id).revision == revisionBefore)
  }

  @Test("An index predating trust weighting is discarded and rebuilt, losing no records")
  func legacyIndexMigratesOnOpen() async throws {
    let root = temporaryRoot()
    let fileManager = FileManager.default
    for directory in ["log", "index"] {
      try fileManager.createDirectory(
        atPath: (root as NSString).appendingPathComponent(directory),
        withIntermediateDirectories: true)
    }

    // Stand up the exact pre-trust index schema: five columns, no `trust`. Inserting into this
    // table with the current writer fails on every write, which is what the migration exists to
    // prevent.
    let databasePath = (root as NSString).appendingPathComponent("index/brain.db")
    var legacy: OpaquePointer?
    #expect(
      sqlite3_open_v2(
        databasePath, &legacy, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    #expect(
      sqlite3_exec(
        legacy,
        """
        CREATE VIRTUAL TABLE brain_fts USING fts5(id UNINDEXED, type UNINDEXED, title, body, tags);
        INSERT INTO brain_fts (id, type, title, body, tags)
          VALUES ('stale-row', 'log', 'stale', 'stale', '');
        """,
        nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(legacy)

    // A canonical record on disk that the old index never knew about.
    let record = MemoryRecord(
      id: "2026-08-07-canvas-notes-architecture",
      type: .log,
      project: "fixture",
      title: "Canvas notes architecture",
      body: "Notes are canvas-owned Markdown files.",
      author: "agent:beck",
      confidence: .confirmed
    )
    try Data(MemoryRecordSerializer.serialize(record).utf8).write(
      to: URL(
        fileURLWithPath: (root as NSString).appendingPathComponent(
          "log/\(record.id).md")),
      options: .atomic)

    let store = try ProjectBrainStore(rootPath: root, project: "fixture")
    // Initialization only migrates the schema; slow record reads wait until the first search.
    var migrated: OpaquePointer?
    #expect(sqlite3_open_v2(databasePath, &migrated, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    var count: OpaquePointer?
    #expect(
      sqlite3_prepare_v2(migrated, "SELECT COUNT(*) FROM brain_fts", -1, &count, nil) == SQLITE_OK)
    #expect(sqlite3_step(count) == SQLITE_ROW)
    #expect(sqlite3_column_int(count, 0) == 0)
    sqlite3_finalize(count)
    sqlite3_close_v2(migrated)
    // The first search still returns all canonical records without an explicit rebuild.
    let hits = try await store.search("canvas notes", limit: 10)
    #expect(hits.map(\.id) == [record.id])
    #expect(hits.first?.trustScore == MemoryTrust.initial)
    // Writes work against the migrated schema.
    let appended = try await store.appendLog(
      title: "Post-migration write", body: "b", author: "agent:a")
    #expect(try await store.search("post-migration", limit: 5).map(\.id) == [appended.id])
  }

  @Test("A delegation handoff is recorded once, however often the result is read")
  func delegationHandoffIsIdempotent() async throws {
    let store = try makeStore()
    let requester = "11111111-1111-1111-1111-111111111111"
    let target = "22222222-2222-2222-2222-222222222222"

    let first = try await store.recordDelegationHandoff(
      requesterID: requester,
      targetID: target,
      task: "Research how Otto can support slash commands",
      outcome: "Found three viable approaches; recommends the registry-backed one.",
      sourceIDs: ["agent:\(target)"]
    )
    let record = try #require(first)
    #expect(record.type == .handoff)
    #expect(record.body.contains(requester))
    #expect(record.body.contains(target))
    #expect(record.body.contains("slash commands"))

    // Same task and outcome: the requester re-reading the result adds nothing.
    let repeated = try await store.recordDelegationHandoff(
      requesterID: requester,
      targetID: target,
      task: "Research how Otto can support slash commands",
      outcome: "Found three viable approaches; recommends the registry-backed one."
    )
    #expect(repeated == nil)
    #expect(try await store.list(type: .handoff).records.count == 1)

    // A genuinely different outcome is a different handoff.
    let second = try await store.recordDelegationHandoff(
      requesterID: requester,
      targetID: target,
      task: "Now implement it",
      outcome: "Implemented and tested."
    )
    #expect(second != nil)
    #expect(try await store.list(type: .handoff).records.count == 2)
  }

  @Test("agent-role records require profileID and never leak across profiles")
  func agentRoleScopeIsolation() async throws {
    let store = try makeStore()
    let buz = UUID()
    let wang = UUID()
    _ = try await store.write(
      MemoryRecord(
        id: "buz-prefers-unified-diffs",
        type: .wiki,
        scope: .agentRole,
        project: "fixture",
        title: "Buz prefers unified diffs",
        body: "Always request the unified diff format.",
        author: "agent:buz",
        sourceIDs: ["session:buz/message:4"],
        profileID: buz
      ),
      expectedRevision: nil
    )
    _ = try await store.write(
      MemoryRecord(
        id: "shared-deploy-window",
        type: .wiki,
        scope: .project,
        project: "fixture",
        title: "Deploy window",
        body: "Deploys happen after 6pm.",
        author: "user"
      ),
      expectedRevision: nil
    )

    let buzHits = try await store.search(
      "diff", authorisedScopes: [.agentRole], authorisedProfileID: buz)
    #expect(buzHits.map(\.id) == ["buz-prefers-unified-diffs"])

    let wangHits = try await store.search(
      "diff", authorisedScopes: [.agentRole], authorisedProfileID: wang)
    #expect(wangHits.isEmpty)

    let projectHits = try await store.search("diff", authorisedScopes: [.project])
    #expect(projectHits.map(\.id) == [])
    let projectDeploy = try await store.search("deploy", authorisedScopes: [.project])
    #expect(projectDeploy.map(\.id) == ["shared-deploy-window"])

    await #expect(throws: MemoryStoreError.self) {
      try await store.write(
        MemoryRecord(
          id: "missing-owner",
          type: .wiki,
          scope: .agentRole,
          project: "fixture",
          title: "No owner",
          body: "Should fail.",
          author: "agent:x"
        ),
        expectedRevision: nil
      )
    }
  }

  @Test("Context packs enforce bot ownership, provenance, expiry, and token budgets")
  func contextPacksAreBoundedAndScoped() async throws {
    let store = try makeStore()
    let taz = UUID()
    let buzz = UUID()
    _ = try await store.write(
      MemoryRecord(
        id: "taz-prefers-cited-plans",
        type: .wiki,
        scope: .agentRole,
        project: "fixture",
        title: "Taz cites plans",
        body: "Plans must cite current primary sources.",
        author: "agent:taz",
        confidence: .confirmed,
        sourceIDs: ["user:instruction-7"],
        entityIDs: ["agent/taz", "project/muse"],
        factKind: .preference,
        profileID: taz
      ),
      expectedRevision: nil
    )
    _ = try await store.write(
      MemoryRecord(
        id: "buzz-private-research-style",
        type: .wiki,
        scope: .agentRole,
        project: "fixture",
        title: "Buzz research style",
        body: "Buzz checks three sources.",
        author: "agent:buzz",
        sourceIDs: ["session:buzz/message:2"],
        profileID: buzz
      ),
      expectedRevision: nil
    )
    _ = try await store.write(
      MemoryRecord(
        id: "expired-project-fact",
        type: .wiki,
        project: "fixture",
        title: "Old launch date",
        body: "Launch was planned for yesterday.",
        author: "agent:taz",
        sourceIDs: ["calendar:event-1"],
        expiresAt: .distantPast
      ),
      expectedRevision: nil
    )

    let tazPack = try await store.contextPack(
      budgetTokens: 256,
      authorisedScopes: [.agentRole],
      authorisedProfileID: taz
    )
    #expect(tazPack.text.contains("taz-prefers-cited-plans"))
    #expect(tazPack.text.contains("source: user:instruction-7"))
    #expect(tazPack.text.contains("entities: agent/taz, project/muse"))
    #expect(!tazPack.text.contains("buzz-private-research-style"))
    #expect(tazPack.budgetUsed <= tazPack.budgetTokens)

    let shared = try await store.contextPack(
      query: "launch date",
      budgetTokens: 128,
      authorisedScopes: [.project]
    )
    #expect(!shared.text.contains("expired-project-fact"))
    #expect(try await store.search("launch date").isEmpty)
  }

  @Test("A handoff with no outcome is not worth a record")
  func emptyHandoffIsSkipped() async throws {
    let store = try makeStore()
    let written = try await store.recordDelegationHandoff(
      requesterID: "a", targetID: "b", task: "do a thing", outcome: "   \n ")
    #expect(written == nil)
    #expect(try await store.list(type: .handoff).records.isEmpty)
  }

  private func makeStore() throws -> ProjectBrainStore {
    try ProjectBrainStore(rootPath: temporaryRoot(), project: "fixture")
  }

  private func temporaryRoot() -> String {
    FileManager.default.temporaryDirectory
      .appending(path: "otto-brain-\(UUID().uuidString)", directoryHint: .isDirectory).path
  }
}
