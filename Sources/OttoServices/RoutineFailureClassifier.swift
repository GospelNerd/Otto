import Foundation
import OttoRuntime

/// Decides whether a failed automation run is worth one automatic retry. Only failures that look
/// like a passing condition (network, timeout, rate limit, an overloaded provider, a dropped
/// transport) qualify. Anything that was denied, needed approval, failed validation or
/// authentication is never retried: running it again would fail the same way or, worse, act
/// without the person's say-so.
public enum RoutineFailureClassifier {
  public enum Verdict: Equatable, Sendable {
    case transient
    case permanent
  }

  /// Checked first: any of these makes the failure permanent even if it also mentions a timeout.
  static let permanentMarkers = [
    "denied", "not allowed", "approval", "approve", "permission", "forbidden", "unauthorized",
    "unauthorised", "authentication", "not signed in", "sign in", "api key", "invalid",
    "validation",
    "not found", "unsupported", "quota exceeded", "insufficient_quota", "insufficient quota",
    "billing", "credit balance", "cancelled by", "canceled by", "stopped by", "rejected",
    "session closed",
  ]

  static let transientMarkers = [
    "timed out", "timeout", "time out", "network", "connection reset", "connection refused",
    "connection was lost", "connection lost", "connection closed", "not connected to the internet",
    "internet connection", "could not connect", "couldn’t connect", "couldn't connect",
    "rate limit", "rate-limit", "ratelimit", "rate_limit", "too many requests", "429",
    "overloaded", "529", "503", "502", "504", "service unavailable", "bad gateway",
    "gateway timeout", "temporarily unavailable", "try again later", "server error",
    "transport is closed", "transportclosed", "transport closed", "econnreset", "etimedout",
    "socket hang up", "dns", "offline",
  ]

  public static func classify(_ message: String?) -> Verdict {
    guard let message, !message.isEmpty else { return .permanent }
    let text = message.lowercased()
    if permanentMarkers.contains(where: text.contains) { return .permanent }
    return transientMarkers.contains(where: text.contains) ? .transient : .permanent
  }

  public static func classify(_ error: any Error) -> Verdict {
    if let runtime = error as? RuntimeError, case .transportClosed = runtime { return .transient }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
        return .transient
      default: return .permanent
      }
    }
    if error is RoutineStoreError { return .permanent }
    return classify("\(error.localizedDescription) \(String(describing: error))")
  }
}
