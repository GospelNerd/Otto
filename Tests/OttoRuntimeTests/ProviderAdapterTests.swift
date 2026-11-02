import Foundation
import OttoModels
import OttoRuntime
import Testing

@Suite("Provider adapters")
struct ProviderAdapterTests {
  @Test("Execution strategies route to provider-native delegation and Claude workflows")
  func executionStrategies() async throws {
    let claudeStub = try stubProvider(named: "claude", version: "2.1.219")
    let codexStub = try stubProvider(named: "codex", version: "0.116.0")
    defer {
      try? FileManager.default.removeItem(at: claudeStub.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: codexStub.deletingLastPathComponent())
    }

    let workflow = try await ClaudeCodeAdapter(executablePath: claudeStub.path).buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Audit the routes",
        executionStrategy: .scriptedWorkflow
      ))
    let effortIndex = try #require(workflow.arguments.firstIndex(of: "--effort"))
    #expect(workflow.arguments[effortIndex + 1] == "ultracode")
    #expect(workflow.arguments.last?.contains("dynamic workflow runtime") == true)

    let delegated = try await CodexAdapter(executablePath: codexStub.path).buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Inspect auth and tests",
        executionStrategy: .delegated
      ))
    #expect(delegated.arguments.last?.contains("native Codex subagents") == true)

    await #expect(throws: RuntimeError.self) {
      _ = try await CodexAdapter(executablePath: codexStub.path).buildLaunchSpec(
        AgentLaunchRequest(
          workspacePath: "/tmp",
          prompt: "Run a workflow",
          executionStrategy: .scriptedWorkflow
        ))
    }
  }

  @Test("Otto Harness launches carry authoritative system instructions on new and resumed turns")
  func ottoHarnessSystemInstructions() async throws {
    let stub = try stubProvider(named: "otto-openai-agent", version: "1.0.0")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let adapter = OpenAIDirectAdapter(
      executablePath: stub.path,
      credentialProvider: { provider in "test-\(provider.rawValue)-key" })

    let selections: [(persisted: String, backend: String, model: String)] = [
      ("openai/gpt-5.6", "openai", "gpt-5.6"),
      ("anthropic/claude-sonnet-5", "anthropic", "claude-sonnet-5"),
      ("xai/grok-4.6", "xai", "grok-4.6"),
      ("moonshot/kimi-k2.5", "moonshot", "kimi-k2.5"),
    ]
    for selection in selections {
      for sessionID in [nil, "muse_existing"] as [String?] {
        let spec = try await adapter.buildLaunchSpec(
          AgentLaunchRequest(
            workspacePath: "/tmp",
            prompt: "What is your job?",
            model: selection.persisted,
            resumeSessionID: sessionID,
            profileInstructions: "You are Test. Your main job is in-depth research.",
            memoryBootstrap: "Remember verified project decisions."
          ))
        let backendIndex = try #require(spec.arguments.firstIndex(of: "--backend"))
        #expect(spec.arguments[backendIndex + 1] == selection.backend)
        let modelIndex = try #require(spec.arguments.firstIndex(of: "--model"))
        #expect(spec.arguments[modelIndex + 1] == selection.model)
        let systemIndex = try #require(spec.arguments.firstIndex(of: "--system-base64"))
        let systemData = try #require(Data(base64Encoded: spec.arguments[systemIndex + 1]))
        let system = String(decoding: systemData, as: UTF8.self)
        #expect(system.contains("BOT INSTRUCTIONS (authoritative):"))
        #expect(system.contains("You are Test. Your main job is in-depth research."))
        #expect(system.contains("Remember verified project decisions."))
        #expect(system.contains("Visual explanations are the default"))
        #expect(system.contains("<!-- otto:details -->"))
        #expect(system.contains("otto-email"))
        #expect(system.contains("otto-inbox"))
        #expect(system.contains("Simple facts and confirmations"))
        #expect(
          spec.arguments[spec.arguments.firstIndex(of: "--prompt-base64")! + 1]
            == Data("What is your job?".utf8).base64EncodedString())
        if let sessionID {
          let resumeIndex = try #require(spec.arguments.firstIndex(of: "--session-id"))
          #expect(spec.arguments[resumeIndex + 1] == sessionID)
        }
        #expect(spec.environment["OTTO_MODEL_API_KEY"] == "test-\(selection.backend)-key")
      }
    }
  }

  @Test("A bot with no model uses the local server when no OpenAI key is stored")
  func ottoHarnessDefaultsToLocalWithoutOpenAIKey() async throws {
    let stub = try stubProvider(named: "otto-openai-agent", version: "1.0.0")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let suite = "otto.tests.local-harness.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try LocalModelConfiguration(baseURL: "http://gillai:4000/v1", modelID: "qwen3.8-flash-next")
      .save(defaults: defaults)

    let onlyLocal = OpenAIDirectAdapter(
      executablePath: stub.path,
      credentialProvider: { $0 == .local ? "local-key" : nil }, localDefaultsSuite: suite)
    let spec = try await onlyLocal.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: "/tmp", prompt: "hi", model: nil))
    #expect(spec.arguments[spec.arguments.firstIndex(of: "--backend")! + 1] == "local")
    #expect(spec.arguments[spec.arguments.firstIndex(of: "--model")! + 1] == "qwen3.8-flash-next")
    #expect(spec.environment["OTTO_MODEL_API_KEY"] == "local-key")
    #expect(spec.environment["OTTO_MODEL_BASE_URL"] == "http://gillai:4000/v1")

    // With an OpenAI key, or an explicit model, the choice is left alone.
    let withOpenAI = OpenAIDirectAdapter(
      executablePath: stub.path, credentialProvider: { _ in "key" }, localDefaultsSuite: suite)
    let openAISpec = try await withOpenAI.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: "/tmp", prompt: "hi", model: nil))
    #expect(openAISpec.arguments[openAISpec.arguments.firstIndex(of: "--backend")! + 1] == "openai")
    await #expect(throws: RuntimeError.self) {
      _ = try await onlyLocal.buildLaunchSpec(
        AgentLaunchRequest(workspacePath: "/tmp", prompt: "hi", model: "openai/gpt-5.6"))
    }
  }

  @Test("A bot with no model uses the first hosted vendor that has a stored key")
  func ottoHarnessDefaultsToFirstKeyedVendor() async throws {
    let stub = try stubProvider(named: "otto-openai-agent", version: "1.0.0")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let suite = "otto.tests.keyed-harness.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    func adapter(keys: [OttoHarnessProvider: String]) -> OpenAIDirectAdapter {
      OpenAIDirectAdapter(
        executablePath: stub.path, credentialProvider: { keys[$0] }, localDefaultsSuite: suite)
    }
    func launch(
      _ adapter: OpenAIDirectAdapter, account: AgentAccountLaunch? = nil
    ) async throws -> (backend: String, model: String, key: String?) {
      var request = AgentLaunchRequest(workspacePath: "/tmp", prompt: "hi", model: nil)
      request.account = account
      let spec = try await adapter.buildLaunchSpec(request)
      return (
        spec.arguments[spec.arguments.firstIndex(of: "--backend")! + 1],
        spec.arguments[spec.arguments.firstIndex(of: "--model")! + 1],
        spec.environment["OTTO_MODEL_API_KEY"]
      )
    }

    // The reporter's Mac: only an OpenRouter key, nothing chosen on the bot.
    let onlyOpenRouter = try await launch(adapter(keys: [.openRouter: "router-key"]))
    #expect(onlyOpenRouter.backend == "openrouter")
    #expect(onlyOpenRouter.model == "openrouter/auto")
    #expect(onlyOpenRouter.key == "router-key")

    // OpenAI still comes first when it is set up, and the fixed order decides between others.
    let both = try await launch(adapter(keys: [.openRouter: "router-key", .openAI: "openai-key"]))
    #expect(both.backend == "openai")
    #expect(both.key == "openai-key")
    let later = try await launch(adapter(keys: [.moonshot: "moon-key", .gemini: "gemini-key"]))
    #expect(later.backend == "gemini")
    #expect(later.key == "gemini-key")

    // A Mac set up for a local server keeps using it: a stray Gemini key must not start billing.
    try LocalModelConfiguration(baseURL: "http://127.0.0.1:11434/v1", modelID: "qwen3:8b")
      .save(defaults: try #require(UserDefaults(suiteName: suite)))
    let localWins = try await launch(adapter(keys: [.gemini: "gemini-key"]))
    #expect(localWins.backend == "local")
    #expect(localWins.model == "qwen3:8b")
    #expect(localWins.key == nil || localWins.key == "")
    // ...but OpenAI still comes first even with a local server configured.
    let openAIOverLocal = try await launch(adapter(keys: [.gemini: "g", .openAI: "openai-key"]))
    #expect(openAIOverLocal.backend == "openai")
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)

    // An account's own key counts the same way as a Mac-wide one.
    let account = AgentAccountLaunch(
      accountID: UUID(), accountName: "Work", harnessCredentials: ["deepseek.api-key": "acct-key"])
    let fromAccount = try await launch(adapter(keys: [:]), account: account)
    #expect(fromAccount.backend == "deepseek")
    #expect(fromAccount.key == "acct-key")

    // Choosing a model explicitly keeps the old, strict behaviour.
    await #expect(throws: RuntimeError.self) {
      _ = try await adapter(keys: [.openRouter: "router-key"]).buildLaunchSpec(
        AgentLaunchRequest(workspacePath: "/tmp", prompt: "hi", model: "openai/gpt-5.6"))
    }
  }

  @Test("With nothing configured, the launch error says where keys and local servers live")
  func ottoHarnessNothingConfiguredMessage() async throws {
    let stub = try stubProvider(named: "otto-openai-agent", version: "1.0.0")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let suite = "otto.tests.empty-harness.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let adapter = OpenAIDirectAdapter(
      executablePath: stub.path, credentialProvider: { _ in nil }, localDefaultsSuite: suite)
    do {
      _ = try await adapter.buildLaunchSpec(
        AgentLaunchRequest(workspacePath: "/tmp", prompt: "hi", model: nil))
      Issue.record("A launch with no provider configured must fail")
    } catch let error as RuntimeError {
      let message = error.localizedDescription
      #expect(message.contains("Otto Settings → Models"))
      for vendor in OttoHarnessProvider.keyedFallbackOrder {
        #expect(message.contains(vendor.displayName), "\(vendor.displayName) missing from message")
      }
      #expect(message.contains("local OpenAI-compatible server"))
    }

    // A bot still pointing at a local server that was removed says so, instead of a generic
    // missing-settings line.
    do {
      _ = try await adapter.buildLaunchSpec(
        AgentLaunchRequest(workspacePath: "/tmp", prompt: "hi", model: "local/auto/best-coding"))
      Issue.record("A removed local server must fail the launch")
    } catch let error as RuntimeError {
      #expect(error.localizedDescription.contains("no longer configured"))
    }
  }

  @Test("A bundled runtime that fails its version probe is reported missing with its path")
  func ottoHarnessRuntimeProbeFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-harness-probe-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let broken = directory.appending(path: "otto-openai-agent")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: broken)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)

    let status = await OpenAIDirectAdapter(
      executablePath: broken.path, credentialProvider: { _ in nil }
    ).detectInstallation()
    guard case .missing(let remediation) = status else {
      Issue.record("A runtime exiting 1 on --version must be missing, got \(status)")
      return
    }
    #expect(remediation.contains(broken.path))
    #expect(remediation.contains("Reinstall Otto"))
    #expect(remediation.contains("sessions are kept"))

    // A missing file names where the runtime was expected.
    let absent = directory.appending(path: "absent-agent").path
    let absentStatus = await OpenAIDirectAdapter(
      executablePath: absent, credentialProvider: { _ in nil }
    ).detectInstallation()
    guard case .missing(let absentRemediation) = absentStatus else {
      Issue.record("An absent runtime must be missing")
      return
    }
    #expect(absentRemediation.contains(absent))

    // And a working runtime is found, path and version included.
    let working = try stubProvider(named: "otto-openai-agent", version: "3.0.0")
    defer { try? FileManager.default.removeItem(at: working.deletingLastPathComponent()) }
    let installed = await OpenAIDirectAdapter(
      executablePath: working.path, credentialProvider: { _ in nil }
    ).detectInstallation()
    #expect(installed == .installed(path: working.path, version: "otto-openai-agent 3.0.0"))
  }

  @Test("Otto Harness resolves legacy OpenAI ids and provider-prefixed model ids")
  func ottoHarnessModelRouting() {
    #expect(
      OttoHarnessModelSelection.resolve("gpt-5.6")
        == OttoHarnessModelSelection(provider: .openAI, modelID: "gpt-5.6"))
    #expect(
      OttoHarnessModelSelection.resolve("anthropic/claude-opus-5")
        == OttoHarnessModelSelection(provider: .anthropic, modelID: "claude-opus-5"))
    #expect(
      OttoHarnessModelSelection.resolve("moonshot/kimi-k2.5")
        == OttoHarnessModelSelection(provider: .moonshot, modelID: "kimi-k2.5"))
  }

  @Test("Claude workflow strategy rejects provider versions without workflow support")
  func workflowVersionGate() async throws {
    let claudeStub = try stubProvider(named: "claude", version: "2.1.153")
    defer { try? FileManager.default.removeItem(at: claudeStub.deletingLastPathComponent()) }
    await #expect(throws: RuntimeError.self) {
      _ = try await ClaudeCodeAdapter(executablePath: claudeStub.path).buildLaunchSpec(
        AgentLaunchRequest(
          workspacePath: "/tmp",
          prompt: "Audit",
          executionStrategy: .scriptedWorkflow
        ))
    }
  }

  @Test("Installed providers expose versions and safe launch specifications")
  func installedProviders() async throws {
    let workspace = FileManager.default.currentDirectoryPath
    let claude = ClaudeCodeAdapter()
    let codex = CodexAdapter()

    switch await claude.detectInstallation() {
    case .installed(let path, let version):
      #expect(path.hasSuffix("claude"))
      #expect(version.localizedCaseInsensitiveContains("claude"))
      let launch = try await claude.buildLaunchSpec(
        AgentLaunchRequest(
          workspacePath: workspace,
          prompt: "Summarize the directory without editing it.",
          model: "sonnet",
          permissionMode: .readOnly
        ))
      #expect(launch.arguments.contains("plan"))
      #expect(launch.arguments.contains("--print"))
      #expect(launch.arguments.contains("stream-json"))
      // Headless runs must drop the built-in question tool so Claude asks through the otto
      // agent.ask_user tool, which renders as choice buttons in the conversation.
      #expect(launch.arguments.contains("--disallowed-tools"))
      #expect(launch.arguments.contains("AskUserQuestion"))
      let resumed = try await claude.buildLaunchSpec(
        AgentLaunchRequest(
          workspacePath: workspace,
          prompt: "Continue.",
          permissionMode: .readOnly,
          resumeSessionID: "claude-session"
        ))
      #expect(resumed.arguments.contains("--resume"))
      #expect(resumed.arguments.contains("claude-session"))
    case .missing(let remediation):
      #expect(!remediation.isEmpty)
    }

    switch await codex.detectInstallation() {
    case .installed(let path, let version):
      #expect(path.hasSuffix("codex"))
      #expect(version.localizedCaseInsensitiveContains("codex"))
      let launch = try await codex.buildLaunchSpec(
        AgentLaunchRequest(
          workspacePath: workspace,
          prompt: "Summarize the directory without editing it.",
          effort: "medium",
          permissionMode: .readOnly
        ))
      #expect(launch.arguments.contains("read-only"))
      #expect(launch.arguments.contains("--json"))
      #expect(launch.arguments.contains("--skip-git-repo-check"))
      let interactive = try await codex.buildLaunchSpec(
        AgentLaunchRequest(
          workspacePath: workspace,
          effort: "high",
          permissionMode: .workspaceWrite
        ))
      #expect(!interactive.arguments.contains("exec"))
      #expect(interactive.arguments.contains("workspace-write"))
      #expect(interactive.arguments.contains("model_reasoning_effort=high"))
      let resumed = try await codex.buildLaunchSpec(
        AgentLaunchRequest(
          workspacePath: workspace,
          prompt: "Continue.",
          effort: "high",
          resumeSessionID: "codex-session"
        ))
      #expect(resumed.arguments.starts(with: ["exec", "resume", "--json"]))
      #expect(resumed.arguments.contains("--skip-git-repo-check"))
      #expect(resumed.arguments.contains("sandbox_mode=\"workspace-write\""))
      #expect(resumed.arguments.contains("codex-session"))
    case .missing(let remediation):
      #expect(!remediation.isEmpty)
    }

    // Cursor's catalog is read from the CLI at runtime. `cursor-agent models` renders an
    // interactive view and never exits under a PTY, so this also guards the pipe-based capture
    // path staying in place — on a PTY it would hang rather than fail.
    let cursor = CursorAdapter()
    if case .installed = await cursor.detectInstallation() {
      let models = await cursor.availableModels()
      #expect(models.contains { $0.id == "auto" })
      #expect(!models.contains { $0.displayName.contains("Available models") })
      if await cursor.discoverModels() != nil {
        #expect(models.count > AgentModelCatalog.options(for: .cursor).count)
      } else {
        // Installation and account authentication are separate. A logged-out CLI must fall back
        // to the safe static catalog rather than making an environment-dependent test fail.
        #expect(models == AgentModelCatalog.options(for: .cursor))
      }
    }

    // OpenCode installs outside PATH for a LaunchServices-started app, so detection has to find
    // it at the installer's own directory. Tolerates absence so the suite still runs elsewhere.
    switch await OpenCodeAdapter().detectInstallation() {
    case .installed(let path, let version):
      #expect(path.hasSuffix("opencode"))
      #expect(
        ProviderCompatibilityPolicy.evaluate(provider: .openCode, reportedVersion: version)
          .state != .unsupported)
    case .missing(let remediation):
      #expect(remediation.contains("opencode.ai/install"))
    }
  }

  @Test("LaunchServices fallback paths find user-installed CLIs without PATH")
  func launchServicesFallbackPaths() throws {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "otto-executable-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let executable = bin.appending(path: "claude")
    try Data("#!/bin/sh\\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)

    #expect(
      ExecutableLocator.find("claude", environment: [:], homeDirectory: home.path)
        == executable.path)
  }

  @Test("Interactive reopen resumes the persisted provider session")
  func interactiveResumeArguments() async throws {
    let claudeStub = try stubProvider(named: "claude")
    let codexStub = try stubProvider(named: "codex")
    defer {
      try? FileManager.default.removeItem(at: claudeStub.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: codexStub.deletingLastPathComponent())
    }

    let claude = try await ClaudeCodeAdapter(executablePath: claudeStub.path).buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        permissionMode: .workspaceWrite,
        resumeSessionID: "claude-persisted-session"
      ))
    #expect(!claude.arguments.contains("--print"))
    #expect(claude.arguments.contains("--resume"))
    #expect(claude.arguments.contains("claude-persisted-session"))

    let codex = try await CodexAdapter(executablePath: codexStub.path).buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        permissionMode: .readOnly,
        resumeSessionID: "codex-persisted-session"
      ))
    #expect(codex.arguments.first == "resume")
    #expect(!codex.arguments.contains("exec"))
    #expect(codex.arguments.contains("read-only"))
    #expect(codex.arguments.contains("codex-persisted-session"))
    #expect(codex.inheritedEnvironmentPrefixesToRemove == ["CODEX_"])
  }

  @Test("Launch environment can isolate a child provider from its parent harness")
  func inheritedProviderEnvironmentIsScrubbed() {
    let spec = ProcessLaunchSpec(
      executable: "/usr/bin/env",
      environment: ["CODEX_EXPLICIT": "restored", "OTTO_NODE_ID": "node-1"],
      inheritedEnvironmentPrefixesToRemove: ["CODEX_"],
      workingDirectory: "/tmp"
    )
    let resolved = spec.resolvedEnvironment(
      inheriting: [
        "CODEX_THREAD_ID": "parent-thread",
        "CODEX_SHELL": "1",
        "PATH": "/usr/bin",
      ])

    #expect(resolved["CODEX_THREAD_ID"] == nil)
    #expect(resolved["CODEX_SHELL"] == nil)
    #expect(resolved["CODEX_EXPLICIT"] == "restored")
    #expect(resolved["OTTO_NODE_ID"] == "node-1")
    #expect(resolved["PATH"] == "/usr/bin")
    #expect(resolved["TERM"] == "xterm-256color")
  }

  @Test("Provider control credentials are launch environment only")
  func scopedEnvironment() {
    let context = AgentContext(
      nodeID: UUID(),
      workspaceID: UUID(),
      controlSocket: "/tmp/otto/control.sock",
      controlToken: "secret-token",
      mcpExecutable: "/Applications/Otto.app/Contents/MacOS/otto-mcp"
    )
    let environment = CodexAdapter().environment(for: context)
    #expect(environment["OTTO_CONTROL_TOKEN"] == "secret-token")
    #expect(environment["OTTO_NODE_ID"] == context.nodeID.uuidString)
  }

  @Test("Hermes adapter selects local CLI or remote gateway bridge from preferences")
  func hermesConnectionModes() async throws {
    let hermes = try stubProvider(named: "hermes")
    let bridge = try stubProvider(named: "otto-hermes-bridge")
    defer {
      try? FileManager.default.removeItem(at: hermes.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: bridge.deletingLastPathComponent())
    }

    let local = HermesAdapter(
      executablePath: hermes.path,
      bridgePath: bridge.path,
      configurationProvider: { HermesConnectionConfiguration() }
    )
    let interactive = try await local.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: "/tmp", permissionMode: .workspaceWrite))
    #expect(interactive.executable == hermes.path)
    #expect(interactive.arguments.contains("--tui"))

    let oneShot = try await local.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Review the repository",
        model: "claude-opus-4-6",
        effort: "high",
        permissionMode: .unrestricted,
        resumeSessionID: "hermes-session"
      ))
    #expect(oneShot.executable == bridge.path)
    #expect(oneShot.arguments.contains("local"))
    #expect(oneShot.arguments.contains("hermes-session"))
    #expect(!oneShot.arguments.contains("claude-opus-4-6"))
    #expect(!oneShot.arguments.contains("high"))
    let promptIndex = try #require(oneShot.arguments.firstIndex(of: "--prompt"))
    #expect(oneShot.arguments[promptIndex + 1].contains("terminal.wait"))
    #expect(oneShot.arguments[promptIndex + 1].hasSuffix("Review the repository"))

    let remote = HermesAdapter(
      executablePath: hermes.path,
      bridgePath: bridge.path,
      configurationProvider: {
        HermesConnectionConfiguration(
          mode: .remote,
          remoteURL: "https://hermes.example.test/base",
          remoteProfile: "silco",
          remoteWorkingDirectory: "/srv/otto"
        )
      }
    )
    let remoteSpec = try await remote.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/local/path",
        prompt: "Run remotely",
        model: "claude-opus-4-6",
        effort: "high",
        permissionMode: .workspaceWrite
      ))
    #expect(remoteSpec.executable == bridge.path)
    #expect(remoteSpec.arguments.contains("remote"))
    #expect(remoteSpec.arguments.contains("https://hermes.example.test/base"))
    #expect(remoteSpec.arguments.contains("--profile"))
    #expect(remoteSpec.arguments.contains("silco"))
    #expect(remoteSpec.arguments.contains("/srv/otto"))
    let localDirectoryIndex = try #require(
      remoteSpec.arguments.firstIndex(of: "--local-working-directory"))
    #expect(remoteSpec.arguments[localDirectoryIndex + 1] == "/local/path")
    #expect(!remoteSpec.arguments.contains("claude-opus-4-6"))
    #expect(!remoteSpec.arguments.contains("high"))
  }

  @Test("Remote and local Hermes receive the scoped Otto tool tunnel")
  func hermesOttoBrowserTunnelRegistration() async throws {
    let hermes = try stubProvider(named: "hermes")
    let bridge = try stubProvider(named: "otto-hermes-bridge")
    defer {
      try? FileManager.default.removeItem(at: hermes.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: bridge.deletingLastPathComponent())
    }
    let controlEnvironment = [
      "OTTO_CONTROL_SOCKET": "/tmp/otto-control.sock",
      "OTTO_CONTROL_TOKEN": "scoped-token",
      "OTTO_NODE_ID": UUID().uuidString,
      "OTTO_CANVAS_ID": UUID().uuidString,
    ]
    let request = AgentLaunchRequest(
      workspacePath: "/tmp",
      prompt: "Open example.com",
      permissionMode: .workspaceWrite,
      ottoMCPExecutable: "/opt/otto/otto-mcp",
      controlEnvironment: controlEnvironment
    )
    let remote = HermesAdapter(
      executablePath: hermes.path,
      bridgePath: bridge.path,
      configurationProvider: {
        HermesConnectionConfiguration(
          mode: .remote,
          remoteURL: "https://hermes.example.test",
          remoteWorkingDirectory: "/srv/otto"
        )
      })
    let remoteSpec = try await remote.buildLaunchSpec(request)
    #expect(remoteSpec.arguments.contains("--otto-tool-tunnel"))
    let promptIndex = try #require(remoteSpec.arguments.firstIndex(of: "--prompt"))
    let prompt = remoteSpec.arguments[promptIndex + 1]
    #expect(prompt.contains(HermesOttoToolTunnelProtocol.marker))
    #expect(prompt.contains("Hermes'"))
    #expect(prompt.contains("browser_* tools"))
    #expect(prompt.contains("terminal.wait"))
    #expect(prompt.contains("Open example.com"))

    let local = HermesAdapter(
      executablePath: hermes.path,
      bridgePath: bridge.path,
      configurationProvider: { HermesConnectionConfiguration(mode: .local) })
    let localSpec = try await local.buildLaunchSpec(request)
    #expect(localSpec.arguments.contains("--otto-tool-tunnel"))
  }

  @Test("Hermes Otto browser tunnel parses only allowlisted marker requests")
  func hermesOttoBrowserTunnelProtocol() throws {
    #expect(
      HermesOttoToolTunnelProtocol.parse(question: "Which account should I use?")
        == .ordinaryClarification)

    let valid =
      HermesOttoToolTunnelProtocol.marker
      + #"{"name":"browser.click","arguments":{"nodeID":"abc","elementID":"login"}}"#
    guard case .request(let request) = HermesOttoToolTunnelProtocol.parse(question: valid) else {
      Issue.record("Expected a parsed Otto browser request")
      return
    }
    #expect(request.name == "browser.click")
    let arguments = try JSONSerialization.jsonObject(with: request.argumentsJSON) as? [String: Any]
    #expect(arguments?["elementID"] as? String == "login")

    let terminalWait =
      HermesOttoToolTunnelProtocol.marker
      + #"{"name":"terminal.wait","arguments":{"terminalID":"abc","timeoutMilliseconds":30000}}"#
    guard
      case .request(let waitRequest) = HermesOttoToolTunnelProtocol.parse(question: terminalWait)
    else {
      Issue.record("Expected terminal.wait to pass the Hermes allowlist")
      return
    }
    #expect(waitRequest.name == "terminal.wait")

    let disallowed =
      HermesOttoToolTunnelProtocol.marker
      + #"{"name":"node.close_all","arguments":{}}"#
    guard case .rejected = HermesOttoToolTunnelProtocol.parse(question: disallowed) else {
      Issue.record("Expected a destructive Otto tool to be rejected")
      return
    }
  }

  @Test("Provider version commands run through the PTY transport")
  func versionThroughPTY() async throws {
    for executable in [ExecutableLocator.find("claude"), ExecutableLocator.find("codex")]
      .compactMap({ $0 })
    {
      let process = try PTYProcess.spawn(
        ProcessLaunchSpec(
          executable: executable,
          arguments: ["--version"],
          workingDirectory: FileManager.default.currentDirectoryPath
        ))
      var output = ""
      for await data in process.output {
        output += String(decoding: data, as: UTF8.self)
      }
      #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  @Test("Version probes drain output before observing process exit")
  func versionProbeDrain() async throws {
    let version = await ExecutableLocator.version(
      executable: "/usr/bin/printf",
      arguments: ["provider-version-1.2.3\\n"]
    )
    #expect(version == "provider-version-1.2.3")
  }

  @Test("Provider selection skips an executable that cannot start")
  func brokenExecutableFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-provider-fallback-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let broken = root.appending(path: "broken-codex")
    let working = root.appending(path: "working-codex")
    try Data("#!/bin/sh\nexit 126\n".utf8).write(to: broken)
    try Data("#!/bin/sh\nprintf 'codex-cli 1.2.3\\n'\n".utf8).write(to: working)
    for executable in [broken, working] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    let selected = await ExecutableLocator.firstWorking(
      candidates: [broken.path, working.path])
    #expect(selected?.path == working.path)
    #expect(selected?.version == "codex-cli 1.2.3")
  }

  @Test("Cursor runs stream JSON, clear their own prompts, and register the bridge in .cursor")
  func cursorLaunchSpecification() async throws {
    let stub = try stubProvider(named: "cursor-agent", version: "2026.08.04-aaa8809")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let adapter = CursorAdapter(executablePath: stub.path)
    let workspace = FileManager.default.temporaryDirectory.appending(
      path: "otto-cursor-workspace-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    switch await adapter.detectInstallation() {
    case .installed(let path, let version):
      #expect(path == stub.path)
      #expect(version.contains("2026.08.04"))
    case .missing(let remediation):
      Issue.record("stub cursor-agent should be detected: \(remediation)")
    }

    let launch = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path,
        prompt: "Add authentication coverage.",
        ottoMCPExecutable: "/opt/otto/otto-mcp",
        memoryBootstrap: "# Otto agent bootstrap"
      ))
    #expect(launch.arguments.starts(with: ["--print", "--output-format", "stream-json"]))
    // A headless run cannot paint the trust or MCP-approval prompts, so both are pre-answered.
    #expect(launch.arguments.contains("--trust"))
    #expect(launch.arguments.contains("--approve-mcps"))
    // Workspace-safe keeps Cursor's own approval flow.
    #expect(!launch.arguments.contains("--force"))
    #expect(!launch.arguments.contains("--mode=plan"))
    // No system-prompt channel: guidance and bootstrap ride ahead of the task.
    let prompt = try #require(launch.arguments.last)
    #expect(prompt.contains("browser.open"))
    #expect(prompt.contains("# Otto agent bootstrap"))
    #expect(prompt.hasSuffix("Add authentication coverage."))

    // Cursor takes no MCP flag; the bridge is registered in the workspace's own .cursor/mcp.json.
    let mcpFile = workspace.appending(path: ".cursor/mcp.json")
    let registered = try JSONSerialization.jsonObject(with: try Data(contentsOf: mcpFile))
    let servers = try #require((registered as? [String: Any])?["mcpServers"] as? [String: Any])
    let otto = try #require(servers["otto"] as? [String: Any])
    #expect(otto["command"] as? String == "/opt/otto/otto-mcp")
    // Scoped credentials reach the bridge through the inherited process environment, never the
    // shared file, so parallel Cursor nodes cannot overwrite each other's token.
    #expect(otto["env"] == nil)

    // A user's existing servers in the project file survive registration.
    try Data(
      #"{"mcpServers":{"linear":{"command":"npx","args":["-y","linear-mcp-server"]}}}"#.utf8
    ).write(to: mcpFile)
    _ = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Again.",
        ottoMCPExecutable: "/opt/otto/otto-mcp"))
    let merged = try JSONSerialization.jsonObject(with: try Data(contentsOf: mcpFile))
    let mergedServers = try #require((merged as? [String: Any])?["mcpServers"] as? [String: Any])
    #expect(mergedServers["linear"] != nil)
    #expect(mergedServers["otto"] != nil)

    // Unlike Kimi, Cursor has a real read-only mode for headless runs.
    let readOnly = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Look around.", permissionMode: .readOnly))
    #expect(readOnly.arguments.contains("--mode=plan"))
    #expect(!readOnly.arguments.contains("--force"))

    let unrestricted = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Ship it.", permissionMode: .unrestricted))
    #expect(unrestricted.arguments.contains("--force"))

    // Continuations resume by real chat id, receive current Otto guidance, and skip the durable
    // bootstrap already in the session.
    let resumed = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path,
        prompt: "And now the tests.",
        resumeSessionID: "d10d535f-5a2d-4a5a-bf07-2630a7c3ce83",
        memoryBootstrap: "# Otto agent bootstrap"
      ))
    #expect(resumed.arguments.contains("--resume"))
    #expect(resumed.arguments.contains("d10d535f-5a2d-4a5a-bf07-2630a7c3ce83"))
    #expect(resumed.arguments.last?.contains("terminal.wait") == true)
    #expect(resumed.arguments.last?.contains("# Otto agent bootstrap") == false)
    #expect(resumed.arguments.last?.hasSuffix("And now the tests.") == true)

    // A TUI launch takes no print flags but still clears the trust prompt.
    let interactive = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: workspace.path))
    #expect(!interactive.arguments.contains("--print"))
    #expect(interactive.arguments.contains("--trust"))
  }

  @Test("Cursor discovery reports failure distinctly instead of masquerading as a short catalog")
  func cursorDiscoveryDistinguishesFailure() async throws {
    // Collapsing "the CLI could not be asked" into the static fallback is what made a broken
    // picker look identical to a working one, so callers must be able to tell them apart.
    let missing = CursorAdapter(executablePath: "/nonexistent/cursor-agent")
    #expect(await missing.discoverModels() == nil)
    #expect(await missing.availableModels() == AgentModelCatalog.options(for: .cursor))

    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-cursor-models-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stub = directory.appending(path: "cursor-agent")
    try Data(
      """
      #!/bin/sh
      if [ "$1" = "models" ]; then printf 'auto - Auto (default)\\ncomposer-2.5 - Composer 2.5\\ngpt-5.2 - GPT-5.2\\n'
      else printf '2026.08.04-aaa8809\\n'; fi
      """.utf8
    ).write(to: stub)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    let discovered = await CursorAdapter(executablePath: stub.path).discoverModels()
    #expect(discovered?.count == 3)
    #expect(discovered?.contains { $0.id == "gpt-5.2" } == true)
  }

  @Test("List commands are captured without a terminal, and a hanging one cannot block forever")
  func captureOutputAvoidsTerminalAndBounds() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-capture-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Mirrors `cursor-agent models`: prints a plain list only when stdout is not a terminal, and
    // otherwise behaves like an interactive view that never exits.
    let script = directory.appending(path: "lister")
    try Data(
      """
      #!/bin/sh
      if [ -t 1 ]; then sleep 600; else printf 'auto - Auto (default)\\n'; fi
      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let output = await ExecutableLocator.captureOutput(executable: script.path, arguments: [])
    #expect(output == "auto - Auto (default)")
    #expect(CursorAdapter.parseModels(output ?? "").first?.id == "auto")

    // A command that hangs regardless is cut off rather than blocking the caller forever.
    let hanging = directory.appending(path: "hanging")
    try Data("#!/bin/sh\nsleep 600\n".utf8).write(to: hanging)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hanging.path)
    let started = ContinuousClock.now
    let timedOut = await ExecutableLocator.captureOutput(
      executable: hanging.path, arguments: [], timeout: .milliseconds(300))
    #expect(timedOut == nil)
    #expect(ContinuousClock.now - started < .seconds(20))
  }

  @Test("Model selection is offered exactly to the providers Otto can set a model on")
  func modelSelectionCapability() {
    // The picker chip and agent.set_model both read this, so a provider gaining models turns on
    // in both places at once instead of needing a hand-maintained list in each.
    #expect(AgentModelCatalog.supportsModelSelection(for: .claudeCode))
    #expect(AgentModelCatalog.supportsModelSelection(for: .codex))
    #expect(AgentModelCatalog.supportsModelSelection(for: .openAI))
    #expect(AgentModelCatalog.supportsModelSelection(for: .cursor))
    #expect(AgentModelCatalog.supportsModelSelection(for: .grok))
    #expect(AgentModelCatalog.supportsModelSelection(for: .kimi))
    #expect(AgentModelCatalog.supportsModelSelection(for: .openCode))

    // Hermes resolves its model at the gateway and a shell has no model.
    #expect(!AgentModelCatalog.supportsModelSelection(for: .hermes))
    #expect(!AgentModelCatalog.supportsModelSelection(for: .shell))
    let claudeModels = AgentModelCatalog.options(for: .claudeCode)
    #expect(claudeModels.first?.id == "fable")
    #expect(claudeModels.contains { $0.id == "claude-fable-5-1" })
    #expect(
      AgentModelCatalog.options(for: .openAI).contains {
        $0.id == "anthropic/claude-fable-5-1"
      })
    #expect(
      AgentModelCatalog.effortLevels(for: .codex, modelID: "gpt-5.6-sol")
        == ["low", "medium", "high", "xhigh", "max", "ultra"])
    #expect(
      AgentModelCatalog.effortLevels(for: .codex, modelID: "gpt-5.6-luna")
        == ["low", "medium", "high", "xhigh", "max"])
  }

  @Test("Provider model catalogs parse the account-visible model formats")
  func parsesProviderModelCatalogs() throws {
    let codex = CodexAdapter.parseModelsCache(
      Data(
        #"{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6 Sol","visibility":"list"},{"slug":"gpt-5.6-terra","display_name":"GPT-5.6 Terra","visibility":"list"},{"slug":"openrouter/claude","display_name":"Claude","visibility":"list"},{"slug":"gpt-hidden","visibility":"hidden"}]}"#
          .utf8))
    #expect(codex.map(\.id) == ["gpt-5.6-sol", "gpt-5.6-terra"])

    let kimi = KimiAdapter.parseModels(
      #"{"models":{"kimi-code/k3":{"display_name":"K3"},"team/fast":{"display_name":"Team Fast"}}}"#
    )
    #expect(kimi.map(\.id) == ["kimi-code/k3", "team/fast"])

    let openCode = OpenCodeAdapter.parseModels(
      "openai/gpt-5.6-sol\nopenrouter/claude-sonnet\nopenai/gpt-5.6-sol\n")
    #expect(openCode.map(\.id) == ["openai/gpt-5.6-sol", "openrouter/claude-sonnet"])
  }

  @Test("OpenCode verbose catalogs put the newest models first and drop deprecated ones")
  func parsesOpenCodeVerboseCatalog() {
    let output = """
      openai/gpt-5.6-sol
      {
        "id": "gpt-5.6-sol",
        "name": "GPT-5.6 Sol",
        "status": "active",
        "release_date": "2026-03-01"
      }
      anthropic/claude-opus-5-5
      {
        "id": "claude-opus-5-5",
        "name": "Claude Opus 5.5",
        "release_date": "2026-09-20",
        "variants": { "high": { "reasoningEffort": "high" } }
      }
      openai/gpt-4o
      {
        "name": "GPT-4o",
        "status": "deprecated",
        "release_date": "2024-05-13"
      }
      """
    let models = OpenCodeAdapter.parseVerboseModels(output)
    #expect(models.map(\.id) == ["anthropic/claude-opus-5-5", "openai/gpt-5.6-sol"])
    #expect(models.first?.displayName == "Claude Opus 5.5 · anthropic")
    // Plain `opencode models` output carries no metadata and so parses as nothing here.
    #expect(OpenCodeAdapter.parseVerboseModels("openai/gpt-5.6-sol\n").isEmpty)
  }

  @Test("Model search matches every word against names and ids, ignoring separators")
  func modelSearchMatchesWords() {
    let models = [
      AgentModel(id: "anthropic/claude-opus-5-5", displayName: "Claude Opus 5.5 · anthropic"),
      AgentModel(id: "openai/gpt-6-astra", displayName: "GPT-6 Astra · openai"),
      AgentModel(id: "openrouter/openai/gpt-6-astra", displayName: "GPT-6 Astra · openrouter"),
    ]
    #expect(AgentModelCatalog.matching(models, query: "").count == 3)
    #expect(AgentModelCatalog.matching(models, query: "OPUS").map(\.id) == [models[0].id])
    #expect(
      AgentModelCatalog.matching(models, query: "gpt6 openrouter").map(\.id) == [models[2].id])
    #expect(AgentModelCatalog.matching(models, query: "astra").count == 2)
    #expect(AgentModelCatalog.matching(models, query: "gemini").isEmpty)
  }

  @Test("Direct model APIs are filtered and provider-prefixed")
  func parsesDirectProviderModels() {
    let openAI = OpenAIDirectAdapter.parseDirectModels(
      Data(
        #"{"data":[{"id":"gpt-5.6"},{"id":"gpt-image-1"},{"id":"text-embedding-3-small"}]}"#.utf8),
      provider: .openAI)
    #expect(openAI.map(\.id) == ["openai/gpt-5.6"])

    let anthropic = OpenAIDirectAdapter.parseDirectModels(
      Data(
        #"{"data":[{"id":"claude-sonnet-5","display_name":"Claude Sonnet 5"},{"id":"not-a-model"}]}"#
          .utf8),
      provider: .anthropic)
    #expect(anthropic.map(\.id) == ["anthropic/claude-sonnet-5"])
    #expect(anthropic.first?.displayName == "Anthropic · Claude Sonnet 5")
  }

  @Test("Cursor's calendar build stamp is recognised instead of failing semver parsing")
  func cursorCalendarVersion() {
    // Cursor stamps "2026.08.04-aaa8809". The shared semver parser reads that as 2026.8.4 and
    // would call it untested, so the provider needs its own branch.
    let supported = ProviderCompatibilityPolicy.evaluate(
      provider: .cursor, reportedVersion: "2026.08.04-aaa8809")
    #expect(supported.state == .supported)

    let garbled = ProviderCompatibilityPolicy.evaluate(
      provider: .cursor, reportedVersion: "unknown-build")
    #expect(garbled.state == .untested)
  }

  @Test("Pi runs stream JSON, trust a project mcp.json naming Otto, and carry Otto guidance")
  func piLaunchSpecification() async throws {
    let stub = try stubProvider(named: "pi", version: "1.4.0")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let adapter = PiAdapter(executablePath: stub.path)
    let workspace = FileManager.default.temporaryDirectory.appending(
      path: "otto-pi-workspace-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    switch await adapter.detectInstallation() {
    case .installed(let path, let version):
      #expect(path == stub.path)
      #expect(version == "pi 1.4.0")
      #expect(
        ProviderCompatibilityPolicy.evaluate(provider: .pi, reportedVersion: version).state
          == .supported)
    case .missing(let remediation):
      Issue.record("stub pi should be detected: \(remediation)")
    }
    // A version-only stub prints no model table, so discovery fails explicitly.
    #expect(await adapter.availableModels().isEmpty)

    let launch = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path,
        prompt: "Add authentication coverage.",
        model: "anthropic/claude-sonnet-5",
        effort: "high",
        ottoMCPExecutable: "/opt/otto/otto-mcp",
        profileInstructions: "You are Beck, the release engineer.",
        memoryBootstrap: "# Otto agent bootstrap"
      ))
    #expect(launch.arguments.starts(with: ["--mode", "json"]))
    #expect(launch.arguments.contains("--approve"))
    let modelIndex = try #require(launch.arguments.firstIndex(of: "--model"))
    #expect(launch.arguments[modelIndex + 1] == "anthropic/claude-sonnet-5")
    let thinkingIndex = try #require(launch.arguments.firstIndex(of: "--thinking"))
    #expect(launch.arguments[thinkingIndex + 1] == "high")
    // Workspace-write runs keep Pi's default tool set; only read-only narrows it.
    #expect(!launch.arguments.contains("--tools"))
    // Guidance, profile and bootstrap travel in the system prompt, not the transcript.
    let systemIndex = try #require(launch.arguments.firstIndex(of: "--append-system-prompt"))
    let systemPrompt = launch.arguments[systemIndex + 1]
    #expect(systemPrompt.contains("browser.open"))
    #expect(systemPrompt.contains("You are Beck, the release engineer."))
    #expect(systemPrompt.contains("# Otto agent bootstrap"))
    // The task is the final positional argument, after `--` so a leading dash is never a flag.
    #expect(launch.arguments.suffix(2) == ["--", "Add authentication coverage."])
    #expect(launch.workingDirectory == workspace.path)

    // The bridge is registered in the project file with placeholders, never a token: the file is
    // identical for every node and two nodes sharing a directory cannot clobber each other.
    let file = workspace.appending(path: ".pi/mcp.json")
    let root = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let servers = try #require(root["mcpServers"] as? [String: Any])
    let otto = try #require(servers["otto"] as? [String: Any])
    #expect(otto["command"] as? String == "/opt/otto/otto-mcp")
    #expect(otto["timeout"] as? Int == 3_600)
    let env = try #require(otto["env"] as? [String: String])
    #expect(env["OTTO_CONTROL_TOKEN"] == "${OTTO_CONTROL_TOKEN}")
    #expect(env["OTTO_CONTROL_SOCKET"] == "${OTTO_CONTROL_SOCKET}")
    #expect(env["OTTO_NODE_ID"] == "${OTTO_NODE_ID}")
    #expect(env["OTTO_WORKSPACE_ID"] == "${OTTO_WORKSPACE_ID}")
    #expect(!env.values.contains { !$0.hasPrefix("${") })

    // A user-authored server in the same file survives re-registration untouched.
    var edited = root
    var editedServers = servers
    editedServers["docs"] = ["url": "https://example.com/mcp"]
    edited["mcpServers"] = editedServers
    try JSONSerialization.data(withJSONObject: edited).write(to: file)
    _ = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Again.", ottoMCPExecutable: "/opt/otto/otto-mcp"))
    let rewritten = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let rewrittenServers = try #require(rewritten["mcpServers"] as? [String: Any])
    #expect((rewrittenServers["docs"] as? [String: String])?["url"] == "https://example.com/mcp")
    #expect(rewrittenServers["otto"] != nil)

    // Read-only declares only the inspection tools, which Pi then never offers the model.
    let readOnly = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Look around.", permissionMode: .readOnly,
        resumeSessionID: "01a181cc-561f-75f3-b9b5-889ecc5ce8b6"))
    let toolsIndex = try #require(readOnly.arguments.firstIndex(of: "--tools"))
    #expect(readOnly.arguments[toolsIndex + 1] == "read,grep,find,ls")
    let sessionIndex = try #require(readOnly.arguments.firstIndex(of: "--session"))
    #expect(readOnly.arguments[sessionIndex + 1] == "01a181cc-561f-75f3-b9b5-889ecc5ce8b6")
    // Without a bridge there is nothing to trust the project for.
    #expect(!readOnly.arguments.contains("--approve"))

    // Interactive launches open Pi's own TUI: no JSON mode and no positional prompt.
    let interactive = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: workspace.path, ottoMCPExecutable: "/opt/otto/otto-mcp"))
    #expect(!interactive.arguments.contains("--mode"))
    #expect(!interactive.arguments.contains("--"))
    #expect(interactive.arguments.contains("--approve"))
    #expect(interactive.arguments.contains("--append-system-prompt"))
  }

  @Test("Pi prompts that start with a mention are not read as file attachments")
  func piPromptArgument() {
    #expect(
      PiAdapter.promptArgument("@Beck review this", for: .direct)
        .hasPrefix("Task from the user:\n@Beck"))
    #expect(PiAdapter.promptArgument("Review this", for: .direct) == "Review this")
    #expect(
      PiAdapter.promptArgument("Review this", for: .delegated)
        .hasPrefix("Execution strategy: delegated."))
  }

  @Test("Pi model tables become provider-qualified ids")
  func parsesPiModelTable() {
    let output = """
      provider   model                      context  max-out  thinking  images
      anthropic  claude-sonnet-5            200K     64K      yes       yes
      anthropic  claude-opus-5              200K     32K      yes       yes
      openai     gpt-5.6                    400K     128K     yes       yes
      anthropic  claude-sonnet-5            200K     64K      yes       yes
      """
    let models = PiAdapter.parseModels(output)
    #expect(
      models.map(\.id) == [
        "anthropic/claude-sonnet-5", "anthropic/claude-opus-5", "openai/gpt-5.6",
      ])
    #expect(models.first?.displayName == "claude-sonnet-5 · anthropic")
    // A signed-out Pi prints a hint instead of a table.
    #expect(
      PiAdapter.parseModels(
        "No models available. Use /login to log into a provider via OAuth or API key. See:\n  /x/docs/providers.md"
      ).isEmpty)
  }

  @Test("OpenCode runs stream JSON events and carry Otto's config through the environment")
  func openCodeLaunchSpecification() async throws {
    let stub = try stubProvider(named: "opencode", version: "1.18.15")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let adapter = OpenCodeAdapter(executablePath: stub.path)
    let workspace = FileManager.default.temporaryDirectory.appending(
      path: "otto-opencode-workspace-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    switch await adapter.detectInstallation() {
    case .installed(let path, let version):
      #expect(path == stub.path)
      #expect(version == "opencode 1.18.15")
    case .missing(let remediation):
      Issue.record("stub opencode should be detected: \(remediation)")
    }
    // A version-only stub has no model catalog, so discovery fails explicitly.
    #expect(await adapter.availableModels().isEmpty)

    let launch = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path,
        prompt: "Add authentication coverage.",
        ottoMCPExecutable: "/opt/otto/otto-mcp",
        memoryBootstrap: "# Otto agent bootstrap"
      ))
    #expect(launch.arguments.starts(with: ["run", "--format", "json"]))
    // Workspace-safe runs use OpenCode's own approval policy, so --auto must not appear.
    #expect(!launch.arguments.contains("--auto"))
    // No system-prompt channel: guidance and bootstrap ride ahead of the task.
    let prompt = try #require(launch.arguments.last)
    #expect(prompt.contains("browser.open"))
    #expect(prompt.contains("# Otto agent bootstrap"))
    #expect(prompt.hasSuffix("Add authentication coverage."))

    // The bridge is injected inline rather than written into the user's workspace, so nothing
    // lands on disk and two nodes in one directory cannot overwrite each other's config.
    #expect(
      !FileManager.default.fileExists(atPath: workspace.appending(path: "opencode.json").path))
    let inline = try #require(launch.environment["OPENCODE_CONFIG_CONTENT"])
    let config = try #require(
      try JSONSerialization.jsonObject(with: Data(inline.utf8)) as? [String: Any])
    let servers = try #require(config["mcp"] as? [String: Any])
    let otto = try #require(servers["otto"] as? [String: Any])
    #expect(otto["type"] as? String == "local")
    #expect(otto["command"] as? [String] == ["/opt/otto/otto-mcp"])
    #expect(otto["timeout"] as? Int == 3_600_000)
    // Workspace-safe runs must not silently narrow the tools OpenCode offers.
    #expect(config["permission"] == nil)

    // Read-only denies the mutating tools outright, which removes them from the model's list
    // rather than prompting — a guarantee, not a request.
    let readOnly = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Look around.", permissionMode: .readOnly))
    let readOnlyInline = try #require(readOnly.environment["OPENCODE_CONFIG_CONTENT"])
    let readOnlyConfig = try #require(
      try JSONSerialization.jsonObject(with: Data(readOnlyInline.utf8)) as? [String: Any])
    let permission = try #require(readOnlyConfig["permission"] as? [String: String])
    #expect(permission["edit"] == "deny")
    #expect(permission["bash"] == "deny")
    #expect(!readOnly.arguments.contains("--auto"))

    // Bypass is the only mode that maps to a flag.
    let unrestricted = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Ship it.", permissionMode: .unrestricted))
    #expect(unrestricted.arguments.contains("--auto"))

    // Continuations resume by real session id, receive current Otto guidance, and skip the
    // durable bootstrap already in the session.
    let resumed = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path,
        prompt: "And now the tests.",
        resumeSessionID: "ses_0232a9e4dffejY60mWFaqfUUrP",
        memoryBootstrap: "# Otto agent bootstrap"
      ))
    #expect(resumed.arguments.contains("--session"))
    #expect(resumed.arguments.contains("ses_0232a9e4dffejY60mWFaqfUUrP"))
    #expect(resumed.arguments.last?.contains("terminal.wait") == true)
    #expect(resumed.arguments.last?.contains("# Otto agent bootstrap") == false)
    #expect(resumed.arguments.last?.hasSuffix("And now the tests.") == true)

    // A TUI launch takes no run subcommand.
    let interactive = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: workspace.path))
    #expect(!interactive.arguments.contains("run"))
  }

  @Test("Kimi launches stream print-mode JSON and carry the canvas bootstrap in the prompt")
  func kimiLaunchSpecification() async throws {
    let stub = try stubProvider(named: "kimi", version: "0.34.0")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let adapter = KimiAdapter(executablePath: stub.path)
    let workspace = FileManager.default.temporaryDirectory.appending(
      path: "otto-kimi-workspace-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    switch await adapter.detectInstallation() {
    case .installed(let path, let version):
      #expect(path == stub.path)
      #expect(version == "kimi 0.34.0")
    case .missing(let remediation):
      Issue.record("stub kimi should be detected: \(remediation)")
    }
    // A version-only stub cannot list configured aliases, so Otto uses current managed defaults.
    #expect(await adapter.availableModels() == AgentModelCatalog.options(for: .kimi))

    let launch = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path,
        prompt: "Add authentication coverage.",
        ottoMCPExecutable: "/opt/otto/otto-mcp",
        memoryBootstrap: "# Otto agent bootstrap"
      ))
    #expect(launch.arguments.starts(with: ["--output-format", "stream-json", "--prompt"]))
    // Kimi rejects the permission flags alongside --prompt, so a prompted run carries none.
    #expect(!launch.arguments.contains("--plan"))
    #expect(!launch.arguments.contains("--yolo"))
    #expect(!launch.arguments.contains("--auto"))
    // Kimi has no system-prompt channel: guidance and bootstrap ride ahead of the task.
    let prompt = try #require(launch.arguments.last)
    #expect(prompt.contains("browser.open"))
    #expect(prompt.contains("# Otto agent bootstrap"))
    #expect(prompt.hasSuffix("Add authentication coverage."))

    // Kimi takes no MCP flag; the bridge is registered in the working directory's mcp.json.
    #expect(!launch.arguments.contains("--mcp-config"))
    let mcpFile = workspace.appending(path: ".kimi-code/mcp.json")
    let registered = try JSONSerialization.jsonObject(with: try Data(contentsOf: mcpFile))
    let servers = try #require((registered as? [String: Any])?["mcpServers"] as? [String: Any])
    let otto = try #require(servers["otto"] as? [String: Any])
    #expect(otto["command"] as? String == "/opt/otto/otto-mcp")
    #expect(otto["toolTimeoutMs"] as? Int == 3_600_000)
    // Scoped credentials reach the bridge through the inherited process environment, never the
    // shared file, so parallel Kimi nodes cannot overwrite each other's token.
    #expect(otto["env"] == nil)

    // Unrelated servers in an existing project file survive registration.
    try Data(
      #"{"mcpServers":{"linear":{"url":"https://mcp.linear.app/mcp"}}}"#.utf8
    ).write(to: mcpFile)
    _ = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Again.",
        ottoMCPExecutable: "/opt/otto/otto-mcp"))
    let merged = try JSONSerialization.jsonObject(with: try Data(contentsOf: mcpFile))
    let mergedServers = try #require((merged as? [String: Any])?["mcpServers"] as? [String: Any])
    #expect(mergedServers["linear"] != nil)
    #expect(mergedServers["otto"] != nil)

    // A read-only chat run would be a promise Kimi cannot keep: print mode always auto-approves.
    await #expect(throws: RuntimeError.self) {
      _ = try await adapter.buildLaunchSpec(
        AgentLaunchRequest(
          workspacePath: workspace.path, prompt: "Look around.", permissionMode: .readOnly))
    }

    // Interactive launches keep Kimi's own approval flow, where the flags are accepted.
    let plan = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: workspace.path, permissionMode: .readOnly))
    #expect(plan.arguments == ["--plan"])
    let yolo = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: workspace.path, permissionMode: .unrestricted))
    #expect(yolo.arguments == ["--yolo"])
    let interactive = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: workspace.path, permissionMode: .workspaceWrite))
    #expect(interactive.arguments.isEmpty)

    // Print mode reports no session id, so continuations resume by working directory. Current
    // Otto guidance is resent while the durable bootstrap remains first-turn-only.
    let continued = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path,
        prompt: "Continue.",
        resumeSessionID: KimiAdapter.continuationSessionToken,
        memoryBootstrap: "# Otto agent bootstrap"
      ))
    #expect(continued.arguments.first == "--continue")
    #expect(!continued.arguments.contains("--session"))
    #expect(continued.arguments.last?.contains("terminal.wait") == true)
    #expect(continued.arguments.last?.contains("# Otto agent bootstrap") == false)
    #expect(continued.arguments.last?.hasSuffix("Continue.") == true)

    let resumed = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Continue.",
        resumeSessionID: "01HZKIMISESSION"))
    #expect(resumed.arguments.starts(with: ["--session", "01HZKIMISESSION"]))
    #expect(resumed.arguments.last?.contains("terminal.wait") == true)
  }

  @Test("Grok launches stream messages-json and write only the project otto MCP server")
  func grokLaunchSpecification() async throws {
    let stub = try stubProvider(named: "grok", version: "1.0.3")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let adapter = GrokAdapter(executablePath: stub.path)
    let workspace = FileManager.default.temporaryDirectory.appending(
      path: "otto-grok-workspace-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    switch await adapter.detectInstallation() {
    case .installed(let path, let version):
      #expect(path == stub.path)
      #expect(version == "grok 1.0.3")
    case .missing(let remediation):
      Issue.record("stub grok should be detected: \(remediation)")
    }

    #expect(
      GrokAdapter.parseModels(
        """
        You are logged in with grok.com.
        Default model: grok-4.6
        Available models:
          * grok-4.6 (default)
          - grok-4.5
        """
      ) == [
        AgentModel(id: "grok-4.6", displayName: "Grok 4.6"),
        AgentModel(id: "grok-4.5", displayName: "Grok 4.5"),
      ])

    let launch = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path,
        prompt: "Add authentication coverage.",
        model: "grok-4.6",
        effort: "high",
        ottoMCPExecutable: "/opt/otto/otto-mcp",
        memoryBootstrap: "# Otto agent bootstrap"
      ))
    #expect(
      launch.arguments.starts(with: [
        "--output-format", "streaming-messages-json", "--include-partial-messages",
      ]))
    #expect(launch.arguments.contains("--disallowed-tools"))
    #expect(launch.arguments.contains("ask_user_question"))
    #expect(launch.arguments.contains("--permission-mode"))
    #expect(launch.arguments.contains("default"))
    #expect(launch.arguments.contains("--sandbox"))
    #expect(launch.arguments.contains("workspace"))
    #expect(launch.arguments.contains("--model"))
    #expect(launch.arguments.contains("grok-4.6"))
    #expect(launch.arguments.contains("--effort"))
    #expect(launch.arguments.contains("high"))
    let rulesIndex = try #require(launch.arguments.firstIndex(of: "--rules"))
    #expect(launch.arguments[rulesIndex + 1].contains("browser.open"))
    #expect(launch.arguments[rulesIndex + 1].contains("terminal.wait"))
    #expect(launch.arguments[rulesIndex + 1].contains("# Otto agent bootstrap"))
    let promptIndex = try #require(launch.arguments.firstIndex(of: "-p"))
    #expect(launch.arguments[promptIndex + 1] == "Add authentication coverage.")

    let mcpFile = workspace.appending(path: ".grok/config.toml")
    let registered = try String(contentsOf: mcpFile, encoding: .utf8)
    #expect(registered.contains("[mcp_servers.otto]"))
    #expect(registered.contains("command = \"/opt/otto/otto-mcp\""))
    #expect(registered.contains("tool_timeout_sec = 3600"))
    #expect(registered.contains("OTTO_CONTROL_TOKEN = \"${OTTO_CONTROL_TOKEN}\""))

    try Data(
      """
      [mcp_servers.linear]
      url = "https://mcp.linear.app/mcp"

      [mcp_servers.muse]
      command = "/old/otto-mcp"
      """.utf8
    ).write(to: mcpFile)
    _ = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Again.",
        ottoMCPExecutable: "/opt/otto/otto-mcp"))
    let merged = try String(contentsOf: mcpFile, encoding: .utf8)
    #expect(merged.contains("[mcp_servers.linear]"))
    #expect(merged.contains("command = \"/opt/otto/otto-mcp\""))
    // The `muse` table Muse wrote before the rename (its own bridge) is removed.
    #expect(!merged.contains("[mcp_servers.muse]"))
    #expect(!merged.contains("/old/otto-mcp"))

    let readOnly = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Look around.", permissionMode: .readOnly))
    #expect(readOnly.arguments.contains("plan"))
    #expect(readOnly.arguments.contains("read-only"))

    let unrestricted = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path, prompt: "Ship it.", permissionMode: .unrestricted))
    #expect(unrestricted.arguments.contains("bypassPermissions"))
    #expect(unrestricted.arguments.contains("off"))

    let resumed = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: workspace.path,
        prompt: "And now the tests.",
        resumeSessionID: "019ffa8f-4a4e-7431-943f-826c8ea8c593",
        memoryBootstrap: "# Otto agent bootstrap"
      ))
    #expect(resumed.arguments.contains("--resume"))
    #expect(resumed.arguments.contains("019ffa8f-4a4e-7431-943f-826c8ea8c593"))
    let resumedRules = try #require(resumed.arguments.firstIndex(of: "--rules"))
    #expect(!resumed.arguments[resumedRules + 1].contains("# Otto agent bootstrap"))

    let interactive = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: workspace.path))
    #expect(!interactive.arguments.contains("-p"))
    #expect(!interactive.arguments.contains("streaming-messages-json"))
    #expect(interactive.arguments.contains("--permission-mode"))
  }

  @Test("Claude launches register the Otto MCP bridge and canvas guidance when available")
  func claudeOttoMCPRegistration() async throws {
    let stub = try stubProvider(named: "claude")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let adapter = ClaudeCodeAdapter(executablePath: stub.path)

    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Open the BBC for me.",
        ottoMCPExecutable: "/opt/otto/otto-mcp"
      ))
    let mcpIndex = try #require(spec.arguments.firstIndex(of: "--mcp-config"))
    #expect(spec.arguments[mcpIndex + 1].contains("\"command\":\"/opt/otto/otto-mcp\""))
    let promptIndex = try #require(spec.arguments.firstIndex(of: "Open the BBC for me."))
    #expect(mcpIndex < promptIndex, "MCP flags must precede the positional prompt")
    let guidanceIndex = try #require(spec.arguments.firstIndex(of: "--append-system-prompt"))
    #expect(spec.arguments[guidanceIndex + 1].contains("browser.open"))
    #expect(spec.arguments[guidanceIndex + 1].contains("visual verification"))
    #expect(spec.arguments[guidanceIndex + 1].contains("browser.inspect"))
    #expect(spec.arguments[guidanceIndex + 1].contains("terminal.wait"))
    #expect(spec.arguments[guidanceIndex + 1].contains("shared background-job protocol"))

    let withoutBridge = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: "/tmp"))
    #expect(!withoutBridge.arguments.contains("--mcp-config"))
    #expect(!withoutBridge.arguments.contains("--append-system-prompt"))
  }

  @Test("Codex launches register the Otto MCP bridge in every launch shape")
  func codexOttoMCPRegistration() async throws {
    let stub = try stubProvider(named: "codex")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let adapter = CodexAdapter(executablePath: stub.path)
    let expected = "mcp_servers.otto.command=\"/opt/otto/otto-mcp\""

    for request in [
      AgentLaunchRequest(
        workspacePath: "/tmp", prompt: "Task", ottoMCPExecutable: "/opt/otto/otto-mcp"),
      AgentLaunchRequest(workspacePath: "/tmp", ottoMCPExecutable: "/opt/otto/otto-mcp"),
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Continue",
        resumeSessionID: "codex-session",
        ottoMCPExecutable: "/opt/otto/otto-mcp"
      ),
    ] {
      let spec = try await adapter.buildLaunchSpec(request)
      #expect(spec.arguments.contains(expected))
    }
    let withoutBridge = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(workspacePath: "/tmp"))
    #expect(!withoutBridge.arguments.contains(expected))
  }

  @Test("Codex receives hidden developer instructions while legacy providers embed bootstrap")
  func promptEmbeddedBootstrapDelivery() async throws {
    let codexStub = try stubProvider(named: "codex")
    defer { try? FileManager.default.removeItem(at: codexStub.deletingLastPathComponent()) }
    let codexSpec = try await CodexAdapter(executablePath: codexStub.path).buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Define who Trigify.io is",
        memoryBootstrap: "# Otto agent bootstrap\nBOOTSTRAP-SENTINEL"
      ))
    let codexPrompt = try #require(codexSpec.arguments.last)
    #expect(codexPrompt == "Define who Trigify.io is")
    let developerInstructions = try #require(
      codexSpec.arguments.first { $0.hasPrefix("developer_instructions=") })
    #expect(developerInstructions.contains("BOOTSTRAP-SENTINEL"))
    #expect(developerInstructions.contains("Existing browser pages are agent-controllable"))
    #expect(developerInstructions.contains("use docs.create for user-facing documents"))
    #expect(developerInstructions.contains("terminal.wait"))
    #expect(!developerInstructions.contains("Task from the user"))

    // Resumed turns receive the current instructions again so edits take effect immediately.
    let resumed = try await CodexAdapter(executablePath: codexStub.path).buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Continue",
        resumeSessionID: "codex-session",
        profileInstructions: "You are Test. Do in-depth research.",
        memoryBootstrap: "# Otto agent bootstrap\nBOOTSTRAP-SENTINEL"
      ))
    #expect(resumed.arguments.last == "Continue")
    let resumedInstructions = try #require(
      resumed.arguments.first { $0.hasPrefix("developer_instructions=") })
    #expect(resumedInstructions.contains("You are Test. Do in-depth research."))
    #expect(resumedInstructions.contains("BOOTSTRAP-SENTINEL"))

    let hermes = try stubProvider(named: "hermes")
    let bridge = try stubProvider(named: "otto-hermes-bridge")
    defer {
      try? FileManager.default.removeItem(at: hermes.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: bridge.deletingLastPathComponent())
    }
    let hermesSpec = try await HermesAdapter(
      executablePath: hermes.path,
      bridgePath: bridge.path,
      configurationProvider: { HermesConnectionConfiguration() }
    ).buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Define who Trigify.io is",
        memoryBootstrap: "# Otto agent bootstrap\nBOOTSTRAP-SENTINEL"
      ))
    let promptIndex = try #require(hermesSpec.arguments.firstIndex(of: "--prompt"))
    #expect(hermesSpec.arguments[promptIndex + 1].contains("BOOTSTRAP-SENTINEL"))
    #expect(hermesSpec.arguments[promptIndex + 1].contains("Define who Trigify.io is"))
  }

  @Test("Claude delivers the memory bootstrap through its appended system prompt")
  func claudeBootstrapDelivery() async throws {
    let stub = try stubProvider(named: "claude")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let spec = try await ClaudeCodeAdapter(executablePath: stub.path).buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Task",
        ottoMCPExecutable: "/opt/otto/otto-mcp",
        memoryBootstrap: "# Otto agent bootstrap\nBOOTSTRAP-SENTINEL"
      ))
    let promptIndex = try #require(spec.arguments.firstIndex(of: "--append-system-prompt"))
    let systemPrompt = spec.arguments[promptIndex + 1]
    #expect(systemPrompt.contains("BOOTSTRAP-SENTINEL"))
    // Otto guidance and bootstrap travel as one appended prompt, guidance first.
    #expect(systemPrompt.contains("Users access conversations in Chat and files in Documents"))
    #expect(systemPrompt.contains("use docs.create for user-facing documents"))
    #expect(!systemPrompt.contains("You are running inside a node on the Otto spatial canvas"))
    #expect(!systemPrompt.contains("document.create so every agent"))
  }

  @Test("Both providers write the bridge's control credentials into their MCP configuration")
  func ottoMCPControlEnvironmentPassThrough() async throws {
    // Provider CLIs spawn MCP servers with a scrubbed environment: without explicit env config,
    // otto-mcp exits with "Missing Otto control environment" and the handshake fails.
    let controlEnvironment = [
      "OTTO_CONTROL_SOCKET": "/tmp/otto-ctl.sock",
      "OTTO_CONTROL_TOKEN": "scoped-token",
    ]

    let codexStub = try stubProvider(named: "codex")
    defer { try? FileManager.default.removeItem(at: codexStub.deletingLastPathComponent()) }
    let codexSpec = try await CodexAdapter(executablePath: codexStub.path).buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Task",
        ottoMCPExecutable: "/opt/otto/otto-mcp",
        controlEnvironment: controlEnvironment
      ))
    #expect(
      codexSpec.arguments.contains(
        "mcp_servers.otto.env.OTTO_CONTROL_SOCKET=\"/tmp/otto-ctl.sock\"")
    )
    #expect(
      codexSpec.arguments.contains("mcp_servers.otto.env.OTTO_CONTROL_TOKEN=\"scoped-token\"")
    )
    // No blanket approval for the otto server: terminal.run and friends keep Codex's policy.
    #expect(!codexSpec.arguments.contains { $0.contains("default_tools_approval_mode") })

    let claudeStub = try stubProvider(named: "claude")
    defer { try? FileManager.default.removeItem(at: claudeStub.deletingLastPathComponent()) }
    let claudeSpec = try await ClaudeCodeAdapter(executablePath: claudeStub.path).buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: "/tmp",
        prompt: "Task",
        ottoMCPExecutable: "/opt/otto/otto-mcp",
        controlEnvironment: controlEnvironment
      ))
    let mcpIndex = try #require(claudeSpec.arguments.firstIndex(of: "--mcp-config"))
    let config = claudeSpec.arguments[mcpIndex + 1]
    #expect(config.contains("\"OTTO_CONTROL_SOCKET\":\"/tmp/otto-ctl.sock\""))
    #expect(config.contains("\"OTTO_CONTROL_TOKEN\":\"scoped-token\""))
  }

  @Test("Supervisor injects scoped control environment into provider spawns")
  func supervisorControlEnvironment() async throws {
    let supervisor = AgentSupervisor()
    let workspaceID = UUID()
    await supervisor.setControlPlane(
      AgentControlPlane(
        socketPath: "/tmp/otto-test.sock",
        token: "scoped-test-token",
        mcpExecutable: "/opt/otto/otto-mcp",
        workspaceID: workspaceID
      ))
    let id = try await supervisor.spawnInteractive(
      adapter: EnvironmentEchoAdapter(),
      request: AgentLaunchRequest(workspacePath: "/tmp")
    )

    let expectedMarkers = [
      "OTTO_CONTROL_SOCKET=/tmp/otto-test.sock",
      "OTTO_CONTROL_TOKEN=scoped-test-token",
      "OTTO_NODE_ID=\(id.uuidString)",
      "OTTO_WORKSPACE_ID=\(workspaceID.uuidString)",
      "OTTO_MCP=/opt/otto/otto-mcp",
    ]
    var output = ""
    for _ in 0..<200 {
      output = (try? await supervisor.snapshot(agentID: id))?.output ?? ""
      if expectedMarkers.allSatisfy(output.contains) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    for marker in expectedMarkers {
      #expect(output.contains(marker))
    }
  }

  @Test(
    "Claude headless launches disable ephemeral background jobs, including resumed turns",
    arguments: [false, true])
  func claudeBackgroundLifetime(resumed: Bool) async throws {
    let stub = try stubProvider(named: "claude")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    let adapter = ClaudeCodeAdapter(executablePath: stub.path)
    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: stub.deletingLastPathComponent().path,
        prompt: "Build the app", executionStrategy: .delegated,
        resumeSessionID: resumed ? "existing-session" : nil,
        ottoMCPExecutable: "/opt/otto/otto-mcp"))
    #expect(spec.environment["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] == "1")
    #expect(spec.arguments.contains("--print"))
    let index = try #require(spec.arguments.firstIndex(of: "--append-system-prompt"))
    #expect(spec.arguments[index + 1].contains("conversation resume does not preserve"))
    #expect(spec.arguments[index + 1].contains("terminal.wait"))
    #expect(spec.arguments[index + 1].contains("do not pass run_in_background"))
    #expect(!spec.arguments.contains("Agent"))
    let interactive = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: stub.deletingLastPathComponent().path))
    #expect(interactive.environment["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] == nil)
  }

  private func stubProvider(named name: String, version: String = "9.9.9") throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-adapter-stub-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: name)
    try Data("#!/bin/sh\nprintf '\(name) \(version)\\n'\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
  }
}

private struct EnvironmentEchoAdapter: AgentAdapter {
  let provider = AgentProvider.shell
  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/usr/bin/env", version: "system")
  }
  func availableModels() async -> [AgentModel] { [] }
  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    ProcessLaunchSpec(
      executable: "/usr/bin/env",
      arguments: [],
      workingDirectory: request.workspacePath
    )
  }
}
