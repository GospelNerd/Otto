import Foundation
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoServices
import Testing

@testable import OttoApp

@Suite("Provider model picker catalog")
struct ProviderModelCatalogTests {
  @Test("One-off sessions offer every agent runtime, Otto's harness under its own name")
  func oneOffSessionProviders() {
    #expect(SessionLaunchProviderCatalog.providers.contains(.codex))
    #expect(SessionLaunchProviderCatalog.providers.contains(.openAI))
    #expect(!SessionLaunchProviderCatalog.providers.contains(.shell))
    #expect(SessionLaunchProviderCatalog.title(for: .openAI) == "Otto")
    #expect(SessionLaunchProviderCatalog.title(for: .codex) == "Codex")
  }

  @Test("Otto's harness is ready to start once any vendor key, account key or local server exists")
  @MainActor
  func harnessLaunchReadiness() async throws {
    let suite = "otto.tests.harness-readiness.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appending(path: "readiness-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = InMemorySecretStore()
    let accounts = ProviderAccountStore(
      rootDirectory: root, userHome: root.appending(path: "home"), secrets: secrets)
    func ready() async -> Bool {
      await OttoHarnessLaunchReadiness.isReady(
        secrets: secrets, accounts: accounts, localDefaults: defaults)
    }

    #expect(await !ready())

    try await secrets.set("sk-mac", for: OttoHarnessProvider.anthropic.credentialKey)
    #expect(await ready())
    try await secrets.delete(OttoHarnessProvider.anthropic.credentialKey)
    #expect(await !ready())

    let work = try accounts.create(name: "Work")
    try await accounts.setHarnessKey(
      "sk-account", accountID: work.id, credentialKey: OttoHarnessProvider.groq.credentialKey)
    #expect(await ready())
    try await accounts.setHarnessKey(
      nil, accountID: work.id, credentialKey: OttoHarnessProvider.groq.credentialKey)
    #expect(await !ready())

    try LocalModelConfiguration(baseURL: "http://127.0.0.1:11434/v1", modelID: "qwen3:8b")
      .save(defaults: defaults)
    #expect(await ready())
  }

  @Test("Every account-aware provider is loaded through the shared catalog")
  @MainActor
  func discoveredProviders() {
    for provider in [
      AgentProvider.claudeCode, .codex, .openAI, .cursor, .kimi, .openCode, .grok,
    ] {
      #expect(ProviderModelCatalogStore.isDiscovered(provider))
    }
    #expect(!ProviderModelCatalogStore.isDiscovered(.hermes))
  }

  @Test("Saved OpenAI-compatible local models appear immediately in the bot picker")
  @MainActor
  func localModelIsVisibleWithoutDiscovery() throws {
    let config = try LocalModelConfiguration(
      baseURL: "http://127.0.0.1:11434/v1", modelID: "qwen3:8b")
    let direct = ProviderModelCatalogStore.withConfiguredLocalModel(
      nil, provider: .openAI, configuration: config)
    #expect(direct?.first?.id == "local/qwen3:8b")
    #expect(direct?.first?.displayName == "Local · qwen3:8b")

    let existing = [AgentModel(id: "openai/gpt-5.6", displayName: "GPT")]
    let combined = ProviderModelCatalogStore.withConfiguredLocalModel(
      existing, provider: .openAI, configuration: config)
    #expect(combined?.count == 2)
    #expect(combined?.first?.id == "local/qwen3:8b")
    let deduped = ProviderModelCatalogStore.withConfiguredLocalModel(
      combined, provider: .openAI, configuration: config)
    #expect(deduped?.count == 2)
    #expect(
      ProviderModelCatalogStore.withConfiguredLocalModel(
        nil, provider: .codex, configuration: config) == nil)
  }

  @Test("Every saved local model appears in the picker, the default first")
  @MainActor
  func severalLocalModelsAreVisible() throws {
    let config = try LocalModelConfiguration(
      baseURL: "http://gillai:4000/v1", modelID: "qwen3.8-flash",
      additionalModelIDs: ["gpt-oss-20b"])
    let existing = [AgentModel(id: "openai/gpt-5.6", displayName: "GPT")]
    let models = ProviderModelCatalogStore.withConfiguredLocalModel(
      existing, provider: .openAI, configuration: config)
    #expect(models?.map(\.id) == ["local/qwen3.8-flash", "local/gpt-oss-20b", "openai/gpt-5.6"])
  }
}

@Suite("Account catalog isolation")
@MainActor
struct AccountCatalogIsolationTests {
  @Test(arguments: [AgentProvider.codex, .claudeCode])
  func switchingAccountsAndRefreshing(provider: AgentProvider) async {
    let store = ProviderModelCatalogStore()
    let work = UUID()
    let personal = UUID()
    store.accountEnvironment = { id, _ in ["CODEX_HOME": id == work ? "work" : "personal"] }
    var personalModel = "personal-model"
    store.discover = { _, env in
      [
        AgentModel(
          id: env["CODEX_HOME"] == "work" ? "work-model" : personalModel, displayName: "Model")
      ]
    }
    await store.load(provider, accountID: work)?.value
    await store.load(provider, accountID: personal)?.value
    #expect(store.catalog(for: provider, accountID: work)?.first?.id == "work-model")
    #expect(store.catalog(for: provider, accountID: personal)?.first?.id == "personal-model")
    personalModel = "new-personal-model"
    await store.load(provider, accountID: personal, force: true)?.value
    #expect(store.catalog(for: provider, accountID: personal)?.first?.id == "new-personal-model")
    #expect(store.catalog(for: provider, accountID: work)?.first?.id == "work-model")
  }

  @Test func unresolvedAccountNeverUsesMacLogin() async {
    let store = ProviderModelCatalogStore()
    var calls = 0
    store.discover = { _, _ in
      calls += 1
      return []
    }
    await store.load(.codex, accountID: UUID())?.value
    store.accountEnvironment = { _, _ in nil }
    await store.load(.codex, accountID: UUID())?.value
    store.accountEnvironment = { _, _ in throw CocoaError(.fileReadNoPermission) }
    await store.load(.codex, accountID: UUID())?.value
    #expect(calls == 0)
    await store.load(.codex)?.value
    #expect(calls == 1)
  }

  @Test func changingInheritedAccountsInvalidatesCatalogs() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "catalog-defaults-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = ProviderAccountStore(
      rootDirectory: root, userHome: root.appending(path: "home"), secrets: InMemorySecretStore())
    let work = try accounts.create(name: "Work")
    let personal = try accounts.create(name: "Personal")
    try accounts.setDefault(work.id)
    let projects = ConversationProjectStore(workspacePath: root.path)
    let store = ProviderModelCatalogStore()
    store.configure(accounts: accounts, projects: projects)
    store.discover = { _, _ in [AgentModel(id: "cached", displayName: "Cached")] }
    await store.load(.codex, accountID: work.id)?.value
    let beforeDefault = store.revision
    try accounts.setDefault(personal.id)
    for _ in 0..<100 where store.revision == beforeDefault { await Task.yield() }
    #expect(store.revision > beforeDefault)
    #expect(store.catalog(for: .codex, accountID: work.id) == nil)
    let beforeProject = store.revision
    let project = try #require(projects.projects.first)
    try projects.setDefaultAccount(projectID: project.id, accountID: work.id)
    for _ in 0..<100 where store.revision == beforeProject { await Task.yield() }
    #expect(store.revision > beforeProject)
  }

  @Test func invalidationRejectsOldDiscovery() async {
    let store = ProviderModelCatalogStore()
    var continuation: CheckedContinuation<[AgentModel]?, Never>?
    store.discover = { _, _ in await withCheckedContinuation { continuation = $0 } }
    let pending = store.load(.codex)
    while continuation == nil { await Task.yield() }
    let oldRequest = store.request(for: .codex, accountID: nil)
    store.invalidate()
    #expect(oldRequest != store.request(for: .codex, accountID: nil))
    continuation?.resume(returning: [AgentModel(id: "stale", displayName: "Stale")])
    await pending?.value
    #expect(store.catalog(for: .codex) == nil)
    store.discover = { _, _ in [AgentModel(id: "fresh", displayName: "Fresh")] }
    await store.load(.codex)?.value
    #expect(store.catalog(for: .codex)?.first?.id == "fresh")
  }
}
