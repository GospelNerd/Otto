import Foundation
import Speech

/// Engines that can transcribe a finished recording, such as a Telegram voice note.
public enum AudioFileTranscriptionEngine: String, Sendable, CaseIterable {
  case whistle, parakeet, apple
}

public enum AudioFileTranscriptionError: Error, LocalizedError, Equatable {
  case conversion(String)
  case noEngine
  case nothingHeard
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .conversion(let detail): "Could not read the recording: \(detail)"
    case .noEngine:
      "No on-device speech engine is ready. Allow Speech Recognition for Otto, or download Whistle in Voice settings."
    case .nothingHeard: "No speech was found in the recording."
    case .timedOut: "Transcribing the recording took too long."
    }
  }
}

/// Transcribes a recording on this Mac, never through a server. The file is first converted
/// with macOS's own `afconvert`, which also reads the Ogg Opus that Telegram voice notes use.
/// Engines are tried in the order given and skipped when not installed or not allowed.
public enum AudioFileTranscription {
  /// Telegram's Bot API serves files up to 20 MB; nothing larger is read.
  public static let maxBytes = 20_000_000

  /// Runs one engine on the converted clip; nil means the engine is not installed or allowed.
  typealias EngineRunner =
    @Sendable (URL, AudioFileTranscriptionEngine) async throws -> String?

  /// Gives up after `timeout` overall, on top of each engine's own limit, so one stuck
  /// recording cannot hold its caller forever.
  public static func transcribe(
    _ audioURL: URL, preferring order: [AudioFileTranscriptionEngine],
    timeout: Duration = .seconds(600)
  ) async throws -> String {
    try await transcribe(audioURL, preferring: order, timeout: timeout, runner: transcribe(_:with:))
  }

  /// The engines in the order they are tried: the preferred ones first, then every other, so
  /// Apple's on-device speech is the last resort unless it was asked for first.
  static func engineOrder(preferring order: [AudioFileTranscriptionEngine])
    -> [AudioFileTranscriptionEngine]
  {
    order + AudioFileTranscriptionEngine.allCases.filter { !order.contains($0) }
  }

  static func transcribe(
    _ audioURL: URL, preferring order: [AudioFileTranscriptionEngine], timeout: Duration,
    runner: @escaping EngineRunner
  ) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        try await transcribeWithFirstReadyEngine(audioURL, preferring: order, runner: runner)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw AudioFileTranscriptionError.timedOut
      }
      defer { group.cancelAll() }
      guard let transcript = try await group.next() else { throw CancellationError() }
      return transcript
    }
  }

  private static func transcribeWithFirstReadyEngine(
    _ audioURL: URL, preferring order: [AudioFileTranscriptionEngine], runner: EngineRunner
  ) async throws -> String {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let clip = directory.appending(path: "clip.wav")
    try await convert(audioURL, to: clip)

    // An engine that fails does not stop the next one; the last failure is what the caller sees,
    // and every failure is logged so the cause is in Console.
    var lastError: Error = AudioFileTranscriptionError.noEngine
    for engine in engineOrder(preferring: order) {
      do {
        guard let text = try await runner(clip, engine) else { continue }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        lastError = AudioFileTranscriptionError.nothingHeard
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        TranscriptionDiagnostics.logger.error(
          "\(engine.rawValue, privacy: .public) could not transcribe the recording: \(String(describing: error), privacy: .public)"
        )
        lastError = error
      }
    }
    throw lastError
  }

  /// Nil when the engine is not installed or not permitted, so the next one is tried.
  private static func transcribe(_ clip: URL, with engine: AudioFileTranscriptionEngine)
    async throws -> String?
  {
    switch engine {
    case .whistle:
      guard let configuration = WhistleRuntimeConfiguration.installed() else { return nil }
      return try await WhistleOfflineRunner(configuration: configuration).transcribe(clip).text
    case .parakeet:
      guard let configuration = ParakeetRuntimeConfiguration.installed() else { return nil }
      return try await ParakeetOfflineRunner(configuration: configuration).transcribe(clip).text
    case .apple:
      guard SFSpeechRecognizer.authorizationStatus() == .authorized,
        let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
        recognizer.supportsOnDeviceRecognition
      else { return nil }
      let request = SFSpeechURLRecognitionRequest(url: clip)
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = false
      let recognition = AppleRecognition()
      let timeout = Task.detached {
        try await Task.sleep(for: LocalProcess.transcriptionTimeout(for: [clip]))
        recognition.finish(.failure(AudioFileTranscriptionError.timedOut))
      }
      defer { timeout.cancel() }
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          recognition.start(recognizer, request, continuation: continuation)
        }
      } onCancel: {
        recognition.finish(.failure(CancellationError()))
      }
    }
  }

  static func convert(_ source: URL, to destination: URL) async throws {
    let size =
      (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?
      .intValue ?? 0
    guard size > 0, size <= maxBytes else {
      throw AudioFileTranscriptionError.conversion("the file is empty or larger than 20 MB")
    }
    let result = try await LocalProcess.run(
      URL(filePath: "/usr/bin/afconvert"),
      ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source.path, destination.path],
      timeout: LocalProcess.conversionTimeout)
    guard result.status == 0 else {
      TranscriptionDiagnostics.logFailure(
        engine: "afconvert", status: result.status, errorText: result.errorText)
      throw AudioFileTranscriptionError.conversion(
        TranscriptionDiagnostics.summary(of: result.errorText))
    }
    // afconvert writes WAVE_FORMAT_EXTENSIBLE for sources with a channel layout, such as
    // Telegram's Ogg Opus, and sherpa-onnx refuses that header.
    try PCMWaveFile.normalize(at: destination)
  }
}

/// One Apple recognition answered exactly once: by the recognizer's final result or error, the
/// timeout, or cancellation, whichever comes first. The recognizer may never call back, so the
/// answer cannot depend on it alone.
private final class AppleRecognition: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?
  private var outcome: Result<String, Error>?
  private var task: SFSpeechRecognitionTask?

  func start(
    _ recognizer: SFSpeechRecognizer, _ request: SFSpeechRecognitionRequest,
    continuation: CheckedContinuation<String, Error>
  ) {
    let early = lock.withLock { () -> Result<String, Error>? in
      if let outcome { return outcome }
      self.continuation = continuation
      return nil
    }
    if let early {
      continuation.resume(with: early)
      return
    }
    let task = recognizer.recognitionTask(with: request) { [self] result, error in
      if let result, result.isFinal {
        finish(.success(result.bestTranscription.formattedString))
      } else if let error {
        finish(.failure(error))
      }
    }
    let answered = lock.withLock { () -> Bool in
      if outcome != nil { return true }
      self.task = task
      return false
    }
    if answered { task.cancel() }
  }

  func finish(_ result: Result<String, Error>) {
    let pending = lock.withLock {
      () -> (CheckedContinuation<String, Error>?, SFSpeechRecognitionTask?)? in
      guard outcome == nil else { return nil }
      outcome = result
      defer {
        continuation = nil
        task = nil
      }
      return (continuation, task)
    }
    guard let pending else { return }
    pending.1?.cancel()
    pending.0?.resume(with: result)
  }
}
