import Foundation

/// A stable, module-independent meaning for errors that cross package boundaries.
///
/// Runtime errors are declared in OttoRuntime, but callers such as the voice stack only depend
/// on the lower layers. Matching on the error's description string would be brittle; carrying
/// a classification lets those callers recognise the handful of outcomes they must recover
/// from or reword without importing the throwing module.
public enum OttoFailureKind: Sendable, Equatable {
  /// The agent's terminal transport had already closed when the write happened. One-shot
  /// provider CLIs close their PTY just before their exit event arrives, so this usually means
  /// the agent finished, not that the caller failed.
  case agentTransportClosed
  case agentNotFound
  /// The agent cannot accept that control right now (for example a prompt while it is working).
  case agentBusy
  /// The agent's process has already ended (stopped or failed) and cannot take that control.
  case agentStopped
  case agentLaunchFailed
}

public protocol OttoFailureClassifying: Error {
  var failureKind: OttoFailureKind? { get }
}

extension Error {
  /// The cross-module classification for this error, when the throwing module provided one.
  public var ottoFailureKind: OttoFailureKind? {
    (self as? any OttoFailureClassifying)?.failureKind
  }
}
