import Combine
import Foundation
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

enum SessionLaunchProviderCatalog {
  /// Every agent runtime a one-off session can start, including Otto's own harness, which is
  /// the only way to run local (OpenAI-compatible) models and direct API models in a session.
  static let providers = AgentProvider.allCases.filter { $0 != .shell }

  /// The harness is listed simply as Otto, with Otto's mark. Its legacy `OpenAI API` enum label
  /// would read as a second Codex choice, which is why it was hidden before.
  static func title(for provider: AgentProvider) -> String {
    provider == .openAI ? "Otto" : provider.rawValue
  }
}

/// Process-wide cache of provider model catalogs that have to be read from a CLI.
///
/// Provider catalogs are account-specific and can come from a CLI cache, a CLI list command, or
/// the direct model API. Holding discovery in each picker would make bot and session screens
/// disagree, repeat slow work, and freeze newly released models into the app binary.
///
/// The cache is keyed by provider and account, de-duplicates concurrent loads, and survives view recreation.
/// Agent nodes warm it when they appear, so by the time the chip is clicked the list is usually
/// already there.
@MainActor
final class ProviderModelCatalogStore: ObservableObject {
  static let shared = ProviderModelCatalogStore()

  /// Catalogs differ per provider account (work vs personal plans), so each is cached under the
  /// account it was read with. A nil account means this Mac's own provider login.
  struct Key: Hashable {
    var provider: AgentProvider
    var accountID: UUID?
  }

  /// Absent means "not loaded yet"; present-but-empty means discovery ran and found nothing, which
  /// is a different thing the picker has to be able to say out loud.
  @Published private(set) var catalogs: [Key: [AgentModel]] = [:]
  @Published private(set) var revision = 0
  private var inFlight: [Key: UUID] = [:]
  private var loadedAt: [Key: Date] = [:]
  private var subscriptions: Set<AnyCancellable> = []
  private let refreshInterval: TimeInterval = 300
  var accountEnvironment: ((UUID, AgentProvider) async throws -> [String: String]?)?
  var discover: (AgentProvider, [String: String]) async -> [AgentModel]? = ProviderModelCatalogStore
    .models

  struct Request: Hashable {
    let key: Key
    let revision: Int
  }

  func request(for provider: AgentProvider, accountID: UUID?) -> Request {
    Request(key: Key(provider: provider, accountID: accountID), revision: revision)
  }

  func configure(accounts: ProviderAccountStore, projects: ConversationProjectStore) {
    accountEnvironment = { accountID, provider in
      try await accounts.launchContext(accountID: accountID, provider: provider)?.environment
    }
    subscriptions.removeAll()
    accounts.objectWillChange.merge(with: projects.objectWillChange).sink { [weak self] in
      // objectWillChange precedes the mutation; invalidate after the new account is visible.
      Task { @MainActor [weak self] in self?.invalidate() }
    }.store(in: &subscriptions)
    invalidate()
  }

  func invalidate() {
    revision += 1
    inFlight.removeAll()
    loadedAt.removeAll()
    catalogs.removeAll()
  }

  /// Hermes owns model selection remotely. Other selectable harnesses expose a live catalog.
  static func isDiscovered(_ provider: AgentProvider) -> Bool {
    switch provider {
    case .claudeCode, .codex, .openAI, .cursor, .kimi, .openCode, .pi, .grok: true
    case .hermes, .shell: false
    }
  }

  func catalog(for provider: AgentProvider, accountID: UUID? = nil) -> [AgentModel]? {
    let discovered = catalogs[Key(provider: provider, accountID: accountID)]
    return Self.withConfiguredLocalModel(
      discovered, provider: provider, configuration: LocalModelConfiguration.load())
  }

  static func withConfiguredLocalModel(
    _ discovered: [AgentModel]?, provider: AgentProvider,
    configuration: LocalModelConfiguration?
  ) -> [AgentModel]? {
    guard provider == .openAI, let local = configuration else {
      return discovered
    }
    // Configuration is stored independently of network discovery, which can
    // be slow, stale, or unavailable when the local server is offline. Always
    // expose the explicitly saved model in every bot picker immediately.
    var models = discovered ?? []
    for (index, modelID) in local.modelIDs.enumerated() {
      let model = AgentModel(
        id: OttoHarnessModelSelection.persistedID(provider: .local, modelID: modelID),
        displayName: "Local · \(modelID)")
      if !models.contains(where: { $0.id == model.id }) {
        models.insert(model, at: min(index, models.count))
      }
    }
    return models
  }

  /// Starts discovery unless a recent result exists or discovery is already running.
  /// Safe to call from every `onAppear`.
  @discardableResult
  func load(_ provider: AgentProvider, accountID: UUID? = nil, force: Bool = false)
    -> Task<Void, Never>?
  {
    let key = Key(provider: provider, accountID: accountID)
    guard Self.isDiscovered(provider), inFlight[key] == nil else { return nil }
    if !force, catalogs[key] != nil,
      let loadedAt = loadedAt[key], Date().timeIntervalSince(loadedAt) < refreshInterval
    {
      return nil
    }
    let token = UUID()
    inFlight[key] = token
    let resolver = accountEnvironment
    let discover = discover
    return Task { [weak self] in
      var environment: [String: String] = [:]
      if let accountID {
        // A missing resolver, deleted account or missing key must never query this Mac's login.
        do {
          guard let resolver, let resolved = try await resolver(accountID, provider) else {
            self?.finish([], key: key, token: token)
            return
          }
          environment = resolved
        } catch {
          self?.finish([], key: key, token: token)
          return
        }
      }
      let models = await discover(provider, environment)
      self?.finish(models ?? [], key: key, token: token)
    }
  }

  private func finish(_ models: [AgentModel], key: Key, token: UUID) {
    guard inFlight[key] == token else { return }
    catalogs[key] = models
    loadedAt[key] = Date()
    inFlight.removeValue(forKey: key)
  }

  private static func models(for provider: AgentProvider, environment: [String: String]) async
    -> [AgentModel]?
  {
    let models: [AgentModel]
    switch provider {
    case .codex: models = await CodexAdapter().discoverLiveModels(environment: environment) ?? []
    case .claudeCode:
      models = await ClaudeCodeAdapter().discoverModels(environment: environment) ?? []
    case .openAI: models = await OpenAIDirectAdapter().availableModels(environment: environment)
    case .cursor: models = await CursorAdapter().discoverModels(environment: environment) ?? []
    case .kimi: models = await KimiAdapter().discoverModels(environment: environment) ?? []
    case .openCode: models = await OpenCodeAdapter().discoverModels(environment: environment) ?? []
    case .pi: models = await PiAdapter().discoverModels(environment: environment) ?? []
    case .grok: models = await GrokAdapter().discoverModels(environment: environment) ?? []
    case .hermes, .shell: models = AgentModelCatalog.options(for: provider)
    }
    return models.isEmpty ? nil : models
  }
}
