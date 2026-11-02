import Foundation
import OttoVoice
import Testing

@Suite("Speech engine failure summaries")
struct TranscriptionDiagnosticsTests {
  @Test("The configuration dump is dropped and the final error line is kept")
  func configDumpThenError() {
    let stderr = AudioFileTranscriptionTests.sherpaConfigDump + "\nErrors in config!\n"
    #expect(AudioFileTranscriptionTests.sherpaConfigDump.count > 600)
    #expect(TranscriptionDiagnostics.summary(of: stderr) == "Errors in config!")
    #expect(
      ParakeetRuntimeError.failed(255, stderr).errorDescription
        == "Parakeet exited with status 255: Errors in config!")
    #expect(
      WhistleRuntimeError.failed(1, stderr).errorDescription
        == "Whistle exited with status 1: Errors in config!")
  }

  @Test("A dump cut mid-line, as the stderr tail is, still yields only the error")
  func truncatedDumpTail() {
    let tail = String(AudioFileTranscriptionTests.sherpaConfigDump.suffix(900))
    #expect(tail.hasPrefix("ice=") || tail.contains("Config("))
    #expect(
      TranscriptionDiagnostics.summary(of: tail + "\nErrors in config!") == "Errors in config!")
  }

  @Test("An unreadable clip names its cause and the file, not the whole temporary path")
  func unreadableWave() {
    let stderr =
      AudioFileTranscriptionTests.sherpaConfigDump + "\n"
      + "Creating recognizer ...\nrecognizer created in 1.234 s\nStarted\n"
      + "/Users/runner/work/sherpa-onnx/sherpa-onnx/sherpa-onnx/csrc/wave-reader.cc:ReadWave:123 "
      + "Expected subchunk1_size 16. Given: 40\n"
      + "Failed to read '/private/var/folders/ab/T/otto-audio-1234/clip.wav'\n"
    #expect(
      TranscriptionDiagnostics.summary(of: stderr)
        == "Expected subchunk1_size 16. Given: 40; Failed to read 'clip.wav'")
  }

  @Test("The summary is capped and empty output gives a bare status")
  func capAndEmpty() {
    let long = String(repeating: "x", count: 500)
    let summary = TranscriptionDiagnostics.summary(of: long)
    #expect(summary.count == 200)
    #expect(summary.hasSuffix("…"))
    #expect(TranscriptionDiagnostics.summary(of: "") == "")
    #expect(TranscriptionDiagnostics.summary(of: "\n  \nStarted\n") == "")
    #expect(
      ParakeetRuntimeError.failed(255, "").errorDescription == "Parakeet exited with status 255")
  }
}
