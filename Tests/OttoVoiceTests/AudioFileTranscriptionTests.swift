import AVFoundation
import Foundation
import Testing

@testable import OttoVoice

@Suite("Recorded audio transcription")
struct AudioFileTranscriptionTests {
  @Test("An empty or unreadable recording is reported before any engine runs")
  func unreadableRecording() async throws {
    let directory = try Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let empty = directory.appending(path: "empty.oga")
    try Data().write(to: empty)
    await #expect(throws: AudioFileTranscriptionError.self) {
      _ = try await AudioFileTranscription.transcribe(empty, preferring: [.whistle])
    }
    let garbage = directory.appending(path: "garbage.oga")
    try Data("not audio".utf8).write(to: garbage)
    await #expect(throws: AudioFileTranscriptionError.self) {
      _ = try await AudioFileTranscription.transcribe(garbage, preferring: [.whistle])
    }
  }

  @Test("Engines are tried in preference order and Apple's on-device speech comes last")
  func engineOrder() {
    #expect(AudioFileTranscription.engineOrder(preferring: []) == [.whistle, .parakeet, .apple])
    #expect(
      AudioFileTranscription.engineOrder(preferring: [.parakeet]) == [.parakeet, .whistle, .apple])
    #expect(
      AudioFileTranscription.engineOrder(preferring: [.apple]) == [.apple, .whistle, .parakeet])
  }

  @Test("A failing engine does not stop the next one, and the last resort can still answer")
  func fallsBackAfterEngineFailure() async throws {
    let directory = try Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tone = directory.appending(path: "tone.wav")
    try Self.writeTone(to: tone)
    let tried = EngineLog()
    let text = try await AudioFileTranscription.transcribe(
      tone, preferring: [.parakeet], timeout: .seconds(60)
    ) { _, engine in
      tried.record(engine)
      switch engine {
      case .parakeet:
        throw ParakeetRuntimeError.failed(255, Self.sherpaConfigDump + "\nErrors in config!")
      case .whistle: return nil  // Not installed.
      case .apple: return "hello there"
      }
    }
    #expect(text == "hello there")
    #expect(tried.engines == [.parakeet, .whistle, .apple])
  }

  @Test("When no engine succeeds the failing engine's shaped reason is thrown")
  func throwsShapedReasonWhenAllFail() async throws {
    let directory = try Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tone = directory.appending(path: "tone.wav")
    try Self.writeTone(to: tone)
    do {
      _ = try await AudioFileTranscription.transcribe(
        tone, preferring: [.parakeet], timeout: .seconds(60)
      ) { _, engine in
        switch engine {
        case .parakeet:
          throw ParakeetRuntimeError.failed(255, Self.sherpaConfigDump + "\nErrors in config!")
        case .whistle, .apple: return nil
        }
      }
      Issue.record("expected the Parakeet failure to be thrown")
    } catch let error as ParakeetRuntimeError {
      #expect(error.errorDescription == "Parakeet exited with status 255: Errors in config!")
    }
  }

  @Test("A source with a channel layout still converts to the plain PCM WAVE sherpa-onnx reads")
  func convertedClipIsPlainPCM() async throws {
    let directory = try Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tone = directory.appending(path: "tone.wav")
    try Self.writeTone(to: tone)
    // Telegram's Ogg Opus carries a channel layout; a CAF with one makes afconvert write the
    // same WAVE_FORMAT_EXTENSIBLE header, so the regression is reproduced without Opus tooling.
    let note = directory.appending(path: "note.caf")
    let encoded = try await LocalProcess.run(
      URL(filePath: "/usr/bin/afconvert"),
      ["-f", "caff", "-d", "LEI16@16000", "-c", "1", "-l", "Mono", tone.path, note.path],
      timeout: .seconds(60))
    try #require(encoded.status == 0)

    let clip = directory.appending(path: "clip.wav")
    try await AudioFileTranscription.convert(note, to: clip)
    let bytes = [UInt8](try Data(contentsOf: clip))
    try #require(bytes.count > 44)
    #expect(String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: bytes[12..<16], as: UTF8.self) == "fmt ")
    #expect(Self.u32(bytes, 16) == 16, "fmt chunk must be the 16-byte PCM form")
    #expect(Self.u16(bytes, 20) == 1, "audio format must be integer PCM, not 0xFFFE")
    #expect(Self.u16(bytes, 22) == 1)
    #expect(Self.u32(bytes, 24) == 16_000)
    #expect(Self.u16(bytes, 34) == 16)
    #expect(String(decoding: bytes[36..<40], as: UTF8.self) == "data", "no FLLR before data")
    #expect(Self.u32(bytes, 40) == 16_000 * 2)
    #expect(bytes.count == 44 + 16_000 * 2)
  }

  @Test("An extensible WAVE header is rewritten as plain PCM with the samples untouched")
  func extensibleHeaderIsRewritten() throws {
    let samples: [UInt8] = [0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0x10, 0x20]
    var extensible: [UInt8] = []
    extensible += Array("RIFF".utf8) + Self.le32(0) + Array("WAVE".utf8)
    extensible += Array("fmt ".utf8) + Self.le32(40)
    extensible += [0xFE, 0xFF] + [0x01, 0x00] + Self.le32(16_000) + Self.le32(32_000)
    extensible += [0x02, 0x00] + [0x10, 0x00] + [0x16, 0x00] + [0x10, 0x00] + Self.le32(4)
    extensible += [
      0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B,
      0x71,
    ]
    extensible += Array("FLLR".utf8) + Self.le32(10) + [UInt8](repeating: 0, count: 10)
    extensible += Array("data".utf8) + Self.le32(samples.count) + samples

    let plain = try #require(PCMWaveFile.plainPCM(Data(extensible)))
    let bytes = [UInt8](plain)
    #expect(bytes.count == 44 + samples.count)
    #expect(Self.u32(bytes, 4) == 36 + samples.count)
    #expect(Self.u32(bytes, 16) == 16)
    #expect(Self.u16(bytes, 20) == 1)
    #expect(Self.u16(bytes, 22) == 1)
    #expect(Self.u32(bytes, 24) == 16_000)
    #expect(Self.u32(bytes, 28) == 32_000)
    #expect(Self.u16(bytes, 32) == 2)
    #expect(Self.u16(bytes, 34) == 16)
    #expect(String(decoding: bytes[36..<40], as: UTF8.self) == "data")
    #expect(Array(bytes[44...]) == samples)

    // Already plain: left alone. Float or unknown formats: left alone too.
    #expect(PCMWaveFile.plainPCM(plain) == nil)
    var float = bytes
    float[20] = 3
    #expect(PCMWaveFile.plainPCM(Data(float)) == nil)
    #expect(PCMWaveFile.plainPCM(Data("not a wave".utf8)) == nil)
  }

  // MARK: - Helpers

  /// A sherpa-onnx style configuration dump: one very long line of nested `Config(...)` fields.
  static let sherpaConfigDump: String = {
    let tokens = "/Users/dhruvtayal/Library/Application Support/Otto/VoiceModels/Parakeet/model"
    return "OfflineRecognizerConfig(feat_config=FeatureExtractorConfig(sampling_rate=16000, "
      + "feature_dim=80, low_freq=20, high_freq=-400, dither=0, normalize_samples=True, "
      + "snip_edges=False), model_config=OfflineModelConfig(transducer="
      + "OfflineTransducerModelConfig(encoder_filename=\"\(tokens)/encoder.int8.onnx\", "
      + "decoder_filename=\"\(tokens)/decoder.int8.onnx\", "
      + "joiner_filename=\"\(tokens)/joiner.int8.onnx\"), paraformer=OfflineParaformerModelConfig("
      + "model=\"\"), nemo_ctc=OfflineNemoEncDecCtcModelConfig(model=\"\"), whisper="
      + "OfflineWhisperModelConfig(encoder=\"\", decoder=\"\", language=\"\", task=\"transcribe\", "
      + "tail_paddings=-1), tdnn=OfflineTdnnModelConfig(model=\"\"), zipformer_ctc="
      + "OfflineZipformerCtcModelConfig(model=\"\"), wenet_ctc=OfflineWenetCtcModelConfig("
      + "model=\"\"), sense_voice=OfflineSenseVoiceModelConfig(model=\"\", language=\"auto\", "
      + "use_itn=False), moonshine=OfflineMoonshineModelConfig(preprocessor=\"\", encoder=\"\", "
      + "uncached_decoder=\"\", cached_decoder=\"\"), fire_red_asr=OfflineFireRedAsrModelConfig("
      + "encoder=\"\", decoder=\"\"), dolphin=OfflineDolphinModelConfig(model=\"\"), canary="
      + "OfflineCanaryModelConfig(encoder=\"\", decoder=\"\", src_lang=\"en\", tgt_lang=\"en\", "
      + "use_pnc=True), telespeech_ctc=\"\", tokens=\"\(tokens)/tokens.txt\", num_threads=4, "
      + "debug=False, provider=\"cpu\", model_type=\"nemo_transducer\", modeling_unit=\"cjkchar\", "
      + "bpe_vocab=\"\"), lm_config=OfflineLMConfig(model=\"\", scale=0.5, lm_num_threads=1, "
      + "lm_provider=\"cpu\"), ctc_fst_decoder_config=OfflineCtcFstDecoderConfig(graph=\"\", "
      + "max_active=3000), decoding_method=\"greedy_search\", max_active_paths=4, hotwords_file=\"\", "
      + "hotwords_score=1.5, blank_penalty=0, rule_fsts=\"\", rule_fars=\"\")"
  }()

  static func scratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// One second of a 440 Hz tone as 16 kHz mono 16-bit PCM.
  static func writeTone(to url: URL) throws {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let file = try AVAudioFile(
      forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16,
      interleaved: true)
    let frames: AVAudioFrameCount = 16_000
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.int16ChannelData)
    for index in 0..<Int(frames) {
      samples[0][index] = Int16(8_000 * sin(Double(index) * 2 * .pi * 440 / 16_000))
    }
    try file.write(from: buffer)
  }

  static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
  }

  static func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
      | Int(bytes[offset + 3]) << 24
  }

  static func le32(_ value: Int) -> [UInt8] {
    [
      UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24),
    ]
  }
}

/// Which engines a fake runner was asked to try, in order.
private final class EngineLog: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [AudioFileTranscriptionEngine] = []

  var engines: [AudioFileTranscriptionEngine] { lock.withLock { recorded } }

  func record(_ engine: AudioFileTranscriptionEngine) {
    lock.withLock { recorded.append(engine) }
  }
}
