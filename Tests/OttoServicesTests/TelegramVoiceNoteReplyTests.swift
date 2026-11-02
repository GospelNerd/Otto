import Foundation
import Testing

@testable import OttoServices

@Suite("Telegram voice note failure replies")
struct TelegramVoiceNoteReplyTests {
  private struct Described: LocalizedError {
    var errorDescription: String?
  }

  private struct Bare: Error {}

  @Test("The reply is one sentence with the engine's reason in brackets")
  func shortReason() {
    let error = Described(
      errorDescription: "Parakeet exited with status 255: Failed to read 'clip.wav'")
    #expect(
      TelegramConnector.voiceNoteFailureReply(for: error)
        == "Couldn't transcribe that voice note (Parakeet exited with status 255: "
        + "Failed to read 'clip.wav'). Send text instead.")
  }

  @Test("A reason longer than 200 characters is cut, and newlines are flattened")
  func longReason() {
    let dump =
      "Parakeet exited with status 255: " + String(repeating: "OfflineConfig(x=1), ", count: 60)
    let reply = TelegramConnector.voiceNoteFailureReply(for: Described(errorDescription: dump))
    #expect(
      reply.hasPrefix("Couldn't transcribe that voice note (Parakeet exited with status 255: "))
    #expect(reply.hasSuffix("…). Send text instead."))
    #expect(reply.count <= "Couldn't transcribe that voice note (). Send text instead.".count + 200)

    let multiline = Described(errorDescription: "No speech was found.\n\nTry again.")
    #expect(
      TelegramConnector.voiceNoteFailureReply(for: multiline)
        == "Couldn't transcribe that voice note (No speech was found. Try again). Send text instead."
    )
  }

  @Test("An error with no description still gets a plain sentence")
  func noDescription() {
    #expect(
      TelegramConnector.voiceNoteFailureReply(for: Bare())
        == "Couldn't transcribe that voice note. Send text instead.")
    #expect(
      TelegramConnector.voiceNoteFailureReply(for: Described(errorDescription: "..."))
        == "Couldn't transcribe that voice note. Send text instead.")
  }
}
