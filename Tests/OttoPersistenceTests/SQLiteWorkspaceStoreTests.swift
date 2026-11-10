import Foundation
import OttoModels
import OttoTools
import Testing

@testable import OttoPersistence

@Suite("SQLite workspace persistence")
struct SQLiteWorkspaceStoreTests {
  // Persistence tests need real nodes; fresh production workspaces intentionally have none.
  private func populatedWorkspace() -> WorkspaceSnapshot {
    let nodes = [
      OttoNode(
        kind: .agent, displayName: "Idle session", subtitle: "LOCAL",
        frame: WorldRect(x: 0, y: 0, width: 420, height: 270), zIndex: 0),
      OttoNode(
        kind: .agent, displayName: "Working session", subtitle: "LOCAL",
        frame: WorldRect(x: 440, y: 0, width: 420, height: 270), zIndex: 1,
        status: .working),
      OttoNode(
        kind: .markdown, displayName: "Notes", subtitle: "MARKDOWN",
        frame: WorldRect(x: 0, y: 300, width: 360, height: 300), zIndex: 2),
    ]
    let canvas = OttoCanvas(name: "Persistence fixture", nodes: nodes)
    return WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)
  }

  @Test("Migrates and restores a workspace snapshot")
  func roundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = SQLiteWorkspaceStore(path: directory.appending(path: "workspace.sqlite").path)
    var expected = populatedWorkspace()
    expected.canvases[0].nodes[0].agentDefinition = AgentDefinition(
      provider: .claudeCode,
      repositoryPath: "/code/otto",
      workingDirectory: "/code/otto/Sources",
      launchCommand: "claude",
      permissionMode: "workspaceWrite",
      model: "sonnet",
      executionStrategy: .delegated,
      resumeSessionID: "claude-session-123"
    )
    expected.canvases[0].nodes[0].isMinimized = true
    expected.canvases[0].nodes[0].attachments = [
      OttoAttachment(
        displayName: "brief.pdf",
        relativePath: ".otto/attachments/example/brief.pdf",
        mimeType: "application/pdf",
        byteCount: 2_048
      )
    ]
    let second = OttoCanvas(name: "Second canvas")
    expected.canvases.append(second)
    expected.activeCanvasID = second.id
    expected.workspaceSurface = .chat
    expected.chatNavigation = ChatSurfaceNavigationState(
      selectedProfileID: UUID(),
      selectedTeamID: UUID(),
      sidebarList: .bots,
      destination: .routines,
      libraryCanvasID: second.id
    )

    try await store.save(expected)
    let restored = try await store.load()

    #expect(restored == expected)
  }

  @Test("An empty database returns no snapshot")
  func emptyDatabase() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "otto-empty-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: path) }

    let store = SQLiteWorkspaceStore(path: path.path)
    #expect(try await store.load() == nil)
  }

  @Test("Unknown node kinds, content, and extension fields survive a database round trip")
  func opaqueNodeRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-opaque-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    var object = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(populatedWorkspace()))
        as? [String: Any])
    var canvases = try #require(object["canvases"] as? [[String: Any]])
    var nodes = try #require(canvases[0]["nodes"] as? [[String: Any]])
    nodes[0]["kind"] = "futureGrid"
    nodes[0]["content"] = [
      "futureGrid": ["columns": 7, "labels": ["one", "two"], "snap": true]
    ]
    nodes[0]["extensionState"] = [
      "revision": 4, "nested": ["accent": "ultraviolet"], "enabled": true,
    ]
    canvases[0]["nodes"] = nodes
    object["canvases"] = canvases
    let futureData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let futureSnapshot = try decoder.decode(WorkspaceSnapshot.self, from: futureData)
    let futureNode = futureSnapshot.canvases[0].nodes[0]
    #expect(futureNode.kind == .unsupported("futureGrid"))
    #expect(futureNode.content == nil)
    #expect(futureNode.unsupportedContentPayload != nil)
    #expect(futureNode.additionalPayload["extensionState"] != nil)

    let store = SQLiteWorkspaceStore(path: directory.appending(path: "workspace.sqlite").path)
    try await store.save(futureSnapshot)
    let restored = try #require(try await store.load())
    #expect(restored == futureSnapshot)

    let restoredObject = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(restored)) as? [String: Any])
    let restoredCanvases = try #require(restoredObject["canvases"] as? [[String: Any]])
    let restoredNodes = try #require(restoredCanvases[0]["nodes"] as? [[String: Any]])
    #expect(restoredNodes[0]["kind"] as? String == "futureGrid")
    #expect(
      NSDictionary(dictionary: restoredNodes[0]["content"] as? [String: Any] ?? [:])
        == NSDictionary(dictionary: nodes[0]["content"] as? [String: Any] ?? [:]))
    #expect(
      NSDictionary(dictionary: restoredNodes[0]["extensionState"] as? [String: Any] ?? [:])
        == NSDictionary(dictionary: nodes[0]["extensionState"] as? [String: Any] ?? [:]))
  }

  @Test("Version two migration mirrors normalized canvases and nodes")
  func normalizedMigration() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-normalized-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteWorkspaceStore(path: directory.appending(path: "workspace.sqlite").path)

    try await store.save(populatedWorkspace())
    #expect(try await store.schemaVersion() == 2)
    let counts = try await store.normalizedCounts()
    #expect(counts.canvases == 1)
    #expect(counts.nodes == 3)
    #expect(try await store.integrityCheck())
  }

  @Test("Historical version-one fixture upgrades in place")
  func historicalV1Fixture() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "otto-v1-fixture-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    let fixture = try #require(
      Bundle.module.url(
        forResource: "schema-v1", withExtension: "sql", subdirectory: "Fixtures"))
    let process = Process()
    process.executableURL = sqlite3Executable
    process.arguments = [path.path]
    process.standardInput = try FileHandle(forReadingFrom: fixture)
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let store = SQLiteWorkspaceStore(path: path.path)
    #expect(try await store.schemaVersion() == 2)
    let expected = populatedWorkspace()
    try await store.save(expected)
    #expect(try await store.load() == expected)
    #expect(try await store.normalizedCounts() == (canvases: 1, nodes: 3))
  }

  @Test("A newer workspace schema is rejected before writes")
  func rejectsFutureSchema() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "otto-future-schema-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    let process = Process()
    process.executableURL = sqlite3Executable
    process.arguments = [
      path.path,
      "CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL); INSERT INTO schema_migrations VALUES(99, 'future');",
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let store = SQLiteWorkspaceStore(path: path.path)
    await #expect(throws: PersistenceError.self) {
      try await store.schemaVersion()
    }
  }

  @Test("Restoration marks stale local processes stopped")
  func restorationRules() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "otto-restore-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    let store = SQLiteWorkspaceStore(path: path.path)
    try await store.save(populatedWorkspace())

    let restored = try #require(try await store.loadForRestoration())
    #expect(restored.canvases[0].nodes[0].status == .idle)
    #expect(restored.canvases[0].nodes[1].status == .stopped)
    #expect(restored.canvases[0].nodes[1].detail.contains("last exited"))
  }

  @Test("Forced writer termination rolls back an incomplete persistence transaction")
  func forcedTerminationRollback() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "otto-forced-termination-\(UUID().uuidString).sqlite")
    defer {
      try? FileManager.default.removeItem(at: path)
      try? FileManager.default.removeItem(atPath: path.path + "-wal")
      try? FileManager.default.removeItem(atPath: path.path + "-shm")
    }
    let store = SQLiteWorkspaceStore(path: path.path)
    let baseline = populatedWorkspace()
    try await store.save(baseline)

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = sqlite3Executable
    process.arguments = [path.path]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    input.fileHandleForWriting.write(
      Data(
        "BEGIN IMMEDIATE; DELETE FROM nodes; UPDATE workspace_snapshots SET payload=x'00'; .print READY\n"
          .utf8))
    input.fileHandleForWriting.closeFile()
    try await Task.sleep(for: .milliseconds(50))
    kill(process.processIdentifier, SIGKILL)
    let exitDeadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < exitDeadline, kill(process.processIdentifier, 0) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(kill(process.processIdentifier, 0) == -1)

    #expect(try await store.load() == baseline)
    #expect(try await store.normalizedCounts().nodes == 3)
    #expect(try await store.integrityCheck())
  }

  @Test("Tool registry persists successful and denied audit records")
  func durableAudit() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "otto-audit-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    let store = SQLiteWorkspaceStore(path: path.path)
    let registry = ToolRegistry(auditSink: store)
    try await registry.register(PersistenceEchoTool())

    _ = try await registry.call(
      name: "test.persistence_echo",
      input: .object(["text": .string("ok")]),
      context: ToolContext(actorID: "allowed", scopes: [.canvasRead]),
      requestID: "allowed-request"
    )
    await #expect(throws: ToolRegistryError.missingScopes([.canvasRead])) {
      try await registry.call(
        name: "test.persistence_echo",
        input: .object(["text": .string("blocked")]),
        context: ToolContext(actorID: "denied", scopes: []),
        requestID: "denied-request"
      )
    }

    let records = try await store.persistedAuditLog()
    #expect(records.map(\.requestID) == ["allowed-request", "denied-request"])
    #expect(records.map(\.succeeded) == [true, false])
  }
}

private struct PersistenceEchoInput: Codable, Sendable { let text: String }
private struct PersistenceEchoOutput: Codable, Sendable { let text: String }

private struct PersistenceEchoTool: OttoTool {
  static let definition = ToolDefinition(
    name: "test.persistence_echo",
    description: "Audit persistence fixture.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  func call(_ input: PersistenceEchoInput, context: ToolContext) async throws
    -> PersistenceEchoOutput
  {
    PersistenceEchoOutput(text: input.text)
  }
}

/// The sqlite3 CLI used to build legacy fixtures. Hosts without /usr/bin/sqlite3 (for example a
/// rootless Linux box) can point OTTO_TEST_SQLITE3 at another binary.
private let sqlite3Executable = URL(
  fileURLWithPath: ProcessInfo.processInfo.environment["OTTO_TEST_SQLITE3"] ?? "/usr/bin/sqlite3")

@Suite("Disk-full reporting")
struct SQLiteWorkspaceStoreDiskFullTests {
  #if os(macOS)
    // A tiny RAM disk is the only way to reach SQLITE_FULL honestly; faking the code would test
    // the switch statement rather than the behaviour that misled a real user.
    private func withTinyVolume(_ body: (URL) async throws -> Void) async throws {
      let sectors = 2048  // 1 MiB at 512 B/sector — large enough to open, too small to grow.
      let attach = Process()
      attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
      attach.arguments = ["attach", "-nomount", "ram://\(sectors)"]
      let out = Pipe()
      attach.standardOutput = out
      try attach.run()
      attach.waitUntilExit()
      let device = String(
        decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      guard attach.terminationStatus == 0, !device.isEmpty else {
        throw PersistenceTestSkip.ramDiskUnavailable
      }
      defer {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", "-force", device]
        try? detach.run()
        detach.waitUntilExit()
      }

      let mount = FileManager.default.temporaryDirectory
        .appending(path: "otto-full-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: mount) }

      let format = Process()
      format.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
      format.arguments = ["eraseVolume", "HFS+", "OttoFull", device]
      format.standardOutput = Pipe()
      format.standardError = Pipe()
      try format.run()
      format.waitUntilExit()
      guard format.terminationStatus == 0 else { throw PersistenceTestSkip.ramDiskUnavailable }

      try await body(URL(fileURLWithPath: "/Volumes/OttoFull"))
    }

    @Test("Reports a full volume as diskFull, not a database failure")
    func reportsDiskFull() async throws {
      try await withTinyVolume { volume in
        let store = SQLiteWorkspaceStore(
          path: volume.appending(path: "workspace.sqlite").path)

        // Fill the volume so SQLite cannot extend the database or its WAL.
        let ballast = volume.appending(path: "ballast")
        let chunk = Data(count: 64 * 1024)
        _ = FileManager.default.createFile(atPath: ballast.path, contents: Data())
        if let handle = try? FileHandle(forWritingTo: ballast) {
          while (try? handle.write(contentsOf: chunk)) != nil {}
          try? handle.close()
        }

        var caught: Error?
        do {
          try await store.migrate()
          let canvas = OttoCanvas(name: "Disk full", nodes: [])
          try await store.save(
            WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
        } catch {
          caught = error
        }

        let error = try #require(caught as? PersistenceError)
        guard case .diskFull(let available) = error else {
          Issue.record("expected .diskFull, got \(error)")
          return
        }
        // The message must point at the disk, never at the database.
        let described = try #require(error.errorDescription)
        #expect(described.contains("disk is full"))
        #expect(!described.contains("database operation failed"))
        if let available { #expect(available >= 0) }
      }
    }
  #endif

  @Test("Reads remaining volume capacity on this host")
  func readsAvailableCapacity() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-capacity-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let available = try #require(
      SQLiteWorkspaceStore.availableBytes(
        atPath: directory.appending(path: "workspace.sqlite").path))
    #expect(available >= 0)
  }
}

enum PersistenceTestSkip: Error { case ramDiskUnavailable }
