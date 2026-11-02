import Foundation
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoServices
import SwiftUI

/// Whether Otto's own harness can start a session that chose no model. Unlike the CLI harnesses it
/// has no login of its own: it needs a vendor API key saved on this Mac or on an account, or a
/// local OpenAI-compatible server. Mirrors the launch fallback in `OpenAIDirectAdapter`.
enum OttoHarnessLaunchReadiness {
  @MainActor
  static func isReady(
    secrets: any SecretStore = makeDefaultSecretStore(),
    accounts: ProviderAccountStore?,
    localDefaults: UserDefaults = .standard
  ) async -> Bool {
    if LocalModelConfiguration.load(defaults: localDefaults) != nil { return true }
    for provider in OttoHarnessProvider.allCases where provider != .local {
      if let key = try? await secrets.value(for: provider.credentialKey),
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return true
      }
    }
    guard let accounts else { return false }
    for account in accounts.accounts {
      for key in ProviderAccountStore.harnessCredentialKeys {
        if await accounts.hasHarnessKey(accountID: account.id, credentialKey: key) { return true }
      }
    }
    return false
  }
}

/// Shown when Otto's harness is picked for a new session before any key or local server exists.
/// Saving either starts the session the person asked for.
struct OttoHarnessKeySetupSheet: View {
  let services: ApplicationServices
  /// Where keys are read and saved; tests pass an empty store.
  var secrets: any SecretStore = makeDefaultSecretStore()
  let cancel: () -> Void
  let ready: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Label("No API key added", systemImage: "key.slash")
            .font(.headline)
          Spacer()
          Button("Cancel", action: cancel)
            .keyboardShortcut(.cancelAction)
        }
        Text(
          "Otto's own harness talks to model providers directly, so it needs an API key for one of them, or a local OpenAI-compatible server such as Ollama or LM Studio. Save one below and your session starts straight away. Claude Code, Codex and the other agents use their own logins and don't need this."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(16)
      // Same colour as the sheet; the fill makes the header a drawn layer so offscreen
      // renders (snapshot tests) include it.
      .background(Color(nsColor: .windowBackgroundColor))
      Divider()
      ModelProviderSettingsView(
        secrets: secrets, initialProvider: .openAI, onKeySaved: check, onLocalSaved: check)
    }
    .frame(width: 625, height: 700)
    .onExitCommand(perform: cancel)
    .accessibilityIdentifier("harness-key-setup")
  }

  private func check() {
    Task {
      if await OttoHarnessLaunchReadiness.isReady(
        secrets: secrets, accounts: services.providerAccounts)
      {
        ready()
      }
    }
  }
}
