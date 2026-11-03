#if !canImport(Combine)
  // Non-Apple platforms have no Combine. CanvasStore and CanvasCameraModel only use
  // ObservableObject/@Published so SwiftUI can observe them; headless Linux builds get
  // inert stand-ins with the same spelling so the shared sources compile unchanged.
  public protocol ObservableObject: AnyObject {}

  @propertyWrapper
  public struct Published<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
      self.wrappedValue = wrappedValue
    }
  }
#endif
