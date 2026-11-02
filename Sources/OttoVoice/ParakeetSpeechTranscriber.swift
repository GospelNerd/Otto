import AVFoundation
import Foundation

public enum ParakeetDecodingMethod: String, Sendable, Equatable {
  case greedySearch = "greedy_search"
  case modifiedBeamSearch = "modified_beam_search"
}

public struct ParakeetRuntimeConfiguration: Sendable, Equatable {
  public var executableURL: URL
  public var libraryDirectory: URL
  public var modelDirectory: URL
  public var threadCount: Int
  public var decodingMethod: ParakeetDecodingMethod
  public var maxActivePaths: Int
  public var hotwordsFileURL: URL?
  public var hotwordsScore: Double
  public var modelingUnit: String
  public var bpeVocabURL: URL?

  public init(
    executableURL: URL,
    libraryDirectory: URL,
    modelDirectory: URL,
    threadCount: Int = 4,
    decodingMethod: ParakeetDecodingMethod = .greedySearch,
    maxActivePaths: Int = 4,
    hotwordsFileURL: URL? = nil,
    hotwordsScore: Double = 1.5,
    modelingUnit: String = "bpe",
    bpeVocabURL: URL? = nil
  ) {
    self.executableURL = executableURL
    self.libraryDirectory = libraryDirectory
    self.modelDirectory = modelDirectory
    self.threadCount = max(1, threadCount)
    self.decodingMethod = decodingMethod
    self.maxActivePaths = max(1, maxActivePaths)
    self.hotwordsFileURL = hotwordsFileURL
    self.hotwordsScore = hotwordsScore
    self.modelingUnit = modelingUnit
    self.bpeVocabURL = bpeVocabURL
  }

  public static func installed(fileManager: FileManager = .default) -> Self? {
    let root = fileManager.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Otto/VoiceModels/Parakeet")
    let configuration = Self(
      executableURL: root.appending(path: "runtime/bin/sherpa-onnx-offline"),
      libraryDirectory: root.appending(path: "runtime/lib"),
      modelDirectory: root.appending(path: "model")
    )
    return configuration.warmValidationError(fileManager: fileManager) == nil ? configuration : nil
  }

  public func validationError(fileManager: FileManager = .default) -> String? {
    let required = [
      executableURL,
      libraryDirectory.appending(path: "libsherpa-onnx-c-api.dylib"),
      libraryDirectory.appending(path: "libonnxruntime.dylib"),
      modelDirectory.appending(path: "encoder.int8.onnx"),
      modelDirectory.appending(path: "decoder.int8.onnx"),
      modelDirectory.appending(path: "joiner.int8.onnx"),
      modelDirectory.appending(path: "tokens.txt"),
    ]
    if let missing = required.first(where: { !fileManager.fileExists(atPath: $0.path) }) {
      return "Missing Parakeet component: \(missing.lastPathComponent)"
    }
    guard fileManager.isExecutableFile(atPath: executableURL.path) else {
      return "Parakeet runtime is not executable"
    }
    if let hotwordsFileURL {
      guard decodingMethod == .modifiedBeamSearch else {
        return "Parakeet hotwords require modified beam search"
      }
      guard fileManager.fileExists(atPath: hotwordsFileURL.path) else {
        return "Missing Parakeet hotwords file"
      }
      if modelingUnit.contains("bpe") {
        guard let bpeVocabURL, fileManager.fileExists(atPath: bpeVocabURL.path) else {
          return "Missing Parakeet BPE vocabulary"
        }
      }
    }
    return nil
  }

  var recognitionArguments: [String] {
    var arguments = [
      "--decoding-method=\(decodingMethod.rawValue)",
      "--max-active-paths=\(maxActivePaths)",
    ]
    if let hotwordsFileURL {
      arguments += [
        "--hotwords-file=\(hotwordsFileURL.path)",
        "--hotwords-score=\(hotwordsScore)",
        "--modeling-unit=\(modelingUnit)",
      ]
      if let bpeVocabURL { arguments.append("--bpe-vocab=\(bpeVocabURL.path)") }
    }
    return arguments
  }

  public func warmValidationError(fileManager: FileManager = .default) -> String? {
    if let error = validationError(fileManager: fileManager) { return error }
    let worker = executableURL.deletingLastPathComponent()
      .appending(path: "sherpa-onnx-offline-websocket-server")
    guard fileManager.isExecutableFile(atPath: worker.path) else {
      return "Missing Parakeet component: sherpa-onnx-offline-websocket-server"
    }
    return nil
  }
}

public struct ParakeetTranscription: Sendable, Equatable, Decodable {
  public var text: String
  public var timestamps: [Double]
  public var durations: [Double]

  public init(text: String, timestamps: [Double] = [], durations: [Double] = []) {
    self.text = text
    self.timestamps = timestamps
    self.durations = durations
  }
}

public enum ParakeetRuntimeError: Error, LocalizedError {
  case invalidInstallation(String)
  case failed(Int32, String)
  case missingResult
  case invalidResult(String)
  case warmWorker(String)

  public var errorDescription: String? {
    switch self {
    case .invalidInstallation(let detail): return detail
    case .failed(let status, let detail):
      // `detail` is the engine's whole stderr, which begins with a configuration dump; people
      // only see the line that explains the failure.
      let reason = TranscriptionDiagnostics.summary(of: detail)
      return reason.isEmpty
        ? "Parakeet exited with status \(status)"
        : "Parakeet exited with status \(status): \(reason)"
    case .missingResult: return "Parakeet returned no transcript"
    case .invalidResult(let detail): return "Parakeet returned an invalid result: \(detail)"
    case .warmWorker(let detail): return "Parakeet's local recognizer failed: \(detail)"
    }
  }
}

/// Process-backed proof-of-concept runner for the official sherpa-onnx macOS runtime. The app
/// layer can later replace this with the same protocol backed by an in-process warm recognizer.
public struct ParakeetOfflineRunner: Sendable {
  public var configuration: ParakeetRuntimeConfiguration

  public init(configuration: ParakeetRuntimeConfiguration) {
    self.configuration = configuration
  }

  public func transcribe(_ audioURL: URL) async throws -> ParakeetTranscription {
    guard let result = try await transcribe([audioURL]).first else {
      throw ParakeetRuntimeError.missingResult
    }
    return result
  }

  /// Runs several files through one recognizer process so model startup is paid once. This is the
  /// closest CLI-backed approximation of the warm, in-process recognizer used in production.
  public func transcribe(_ audioURLs: [URL]) async throws -> [ParakeetTranscription] {
    guard !audioURLs.isEmpty else { return [] }
    // This runner launches the one-shot offline executable directly. The warm
    // websocket worker is required by ParakeetWarmRecognizer, but requiring it
    // here would unnecessarily disable the supported offline fallback.
    if let error = configuration.validationError() {
      throw ParakeetRuntimeError.invalidInstallation(error)
    }
    let model = configuration.modelDirectory
    let arguments =
      [
        "--tokens=\(model.appending(path: "tokens.txt").path)",
        "--encoder=\(model.appending(path: "encoder.int8.onnx").path)",
        "--decoder=\(model.appending(path: "decoder.int8.onnx").path)",
        "--joiner=\(model.appending(path: "joiner.int8.onnx").path)",
        "--model-type=nemo_transducer",
        "--num-threads=\(configuration.threadCount)",
        "--print-args=false",
      ] + configuration.recognitionArguments + audioURLs.map(\.path)
    var environment = ProcessInfo.processInfo.environment
    environment["DYLD_LIBRARY_PATH"] = configuration.libraryDirectory.path
    let result = try await LocalProcess.run(
      configuration.executableURL, arguments, environment: environment,
      timeout: LocalProcess.transcriptionTimeout(for: audioURLs))
    guard result.status == 0 else {
      TranscriptionDiagnostics.logFailure(
        engine: "Parakeet", status: result.status, errorText: result.errorText)
      throw ParakeetRuntimeError.failed(result.status, result.errorText)
    }

    let outputText = String(decoding: result.output, as: UTF8.self)
    let results = outputText.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
      try? JSONDecoder().decode(ParakeetTranscription.self, from: Data($0.utf8))
    }
    guard results.count == audioURLs.count else {
      if results.isEmpty { throw ParakeetRuntimeError.missingResult }
      throw ParakeetRuntimeError.invalidResult(
        "Expected \(audioURLs.count) transcripts, received \(results.count)"
      )
    }
    return results
  }
}

/// Records the microphone locally, then performs offline Parakeet recognition when push-to-talk
/// ends. It never sends audio over the network.
public final class ParakeetSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
  public let inputDiagnostics: AsyncStream<LocalSpeechInputDiagnostic>
  private let lock = NSLock()
  private let diagnosticContinuation: AsyncStream<LocalSpeechInputDiagnostic>.Continuation
  private let recognizer: ParakeetWarmRecognizer
  private let configuration: ParakeetRuntimeConfiguration
  private var audioEngine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var outputURL: URL?
  private var continuation: AsyncThrowingStream<String, Error>.Continuation?
  private var metricBufferCount = 0

  public init(
    configuration: ParakeetRuntimeConfiguration,
    recognizer: ParakeetWarmRecognizer? = nil
  ) {
    self.configuration = configuration
    self.recognizer = recognizer ?? ParakeetWarmRecognizer(configuration: configuration)
    var continuation: AsyncStream<LocalSpeechInputDiagnostic>.Continuation!
    inputDiagnostics = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    diagnosticContinuation = continuation
  }

  public func requestAuthorization() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
    }
  }

  public func startTranscribing() async throws -> AsyncThrowingStream<String, Error> {
    if let error = configuration.validationError() {
      throw ParakeetRuntimeError.invalidInstallation(error)
    }
    try await recognizer.prepare()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let url = FileManager.default.temporaryDirectory
      .appending(path: "otto-parakeet-\(UUID().uuidString).wav")
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      self.lock.withLock { try? self.audioFile?.write(from: buffer) }
      self.recordInput(buffer)
    }
    engine.prepare()
    try engine.start()
    lock.withLock {
      audioEngine = engine
      audioFile = file
      outputURL = url
    }

    return AsyncThrowingStream { continuation in
      self.lock.withLock { self.continuation = continuation }
      continuation.onTermination = { [weak self] _ in self?.teardown(removeAudio: true) }
    }
  }

  public func stopTranscribing() async {
    let state = lock.withLock { () -> (URL?, AsyncThrowingStream<String, Error>.Continuation?) in
      audioEngine?.inputNode.removeTap(onBus: 0)
      audioEngine?.stop()
      audioEngine = nil
      audioFile = nil
      let state = (outputURL, continuation)
      outputURL = nil
      continuation = nil
      return state
    }
    guard let url = state.0, let continuation = state.1 else { return }
    do {
      let result = try await recognizer.transcribe(url)
      continuation.yield(result.text)
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
    try? FileManager.default.removeItem(at: url)
  }

  private func teardown(removeAudio: Bool) {
    let url = lock.withLock { () -> URL? in
      audioEngine?.inputNode.removeTap(onBus: 0)
      audioEngine?.stop()
      audioEngine = nil
      audioFile = nil
      continuation = nil
      defer { outputURL = nil }
      return outputURL
    }
    if removeAudio, let url { try? FileManager.default.removeItem(at: url) }
  }

  private func recordInput(_ buffer: AVAudioPCMBuffer) {
    let shouldReport = lock.withLock { () -> Bool in
      metricBufferCount += 1
      return metricBufferCount == 1 || metricBufferCount.isMultiple(of: 10)
    }
    guard shouldReport else { return }
    diagnosticContinuation.yield(
      LocalSpeechInputDiagnostic(
        inputName: localSpeechInputName(),
        sampleRate: buffer.format.sampleRate,
        channelCount: Int(buffer.format.channelCount),
        rootMeanSquare: localSpeechRootMeanSquare(buffer)
      ))
  }
}
