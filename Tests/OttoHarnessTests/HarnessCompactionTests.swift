import Foundation
import OttoTools
import Testing

@testable import OttoHarness

@Suite("Otto Harness context compaction")
struct HarnessCompactionTests {
  @Test("Compaction follows the picked model's window: a 32k model compacts, a 200k one does not")
  func compactionIsSizedToTheModel() async throws {
    for (window, expectCompaction) in [(32_768, true), (200_000, false)] {
      let fixture = try CompactionFixture()
      defer { fixture.remove() }
      let store = HarnessSessionStore(rootURL: fixture.url)
      let session = try await fixture.seededSession(store, messages: 40, bytesEach: 2_000)
      let backend = SummarisingBackend()
      let events = EventLog()

      let result = try await HarnessRunner(sessionStore: store).run(
        HarnessTurnRequest(
          sessionID: session.id, providerID: "openrouter", modelID: "some/model",
          systemInstructions: "Base system", prompt: "next question", contextWindow: window),
        backend: backend, onEvent: { events.append($0) })

      let requests = await backend.recordedRequests()
      let turn = try #require(requests.last)
      let saved = try await store.load(sessionID: result.sessionID)
      if expectCompaction {
        #expect(requests.contains { $0.systemInstructions.hasPrefix("You compress") })
        #expect(turn.systemInstructions.contains("SUMMARY-OF-EARLIER"))
        #expect(saved.compaction?.summary == "SUMMARY-OF-EARLIER")
        #expect(saved.compaction?.contextWindowTokens == window)
        #expect(saved.messages.count < 20)
        #expect(saved.messages.first?.role == .user)
        #expect((saved.archivedMessages?.count ?? 0) + saved.messages.count == 42)
        #expect(events.values.contains { if case .compacted = $0 { true } else { false } })
        let sent = try #require(turn.conversationMessages)
        let estimate =
          HarnessCompactor.estimateTokens(turn.systemInstructions)
          + sent.reduce(0) { $0 + HarnessCompactor.estimateTokens($1.content) + 4 }
        #expect(estimate < window / 2)
      } else {
        #expect(requests.count == 1)
        #expect(saved.compaction == nil)
        #expect(saved.messages.count == 42)
      }
    }
  }

  @Test("A provider's 'context too long' rejection compacts and retries once, and is learned")
  func overflowRecovery() async throws {
    let fixture = try CompactionFixture()
    defer { fixture.remove() }
    let store = HarnessSessionStore(rootURL: fixture.url)
    let session = try await fixture.seededSession(store, messages: 30, bytesEach: 2_000)
    let backend = SummarisingBackend(
      failFirstTurnWith: "This model's maximum context length is 8192 tokens.")
    let events = EventLog()

    // Otto believes the window is large, so nothing compacts until the provider says otherwise.
    let result = try await HarnessRunner(sessionStore: store).run(
      HarnessTurnRequest(
        sessionID: session.id, providerID: "local", modelID: "tiny",
        systemInstructions: "Base system", prompt: "next", contextWindow: 128_000),
      backend: backend, onEvent: { events.append($0) })

    #expect(result.text == "answer")
    let overflow = events.values.compactMap {
      if case .contextOverflow(let tokens) = $0 { tokens } else { nil }
    }
    #expect(overflow.count == 1)
    #expect(events.values.contains { if case .compacted = $0 { true } else { false } })
    let saved = try await store.load(sessionID: result.sessionID)
    #expect(saved.compaction != nil)
    #expect(saved.messages.last?.content == "answer")
    #expect(saved.messages.filter { $0.content == "next" }.count == 1)
  }

  @Test("A failed summary never fails the turn; folded messages stay in the archive digest")
  func summaryFailureIsNotFatal() async throws {
    let fixture = try CompactionFixture()
    defer { fixture.remove() }
    let store = HarnessSessionStore(rootURL: fixture.url)
    let session = try await fixture.seededSession(store, messages: 40, bytesEach: 2_000)
    let backend = SummarisingBackend(summaryFails: true)

    let result = try await HarnessRunner(sessionStore: store).run(
      HarnessTurnRequest(
        sessionID: session.id, providerID: "local", modelID: "tiny",
        systemInstructions: "Base system", prompt: "next", contextWindow: 16_384),
      backend: backend)

    #expect(result.text == "answer")
    let saved = try await store.load(sessionID: result.sessionID)
    #expect(saved.compaction == nil)
    #expect((saved.archivedMessages?.count ?? 0) > 0)
    let turn = try #require(await backend.recordedRequests().last)
    #expect(turn.systemInstructions.contains("Earlier session context"))
  }

  @Test("Model listings report the context size Otto should plan for")
  func listingParsing() throws {
    let openRouter = Data(
      #"{"data":[{"id":"anthropic/claude-sonnet-4.5","context_length":1000000,"top_provider":{"context_length":200000}}]}"#
        .utf8)
    #expect(
      HarnessContextWindow.tokens(inModelsListing: openRouter, modelID: "anthropic/claude-sonnet-4.5")
        == 1_000_000)
    let lmStudio = Data(
      #"{"data":[{"id":"qwen3-8b","max_context_length":131072,"loaded_context_length":8192}]}"#.utf8)
    #expect(HarnessContextWindow.tokens(inModelsListing: lmStudio, modelID: "qwen3-8b") == 8_192)
    let gemini = Data(#"{"data":[{"id":"models/gemini-2.5-pro","context_window":1048576}]}"#.utf8)
    #expect(HarnessContextWindow.tokens(inModelsListing: gemini, modelID: "gemini-2.5-pro") == 1_048_576)
    let vllm = Data(#"{"data":[{"id":"llama","max_model_len":32768}]}"#.utf8)
    #expect(HarnessContextWindow.tokens(inModelsListing: vllm, modelID: "llama") == 32_768)
    #expect(HarnessContextWindow.tokens(inModelsListing: vllm, modelID: "other") == nil)

    let anthropic = Data(
      #"{"data":[{"id":"claude-opus-5-5","max_input_tokens":1000000,"max_tokens":128000}]}"#.utf8)
    #expect(HarnessContextWindow.tokens(inModelsListing: anthropic, modelID: "claude-opus-5-5") == 1_000_000)

    #expect(HarnessContextWindow.knownTokens(modelID: "claude-opus-5-5") == 1_000_000)
    #expect(HarnessContextWindow.knownTokens(modelID: "anthropic/claude-opus-4.6") == 1_000_000)
    #expect(HarnessContextWindow.knownTokens(modelID: "claude-haiku-4-5") == 200_000)
    #expect(HarnessContextWindow.knownTokens(modelID: "anthropic/claude-opus-4.5") == 200_000)
    #expect(HarnessContextWindow.knownTokens(modelID: "gpt-5.6") == 272_000)
    #expect(HarnessContextWindow.knownTokens(modelID: "deepseek/deepseek-chat") == 128_000)
    #expect(HarnessContextWindow.knownTokens(modelID: "moonshot-v1-32k") == 32_768)
    #expect(HarnessContextWindow.knownTokens(modelID: "mystery-model") == nil)
  }

  @Test("Overflow errors are recognised, rate limits are not")
  func overflowDetection() {
    func failed(_ text: String) -> Error { HarnessError.providerRequestFailed(text) }
    #expect(HarnessContextWindow.isOverflow(failed("maximum context length is 8192 tokens")))
    #expect(HarnessContextWindow.isOverflow(failed("prompt is too long: 210000 tokens > 200000")))
    #expect(
      !HarnessContextWindow.isOverflow(
        failed("Request too large for gpt-4o on tokens per min (TPM): Limit 30000")))
    #expect(!HarnessContextWindow.isOverflow(HarnessError.missingFinalResponse))
  }

  @Test("A rejected prompt size is remembered and lowers later turns' window")
  func learnedWindowIsCached() async throws {
    let fixture = try CompactionFixture()
    defer { fixture.remove() }
    let resolver = HarnessContextWindowResolver(cacheURL: fixture.url.appending(path: "w.json"))
    let before = await resolver.resolve(
      providerID: "local", modelID: "tiny", modelsURL: nil, apiKey: "")
    #expect(before == .init(tokens: 32_768, source: .fallback))
    resolver.learnOverflow(providerID: "local", modelID: "tiny", promptTokens: 10_000)
    let after = await resolver.resolve(
      providerID: "local", modelID: "tiny", modelsURL: nil, apiKey: "")
    #expect(after == .init(tokens: 9_000, source: .learned))
    let other = await resolver.resolve(
      providerID: "anthropic", modelID: "claude-haiku-4-5", modelsURL: nil, apiKey: "")
    #expect(other == .init(tokens: 200_000, source: .table))
  }
}

extension HarnessBackendRequest {
  fileprivate var conversationMessages: [HarnessMessage]? {
    if case .conversation(let messages) = input { return messages }
    return nil
  }
}

private actor SummarisingBackend: HarnessModelBackend {
  nonisolated let providerID = "local"
  private var requests: [HarnessBackendRequest] = []
  private var overflowMessage: String?
  private let summaryFails: Bool

  init(failFirstTurnWith overflowMessage: String? = nil, summaryFails: Bool = false) {
    self.overflowMessage = overflowMessage
    self.summaryFails = summaryFails
  }

  func complete(_ request: HarnessBackendRequest) async throws -> HarnessBackendResponse {
    requests.append(request)
    if request.systemInstructions.hasPrefix("You compress") {
      if summaryFails { throw HarnessError.providerRequestFailed("summariser unavailable") }
      return HarnessBackendResponse(text: "SUMMARY-OF-EARLIER")
    }
    if let message = overflowMessage {
      overflowMessage = nil
      throw HarnessError.providerRequestFailed("Local model request failed: \(message)")
    }
    return HarnessBackendResponse(text: "answer")
  }

  func recordedRequests() -> [HarnessBackendRequest] { requests }
}

private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [HarnessEvent] = []
  func append(_ event: HarnessEvent) { lock.withLock { events.append(event) } }
  var values: [HarnessEvent] { lock.withLock { events } }
}

private struct CompactionFixture {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appending(path: "otto-compaction-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func seededSession(_ store: HarnessSessionStore, messages: Int, bytesEach: Int) async throws
    -> HarnessSession
  {
    var session = HarnessSession(providerID: "local", modelID: "tiny")
    session.messages = (0..<messages).map {
      HarnessMessage(
        role: $0.isMultiple(of: 2) ? .user : .assistant,
        content: "message \($0) " + String(repeating: "x", count: bytesEach))
    }
    try await store.save(session)
    return session
  }

  func remove() { try? FileManager.default.removeItem(at: url) }
}
