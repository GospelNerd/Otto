import Foundation
import OttoMemory
import Testing

#if canImport(CoreGraphics)
  import CoreGraphics
#endif

@Suite("Memory graph camera")
struct MemoryGraphCameraTests {
  private let viewport = CGSize(width: 750, height: 530)
  private let bounds = CGRect(x: -200, y: -100, width: 400, height: 300)

  @Test("Zoom keeps an off-center world point stationary after panning")
  func anchoredZoom() {
    var camera = MemoryGraphCamera()
    camera.panBy(CGSize(width: 75, height: -40))
    let world = CGPoint(x: 80, y: 30)
    let anchor = camera.screen(world, bounds: bounds, viewport: viewport)
    camera.zoom(by: 2.5, at: anchor, in: viewport)
    let after = camera.screen(world, bounds: bounds, viewport: viewport)
    #expect(abs(after.x - anchor.x) < 0.000001)
    #expect(abs(after.y - anchor.y) < 0.000001)
    #expect(camera.zoom == 2.5)
  }

  @Test("Repeated wheel input cannot drift at the zoom limits")
  func zoomLimits() {
    for factor: CGFloat in [0.001, 1000] {
      var camera = MemoryGraphCamera()
      let anchor = CGPoint(x: 100, y: 420)
      camera.zoom(by: factor, at: anchor, in: viewport)
      let clamped = camera
      for _ in 0..<100 { camera.zoom(by: factor, at: anchor, in: viewport) }
      #expect(camera == clamped)
      #expect(MemoryGraphCamera.zoomRange.contains(camera.zoom))
    }
  }

  @Test("Pan is measured in screen points at every zoom level")
  func panAtZoom() {
    for factor: CGFloat in [0.2, 1, 8] {
      var camera = MemoryGraphCamera()
      camera.zoom(by: factor, at: .zero, in: viewport)
      let before = camera.screen(.zero, bounds: bounds, viewport: viewport)
      camera.panBy(CGSize(width: -60, height: 125))
      let after = camera.screen(.zero, bounds: bounds, viewport: viewport)
      #expect(abs(after.x - before.x + 60) < 0.000001)
      #expect(abs(after.y - before.y - 125) < 0.000001)
    }
  }

  @Test("Invalid device input is ignored and tiny viewports remain finite")
  func invalidInput() {
    var camera = MemoryGraphCamera()
    camera.zoom(by: .nan, at: .zero, in: viewport)
    camera.zoom(by: -1, at: .zero, in: viewport)
    camera.panBy(CGSize(width: CGFloat.infinity, height: 0))
    #expect(camera == MemoryGraphCamera())
    let point = camera.screen(CGPoint(x: 10, y: 20), bounds: .zero, viewport: .zero)
    #expect(point.x.isFinite && point.y.isFinite)
    #expect(camera.scale(bounds: .zero, viewport: .zero) > 0)
  }
}
