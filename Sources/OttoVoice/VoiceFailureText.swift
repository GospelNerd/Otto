import Foundation
import OttoModels
import OttoTools

/// Wording for voice failures that people see — the Voice row in the Chat sidebar, the voice
/// trace, and what the realtime model is told when a tool call fails.
///
/// Runtime and transport errors describe the plumbing ("The terminal transport is closed")
/// and never explain what the person should do next. They are kept verbatim in the technical
/// detail for logs and never shown directly.
public enum VoiceFailureText {
  public static let genericMessage = "Voice action failed. Try again."
  public static let transportClosedMessage = "That agent had already stopped. Try again."

  /// One short sentence a person can act on.
  public static func message(for error: any Error) -> String {
    if error is CancellationError { return "Cancelled." }
    switch error.ottoFailureKind {
    case .agentTransportClosed?, .agentStopped?: return transportClosedMessage
    case .agentNotFound?: return "That agent is no longer open."
    case .agentBusy?: return "That agent is busy. Try again in a moment."
    case .agentLaunchFailed?: return "The agent could not start. Try again."
    case nil: break
    }
    // Other runtime errors describe process plumbing; nothing there helps the person.
    if error is any OttoFailureClassifying { return genericMessage }
    if let registryError = error as? ToolRegistryError {
      switch registryError {
      case .invalidInput(let message):
        // Authored for people by the tool itself ("Focus an agent node first…").
        return message
      case .confirmationRequired:
        return "That action requires confirmation first."
      case .missingScopes, .interactionDenied, .unknownTool, .duplicateTool:
        return "Otto can't do that from voice."
      }
    }
    if let message = (error as? any LocalizedError)?.errorDescription, isPresentable(message) {
      return message
    }
    return genericMessage
  }

  /// The human message plus the raw error, for traces and logs.
  public static func technicalDetail(for error: any Error) -> String {
    let raw = String(reflecting: error)
    let described = error.localizedDescription
    let detail = described.isEmpty || raw.contains(described) ? raw : "\(raw) — \(described)"
    return "\(message(for: error)) [\(detail)]"
  }

  /// Error descriptions written for people in this package (speech engines, providers,
  /// installers) pass through; descriptions that leak transport or protocol plumbing do not.
  private static func isPresentable(_ message: String) -> Bool {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 140 else { return false }
    let lowered = trimmed.lowercased()
    let plumbing = ["transport", "pty", "socket", "file descriptor", "errno", "nserror", "0x"]
    return !plumbing.contains(where: lowered.contains)
  }
}
