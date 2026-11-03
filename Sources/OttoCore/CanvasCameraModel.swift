import Foundation
import OttoModels

#if canImport(Combine)
  import Combine
#endif

/// Owns high-frequency camera presentation independently from the durable workspace snapshot.
/// Gesture updates publish only this small value; callers persist the returned viewport once when
/// the gesture settles.
@MainActor
public final class CanvasCameraModel: ObservableObject {
  public struct Presentation: Equatable, Sendable {
    public var viewport: Viewport
    public var panX: Double
    public var panY: Double
    public var magnification: Double

    public init(
      viewport: Viewport = Viewport(),
      panX: Double = 0,
      panY: Double = 0,
      magnification: Double = 1
    ) {
      self.viewport = viewport
      self.panX = panX
      self.panY = panY
      self.magnification = magnification
    }
  }

  @Published public private(set) var presentation: Presentation
  public private(set) var canvasID: UUID?
  public private(set) var isInteracting = false

  public init(canvasID: UUID? = nil, viewport: Viewport = Viewport()) {
    self.canvasID = canvasID
    self.presentation = Presentation(viewport: viewport)
  }

  /// Reconciles durable state after restoration, tool-driven camera changes, or a canvas switch.
  /// Same-canvas persistence echoes are ignored while a gesture is live so the camera cannot jump.
  public func synchronize(canvasID: UUID, viewport: Viewport) {
    if self.canvasID != canvasID {
      self.canvasID = canvasID
      isInteracting = false
      presentation = Presentation(viewport: viewport)
      return
    }
    guard !isInteracting, presentation.viewport != viewport else { return }
    presentation = Presentation(viewport: viewport)
  }

  public func updatePan(x: Double, y: Double) {
    isInteracting = true
    presentation.panX = x
    presentation.panY = y
  }

  /// Returns the one durable viewport value that should be committed after a pan settles.
  @discardableResult
  public func endPan(x: Double, y: Double) -> Viewport {
    let base = presentation.viewport
    let viewport = Viewport(
      centerX: base.centerX - x / base.scale,
      centerY: base.centerY - y / base.scale,
      scale: base.scale
    )
    settle(on: viewport)
    return viewport
  }

  public func updateZoom(magnification: Double) {
    isInteracting = true
    presentation.magnification = max(0.01, magnification)
  }

  /// Returns the one durable viewport value that should be committed after a zoom settles.
  @discardableResult
  public func endZoom(magnification: Double) -> Viewport {
    let base = presentation.viewport
    let viewport = Viewport(
      centerX: base.centerX,
      centerY: base.centerY,
      scale: base.scale * max(0.01, magnification)
    )
    settle(on: viewport)
    return viewport
  }

  public func cancelInteraction() {
    isInteracting = false
    presentation = Presentation(viewport: presentation.viewport)
  }

  private func settle(on viewport: Viewport) {
    isInteracting = false
    presentation = Presentation(viewport: viewport)
  }
}
