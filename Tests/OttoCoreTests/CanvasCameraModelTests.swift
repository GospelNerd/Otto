import Foundation
import OttoCore
import OttoModels
import OttoPersistence
import Testing

#if canImport(Combine)
  import Combine
#endif

@MainActor
@Suite("Canvas camera presentation")
struct CanvasCameraModelTests {
  // objectWillChange publishers come from Combine; without it the stand-ins publish nothing.
  #if canImport(Combine)
    @Test("Live pan and zoom never republish durable workspace state")
    func liveGestureIsolation() {
      let canvas = OttoCanvas(name: "Camera")
      let store = CanvasStore(
        snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)
      )
      let camera = CanvasCameraModel(canvasID: canvas.id, viewport: canvas.viewport)
      var workspacePublications = 0
      var cameraPublications = 0
      let workspaceObservation = store.objectWillChange.sink { workspacePublications += 1 }
      let cameraObservation = camera.objectWillChange.sink { cameraPublications += 1 }

      for step in 1...120 {
        camera.updatePan(x: Double(step), y: Double(-step))
        camera.updateZoom(magnification: 1 + Double(step) / 1_000)
      }

      #expect(workspacePublications == 0)
      #expect(cameraPublications > 0)
      #expect(store.activeCanvas == canvas)

      let settled = camera.endPan(x: 120, y: -120)
      store.dispatch(.setViewport(settled))
      #expect(workspacePublications > 0)
      #expect(store.activeCanvas.viewport == settled)

      withExtendedLifetime((workspaceObservation, cameraObservation)) {}
    }
  #endif

  @Test("Camera switches canvases and accepts external settled viewport changes")
  func synchronization() {
    let firstID = UUID()
    let secondID = UUID()
    let camera = CanvasCameraModel(
      canvasID: firstID,
      viewport: Viewport(centerX: 10, centerY: 20, scale: 1.2)
    )
    camera.updatePan(x: 80, y: 30)

    let secondViewport = Viewport(centerX: -400, centerY: 90, scale: 0.7)
    camera.synchronize(canvasID: secondID, viewport: secondViewport)
    #expect(camera.canvasID == secondID)
    #expect(
      camera.presentation == CanvasCameraModel.Presentation(viewport: secondViewport)
    )
    #expect(!camera.isInteracting)

    let toolViewport = Viewport(centerX: 55, centerY: -12, scale: 1.8)
    camera.synchronize(canvasID: secondID, viewport: toolViewport)
    #expect(camera.presentation.viewport == toolViewport)
  }

  @Test("Twenty repeated gesture settlements never retain stale camera transforms")
  func repeatedSettlement() {
    let canvasID = UUID()
    let camera = CanvasCameraModel(canvasID: canvasID)

    for step in 1...20 {
      let pan = camera.endPan(x: Double(step * 3), y: Double(step * -2))
      camera.synchronize(canvasID: canvasID, viewport: pan)
      let zoom = camera.endZoom(magnification: step.isMultiple(of: 2) ? 1.01 : 0.99)
      camera.synchronize(canvasID: canvasID, viewport: zoom)

      #expect(camera.presentation.panX == 0)
      #expect(camera.presentation.panY == 0)
      #expect(camera.presentation.magnification == 1)
      #expect(camera.presentation.viewport == zoom)
      #expect(!camera.isInteracting)
    }
  }

  @Test("A settled camera viewport persists and restores")
  func persistenceRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-camera-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = SQLiteWorkspaceStore(path: directory.appending(path: "workspace.sqlite").path)
    try await database.migrate()
    let canvas = OttoCanvas(name: "Persisted camera")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id),
      persistence: database,
      persistCoalesceWindow: .zero
    )
    let camera = CanvasCameraModel(canvasID: canvas.id, viewport: canvas.viewport)
    camera.updatePan(x: 240, y: -120)
    let settled = camera.endPan(x: 240, y: -120)
    store.dispatch(.setViewport(settled))
    await store.flushPersistence()

    let restored = CanvasStore(persistence: database)
    await restored.restore()
    #expect(restored.activeCanvas.id == canvas.id)
    #expect(restored.activeCanvas.viewport == settled)
  }

  @Test("An explicit flush interrupts coalescing and saves the latest node immediately")
  func explicitFlushInterruptsCoalescing() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-flush-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = SQLiteWorkspaceStore(path: directory.appending(path: "workspace.sqlite").path)
    try await database.migrate()
    let canvas = OttoCanvas(name: "Flush")
    let snapshot = WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)
    try await database.save(snapshot)
    let store = CanvasStore(
      snapshot: snapshot,
      persistence: database,
      persistCoalesceWindow: .seconds(30)
    )

    store.dispatch(.renameCanvas("First save starts the coalescing window"))
    try await Task.sleep(for: .milliseconds(50))
    let node = store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 10, y: 20)))
    let nodeID = try #require(node.affectedNodeIDs.first)

    let clock = ContinuousClock()
    let startedAt = clock.now
    await store.flushPersistence()
    #expect(startedAt.duration(to: clock.now) < .seconds(1))

    let restored = try #require(try await database.loadForRestoration())
    #expect(restored.canvases.flatMap(\.nodes).contains { $0.id == nodeID })
  }
}
