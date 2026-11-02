import Foundation
import Testing

@testable import OttoVoice

/// Opt-in: pushes a real voice note through the same path Telegram uses (afconvert → plain PCM →
/// Parakeet). Set OTTO_VOICE_NOTE_FILE to an Ogg Opus (or any audio) file; needs Parakeet installed.
@Suite("Voice note live transcription")
struct AudioFileTranscriptionLiveTests {
  @Test(
    "A real Opus voice note transcribes on Parakeet",
    .enabled(if: ProcessInfo.processInfo.environment["OTTO_VOICE_NOTE_FILE"] != nil))
  func opusNoteTranscribes() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["OTTO_VOICE_NOTE_FILE"])
    try #require(ParakeetRuntimeConfiguration.installed() != nil, "Parakeet is not installed")
    let transcript = try await AudioFileTranscription.transcribe(
      URL(fileURLWithPath: path), preferring: [.parakeet])
    print("TRANSCRIPT: \(transcript)")
    #expect(!transcript.isEmpty)
    if let expected = ProcessInfo.processInfo.environment["OTTO_VOICE_NOTE_EXPECT"] {
      #expect(transcript.lowercased().contains(expected.lowercased()))
    }
  }
}
