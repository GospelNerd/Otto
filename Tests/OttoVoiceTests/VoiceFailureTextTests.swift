import Foundation
import OttoRuntime
import OttoTools
import OttoVoice
import Testing

private struct PresentableSpeechError: LocalizedError {
  var errorDescription: String? { "Parakeet is still downloading. Try again in a minute." }
}

private struct PlumbingError: LocalizedError {
  var errorDescription: String? { "socket closed on file descriptor 12 (errno 32)" }
}

@Suite("Voice failure wording")
struct VoiceFailureTextTests {
  @Test("A closed agent transport is explained as the agent having stopped")
  func transportClosed() {
    let message = VoiceFailureText.message(for: RuntimeError.transportClosed)
    #expect(message == VoiceFailureText.transportClosedMessage)
    #expect(!message.lowercased().contains("transport"))
    #expect(message.hasSuffix("Try again."))
  }

  @Test("Runtime errors never surface their raw descriptions")
  func runtimeErrors() {
    #expect(
      VoiceFailureText.message(for: RuntimeError.agentNotFound(UUID()))
        == "That agent is no longer open.")
    #expect(
      VoiceFailureText.message(for: RuntimeError.invalidTransition(from: .working, to: .working))
        == "That agent is busy. Try again in a moment.")
    // A prompt refused because the process already ended is "stopped", not "busy".
    #expect(
      VoiceFailureText.message(for: RuntimeError.invalidTransition(from: .stopped, to: .working))
        == VoiceFailureText.transportClosedMessage)
    #expect(
      VoiceFailureText.message(for: RuntimeError.invalidTransition(from: .failed, to: .working))
        == VoiceFailureText.transportClosedMessage)
    #expect(
      VoiceFailureText.message(for: RuntimeError.launchFailed("spawn: ENOENT"))
        == "The agent could not start. Try again.")
    #expect(
      VoiceFailureText.message(for: RuntimeError.staleRun(UUID()))
        == VoiceFailureText.genericMessage)
    #expect(
      VoiceFailureText.message(for: RuntimeError.noPendingPermission(UUID()))
        == VoiceFailureText.genericMessage)
  }

  @Test("Tool-authored input messages pass through, registry plumbing does not")
  func registryErrors() {
    #expect(
      VoiceFailureText.message(for: ToolRegistryError.invalidInput("Focus an agent node first"))
        == "Focus an agent node first")
    #expect(
      VoiceFailureText.message(for: ToolRegistryError.confirmationRequired("node.close_all"))
        .contains("requires confirmation"))
    #expect(
      VoiceFailureText.message(for: ToolRegistryError.missingScopes([.agentControl]))
        == "Otto can't do that from voice.")
    #expect(
      VoiceFailureText.message(for: ToolRegistryError.unknownTool("agent.fly"))
        == "Otto can't do that from voice.")
  }

  @Test("Human-written descriptions pass through; plumbing falls back to generic wording")
  func localizedErrors() {
    #expect(
      VoiceFailureText.message(for: PresentableSpeechError())
        == "Parakeet is still downloading. Try again in a minute.")
    #expect(VoiceFailureText.message(for: PlumbingError()) == VoiceFailureText.genericMessage)
    #expect(VoiceFailureText.message(for: CancellationError()) == "Cancelled.")
  }

  @Test("Technical detail keeps the raw error beside the human wording")
  func technicalDetail() {
    let detail = VoiceFailureText.technicalDetail(for: RuntimeError.transportClosed)
    #expect(detail.hasPrefix(VoiceFailureText.transportClosedMessage))
    #expect(detail.contains("transportClosed"))
    #expect(detail.contains("The terminal transport is closed"))
  }
}
