import Foundation
import OttoCore
import OttoModels
import OttoPersistence
import Testing

#if canImport(SQLite3)
  import SQLite3
#else
  import CSQLite
#endif

/// On 19 Oct 2026 Otto Dev saved a Chat destination the release build did not know. The release
/// build could not decode the snapshot, started from the empty starter workspace, and its next
/// save replaced every canvas and session.
@Suite("Workspace decode safety")
@MainActor
struct WorkspaceDecodeSafetyTests {
  @Test("A fresh profile starts empty and stays empty after reopening")
  func freshProfileStartsEmpty() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-fresh-profile-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = SQLiteWorkspaceStore(path: directory.appending(path: "workspace.sqlite").path)
    let store = CanvasStore(persistence: persistence)

    #expect(store.snapshot.canvases.count == 1)
    #expect(store.activeCanvas.nodes.isEmpty)
    await store.restore()
    #expect(!store.isAwaitingRestore)
    #expect(store.persistenceError == nil)
    #expect(store.activeCanvas.nodes.isEmpty)
    let saved = try #require(try await persistence.load())
    #expect(saved == store.snapshot)

    let reopened = CanvasStore(persistence: persistence)
    await reopened.restore()
    #expect(reopened.snapshot == saved)
    #expect(reopened.activeCanvas.nodes.isEmpty)
  }

  @Test("Navigation values from a newer Otto fall back instead of failing the workspace")
  func unknownNavigationValues() throws {
    var snapshot = WorkspaceSnapshot.starter
    snapshot.chatNavigation.destination = .documents
    var json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    var navigation = try #require(json["chatNavigation"] as? [String: Any])
    navigation["destination"] = "Somewhere New"
    navigation["sidebarList"] = "newList"
    json["chatNavigation"] = navigation
    json["workspaceSurface"] = "hologram"

    let decoded = try JSONDecoder().decode(
      WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: json))

    #expect(decoded.canvases == snapshot.canvases)
    #expect(decoded.workspaceSurface == .chat)
    #expect(decoded.chatNavigation.destination == .conversation)
    #expect(decoded.chatNavigation.sidebarList == .sessions)
    #expect(decoded.chatNavigation.selectedSessionID == snapshot.chatNavigation.selectedSessionID)
  }

  @Test("An unreadable workspace is copied aside and never overwritten")
  func unreadableWorkspaceIsNotOverwritten() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databasePath = directory.appending(path: "workspace.sqlite").path

    let persistence = SQLiteWorkspaceStore(path: databasePath)
    try await persistence.save(.starter)
    let unreadable = Data(#"{"canvases":"written by a future Otto"}"#.utf8)
    try overwritePayload(at: databasePath, with: unreadable)

    let store = CanvasStore(persistence: persistence, persistCoalesceWindow: .zero)
    await store.restore()
    #expect(store.persistenceWritesBlocked)
    #expect(store.persistenceError?.contains("left untouched") == true)

    store.dispatch(.createCanvas(name: "Should not be saved"))
    await store.flushPersistence()

    #expect(try readPayload(at: databasePath) == unreadable)
    let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("workspace-unreadable-") }
    #expect(backups.count == 1)
    let backup = try Data(contentsOf: directory.appending(path: try #require(backups.first)))
    #expect(backup == unreadable)
  }

  /// The first Otto launch after a Muse 0.1.59 update quits within a second to rename
  /// Muse.app to Otto.app. That quit flushed the starter placeholder over the migrated workspace
  /// because the window had already changed navigation before `restore()` ran.
  @Test("Quitting before the first restore never replaces the saved workspace")
  func quitBeforeRestoreKeepsSavedWorkspace() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = SQLiteWorkspaceStore(path: directory.appending(path: "workspace.sqlite").path)
    let saved = OttoCanvas(name: "Saved sessions")
    try await persistence.save(WorkspaceSnapshot(canvases: [saved], activeCanvasID: saved.id))
    let savedPayload = try readPayload(at: directory.appending(path: "workspace.sqlite").path)

    let early = CanvasStore(persistence: persistence, persistCoalesceWindow: .zero)
    #expect(early.isAwaitingRestore)
    var navigation = early.snapshot.chatNavigation
    navigation.sidebarList = .bots
    early.updateChatNavigation(navigation)
    early.dispatch(.createCanvas(name: "Starter edit"))
    await early.flushPersistence()
    #expect(try readPayload(at: directory.appending(path: "workspace.sqlite").path) == savedPayload)

    let relaunched = CanvasStore(persistence: persistence, persistCoalesceWindow: .zero)
    await relaunched.restore()
    #expect(!relaunched.isAwaitingRestore)
    #expect(relaunched.snapshot.canvases.map(\.name) == ["Saved sessions"])
    relaunched.dispatch(.createCanvas(name: "After restore"))
    await relaunched.flushPersistence()
    let reread = CanvasStore(persistence: persistence)
    await reread.restore()
    #expect(reread.snapshot.canvases.map(\.name) == ["Saved sessions", "After restore"])
  }

  @Test("A store given an explicit workspace saves without a restore")
  func explicitSnapshotSavesImmediately() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = SQLiteWorkspaceStore(path: directory.appending(path: "workspace.sqlite").path)
    let canvas = OttoCanvas(name: "Explicit")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id),
      persistence: persistence, persistCoalesceWindow: .zero)
    #expect(!store.isAwaitingRestore)
    store.dispatch(.createCanvas(name: "Second"))
    await store.flushPersistence()
    let reread = CanvasStore(persistence: persistence)
    await reread.restore()
    #expect(reread.snapshot.canvases.map(\.name) == ["Explicit", "Second"])
  }

  private func overwritePayload(at path: String, with payload: Data) throws {
    var database: OpaquePointer?
    #expect(sqlite3_open(path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    #expect(
      sqlite3_prepare_v2(
        database, "UPDATE workspace_snapshots SET payload = ? WHERE id = 1", -1, &statement, nil)
        == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    _ = payload.withUnsafeBytes { buffer in
      sqlite3_bind_blob(
        statement, 1, buffer.baseAddress, Int32(buffer.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    #expect(sqlite3_step(statement) == SQLITE_DONE)
  }

  private func readPayload(at path: String) throws -> Data? {
    var database: OpaquePointer?
    #expect(sqlite3_open(path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    #expect(
      sqlite3_prepare_v2(
        database, "SELECT payload FROM workspace_snapshots WHERE id = 1", -1, &statement, nil)
        == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0)
    else { return nil }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
  }
}
