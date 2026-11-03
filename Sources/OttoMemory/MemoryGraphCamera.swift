import Foundation

// On Linux, swift-corelibs-foundation provides CGFloat, CGPoint, CGSize and CGRect.
#if canImport(CoreGraphics)
  import CoreGraphics
#endif

/// Transient graph camera. Zoom preserves the world point under the pointer, including at limits.
public struct MemoryGraphCamera: Equatable, Sendable {
  public static let zoomRange: ClosedRange<CGFloat> = 0.2...8
  public private(set) var zoom: CGFloat = 1
  public var pan: CGSize = .zero

  public init() {}

  public mutating func panBy(_ delta: CGSize) {
    guard delta.width.isFinite, delta.height.isFinite else { return }
    pan.width += delta.width
    pan.height += delta.height
  }

  public mutating func zoom(by factor: CGFloat, at anchor: CGPoint, in viewport: CGSize) {
    guard factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite,
      viewport.width.isFinite, viewport.height.isFinite
    else { return }
    let next = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
    let ratio = next / zoom
    let x = anchor.x - viewport.width / 2
    let y = anchor.y - viewport.height / 2
    pan = CGSize(width: x - (x - pan.width) * ratio, height: y - (y - pan.height) * ratio)
    zoom = next
  }

  public func scale(bounds: CGRect, viewport: CGSize) -> CGFloat {
    max(
      0.01,
      min(
        max(1, viewport.width - 110) / max(1, bounds.width),
        max(1, viewport.height - 90) / max(1, bounds.height))) * zoom
  }

  public func screen(_ point: CGPoint, bounds: CGRect, viewport: CGSize) -> CGPoint {
    let factor = scale(bounds: bounds, viewport: viewport)
    return CGPoint(
      x: viewport.width / 2 + (point.x - bounds.midX) * factor + pan.width,
      y: viewport.height / 2 + (point.y - bounds.midY) * factor + pan.height)
  }
}
