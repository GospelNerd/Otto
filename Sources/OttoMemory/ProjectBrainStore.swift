import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Canonical storage for one Project Brain rooted at `<workspace>/.otto/brain`. Markdown files
/// with frontmatter are the single source of truth; every write is atomic, revision-checked, and
/// keeps the previous revision on disk. Corrupt records are quarantined visibly instead of being
/// skipped silently or trusted blindly. The SQLite/FTS index is a derived accelerator owned by
/// `BrainSearchIndex` and can always be rebuilt from these files.
public actor ProjectBrainStore {
  public let rootPath: String
  public private(set) var manifest: BrainManifest
  private let searchIndex: BrainSearchIndex
  private var needsSearchIndexRebuild: Bool

  public init(rootPath: String, project: String) throws {
    self.rootPath = rootPath
    let fileManager = FileManager.default
    for directory in Self.directories {
      try fileManager.createDirectory(
        atPath: (rootPath as NSString).appendingPathComponent(directory),
        withIntermediateDirectories: true
      )
    }
    let manifestPath = (rootPath as NSString).appendingPathComponent("manifest.json")
    if let data = fileManager.contents(atPath: manifestPath) {
      let decoded = try JSONDecoder.brain.decode(BrainManifest.self, from: data)
      guard decoded.schemaVersion <= BrainManifest.currentSchemaVersion else {
        throw MemoryStoreError.schemaTooNew(
          found: decoded.schemaVersion, supported: BrainManifest.currentSchemaVersion)
      }
      // Future migrations run here; schema 1 is the first version.
      manifest = decoded
    } else {
      manifest = BrainManifest(project: project)
      try JSONEncoder.brain.encode(manifest).write(
        to: URL(fileURLWithPath: manifestPath), options: .atomic)
    }
    let databasePath = (rootPath as NSString).appendingPathComponent("index/brain.db")
    let indexExisted = fileManager.fileExists(atPath: databasePath)
    // The canonical record ids on disk, by folder. A file name is its record id.
    let filesByDirectory: [(directory: String, ids: Set<String>)] = MemoryRecordType.allCases.map {
      type in
      let directory = (rootPath as NSString).appendingPathComponent(type.directoryName)
      let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
      return (
        type.directoryName,
        Set(names.filter { $0.hasSuffix(".md") }.map { ($0 as NSString).deletingPathExtension })
      )
    }
    let hasUnindexedFiles =
      !indexExisted && filesByDirectory.contains { !$0.ids.isEmpty }
    searchIndex = try BrainSearchIndex(databasePath: databasePath)
    // Defer record I/O to the actor's executor. Initialization is called by the desktop's
    // main actor and must not scan cloud-backed history before the UI and mobile host start.
    var indexMissesFiles = false
    if indexExisted {
      // An index that came from the other side of a workspace merge, or from a crash between a
      // file write and its index write, covers fewer records than the folder holds. Rebuild
      // rather than leave search blind to files it never saw.
      let indexed = searchIndex.indexedIDs()
      indexMissesFiles = filesByDirectory.contains { entry in
        !entry.ids.isSubset(of: indexed)
      }
    }
    let schemaRequiresRebuild = searchIndex.requiresRebuild
    needsSearchIndexRebuild = hasUnindexedFiles || schemaRequiresRebuild || indexMissesFiles
  }

  private static let directories = [
    "log", "wiki", "raw", "outputs", "decisions", "handoffs", "index", "quarantine", "deleted",
  ]

  // MARK: - Writing

  /// Persists a record. New records must present `expectedRevision: nil`; updates must present
  /// the revision they read. On success the returned record carries the bumped revision, and the
  /// previous file content is retained under `.revisions/`.
  @discardableResult
  public func write(_ record: MemoryRecord, expectedRevision: Int?) throws -> MemoryRecord {
    guard MemoryRecord.isValidID(record.id) else {
      throw MemoryStoreError.invalidRecordID(record.id)
    }
    guard !record.title.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw MemoryStoreError.invalidTitle
    }
    if let marker = MemorySecretScanner.firstSecretMarker(in: record.body)
      ?? MemorySecretScanner.firstSecretMarker(in: record.title)
      ?? MemorySecretScanner.firstSecretMarker(
        in: (record.sourceIDs + record.tags).joined(separator: "\n"))
    {
      throw MemoryStoreError.secretDetected(marker)
    }
    if record.scope == .agentRole, record.profileID == nil {
      throw MemoryStoreError.malformedRecord(
        path: record.id, reason: "agent-role memory requires a profileID")
    }
    if record.scope == .agentRole, record.sourceIDs.isEmpty {
      throw MemoryStoreError.malformedRecord(
        path: record.id, reason: "agent-role memory requires provenance in sourceIDs")
    }
    if let invalidEntity = record.entityIDs.first(where: { !Self.isValidEntityID($0) }) {
      throw MemoryStoreError.malformedRecord(
        path: record.id, reason: "invalid entity id \(invalidEntity)")
    }

    let path = recordPath(type: record.type, id: record.id)
    let fileManager = FileManager.default
    let existing: MemoryRecord?
    if fileManager.fileExists(atPath: path) {
      existing = try loadRecord(atPath: path)
    } else {
      existing = nil
    }
    switch (existing, expectedRevision) {
    case (nil, nil):
      break
    case (nil, .some):
      throw MemoryStoreError.recordNotFound(record.id)
    case (.some(let current), .some(let expected)) where current.revision == expected:
      try retainRevision(of: current, atPath: path)
    case (.some(let current), _):
      throw MemoryStoreError.revisionConflict(id: record.id, currentRevision: current.revision)
    }

    var persisted = record
    persisted.revision = (existing?.revision ?? 0) + 1
    persisted.createdAt = existing?.createdAt ?? record.createdAt
    persisted.updatedAt = .now
    let serialized = MemoryRecordSerializer.serialize(persisted)
    do {
      try Data(serialized.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
      throw MemoryStoreError.storageFailure(error.localizedDescription)
    }
    try? searchIndex.upsert(persisted)
    return persisted
  }

  /// Appends a dated log entry, deriving a collision-free id like `2026-08-04-fixed-auth-2`.
  @discardableResult
  public func appendLog(
    title: String,
    body: String,
    author: String,
    sourceIDs: [String] = [],
    tags: [String] = []
  ) throws -> MemoryRecord {
    let day = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false))
      .prefix(10)
    let base = "\(day)-\(MemoryRecord.slug(from: title))"
    var candidate = base
    var suffix = 2
    while FileManager.default.fileExists(atPath: recordPath(type: .log, id: candidate)) {
      candidate = "\(base)-\(suffix)"
      suffix += 1
    }
    return try write(
      MemoryRecord(
        id: candidate,
        type: .log,
        project: manifest.project,
        title: title,
        body: body,
        author: author,
        confidence: .confirmed,
        sourceIDs: sourceIDs,
        tags: tags
      ),
      expectedRevision: nil
    )
  }

  // MARK: - Delegation

  /// Records that one agent handed work to another and read the result back.
  ///
  /// Delegation is the one event neither participant reliably remembers: the worker logs its own
  /// run without knowing who asked, and the requester folds the answer into its own summary
  /// where the provenance disappears. This captures the edge itself — who asked whom, for what,
  /// and what came back — which is the whole content of a handoff.
  ///
  /// Idempotent by construction: the id is derived from the participants and the outcome, so a
  /// requester that reads the same result twice gets one record and `nil` the second time,
  /// without needing any in-memory ledger to survive between tool calls.
  @discardableResult
  public func recordDelegationHandoff(
    requesterID: String,
    targetID: String,
    task: String,
    outcome: String,
    sourceIDs: [String] = []
  ) throws -> MemoryRecord? {
    let trimmedOutcome = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedOutcome.isEmpty else { return nil }
    let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
    let id = "handoff-\(Self.shortID(targetID))-\(Self.fingerprint(trimmedTask + trimmedOutcome))"
    guard !FileManager.default.fileExists(atPath: recordPath(type: .handoff, id: id)) else {
      return nil
    }
    let day = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false))
      .prefix(10)
    let body = """
      Requested by: \(requesterID)
      Performed by: \(targetID)

      Task: \(String(trimmedTask.prefix(500)))

      Returned: \(String(trimmedOutcome.prefix(900)))
      """
    return try write(
      MemoryRecord(
        id: id,
        type: .handoff,
        project: manifest.project,
        title: "Handoff \(day): \(String(trimmedTask.prefix(60)))",
        body: body,
        author: "otto:delegation",
        confidence: .confirmed,
        sourceIDs: sourceIDs
      ),
      expectedRevision: nil
    )
  }

  /// First UUID group, lowercased — enough to identify the agent inside an id without spending
  /// the slug's length budget on a full UUID.
  private static func shortID(_ raw: String) -> String {
    let lowered = raw.lowercased()
    let head = lowered.split(separator: "-").first.map(String.init) ?? lowered
    return String(head.prefix(8)).filter { $0.isNumber || ($0.isLetter && $0.isASCII) }
  }

  /// FNV-1a over the content: stable across launches (unlike `hashValue`) and only needs to
  /// separate distinct outcomes, not resist attack.
  private static func fingerprint(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x1000_0000_01b3
    }
    return String(format: "%016llx", hash)
  }

  // MARK: - Lifecycle (confirm, archive, supersede, delete)

  /// Marks a proposed record as confirmed. The tool layer restricts this to user-initiated
  /// calls; quarantined provenance requires explicit user promotion.
  @discardableResult
  public func confirm(id: String, expectedRevision: Int) throws -> MemoryRecord {
    var record = try read(id: id)
    record.confidence = .confirmed
    return try write(record, expectedRevision: expectedRevision)
  }

  @discardableResult
  public func archive(id: String, expectedRevision: Int) throws -> MemoryRecord {
    var record = try read(id: id)
    record.status = .archived
    return try write(record, expectedRevision: expectedRevision)
  }

  /// Marks the old record superseded and links the replacement both ways.
  @discardableResult
  public func supersede(
    id: String, by replacementID: String, expectedRevision: Int
  ) throws -> MemoryRecord {
    var replacement = try read(id: replacementID)
    var superseded = try read(id: id)
    superseded.status = .superseded
    let updated = try write(superseded, expectedRevision: expectedRevision)
    if !replacement.supersedes.contains(id) {
      replacement.supersedes.append(id)
      _ = try write(replacement, expectedRevision: replacement.revision)
    }
    return updated
  }

  /// Deletion is recoverable: the canonical file moves to `deleted/` with a timestamp instead
  /// of vanishing, and the search index forgets it.
  public func delete(id: String) throws {
    let record = try read(id: id)
    let path = recordPath(type: record.type, id: record.id)
    let destination = ((rootPath as NSString).appendingPathComponent("deleted") as NSString)
      .appendingPathComponent("\(Int(Date.now.timeIntervalSince1970))-\(record.id).md")
    do {
      try FileManager.default.moveItem(atPath: path, toPath: destination)
    } catch {
      throw MemoryStoreError.storageFailure(error.localizedDescription)
    }
    try? searchIndex.remove(id: record.id)
  }

  /// Legacy importers must not resurrect records the user has deleted.
  public func wasDeleted(id: String) -> Bool {
    guard MemoryRecord.isValidID(id) else { return false }
    let directory = (rootPath as NSString).appendingPathComponent("deleted")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return names.contains { name in
      guard let separator = name.firstIndex(of: "-") else { return false }
      return name[name.index(after: separator)...] == "\(id).md"
    }
  }

  // MARK: - Reading

  public func read(type: MemoryRecordType, id: String) throws -> MemoryRecord {
    guard MemoryRecord.isValidID(id) else { throw MemoryStoreError.invalidRecordID(id) }
    let path = recordPath(type: type, id: id)
    guard FileManager.default.fileExists(atPath: path) else {
      throw MemoryStoreError.recordNotFound(id)
    }
    return try loadRecord(atPath: path)
  }

  /// Finds a record by id across every type directory — ids are unique brain-wide by
  /// construction, so the first hit wins.
  public func read(id: String) throws -> MemoryRecord {
    for type in MemoryRecordType.allCases {
      if let record = try? read(type: type, id: id) { return record }
    }
    throw MemoryStoreError.recordNotFound(id)
  }

  public struct ListResult: Sendable {
    public let records: [MemoryRecord]
    public let quarantined: [QuarantinedRecord]
  }

  /// Lists records of one type, newest first. Files that fail to parse are moved to
  /// `quarantine/` and reported so corruption is visible instead of contagious.
  public func list(type: MemoryRecordType) throws -> ListResult {
    let directory = (rootPath as NSString).appendingPathComponent(type.directoryName)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    var records: [MemoryRecord] = []
    var quarantined: [QuarantinedRecord] = []
    for name in names.sorted() where name.hasSuffix(".md") {
      let path = (directory as NSString).appendingPathComponent(name)
      do {
        records.append(try loadRecord(atPath: path))
      } catch {
        quarantined.append(quarantine(path: path, reason: "\(error.localizedDescription)"))
      }
    }
    records.sort { $0.updatedAt > $1.updatedAt }
    return ListResult(records: records, quarantined: quarantined)
  }

  public func allRecords() throws -> [MemoryRecord] {
    try MemoryRecordType.allCases.flatMap { try list(type: $0).records }
  }

  // MARK: - Search index

  /// Rebuilds the derived FTS index from the canonical files. Safe to call any time; the index
  /// carries no knowledge of its own.
  public func rebuildSearchIndex() throws {
    try searchIndex.rebuild(with: try allRecords())
    needsSearchIndexRebuild = false
  }

  /// Trust-weighted search. `minTrust` withholds records that repeated feedback has marked
  /// unhelpful; pass `0` to see everything, including what the brain has learned to distrust.
  public func search(
    _ query: String,
    limit: Int = 12,
    minTrust: Double = MemoryTrust.searchFloor,
    authorisedScopes: Set<MemoryScope> = [.project, .canvas],
    authorisedProfileID: UUID? = nil,
    confirmedOnly: Bool = false,
    recordTypes: Set<MemoryRecordType>? = nil,
    localFilesOnly: Bool = false
  ) throws -> [BrainSearchHit] {
    if needsSearchIndexRebuild {
      if localFilesOnly { return [] }
      try rebuildSearchIndex()
    }
    let candidates = try searchIndex.search(
      query,
      limit: max(limit * 4, 24),
      minTrust: minTrust,
      authorisedScopes: authorisedScopes,
      authorisedProfileID: authorisedProfileID,
      confirmedOnly: confirmedOnly, recordTypes: recordTypes
    )
    var results: [BrainSearchHit] = []
    for hit in candidates {
      guard let record = contextRecord(type: hit.type, id: hit.id, localFilesOnly: localFilesOnly),
        record.isAvailable(),
        !confirmedOnly || record.confidence == .confirmed,
        recordTypes == nil || recordTypes!.contains(record.type)
      else { continue }
      results.append(hit)
      if results.count >= limit { break }
    }
    return results
  }

  /// Produces a bounded, citation-bearing block from the same canonical records used by search.
  /// Blank queries mean "most useful recent records" and are used for frozen bot-memory
  /// bootstraps. Non-blank queries use trust-weighted FTS before packing.
  public func contextPack(
    query: String = "",
    budgetTokens: Int = 1_200,
    authorisedScopes: Set<MemoryScope> = [.project, .canvas],
    authorisedProfileID: UUID? = nil,
    minTrust: Double = MemoryTrust.searchFloor,
    confirmedOnly: Bool = false,
    recordTypes: Set<MemoryRecordType>? = nil,
    localFilesOnly: Bool = false
  ) throws -> MemoryContextPack {
    let budget = min(max(budgetTokens, 128), 8_000)
    let candidates: [MemoryRecord]
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if needsSearchIndexRebuild && localFilesOnly {
        return MemoryContextPack(
          text: "", recordIDs: [], budgetTokens: budget, budgetUsed: 0, droppedCount: 0)
      }
      if needsSearchIndexRebuild { try rebuildSearchIndex() }
      candidates = try searchIndex.contextCandidates(
        limit: 80, minTrust: minTrust, authorisedScopes: authorisedScopes,
        authorisedProfileID: authorisedProfileID, confirmedOnly: confirmedOnly,
        recordTypes: recordTypes
      ).compactMap { contextRecord(type: $0.0, id: $0.1, localFilesOnly: localFilesOnly) }
        .filter {
          $0.isAvailable()
            && authorisedScopes.contains($0.scope)
            && ($0.scope != .agentRole || $0.profileID == authorisedProfileID)
            && $0.trustScore >= minTrust
        }
        .sorted {
          if $0.trustScore != $1.trustScore { return $0.trustScore > $1.trustScore }
          return $0.updatedAt > $1.updatedAt
        }
    } else {
      candidates = try search(
        query,
        limit: 40,
        minTrust: minTrust,
        authorisedScopes: authorisedScopes,
        authorisedProfileID: authorisedProfileID,
        confirmedOnly: confirmedOnly, recordTypes: recordTypes, localFilesOnly: localFilesOnly
      ).compactMap { contextRecord(type: $0.type, id: $0.id, localFilesOnly: localFilesOnly) }
    }

    let characterBudget = budget * 4
    var chunks: [String] = []
    var ids: [String] = []
    var used = 0
    var dropped = 0
    for record in candidates {
      guard !confirmedOnly || record.confidence == .confirmed,
        recordTypes == nil || recordTypes!.contains(record.type)
      else { continue }
      let provenance =
        record.sourceIDs.isEmpty ? "uncited" : record.sourceIDs.joined(separator: ", ")
      let entities =
        record.entityIDs.isEmpty
        ? "" : " · entities: \(record.entityIDs.joined(separator: ", "))"
      let chunk =
        "[memory:\(record.id) · \(record.factKind.rawValue) · source: \(provenance)\(entities)]\n\(record.title)\n\(record.body.trimmingCharacters(in: .whitespacesAndNewlines))"
      guard used + chunk.count <= characterBudget else {
        dropped += 1
        continue
      }
      chunks.append(chunk)
      ids.append(record.id)
      used += chunk.count + 2
    }
    return MemoryContextPack(
      text: chunks.joined(separator: "\n\n"),
      recordIDs: ids,
      budgetTokens: budget,
      budgetUsed: min(budget, Int(ceil(Double(used) / 4.0))),
      droppedCount: dropped
    )
  }

  public func archiveAll(scope: MemoryScope, profileID: UUID) throws {
    for record in try allRecords()
    where record.scope == scope && record.profileID == profileID && record.status == .active {
      _ = try archive(id: record.id, expectedRevision: record.revision)
    }
  }

  public func restoreAll(scope: MemoryScope, profileID: UUID) throws {
    for var record in try allRecords()
    where record.scope == scope && record.profileID == profileID && record.status == .archived {
      record.status = .active
      _ = try write(record, expectedRevision: record.revision)
    }
  }

  /// How many times a record has been returned by search since the index was last rebuilt.
  public func retrievalCount(id: String) -> Int {
    searchIndex.retrievalCount(id: id)
  }

  // MARK: - Feedback

  /// Adjusts a record's trust from use: helpful nudges it up, unhelpful pushes it down harder.
  ///
  /// This is the only loop that lets the brain improve without anyone pruning it by hand — a
  /// record that keeps misleading readers sinks below the search floor on its own, and one that
  /// keeps earning its place rises above newer noise. The write goes through the normal
  /// revision-checked path, so every trust change is versioned and auditable like any other
  /// edit.
  @discardableResult
  public func recordFeedback(id: String, helpful: Bool) throws -> MemoryRecord {
    var record = try read(id: id)
    record.trustScore = MemoryTrust.clamp(
      record.trustScore + (helpful ? MemoryTrust.helpfulDelta : MemoryTrust.unhelpfulDelta))
    if helpful {
      record.helpfulCount += 1
    } else {
      record.unhelpfulCount += 1
    }
    return try write(record, expectedRevision: record.revision)
  }

  // MARK: - Internals

  private func recordPath(type: MemoryRecordType, id: String) -> String {
    let directory = (rootPath as NSString).appendingPathComponent(type.directoryName)
    return (directory as NSString).appendingPathComponent("\(id).md")
  }

  private nonisolated static func isValidEntityID(_ id: String) -> Bool {
    guard (1...128).contains(id.count), !id.hasPrefix("/"), !id.hasSuffix("/") else {
      return false
    }
    return id.allSatisfy {
      ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "/"
    }
  }

  /// Automatic prompt enrichment must not download cloud placeholders on the send path.
  /// Explicit reads retain their normal canonical-file behavior.
  private func contextRecord(type: MemoryRecordType, id: String, localFilesOnly: Bool)
    -> MemoryRecord?
  {
    #if canImport(Darwin)
      if localFilesOnly {
        var info = stat()
        guard stat(recordPath(type: type, id: id), &info) == 0,
          info.st_flags & UInt32(SF_DATALESS) == 0
        else { return nil }
      }
    #endif
    return try? read(type: type, id: id)
  }

  private func loadRecord(atPath path: String) throws -> MemoryRecord {
    guard let data = FileManager.default.contents(atPath: path) else {
      throw MemoryStoreError.storageFailure("Unreadable file at \(path)")
    }
    do {
      return try MemoryRecordSerializer.parse(String(decoding: data, as: UTF8.self))
    } catch let error as MemoryStoreError {
      if case .malformedRecord(_, let reason) = error {
        throw MemoryStoreError.malformedRecord(path: path, reason: reason)
      }
      throw error
    }
  }

  private func retainRevision(of record: MemoryRecord, atPath path: String) throws {
    let revisionsDirectory = ((path as NSString).deletingLastPathComponent as NSString)
      .appendingPathComponent(".revisions")
    try FileManager.default.createDirectory(
      atPath: revisionsDirectory, withIntermediateDirectories: true)
    let destination = (revisionsDirectory as NSString)
      .appendingPathComponent("\(record.id).r\(record.revision).md")
    if !FileManager.default.fileExists(atPath: destination) {
      try? FileManager.default.copyItem(atPath: path, toPath: destination)
    }
  }

  private func quarantine(path: String, reason: String) -> QuarantinedRecord {
    let name = (path as NSString).lastPathComponent
    let stamp = Int(Date.now.timeIntervalSince1970)
    let destination = ((rootPath as NSString).appendingPathComponent("quarantine") as NSString)
      .appendingPathComponent("\(stamp)-\(name)")
    try? FileManager.default.moveItem(atPath: path, toPath: destination)
    return QuarantinedRecord(originalPath: path, quarantinePath: destination, reason: reason)
  }
}

extension JSONEncoder {
  fileprivate static var brain: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var brain: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
