import Foundation
import OttoCore
import OttoModels
import OttoPersistence
import Testing

@MainActor
@Suite("Persistence notice lifecycle")
struct PersistenceNoticeTests {
  /// A directory the store may read but not write, so saving fails the way a full or
  /// read-only volume does, without needing either.
  private func unwritableDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-notice-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try setWritable(false, directory)
    return directory
  }

  private func setWritable(_ writable: Bool, _ directory: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: writable ? 0o755 : 0o500], ofItemAtPath: directory.path)
  }

  private func cleanUp(_ directory: URL) {
    try? setWritable(true, directory)
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeStore(at directory: URL) -> CanvasStore {
    let canvas = OttoCanvas(name: "Notice", nodes: [])
    return CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id),
      persistence: SQLiteWorkspaceStore(
        path: directory.appending(path: "workspace.sqlite").path),
      persistCoalesceWindow: .milliseconds(1)
    )
  }

  private func touch(_ store: CanvasStore) {
    store.updateChatNavigation(ChatSurfaceNavigationState(selectedProfileID: UUID()))
  }

  @Test("Dismissing clears the notice rather than latching it for the session")
  func dismissClearsNotice() async throws {
    let directory = try unwritableDirectory()
    defer { cleanUp(directory) }

    let store = makeStore(at: directory)
    touch(store)
    await store.flushPersistence()
    #expect(store.persistenceError != nil)

    store.dismissPersistenceError()
    #expect(store.persistenceError == nil)
  }

  @Test("A completed save clears a notice raised by an earlier failure")
  func completedSaveClearsStaleNotice() async throws {
    let directory = try unwritableDirectory()
    defer { cleanUp(directory) }

    let store = makeStore(at: directory)
    touch(store)
    await store.flushPersistence()
    #expect(store.persistenceError != nil)

    // The condition goes away, as a freed-up disk does. The warning must go away with it.
    try setWritable(true, directory)
    touch(store)
    await store.flushPersistence()
    #expect(store.persistenceError == nil)
  }
}
