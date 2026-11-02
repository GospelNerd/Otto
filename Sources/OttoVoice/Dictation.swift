import Foundation
import OttoModels
import OttoTools

/// Abstracts on-device speech recognition so the dictation pipeline is testable without a
/// microphone. The production implementation wraps SFSpeechRecognizer in the app target.
public protocol SpeechTranscriber: Sendable {
  var inputDiagnostics: AsyncStream<LocalSpeechInputDiagnostic> { get }
  /// Requests speech + microphone authorization. Returns true when transcription may start.
  func requestAuthorization() async -> Bool
  /// Starts capturing; the stream yields the evolving transcript (each element replaces the
  /// previous one) and finishes when capture stops.
  func startTranscribing() async throws -> AsyncThrowingStream<String, Error>
  func stopTranscribing() async
}

extension SpeechTranscriber {
  public var inputDiagnostics: AsyncStream<LocalSpeechInputDiagnostic> {
    AsyncStream { $0.finish() }
  }
}

public enum LocalSpeechSignalQuality: String, Sendable, Equatable {
  case silent
  case low
  case good
  case clipping
}

public struct LocalSpeechInputDiagnostic: Sendable, Equatable {
  public var inputName: String
  public var sampleRate: Double
  public var channelCount: Int
  public var rootMeanSquare: Double
  public var quality: LocalSpeechSignalQuality

  public init(
    inputName: String,
    sampleRate: Double,
    channelCount: Int,
    rootMeanSquare: Double
  ) {
    self.inputName = inputName
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.rootMeanSquare = rootMeanSquare
    quality = Self.quality(for: rootMeanSquare)
  }

  public static func quality(for rootMeanSquare: Double) -> LocalSpeechSignalQuality {
    switch rootMeanSquare {
    case ..<0.002: .silent
    case ..<0.015: .low
    case 0.85...: .clipping
    default: .good
    }
  }

  public var actionableDetail: String {
    let level = Int((min(max(rootMeanSquare, 0), 1) * 100).rounded())
    return switch quality {
    case .silent:
      "\(inputName) · no signal — check the selected input or microphone mute"
    case .low:
      "\(inputName) · low signal (\(level)%) — move closer or raise input level"
    case .good:
      "\(inputName) · signal \(level)%"
    case .clipping:
      "\(inputName) · clipping — lower the microphone input level"
    }
  }
}

public enum DictationState: String, Sendable, Equatable {
  case idle
  case listening
  case delivering
  case denied
  case failed
}

public struct DictationUpdate: Sendable, Equatable {
  public var state: DictationState
  public var transcript: String
  /// Short wording for the Voice row; never a raw runtime or transport error.
  public var detail: String
  public var inputDiagnostic: LocalSpeechInputDiagnostic?
  public var delivered: Bool
  /// The underlying error for logs when `state` is `.failed`.
  public var technicalDetail: String?

  public init(
    state: DictationState,
    transcript: String = "",
    detail: String = "",
    inputDiagnostic: LocalSpeechInputDiagnostic? = nil,
    delivered: Bool = false,
    technicalDetail: String? = nil
  ) {
    self.state = state
    self.transcript = transcript
    self.detail = detail
    self.inputDiagnostic = inputDiagnostic
    self.delivered = delivered
    self.technicalDetail = technicalDetail
  }
}

/// Delivers a finished dictation verbatim to a target node: prompts an idle/done agent, and
/// falls back to raw input when the agent is mid-run so the text still lands in its harness.
public struct DictationRouter: Sendable {
  private let registry: ToolRegistry
  private let context: ToolContext

  public init(registry: ToolRegistry, context: ToolContext) {
    self.registry = registry
    self.context = context
  }

  @discardableResult
  public func deliver(transcript: String, to nodeID: UUID) async throws -> String {
    guard let verbatim = PromptSubmission.verbatimText(from: transcript) else {
      return "Nothing to send"
    }
    let status = try await registry.call(
      name: "agent.get_status",
      input: .object(["agentID": .string(nodeID.uuidString)]),
      context: context
    )
    let state = status["state"]?.stringValue ?? ""
    if ["IDLE", "DONE", "idle", "done"].contains(state) {
      _ = try await registry.call(
        name: "agent.send_prompt",
        input: .object([
          "agentID": .string(nodeID.uuidString),
          "prompt": .string(verbatim),
        ]),
        context: context
      )
      return "Prompted \(String(verbatim.prefix(60)))"
    }
    let delivery = try await VoiceAgentRelay.send(
      toolName: VoiceAgentRelay.inputToolName,
      agentID: nodeID,
      text: verbatim,
      lastKnownState: state,
      registry: registry,
      context: context
    )
    if delivery.continuedAfterExit { return "Prompted \(String(verbatim.prefix(60)))" }
    return "Sent input \(String(verbatim.prefix(60)))"
  }
}

/// Push-to-talk dictation: start() begins on-device transcription, stop() finalizes the
/// transcript and hands it to the router. All progress is published as DictationUpdate values.
public actor DictationSession {
  public nonisolated let updates: AsyncStream<DictationUpdate>
  private let updateContinuation: AsyncStream<DictationUpdate>.Continuation

  private let transcriber: any SpeechTranscriber
  private let router: DictationRouter
  private var transcript = ""
  private var listenTask: Task<Void, Never>?
  private var diagnosticsTask: Task<Void, Never>?
  private var isListening = false
  /// Set while stopping: batch engines (Whistle, Parakeet) only produce text once capture ends.
  private var isFinishing = false
  private var finishError: String?
  private var latestInputDiagnostic: LocalSpeechInputDiagnostic?

  public init(transcriber: any SpeechTranscriber, router: DictationRouter) {
    self.transcriber = transcriber
    self.router = router
    var continuation: AsyncStream<DictationUpdate>.Continuation!
    updates = AsyncStream { continuation = $0 }
    updateContinuation = continuation
  }

  deinit {
    listenTask?.cancel()
    diagnosticsTask?.cancel()
  }

  public func start() async {
    guard !isListening else { return }
    guard await transcriber.requestAuthorization() else {
      updateContinuation.yield(
        DictationUpdate(
          state: .denied,
          detail: "Enable Speech Recognition for Otto in System Settings › Privacy"
        ))
      return
    }
    do {
      let stream = try await transcriber.startTranscribing()
      isListening = true
      transcript = ""
      latestInputDiagnostic = nil
      startDiagnostics()
      updateContinuation.yield(DictationUpdate(state: .listening))
      listenTask = Task { [weak self] in
        do {
          for try await text in stream {
            await self?.record(text)
          }
        } catch {
          await self?.captureFailed(
            VoiceFailureText.message(for: error),
            technicalDetail: VoiceFailureText.technicalDetail(for: error)
          )
        }
      }
    } catch {
      updateContinuation.yield(
        DictationUpdate(
          state: .failed,
          detail: VoiceFailureText.message(for: error),
          technicalDetail: VoiceFailureText.technicalDetail(for: error)
        ))
    }
  }

  /// Stops capture and delivers the final transcript to the given node.
  public func stopAndDeliver(to nodeID: UUID?) async {
    guard isListening else { return }
    isListening = false
    isFinishing = true
    finishError = nil
    await transcriber.stopTranscribing()
    await finishTranscription(listenTask)
    isFinishing = false
    listenTask = nil
    diagnosticsTask?.cancel()
    diagnosticsTask = nil
    guard let final = PromptSubmission.verbatimText(from: transcript) else {
      updateContinuation.yield(
        finishError.map { DictationUpdate(state: .failed, detail: $0) }
          ?? DictationUpdate(state: .idle, detail: "Heard nothing"))
      return
    }
    guard let nodeID else {
      updateContinuation.yield(
        DictationUpdate(
          state: .failed,
          transcript: final,
          detail: "Focus an agent node first, then dictate"
        ))
      return
    }
    updateContinuation.yield(
      DictationUpdate(
        state: .delivering,
        transcript: final,
        inputDiagnostic: latestInputDiagnostic
      ))
    do {
      let receipt = try await router.deliver(transcript: final, to: nodeID)
      updateContinuation.yield(
        DictationUpdate(state: .idle, transcript: final, detail: receipt, delivered: true))
    } catch {
      updateContinuation.yield(
        DictationUpdate(
          state: .failed,
          transcript: final,
          detail: VoiceFailureText.message(for: error),
          technicalDetail: VoiceFailureText.technicalDetail(for: error)
        ))
    }
  }

  public func cancel() async {
    guard isListening else { return }
    isListening = false
    await transcriber.stopTranscribing()
    listenTask?.cancel()
    listenTask = nil
    diagnosticsTask?.cancel()
    diagnosticsTask = nil
    updateContinuation.yield(
      DictationUpdate(state: .idle, transcript: transcript, detail: "Dictation cancelled"))
  }

  private func record(_ text: String) {
    guard isListening || isFinishing else { return }
    transcript = text
    guard isListening else { return }
    updateContinuation.yield(
      DictationUpdate(
        state: .listening,
        transcript: text,
        inputDiagnostic: latestInputDiagnostic
      ))
  }

  private func startDiagnostics() {
    diagnosticsTask?.cancel()
    let stream = transcriber.inputDiagnostics
    diagnosticsTask = Task { [weak self] in
      for await diagnostic in stream { await self?.record(diagnostic) }
    }
  }

  private func record(_ diagnostic: LocalSpeechInputDiagnostic) {
    guard isListening else { return }
    latestInputDiagnostic = diagnostic
    updateContinuation.yield(
      DictationUpdate(
        state: .listening,
        transcript: transcript,
        detail: diagnostic.actionableDetail,
        inputDiagnostic: diagnostic
      ))
  }

  private func captureFailed(_ message: String, technicalDetail: String? = nil) {
    if isFinishing { finishError = message }
    guard isListening else { return }
    isListening = false
    updateContinuation.yield(
      DictationUpdate(
        state: .failed,
        transcript: transcript,
        detail: message,
        technicalDetail: technicalDetail
      ))
  }
}
