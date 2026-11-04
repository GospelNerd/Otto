import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// How many tokens the selected model can read in one request. Compaction is sized from this, so
/// a 32k local model compacts early and a 1M-token model compacts late.
public enum HarnessContextWindow {
  /// Used only when neither the provider's model listing nor the built-in table knows the model.
  public static func fallbackTokens(providerID: String) -> Int {
    providerID == "local" ? 32_768 : 128_000
  }

  /// Published input limits for the models Otto offers. Longer prefixes come first.
  private static let table: [(prefix: String, tokens: Int)] = [
    // Claude 4.6 and later read 1M tokens by default; Haiku 4.5 and older Claude models 200k.
    ("claude-fable", 1_000_000),
    ("claude-mythos", 1_000_000),
    ("claude-opus-5", 1_000_000),
    ("claude-sonnet-5", 1_000_000),
    ("claude-haiku-5", 1_000_000),
    ("claude-opus-4-6", 1_000_000),
    ("claude-opus-4-7", 1_000_000),
    ("claude-opus-4-8", 1_000_000),
    ("claude-sonnet-4-6", 1_000_000),
    ("claude-", 200_000),
    ("gpt-5", 272_000),
    ("gpt-4.1", 1_047_576),
    ("gpt-4o", 128_000),
    ("gpt-4-turbo", 128_000),
    ("o1", 200_000),
    ("o3", 200_000),
    ("o4", 200_000),
    ("grok-4.1-fast", 2_000_000),
    ("grok-4-fast", 2_000_000),
    ("grok-code", 256_000),
    ("grok-4", 256_000),
    ("grok-3", 131_072),
    ("gemini-", 1_048_576),
    ("deepseek-", 128_000),
    ("kimi-k2", 262_144),
    ("kimi-", 131_072),
    ("codestral", 256_000),
    ("mistral-", 128_000),
    ("llama-4", 131_072),
    ("llama-3", 131_072),
  ]

  /// The built-in figure for a model, matching `vendor/model` ids (OpenRouter) on the model part.
  public static func knownTokens(modelID: String) -> Int? {
    let lowered = modelID.lowercased()
    var name = lowered.split(separator: "/").last.map(String.init) ?? lowered
    // OpenRouter writes Claude versions with dots (claude-opus-4.6); Anthropic uses dashes.
    if name.hasPrefix("claude-") { name = name.replacingOccurrences(of: ".", with: "-") }
    for (marker, tokens) in [("-8k", 8_192), ("-32k", 32_768), ("-128k", 131_072)]
    where name.hasSuffix(marker) {
      return tokens
    }
    return table.first { name.hasPrefix($0.prefix) }?.tokens
  }

  /// Reads a `/models` listing (OpenRouter, Groq, Mistral, Moonshot, vLLM, LM Studio…) and returns
  /// the context size it reports for `modelID`. A runtime limit (LM Studio's loaded context) wins
  /// over the model's trained maximum because it is what the server will actually accept.
  public static func tokens(inModelsListing data: Data, modelID: String) -> Int? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let models = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]])
    else { return nil }
    let wanted = modelID.lowercased()
    let entry = models.first { model in
      guard let id = (model["id"] as? String)?.lowercased() else { return false }
      return id == wanted || id.hasSuffix("/" + wanted) || wanted.hasSuffix("/" + id)
    }
    guard let entry else { return nil }
    func int(_ value: Any?) -> Int? {
      guard let number = (value as? NSNumber)?.intValue, number >= 1_024 else { return nil }
      return number
    }
    let topProvider = entry["top_provider"] as? [String: Any]
    return int(entry["loaded_context_length"])
      ?? int(entry["max_input_tokens"])
      ?? int(entry["context_length"])
      ?? int(entry["context_window"])
      ?? int(entry["max_context_length"])
      ?? int(entry["max_model_len"])
      ?? int(topProvider?["context_length"])
  }

  /// True when a provider rejected a request because the prompt did not fit the model.
  public static func isOverflow(_ error: Error) -> Bool {
    guard case HarnessError.providerRequestFailed(let message) = error else { return false }
    let lowered = message.lowercased()
    // OpenAI also says "Request too large … tokens per min" for rate limits; that is not this.
    if lowered.contains("per min") || lowered.contains("rate limit") { return false }
    return [
      "context length", "context_length", "maximum context", "context window",
      "prompt is too long", "input is too long", "too many tokens", "reduce the length",
      "exceeds the context", "maximum input", "input token count",
    ].contains { lowered.contains($0) }
  }
}

/// Finds and remembers each model's context size. Every Otto Harness turn is a fresh process, so
/// the answer is cached on disk: listings for a week, limits learned from overflow errors for 30
/// days (servers get upgraded).
public struct HarnessContextWindowResolver: Sendable {
  public enum Source: String, Codable, Sendable {
    case listing
    case table
    case fallback
    case learned
  }

  public struct Resolution: Equatable, Sendable {
    public var tokens: Int
    public var source: Source
  }

  private struct Entry: Codable {
    var tokens: Int
    var source: Source
    var recordedAt: Date
  }

  private let cacheURL: URL
  private let session: URLSession
  private let now: @Sendable () -> Date

  public init(
    cacheURL: URL = HarnessSessionStore.defaultRootURL()
      .deletingLastPathComponent().appending(path: "context-windows.json"),
    session: URLSession = .shared,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.cacheURL = cacheURL
    self.session = session
    self.now = now
  }

  /// - Parameter modelsURL: the provider's OpenAI-style `/models` endpoint, when it reports
  ///   context sizes (Anthropic reports `max_input_tokens`). Pass nil for providers whose listing
  ///   does not (OpenAI, xAI).
  public func resolve(
    providerID: String, modelID: String, modelsURL: URL?, apiKey: String
  ) async -> Resolution {
    var cache = readCache()
    let key = "\(providerID)|\(modelID)"
    let learned = cache[key + "|learned"].flatMap { entry in
      now().timeIntervalSince(entry.recordedAt) < 30 * 86_400 ? entry.tokens : nil
    }
    var resolution: Resolution
    if let cached = cache[key], cached.source == .listing,
      now().timeIntervalSince(cached.recordedAt) < 7 * 86_400
    {
      resolution = Resolution(tokens: cached.tokens, source: .listing)
    } else if let modelsURL,
      let listed = await fetchListing(modelsURL, modelID: modelID, apiKey: apiKey)
    {
      resolution = Resolution(tokens: listed, source: .listing)
      cache[key] = Entry(tokens: listed, source: .listing, recordedAt: now())
      writeCache(cache)
    } else if let known = HarnessContextWindow.knownTokens(modelID: modelID) {
      resolution = Resolution(tokens: known, source: .table)
    } else {
      resolution = Resolution(
        tokens: HarnessContextWindow.fallbackTokens(providerID: providerID), source: .fallback)
    }
    if let learned, learned < resolution.tokens {
      resolution = Resolution(tokens: learned, source: .learned)
    }
    return resolution
  }

  /// Records that a request of about `promptTokens` was rejected as too long, so later turns plan
  /// for a smaller window than the listing or table claimed.
  public func learnOverflow(providerID: String, modelID: String, promptTokens: Int) {
    var cache = readCache()
    let key = "\(providerID)|\(modelID)|learned"
    let tokens = max(4_096, Int(Double(promptTokens) * 0.9))
    if let existing = cache[key], existing.tokens <= tokens { return }
    cache[key] = Entry(tokens: tokens, source: .learned, recordedAt: now())
    writeCache(cache)
  }

  private func fetchListing(_ url: URL, modelID: String, apiKey: String) async -> Int? {
    var request = URLRequest(url: url, timeoutInterval: 5)
    if url.host == "api.anthropic.com" {
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    } else if !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else { return nil }
    return HarnessContextWindow.tokens(inModelsListing: data, modelID: modelID)
  }

  private func readCache() -> [String: Entry] {
    guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
  }

  private func writeCache(_ cache: [String: Entry]) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(cache) else { return }
    try? FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try? data.write(to: cacheURL, options: .atomic)
  }
}
