import AppKit
import OttoApplicationTools
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

struct CustomAgentCreationView: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var services: ApplicationServices
  @ObservedObject private var catalogStore = ProviderModelCatalogStore.shared
  let point: WorldPoint

  @State private var name = ""
  @State private var role = ""
  @State private var jobTitle = ""
  @State private var instructions = ""
  @State private var provider = AgentProvider.codex
  @State private var accountID: UUID?
  @State private var model = ""
  @State private var effort = ""
  @State private var executionStrategy = AgentExecutionStrategy.direct
  @State private var permissionMode = AgentPermissionMode.workspaceWrite
  @State private var isolatedWorktree = false
  @State private var firstPrompt = ""
  @State private var availability: [AgentProviderInfo] = []
  @State private var saving = false
  @State private var errorMessage: String?

  private var modelAccountID: UUID? { accountID ?? services.providerAccounts.defaultAccountID }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("CREATE CUSTOM AGENT")
        .font(.ottoMono(10, weight: .black))
        .tracking(2)
        .foregroundStyle(palette.signal)
      Text("Give a reusable teammate an identity, private instructions, and a harness.")
        .font(.ottoDisplay(18))
        .foregroundStyle(palette.paper)

      HStack(spacing: 10) {
        TextField("Agent name", text: $name)
          .textFieldStyle(.roundedBorder)
        TextField("Primary job", text: $jobTitle)
          .textFieldStyle(.roundedBorder)
      }
      TextField("Role (optional)", text: $role)
        .textFieldStyle(.roundedBorder)

      VStack(alignment: .leading, spacing: 7) {
        Text("SYSTEM PROMPT")
          .font(.ottoMono(8, weight: .black))
          .tracking(1.2)
          .foregroundStyle(palette.muted)
        TextEditor(text: $instructions)
          .font(.ottoMono(10.5))
          .scrollContentBackground(.hidden)
          .padding(8)
          .frame(minHeight: 150)
          .background(palette.ink.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.paper.opacity(0.1)))
        Text("Applied privately on every turn; never posted as user chat.")
          .font(.ottoMono(8))
          .foregroundStyle(palette.muted)
      }

      Picker("Harness", selection: $provider) {
        ForEach(AgentProvider.allCases.filter { $0 != .shell }, id: \.self) { provider in
          Text(providerLabel(provider)).tag(provider)
        }
      }
      .onChange(of: provider) { _, provider in
        catalogStore.load(provider, accountID: modelAccountID)
        alignSelections(for: provider)
      }
      if let info = availability.first(where: { $0.provider == provider }), !info.installed {
        // Say why a harness is greyed out, so "not installed" is never a dead end.
        Text(info.remediation ?? "Install it, sign in, then come back.")
          .font(.ottoMono(8))
          .foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("agent-harness-remediation")
      }

      BotCreationAccountPicker(accounts: services.providerAccounts, selection: $accountID)
        .onChange(of: accountID) { _, _ in
          model = ""
          effort = ""
        }

      if provider == .openAI {
        Text(
          "Otto owns the system prompt, tool loop, and local conversation memory. Choose the model provider below."
        )
        .font(.ottoMono(8))
        .foregroundStyle(palette.muted)
      }

      if !modelOptions.isEmpty {
        Picker("Model", selection: $model) {
          ForEach(modelOptions, id: \.id) { option in
            Text(option.displayName).tag(option.id)
          }
        }
      }
      if !effortOptions.isEmpty {
        Picker("Reasoning effort", selection: $effort) {
          Text("Provider default").tag("")
          ForEach(effortOptions, id: \.self) { level in
            Text(level.capitalized).tag(level)
          }
        }
      }
      Picker("Execution", selection: $executionStrategy) {
        ForEach(
          AgentExecutionStrategy.allCases.filter { $0.isSupported(by: provider) }, id: \.self
        ) { strategy in
          Text(executionLabel(strategy)).tag(strategy)
        }
      }
      Picker("Permissions", selection: $permissionMode) {
        ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
          Text(permissionLabel(mode)).tag(mode)
        }
      }
      Toggle("Use an isolated Git worktree", isOn: $isolatedWorktree)
        .toggleStyle(.ottoSwitch)
        .disabled(permissionMode == .readOnly)
        .onChange(of: permissionMode) { _, mode in
          if mode == .readOnly { isolatedWorktree = false }
        }

      TextField("First prompt (optional)", text: $firstPrompt)
        .textFieldStyle(.roundedBorder)

      if let errorMessage {
        Text(errorMessage).font(.ottoMono(9)).foregroundStyle(palette.red)
      }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button(saving ? "Creating…" : "Create & Open") { create() }
          .disabled(saving || !canCreate)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 560)
    .background(palette.surface)
    .task(id: catalogStore.request(for: provider, accountID: modelAccountID)) {
      await catalogStore.load(provider, accountID: modelAccountID)?.value
    }
    .task {
      availability = (try? await services.providerAvailability()) ?? []
      catalogStore.load(provider, accountID: modelAccountID)
      alignSelections(for: provider)
    }
    .onChange(of: model) { _, newModel in
      let efforts = AgentModelCatalog.effortLevels(for: provider, modelID: newModel)
      if !efforts.contains(effort) { effort = "" }
    }
  }

  private var modelOptions: [AgentModel] {
    catalogStore.catalog(for: provider, accountID: modelAccountID)
      ?? (ProviderModelCatalogStore.isDiscovered(provider)
        ? [] : AgentModelCatalog.options(for: provider))
  }
  private var effortOptions: [String] {
    AgentModelCatalog.effortLevels(for: provider, modelID: model)
  }

  private var canCreate: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && availability.first(where: { $0.provider == provider })?.installed == true
  }

  private func alignSelections(for provider: AgentProvider) {
    if !executionStrategy.isSupported(by: provider) { executionStrategy = .direct }
    let models =
      catalogStore.catalog(for: provider, accountID: modelAccountID)
      ?? (ProviderModelCatalogStore.isDiscovered(provider)
        ? [] : AgentModelCatalog.options(for: provider))
    if !models.contains(where: { $0.id == model }) { model = models.first?.id ?? "" }
    let efforts = AgentModelCatalog.effortLevels(for: provider, modelID: model)
    if !efforts.contains(effort) { effort = "" }
  }

  private func create() {
    saving = true
    errorMessage = nil
    Task {
      do {
        let trimmedJob = jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = try services.saveAgentProfile(
          AgentProfile(
            name: name,
            role: role,
            jobTitle: trimmedJob.isEmpty ? nil : trimmedJob,
            instructions: instructions,
            provider: provider,
            accountID: accountID,
            model: model.isEmpty ? nil : model,
            effort: effort.isEmpty ? nil : effort,
            permissionMode: permissionMode.rawValue,
            executionStrategy: executionStrategy,
            isolatedWorktree: isolatedWorktree
          ))
        _ = try await services.launchAgentProfile(
          profile,
          prompt: PromptSubmission.verbatimText(from: firstPrompt),
          at: point
        )
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        saving = false
      }
    }
  }

  private func providerLabel(_ provider: AgentProvider) -> String {
    let info = availability.first { $0.provider == provider }
    let name = provider == .openAI ? "Otto Harness" : provider.rawValue
    return info?.installed == true
      ? "\(name) · \(info?.version ?? "installed")"
      : "\(name) · not installed"
  }

  private func executionLabel(_ strategy: AgentExecutionStrategy) -> String {
    switch strategy {
    case .direct: "Direct"
    case .delegated: "Delegate to subagents"
    case .scriptedWorkflow: "Claude dynamic workflow"
    }
  }

  private func permissionLabel(_ mode: AgentPermissionMode) -> String {
    switch mode {
    case .readOnly: "Read only"
    case .workspaceWrite: "Ask to approve (workspace write)"
    case .unrestricted: "Bypass all permissions"
    }
  }
}
