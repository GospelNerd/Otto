import OttoModels
import OttoRuntime
import OttoSecurity
import SwiftUI

struct ModelProviderSettingsView: View {
  @State private var provider = OttoHarnessProvider.openAI
  @State private var apiKey = ""
  @State private var configured: Set<OttoHarnessProvider> = []
  @State private var localURL = LocalModelConfiguration.exampleURL
  @State private var localModel = ""
  @State private var hasLocalSettings = false
  /// Models the local server listed, or the ones saved earlier, and which of them are offered.
  @State private var localChoices: [String] = []
  @State private var chosenLocalModels: Set<String> = []
  @State private var isFetchingLocalModels = false
  @State private var message: String?
  @State private var isError = false
  /// Whether the bundled otto-openai-agent answers, so a person can tell a missing runtime from a
  /// missing key without reading logs.
  @State private var runtimeStatus: InstallationStatus?
  @State private var isCheckingRuntime = false
  private let secrets: any SecretStore
  /// Called after a vendor key is stored, so a sheet waiting on a key can carry on.
  private let onKeySaved: (() -> Void)?
  private let onLocalSaved: (() -> Void)?

  init(
    secrets: any SecretStore = makeDefaultSecretStore(),
    initialProvider: OttoHarnessProvider = .openAI,
    onKeySaved: (() -> Void)? = nil,
    onLocalSaved: (() -> Void)? = nil
  ) {
    self.secrets = secrets
    self._provider = State(initialValue: initialProvider)
    self.onKeySaved = onKeySaved
    self.onLocalSaved = onLocalSaved
  }

  var body: some View {
    Form {
      Section("Otto Harness runtime") {
        HStack(alignment: .top) {
          runtimeStatusLabel
          Spacer()
          Button(isCheckingRuntime ? "Checking…" : "Check again") {
            Task { await checkRuntime() }
          }
          .disabled(isCheckingRuntime)
        }
      }

      Section("Otto Harness model providers") {
        Picker("Configure provider", selection: $provider) {
          ForEach(OttoHarnessProvider.allCases) { candidate in
            Text(candidate.displayName).tag(candidate)
          }
        }
        .pickerStyle(.menu)
        .onChange(of: provider) { _, _ in
          // A partially entered secret must not follow the user to another provider.
          apiKey = ""
          message = nil
        }

        if provider == .local {
          TextField("API base URL (e.g. http://127.0.0.1:11434/v1)", text: $localURL)
            .textFieldStyle(.roundedBorder)
            .textContentType(.URL)
            .accessibilityIdentifier("local-model-url")
          HStack {
            TextField("Model ID (e.g. qwen3:8b)", text: $localModel)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("local-model-id")
            Button(isFetchingLocalModels ? "Fetching…" : "Fetch models") {
              Task { await fetchLocalModels() }
            }
            .disabled(localURL.isEmpty || isFetchingLocalModels)
            .help("List the models this server offers, such as every model in a LiteLLM proxy")
          }
          if !localChoices.isEmpty {
            localModelChoices
          }
          Button(
            chosenLocalModels.count > 1
              ? "Save endpoint and \(chosenLocalModels.count) models"
              : "Save local endpoint and model"
          ) { saveLocal() }
          .disabled(localURL.isEmpty || (localModel.isEmpty && chosenLocalModels.isEmpty))
          Text(
            "Connect to Ollama, LM Studio, llama.cpp or vLLM on this Mac or a private LAN. A key is optional. HTTP is allowed for private hosts, but keys sent over LAN HTTP are not encrypted; use HTTPS when possible. The server must support OpenAI Chat Completions."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          if hasLocalSettings {
            Label("Local endpoint configured", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
        }

        SecureField(
          provider == .local ? "Optional local server API key" : "\(provider.displayName) API key",
          text: $apiKey
        )
        .textFieldStyle(.roundedBorder)
        HStack {
          Button("Save securely") { Task { await save() } }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Remove key", role: .destructive) { Task { await remove() } }
            .disabled(!configured.contains(provider))
          Spacer()
          Label(
            configured.contains(provider)
              ? "Key stored"
              : (provider == .local ? "No key (optional)" : "No key stored"),
            systemImage: configured.contains(provider)
              ? "checkmark.shield.fill" : "key.slash"
          )
          .foregroundStyle(configured.contains(provider) ? .green : .secondary)
        }
        Text(
          "API keys stay in Otto's secure credential store. OpenAI and xAI keys are shared with Voice settings."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if let message {
          Text(message).foregroundStyle(isError ? Color.red : Color.secondary)
        }
      }

      Section("Available in Otto Harness") {
        ForEach(OttoHarnessProvider.allCases) { candidate in
          let models = AgentModelCatalog.options(for: .openAI).filter {
            OttoHarnessModelSelection.resolve($0.id).provider == candidate
          }
          HStack(alignment: .top) {
            Image(
              systemName:
                configured.contains(candidate) || (candidate == .local && hasLocalSettings)
                ? "checkmark.circle.fill" : "circle"
            )
            .foregroundStyle(
              configured.contains(candidate) || (candidate == .local && hasLocalSettings)
                ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
              Text(candidate.displayName)
              Text(
                candidate == .local
                  ? (LocalModelConfiguration.load()?.modelIDs.joined(separator: ", ")
                    ?? "Configure an endpoint and model above")
                  : models.map(\.displayName).joined(separator: ", ")
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .task { await refresh() }
    .task { await checkRuntime() }
  }

  @ViewBuilder
  private var runtimeStatusLabel: some View {
    switch runtimeStatus {
    case .installed(let path, let version):
      VStack(alignment: .leading, spacing: 3) {
        Label("Runtime ready · \(version)", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      .accessibilityIdentifier("harness-runtime-ready")
    case .missing(let remediation):
      VStack(alignment: .leading, spacing: 3) {
        Label("Runtime unavailable", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
        Text(remediation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      .accessibilityIdentifier("harness-runtime-missing")
    case nil:
      Label("Checking the bundled runtime…", systemImage: "hourglass")
        .foregroundStyle(.secondary)
    }
  }

  private func checkRuntime() async {
    isCheckingRuntime = true
    defer { isCheckingRuntime = false }
    runtimeStatus = await OpenAIDirectAdapter().detectInstallation()
  }

  private var localModelChoices: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Offer these models in Otto Harness")
          .font(.caption.weight(.semibold))
        Spacer()
        Button("All") { chosenLocalModels = Set(localChoices) }
          .buttonStyle(.link)
        Button("None") { chosenLocalModels = [] }
          .buttonStyle(.link)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(localChoices, id: \.self) { model in
            Toggle(
              model,
              isOn: Binding(
                get: { chosenLocalModels.contains(model) },
                set: { isOn in
                  if isOn {
                    chosenLocalModels.insert(model)
                  } else {
                    chosenLocalModels.remove(model)
                  }
                })
            )
            .toggleStyle(.checkbox)
            .font(.callout)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 180)
      Text(
        "The Model ID above is the default for new bots; every ticked model appears in the model menu."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  /// Asks the server for its model list with the address in the field, before it is saved, and
  /// with the key typed below, or the stored one only when the address is the saved server's.
  private func fetchLocalModels() async {
    isFetchingLocalModels = true
    defer { isFetchingLocalModels = false }
    do {
      let probe = try LocalModelConfiguration(baseURL: localURL, modelID: "probe")
      let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      let key: String
      if !typed.isEmpty {
        key = typed
      } else if let saved = LocalModelConfiguration.load(),
        Self.sameServer(saved.baseURL, probe.baseURL)
      {
        key = try await secrets.value(for: OttoHarnessProvider.local.credentialKey) ?? ""
      } else {
        // The stored key belongs to the saved server; never hand it to a newly typed address.
        key = ""
      }
      guard
        let models = await OpenAIDirectAdapter.discoverDirectModels(
          provider: .local, apiKey: key, local: probe)
      else {
        message =
          "Couldn't list models at \(probe.modelsURL.absoluteString). Check the address, and save the server's API key below if it needs one."
        isError = true
        return
      }
      let listed = models.map { OttoHarnessModelSelection.resolve($0.id).modelID }
      localChoices = Array(Set(listed).union(chosenLocalModels)).sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
      }
      if localModel.isEmpty, let first = listed.first { localModel = first }
      if chosenLocalModels.isEmpty, !localModel.isEmpty { chosenLocalModels = [localModel] }
      message =
        "Found \(listed.count) model\(listed.count == 1 ? "" : "s"). Tick the ones to offer, then save."
      isError = false
    } catch {
      message = error.localizedDescription
      isError = true
    }
  }

  private static func sameServer(_ first: URL, _ second: URL) -> Bool {
    func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
    return first.scheme?.lowercased() == second.scheme?.lowercased()
      && first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
  }

  private func save() async {
    do {
      try await secrets.set(
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.credentialKey)
      apiKey = ""
      message = "\(provider.displayName) key saved."
      isError = false
      await refresh(clearMessage: false)
      onKeySaved?()
    } catch {
      message = error.localizedDescription
      isError = true
    }
  }

  private func saveLocal() {
    do {
      let chosen = localChoices.filter(chosenLocalModels.contains)
      let primary = localModel.trimmingCharacters(in: .whitespacesAndNewlines)
      let configuration = try LocalModelConfiguration(
        baseURL: localURL, modelID: primary.isEmpty ? chosen.first ?? "" : primary,
        additionalModelIDs: chosen)
      configuration.save()
      localURL = configuration.baseURL.absoluteString
      localModel = configuration.modelID
      chosenLocalModels = Set(configuration.modelIDs)
      localChoices = Array(Set(localChoices).union(configuration.modelIDs)).sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
      }
      hasLocalSettings = true
      ProviderModelCatalogStore.shared.invalidate()
      onLocalSaved?()
      let count = configuration.modelIDs.count
      message =
        count == 1
        ? "Local model saved. It is now available under Otto Harness → Model."
        : "\(count) local models saved. They are now available under Otto Harness → Model."
      isError = false
    } catch {
      message = error.localizedDescription
      isError = true
    }
  }

  private func remove() async {
    do {
      try await secrets.delete(provider.credentialKey)
      apiKey = ""
      message = "\(provider.displayName) key removed."
      isError = false
      await refresh(clearMessage: false)
    } catch {
      message = error.localizedDescription
      isError = true
    }
  }

  private func refresh(clearMessage: Bool = true) async {
    do {
      if let local = LocalModelConfiguration.load() {
        localURL = local.baseURL.absoluteString
        localModel = local.modelID
        hasLocalSettings = true
        if localChoices.isEmpty {
          localChoices = local.modelIDs
          chosenLocalModels = Set(local.modelIDs)
        }
      }
      var result: Set<OttoHarnessProvider> = []
      for candidate in OttoHarnessProvider.allCases {
        if try await !(secrets.value(for: candidate.credentialKey) ?? "").isEmpty {
          result.insert(candidate)
        }
      }
      configured = result
      if clearMessage { message = nil }
    } catch {
      message = error.localizedDescription
      isError = true
    }
  }
}
