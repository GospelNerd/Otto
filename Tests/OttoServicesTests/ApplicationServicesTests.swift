import Combine
import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoObservability
import OttoRemote
import OttoRuntime
import OttoSecurity
import OttoServices
import OttoTools
import Testing

@MainActor
@Suite("Application services")
struct ApplicationServicesTests {
  @Test("A blocked Git snapshot cannot prevent a user's prompt reaching the agent")
  func sendsPromptAfterSnapshotTimeout() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-send-checkpoint-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = arguments
      process.currentDirectoryURL = root
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
    }
    try git(["init"])
    try git([
      "-c", "user.name=Test", "-c", "user.email=test@localhost",
      "commit", "--allow-empty", "-m", "base",
    ])
    try ".otto/\n".write(
      to: root.appendingPathComponent(".gitignore"),
      atomically: true, encoding: .utf8)
    try "blocked.txt filter=stall\n".write(
      to: root.appendingPathComponent(".gitattributes"),
      atomically: true, encoding: .utf8)
    try "test\n".write(
      to: root.appendingPathComponent("blocked.txt"),
      atomically: true, encoding: .utf8)
    try git([
      "config", "filter.stall.clean", "echo started > .git/stall-started; exec /bin/sleep 30",
    ])
    let canvas = OttoCanvas(name: "Snapshot timeout")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let nodeID = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
        .affectedNodeIDs.first)
    let services = ApplicationServices(store: store, workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    _ = try await services.supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          """
          printf 'OTTO_STATUS:IDLE\\r\\n'
          IFS= read -r prompt
          printf 'OTTO_RESULT:Completed %s\\r\\n' "$prompt"
          printf 'OTTO_STATUS:DONE\\r\\n'
          """,
        ], workingDirectory: root.path), id: nodeID)
    try await waitUntil { services.fleet[nodeID]?.state == .idle }
    let start = ContinuousClock.now
    try await services.sendPrompt(agentID: nodeID, prompt: "send despite stalled snapshot")
    #expect(start.duration(to: .now) < .seconds(5))
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/stall-started").path)
    )
    try await waitUntil { services.fleet[nodeID]?.state == .done }
    #expect(services.fleet[nodeID]?.result == "Completed send despite stalled snapshot")
    await services.shutdown()
  }

  @Test("Runtime projection survives a later startup failure")
  func runtimeProjectionSurvivesPartialStartup() async throws {
    let canvas = OttoCanvas(name: "Partial startup")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await registry.register(
      AgentProfileOpenTool { _, _ in
        throw ToolRegistryError.invalidInput("Duplicate registration test")
      })
    let services = ApplicationServices(store: store, registry: registry)
    await services.start()
    defer { services.stop() }

    #expect(!services.isOnline)
    #expect(services.errorMessage != nil)

    let spawned = try await services.spawnMockAgent(at: WorldPoint(x: 20, y: 30))
    try await waitUntil { services.fleet[spawned.agentID]?.state == .idle }
    try await services.sendPrompt(agentID: spawned.agentID, prompt: "still project events")
    try await waitUntil { services.fleet[spawned.agentID]?.state == .done }
    #expect(services.fleet[spawned.agentID]?.result == "Completed still project events")
  }

  @Test("A failed send remains visible when its runtime is missing")
  func failedSendUpdatesPersistedNode() async throws {
    let canvas = OttoCanvas(name: "Failed send")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let receipt = store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 10, y: 10)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    let services = ApplicationServices(store: store)

    await services.recordConversationSendFailure(
      agentID: nodeID,
      prompt: "Keep this visible",
      error: ToolRegistryError.invalidInput("No runtime is available")
    )

    let node = try #require(store.activeCanvas.nodes.first(where: { $0.id == nodeID }))
    #expect(node.status == .failed)
    #expect(node.detail.contains("No runtime is available"))
  }

  @Test("Phase 4 stores share the application lifecycle and workspace")
  func phase4Composition() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-services-phase4-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Phase 4")
    let services = ApplicationServices(
      store: CanvasStore(
        snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)),
      workspacePath: root.path)
    let profileID = UUID()
    let playbook = try await services.playbooks.capture(
      name: "Publish", profileID: profileID,
      demonstratedSteps: [
        PlaybookStep(
          instruction: "Publish", anchor: SemanticAnchor(role: "button", name: "Publish"))
      ])
    try await services.botVoices.set(
      BotVoicePreference(profileID: profileID, voiceID: "voice-clear", autoSpeak: .completions))
    #expect(await services.playbooks.all().map(\.id) == [playbook.id])
    #expect(await services.botVoices.preference(profileID: profileID).autoSpeak == .completions)
  }

  @Test("Remote Fleet connects through Keychain-backed services and disconnects explicitly")
  func remoteFleetConnection() async throws {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appending(path: "otto-svc-r-\(UUID().uuidString.prefix(10))", directoryHint: .isDirectory)
    let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let token = "services-remote-token-0123456789abcdef"
    let daemon = try RemoteDaemon(
      token: token,
      stateDirectory: state,
      workspaceRoots: [workspace]
    )
    let socket = state.appending(path: "ottod.sock").path
    let server = try RemoteSocketServer(socketPath: socket, daemon: daemon)
    defer { server.stop() }
    let canvas = OttoCanvas(name: "Remote services")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let secrets = InMemorySecretStore()
    let services = ApplicationServices(
      store: store, secrets: secrets, workspacePath: workspace.path)

    try await services.connectRemote(socketPath: socket, token: token)
    #expect(services.remoteFleet?.status == .remote)
    #expect(services.remoteFleet?.daemonID != nil)
    try await services.rotateRemoteToken(socketPath: socket)
    let rotatedToken = try #require(try await secrets.value(for: "remote.default.token"))
    #expect(rotatedToken != token)
    await #expect(throws: (any Error).self) {
      try await RemoteSocketClient(socketPath: socket, token: token).request(.heartbeat)
    }
    let rotatedHeartbeat = try await RemoteSocketClient(socketPath: socket, token: rotatedToken)
      .request(.heartbeat).decode(RemoteHeartbeat.self)
    let daemonID = await daemon.id
    #expect(rotatedHeartbeat.daemonID == daemonID)
    await services.disconnectRemote()
    #expect(services.remoteFleet?.status == .offline)
    await services.disconnectRemote(forgetToken: true)
    await #expect(throws: (any Error).self) {
      try await services.connectRemote(socketPath: socket)
    }
  }

  @Test("Runtime events update Fleet and canvas node state end to end")
  func fleetPropagation() async throws {
    let canvas = OttoCanvas(name: "Services")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let services = ApplicationServices(store: store)
    await services.start()
    // The deterministic shell fixture reads one line; context injection has its own routing tests.
    await services.supervisor.setTurnContextProvider { _, _ in nil }
    defer { services.stop() }
    #expect(services.isOnline)

    let spawned = try await services.spawnMockAgent(at: WorldPoint(x: 20, y: 30))
    try await waitUntil { store.activeCanvas.nodes.first?.status == .idle }
    try await services.sendPrompt(agentID: spawned.agentID, prompt: "inspect the runtime")
    try await waitUntil { store.activeCanvas.nodes.first?.status == .done }
    try await waitUntil { services.runHistory[spawned.agentID]?.count == 1 }

    #expect(services.fleet[spawned.agentID]?.state == .done)
    #expect(
      services.runHistory[spawned.agentID]?.first?.output.contains("inspect the runtime") == true)
    #expect(store.activeCanvas.nodes.first?.detail == "Completed inspect the runtime")
    #expect(
      try await services.status(agentID: spawned.agentID).result == "Completed inspect the runtime")
    await services.shutdown()
  }

  @Test("Background completion updates its owning canvas and queues non-interrupting attention")
  func backgroundCompletionIsolation() async throws {
    let foreground = OttoCanvas(name: "Foreground")
    let background = OttoCanvas(name: "Background")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(
        canvases: [foreground, background],
        activeCanvasID: foreground.id
      ))
    let receipt = store.dispatch(
      .createNode(kind: .agent, at: WorldPoint(x: 20, y: 30)),
      targetCanvasID: background.id
    )
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    let untouchedForeground = try #require(
      store.snapshot.canvases.first(where: { $0.id == foreground.id }))
    let services = ApplicationServices(store: store)
    await services.start()
    // Keep this lifecycle test independent of the multiline memory envelope.
    await services.supervisor.setTurnContextProvider { _, _ in nil }
    defer { services.stop() }

    _ = try await services.supervisor.spawnDeterministicMock(
      id: nodeID,
      canvasID: background.id
    )
    try await waitUntil {
      store.snapshot.canvases.first(where: { $0.id == background.id })?
        .nodes.first(where: { $0.id == nodeID })?.status == .idle
    }
    try await services.sendPrompt(agentID: nodeID, prompt: "finish in the background")
    try await waitUntil {
      services.attentionItems.contains { $0.nodeID == nodeID && $0.state == .done }
    }

    #expect(store.snapshot.activeCanvasID == foreground.id)
    #expect(store.snapshot.canvases.first(where: { $0.id == foreground.id }) == untouchedForeground)
    #expect(
      store.snapshot.canvases.first(where: { $0.id == background.id })?
        .nodes.first(where: { $0.id == nodeID })?.detail
        == "Completed finish in the background"
    )
    #expect(services.attentionItems.first?.canvasID == background.id)
    services.acknowledgeAttention(nodeID: nodeID)
    #expect(services.attentionItems.isEmpty)
    await services.shutdown()
  }

  @Test("High-frequency PTY output does not republish Fleet membership to SwiftUI")
  func outputCoalescing() async throws {
    let canvas = OttoCanvas(name: "Output pressure")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let receipt = store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    let services = ApplicationServices(store: store)
    await services.start()
    defer { services.stop() }
    var fleetMembershipPublications = 0
    let observation = services.fleetStore.$models.dropFirst().sink { _ in
      fleetMembershipPublications += 1
    }
    defer { observation.cancel() }

    _ = try await services.supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "printf 'OTTO_STATUS:WORKING\\n'; i=0; while [ $i -lt 600 ]; do printf 'line-%s\\n' \"$i\"; i=$((i + 1)); done; printf 'OTTO_STATUS:DONE\\n'",
        ],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      id: nodeID,
      successfulExitState: .done
    )
    try await waitUntil {
      services.fleet[nodeID]?.state == .done
        && services.fleet[nodeID]?.output.contains("line-599") == true
    }

    // One publication adds the stable per-agent model. Subsequent output updates publish only
    // through that model, so the canvas and workspace do not rebuild for every PTY refresh.
    #expect(fleetMembershipPublications <= 1)
    await services.shutdown()
  }

  @Test("Transcript event bursts publish at a bounded render cadence")
  func transcriptCoalescing() async throws {
    let canvas = OttoCanvas(name: "Transcript pressure")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let receipt = store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    let services = ApplicationServices(store: store)
    await services.start()
    defer { services.stop() }

    _ = try await services.supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "sleep 30"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      id: nodeID,
      successfulExitState: .done
    )
    try await waitUntil { services.fleetStore.model(for: nodeID) != nil }
    let model = try #require(services.fleetStore.model(for: nodeID))
    var snapshotPublications = 0
    let observation = model.objectWillChange.sink { snapshotPublications += 1 }
    defer { observation.cancel() }

    for index in 0..<200 {
      try await services.supervisor.appendLocalTranscript(
        agentID: nodeID,
        role: .activity,
        text: "event-\(index)"
      )
    }
    try await waitUntil { services.fleet[nodeID]?.transcript.last?.text == "event-199" }

    // The 200 awaited actor calls can span several 40 ms refresh windows when the full suite is
    // running in parallel. Keep this assertion about the contract (heavy coalescing), rather than
    // tying it to how quickly one machine can enqueue the burst.
    #expect(snapshotPublications <= 20)
    #expect(services.fleet[nodeID]?.transcript.count == 200)
    await services.shutdown()
  }

  @Test("Startup rehydrates the clean transcript for an idle persisted Codex agent")
  func persistedTranscriptRestoration() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-restored-transcript-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
    let sessionID = "019fdb85-service-restore"
    let sessions = root.appending(path: ".codex/sessions/2026/08/07")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let lines = [
      "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionID)\",\"cwd\":\"\(workspace.path)\"}}",
      #"{"type":"event_msg","payload":{"type":"user_message","message":"continue the feature"}}"#,
      #"{"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"Feature complete."}}"#,
    ]
    try Data(lines.joined(separator: "\n").utf8).write(
      to: sessions.appending(path: "rollout-2026-08-07T10-19-49-\(sessionID).jsonl")
    )

    let canvas = OttoCanvas(name: "Restored")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let receipt = store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: nodeID,
        definition: AgentDefinition(
          provider: .codex,
          workingDirectory: workspace.path,
          launchCommand: "codex",
          permissionMode: "workspaceWrite",
          resumeSessionID: sessionID
        )
      )
    )
    let services = ApplicationServices(
      store: store,
      workspacePath: workspace.path,
      providerSessionHome: root
    )
    await services.start()
    defer { services.stop() }
    try await waitUntil { services.fleet[nodeID]?.transcript.count == 2 }

    #expect(services.fleet[nodeID]?.state == .idle)
    #expect(
      services.fleet[nodeID]?.transcript.map(\.text) == [
        "continue the feature", "Feature complete.",
      ])
    await services.shutdown()
  }

  @Test("Attachment imports copy assets and update persisted node metadata")
  func attachmentImport() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-service-attachments-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.txt")
    try Data("attachment body".utf8).write(to: source)
    let canvas = OttoCanvas(name: "Attachments")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let node = store.dispatch(.createNode(kind: .markdown, at: WorldPoint(x: 0, y: 0)))
    let nodeID = try #require(node.affectedNodeIDs.first)
    let services = ApplicationServices(store: store, workspacePath: root.path)

    let imported = try await services.importAttachments([source], to: nodeID)
    let attachment = try #require(imported.first)
    #expect(store.activeCanvas.nodes.first?.attachments == imported)
    #expect(attachment.relativePath.hasPrefix(".otto/attachments/"))
    #expect(
      try String(
        contentsOf: root.appending(path: attachment.relativePath),
        encoding: .utf8
      ) == "attachment body")
  }

  @Test("Real service flow records a content-free diagnostic timeline and clean exit")
  func observabilityFlow() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-service-observability-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let observability = try ObservabilityStore(
      directory: directory,
      appVersion: "1.0-test",
      operatingSystemVersion: "macOS 26.3"
    )
    let registry = ToolRegistry(auditSink: observability)
    let canvas = OttoCanvas(name: "Diagnostics")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)
    )
    let services = ApplicationServices(
      store: store,
      registry: registry,
      observability: observability,
      workspacePath: directory.path
    )
    await services.start()
    let spawned = try await services.spawnMockAgent(at: WorldPoint(x: 0, y: 0))
    try await waitUntil { store.activeCanvas.nodes.first?.status == .idle }
    let secretPrompt = "Review /Users/alice/private.swift at https://private.example"
    try await services.sendPrompt(agentID: spawned.agentID, prompt: secretPrompt)
    try await waitUntil { store.activeCanvas.nodes.first?.status == .done }
    try await waitUntil {
      services.diagnosticTimeline.contains { $0.kind == .resultExtracted }
    }

    #expect(services.diagnosticTimeline.contains { $0.kind == .toolCall })
    #expect(services.diagnosticTimeline.contains { $0.kind == .agentStateChanged })
    #expect(services.diagnosticTimeline.contains { $0.kind == .resultExtracted })
    let encoded = String(
      decoding: try JSONEncoder().encode(services.diagnosticTimeline),
      as: UTF8.self
    )
    #expect(!encoded.contains(secretPrompt))
    #expect(!encoded.contains("private.swift"))
    #expect(!encoded.contains("private.example"))
    await services.shutdown()

    let nextSession = try ObservabilityStore(directory: directory, appVersion: "1.0-test")
    try await nextSession.beginSession()
    #expect(!(await nextSession.snapshot().previousSessionAbnormal))
    try await nextSession.endSession()
  }

  @Test("A detected development URL opens a real browser node through shared tools")
  func detectedPreviewFlow() async throws {
    let canvas = OttoCanvas(name: "Preview")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)
    )
    let services = ApplicationServices(store: store)
    await services.start()
    defer { services.stop() }
    let output = "Server ready — http://localhost:4317/review"
    let detected = try #require(LocalhostURLDetector.urls(in: output).first)
    let opened = try await services.openBrowser(
      url: detected.absoluteString,
      at: WorldPoint(x: 240, y: 80)
    )
    #expect(opened.node.kind == .browser)
    #expect(opened.node.content == .browser(url: "http://localhost:4317/review"))
    #expect(store.activeCanvas.nodes.map(\.id) == [opened.node.id])
    #expect(store.activeCanvas.nodes.first?.content == opened.node.content)
    await services.shutdown()
  }

  @Test("Quit preparation stops every supervised process before returning")
  func quitPreparation() async throws {
    let canvas = OttoCanvas(name: "Quit safety")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)
    )
    let services = ApplicationServices(store: store)
    await services.start()
    defer { services.stop() }
    let spawned = try await services.spawnMockAgent(at: WorldPoint(x: 0, y: 0))
    try await waitUntil { services.activeProcessCount == 1 }

    await services.stopAllProcesses()
    try await waitUntil { services.fleet[spawned.agentID]?.exitCode != nil }

    #expect(services.activeProcessCount == 0)
    #expect(await services.supervisor.activeProcessIDs().isEmpty)
    await services.shutdown()
  }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(15)
  while ContinuousClock.now < deadline {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for service state")
}
