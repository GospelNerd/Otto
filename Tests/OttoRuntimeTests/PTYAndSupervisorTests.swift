import Foundation
import OttoModels
import OttoRuntime
import Testing

#if os(macOS)
  import Darwin
#endif

@Suite("PTY transport")
struct PTYTransportTests {
  @Test("PTY transports interactive input and output")
  func interactiveRoundTrip() async throws {
    let process = try PTYProcess.spawn(
      ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'ready\\n'; IFS= read -r line; printf 'echo:%s\\n' \"$line\""],
        workingDirectory: FileManager.default.currentDirectoryPath
      ))

    let probe = OutputProbe()
    let collector = Task {
      for await data in process.output { await probe.append(data) }
    }
    defer { collector.cancel() }
    try await waitForOutput("ready", probe: probe)
    try process.send(text: "hello otto\n")
    try await waitForOutput("echo:hello otto", probe: probe)
    let output = await probe.text
    #expect(output.contains("ready"))
    #expect(output.contains("echo:hello otto"))
  }

  @Test("PTY drains buffered output after a short-lived child exits")
  func drainsOutputAfterExit() async throws {
    let process = try PTYProcess.spawn(
      ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'final-output'"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ))

    var output = ""
    for await data in process.output {
      output += String(decoding: data, as: UTF8.self)
    }

    #expect(output == "final-output")
  }

  @Test("PTY exposes terminal dimensions")
  func resize() async throws {
    let process = try PTYProcess.spawn(
      ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "sleep 0.1; stty size"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ))
    try process.resize(columns: 132, rows: 43)
    let output = await collect(process.output, until: "43 132", timeout: .seconds(2))
    #expect(output.contains("43 132"))
  }

  @Test("A same-size refresh signals a live terminal application to repaint")
  func sameSizeRefresh() async throws {
    let process = try PTYProcess.spawn(
      ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "trap 'printf repaint\\n' WINCH; printf ready\\n; while :; do sleep 0.05; done",
        ],
        workingDirectory: FileManager.default.currentDirectoryPath,
        columns: 91,
        rows: 27
      ))
    let probe = OutputProbe()
    let collector = Task {
      for await data in process.output { await probe.append(data) }
    }
    defer {
      collector.cancel()
      try? process.forceTerminate()
    }
    try await waitForOutput("ready", probe: probe)
    try process.resize(columns: 91, rows: 27)
    try await waitForOutput("repaint", probe: probe)
  }

  #if os(macOS)
    @Test("Closing supervision terminates the provider process group")
    func closingSupervisionTerminatesProcessGroup() async throws {
      let process = try PTYProcess.spawn(
        ProcessLaunchSpec(
          executable: "/bin/sh",
          arguments: [
            "-c", "sleep 30 & child=$!; printf 'child=%s\\n' \"$child\"; wait \"$child\"",
          ],
          workingDirectory: FileManager.default.currentDirectoryPath
        ))
      let probe = OutputProbe()
      let collector = Task {
        for await data in process.output { await probe.append(data) }
      }
      defer {
        collector.cancel()
        try? process.forceTerminate()
      }

      try await waitForOutput("child=", probe: probe)
      let childLine = await probe.text.split(separator: "\n").first {
        $0.hasPrefix("child=")
      }
      let childPIDText = childLine.map {
        $0.dropFirst("child=".count).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let childPID = try #require(childPIDText.flatMap(pid_t.init))

      process.close()

      let exitCode = await collectExit(process.exit, timeout: .seconds(5))
      #expect(exitCode != nil)
      try await waitForOSProcessExit(childPID)
    }

    @Test("Lifetime monitor is not a provider child process")
    func lifetimeMonitorIsNotProviderChild() async throws {
      let process = try PTYProcess.spawn(
        ProcessLaunchSpec(
          executable: "/bin/sleep",
          arguments: ["30"],
          workingDirectory: FileManager.default.currentDirectoryPath
        ))
      defer { process.close() }

      // Polls until the transient pre-exec helper is gone; a loaded CI runner can take seconds.
      let deadline = ContinuousClock.now + .seconds(10)
      var childCount: Int32 = -1
      while ContinuousClock.now < deadline {
        var childPIDs = [pid_t](repeating: 0, count: 8)
        childCount = childPIDs.withUnsafeMutableBytes { buffer in
          proc_listchildpids(process.processIdentifier, buffer.baseAddress, Int32(buffer.count))
        }
        if childCount <= 0 { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(childCount <= 0)
    }
  #endif
}

private actor OutputProbe {
  private(set) var text = ""
  func append(_ data: Data) { text += String(decoding: data, as: UTF8.self) }
}

private func waitForOutput(_ marker: String, probe: OutputProbe) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if await probe.text.contains(marker) { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for PTY output: \(marker)")
}

@Suite("Agent supervisor")
struct AgentSupervisorTests {
  @Test("Stale controls cannot stop or interrupt a replacement run")
  func staleRunControls() async throws {
    let supervisor = AgentSupervisor()
    let id = UUID()
    _ = try await supervisor.spawnInteractive(
      adapter: ScriptedInteractiveAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: nil, permissionMode: .workspaceWrite), id: id)
    let first = try #require(await supervisor.snapshot(agentID: id).runID)
    try await supervisor.stop(agentID: id, expectedRunID: first)
    _ = try await supervisor.spawnInteractive(
      adapter: ScriptedInteractiveAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: nil, permissionMode: .workspaceWrite), id: id)
    let second = try #require(await supervisor.snapshot(agentID: id).runID)
    #expect(first != second)
    await #expect(throws: RuntimeError.staleRun(first)) {
      try await supervisor.stop(agentID: id, expectedRunID: first)
    }
    await #expect(throws: RuntimeError.staleRun(first)) {
      try await supervisor.interrupt(agentID: id, expectedRunID: first)
    }
    #expect(try await supervisor.snapshot(agentID: id).state == .idle)
    try await supervisor.stop(agentID: id, expectedRunID: second)
  }

  @Test("Each prompt gets a new control identity within the same provider process")
  func promptRunIdentity() async throws {
    let supervisor = AgentSupervisor()
    let id = UUID()
    _ = try await supervisor.spawnInteractive(
      adapter: ScriptedInteractiveAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: nil, permissionMode: .workspaceWrite), id: id)
    let previous = try #require(await supervisor.snapshot(agentID: id).runID)
    try await supervisor.sendPrompt(agentID: id, prompt: "Current work")
    let current = try #require(await supervisor.snapshot(agentID: id).runID)
    #expect(current != previous)
    await #expect(throws: RuntimeError.staleRun(previous)) {
      try await supervisor.stop(agentID: id, expectedRunID: previous)
    }
    try await supervisor.stop(agentID: id, expectedRunID: current)
  }

  @Test("Interactive provider agents start idle and accept a later prompt")
  func interactiveProviderStartsWithoutPrompt() async throws {
    let supervisor = AgentSupervisor()
    let id = UUID()
    _ = try await supervisor.spawnInteractive(
      adapter: ScriptedInteractiveAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: nil,
        permissionMode: .workspaceWrite
      ),
      id: id
    )

    #expect(try await supervisor.snapshot(agentID: id).state == .idle)
    #expect(
      try await supervisor.snapshot(agentID: id).executionMode == .interactiveProvider)
    try await supervisor.sendPrompt(agentID: id, prompt: "hello later")
    try await waitForOutput("heard:hello later", id: id, supervisor: supervisor)
    #expect(try await supervisor.snapshot(agentID: id).output.contains("heard:hello later"))
    try await supervisor.stop(agentID: id)
  }

  @Test("Interactive provider submission sends a carriage-return Enter key")
  func interactiveProviderUsesCarriageReturn() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawn(
      provider: .codex,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "stty raw -echo; printf 'ready\\n'; od -An -t x1 -N3 | tr -d ' \\n'; printf '\\n'; sleep 5",
        ],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      initialState: .idle,
      executionMode: .interactiveProvider
    )
    try await waitForOutput("ready", id: id, supervisor: supervisor)
    try await supervisor.sendInput(agentID: id, text: "go")
    try await waitForOutput("676f0d", id: id, supervisor: supervisor)
    try await supervisor.stop(agentID: id)
  }

  @Test("Prose on an interactive screen that mentions approval does not raise a phantom card")
  func interactiveProseIsNotAPermissionPrompt() async throws {
    let supervisor = AgentSupervisor()
    // The squashed screen line a resumed Claude TUI painted for an agent's own reply, which
    // quoted an approval card. Before the fix this became WAITING_PERMISSION with no request
    // behind it, and Approve only typed Enter into the agent's input box.
    let id = try await supervisor.spawn(
      provider: .claudeCode,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          #"printf 'OttoDevshowing"Permissionrequired·Bash:echohi>a.txt"withApproveandDeny\nready\n'; sleep 5"#,
        ],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: .claude(ClaudeOutputParser()),
      initialState: .idle,
      executionMode: .interactiveProvider
    )
    try await waitForOutput("ready", id: id, supervisor: supervisor)
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.state != .waitingPermission)
    #expect(snapshot.attentionReason == nil)
    try await supervisor.stop(agentID: id)
  }

  @Test("A provider auth failure at its idle prompt fails the run and clears attention")
  func providerAuthFailureFailsRunAndClearsAttention() async throws {
    // Issue #54: Claude Code's OAuth session expires and the CLI prints its failure line while
    // staying at its idle prompt. The prose must read as a failed run that needs re-authentication
    // — not as a question waiting on the person — so attention resolves instead of lingering as
    // a Home "Needs you" card and buddy bubble that re-post forever.
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawn(
      provider: .claudeCode,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          #"printf 'ready\n'; while IFS= read -r line; do :; done"#,
        ],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: .claude(ClaudeOutputParser()),
      initialState: .idle,
      executionMode: .interactiveProvider
    )
    try await waitForOutput("ready", id: id, supervisor: supervisor)
    try await supervisor.sendInput(
      agentID: id, text: "Failed to authenticate: OAuth session expired")
    try await waitForState(.failed, id: id, supervisor: supervisor)
    let snapshot = try await supervisor.snapshot(agentID: id)
    // The failure is visible in the conversation, and the run left the waiting state: a dead
    // provider is not a question the person can answer in chat.
    #expect(
      snapshot.transcript.contains {
        $0.kind == .notice && $0.text.contains("Failed to authenticate")
      })
    #expect(snapshot.state != .waitingUser && snapshot.state != .waitingPermission)
    try await supervisor.stop(agentID: id)
  }

  @Test("Approve or Deny on a card with nothing behind it clears the card")
  func dismissUnbackedAttention() async throws {
    let supervisor = AgentSupervisor()
    // A structured run still reads a stray non-JSON line as a guessed wait, with no request parked.
    let id = try await supervisor.spawn(
      provider: .claudeCode,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'Permission required: approve this?\n'; sleep 5"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: .claude(ClaudeOutputParser()),
      initialState: .working
    )
    try await waitForState(.waitingPermission, id: id, supervisor: supervisor)
    #expect(await !supervisor.hasPendingPermission(agentID: id))
    #expect(try await supervisor.dismissUnbackedAttention(agentID: id))
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.state == .idle)
    #expect(snapshot.attentionReason == nil)
    // Nothing left to clear: a second call is a no-op.
    #expect(try await !supervisor.dismissUnbackedAttention(agentID: id))
    try await supervisor.stop(agentID: id)
  }

  @Test("A failed prompt write does not strand the agent in working state")
  func failedPromptWritePreservesCompletedState() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/usr/bin/true",
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      successfulExitState: .done
    )
    try await waitForExit(id: id, supervisor: supervisor)

    await #expect(throws: RuntimeError.transportClosed) {
      try await supervisor.sendPrompt(agentID: id, prompt: "too late")
    }
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.state == .done)
    #expect(snapshot.transcript.isEmpty)
  }

  @Test("A quiet returned native prompt completes an interactive agent with a bounded excerpt")
  func interactiveProviderCompletion() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawnInteractive(
      adapter: CompletingInteractiveAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        permissionMode: .workspaceWrite
      )
    )
    try await supervisor.sendInput(agentID: id, text: "do it")
    try await waitForState(.done, id: id, supervisor: supervisor)
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.result?.contains("finished the requested work") == true)
    #expect((snapshot.result?.count ?? 0) <= 2_000)
    #expect(snapshot.transcript.first?.role == .user)
    #expect(snapshot.transcript.first?.text == "do it")
    // Scraped TUI screens inform the result summary only; the conversation surface must never
    // present terminal paint as an assistant message.
    #expect(!snapshot.transcript.contains { $0.role == .assistant })
    try await supervisor.stop(agentID: id)
  }

  @Test("New and resumed provider tasks refresh memory while preserving the visible user message")
  func taskMemoryDelivery() async throws {
    let supervisor = AgentSupervisor()
    let capture = MemoryRequestCapture()
    let adapter = MemoryCapturingAdapter(capture: capture)
    await supervisor.setTurnContextProvider { _, query in "fresh memory for \(query)" }
    let workspace = FileManager.default.temporaryDirectory.path
    let id = try await supervisor.spawnOneShot(
      adapter: adapter, request: AgentLaunchRequest(workspacePath: workspace, prompt: "first task"))
    try await waitForExit(id: id, supervisor: supervisor)
    let first = await capture.latest()
    #expect(first?.prompt?.contains("fresh memory for first task") == true)
    #expect(PromptSubmission.originalUserText(first?.prompt ?? "") == "first task")
    #expect(try await supervisor.snapshot(agentID: id).lastPrompt == "first task")
    _ = try await supervisor.resumeOneShot(
      adapter: adapter,
      request: AgentLaunchRequest(workspacePath: workspace, prompt: "second task"),
      sessionID: "saved-session", id: id)
    try await waitForExit(id: id, supervisor: supervisor)
    let resumed = await capture.latest()
    #expect(resumed?.prompt?.contains("fresh memory for second task") == true)
    #expect(resumed?.resumeSessionID == "saved-session")
    #expect(try await supervisor.snapshot(agentID: id).lastPrompt == "second task")
  }

  @Test("Repeating an identical tool call keeps every call, but an instant duplicate is dropped")
  func repeatedToolCallsStayInTranscript() async throws {
    let supervisor = AgentSupervisor()
    await supervisor.setTurnContextProvider { _, _ in nil }
    let id = try await supervisor.spawnOneShot(
      adapter: RepeatingToolCallAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.temporaryDirectory.path, prompt: "loop"))
    try await waitForExit(id: id, supervisor: supervisor, timeout: .seconds(20))
    let calls = try await supervisor.snapshot(agentID: id).transcript.filter {
      $0.kind == .toolCall
    }
    #expect(calls.count == 3)
    #expect(calls.allSatisfy { $0.text == "sleep 25; echo same" })
  }

  @Test("A shell agent runs its prompt as written even when turn memory is on")
  func shellPromptSkipsMemoryEnvelope() async throws {
    let supervisor = AgentSupervisor()
    // The envelope contains a ")" on its second line, which zsh and sh reject as a command.
    await supervisor.setTurnContextProvider { _, _ in "remembered (retrieved data)" }
    let id = try await supervisor.spawnOneShot(
      adapter: ShellAdapter(executablePath: "/bin/sh"),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.temporaryDirectory.path,
        prompt: "echo SHELL-PROMPT-OK"))
    try await waitForExit(id: id, supervisor: supervisor)
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.output.contains("SHELL-PROMPT-OK"))
    #expect(!snapshot.output.contains("parse error"))
    #expect(!snapshot.output.contains("syntax error"))
  }

  @Test("Provider launches receive the memory bootstrap and record its hash")
  func bootstrapInjection() async throws {
    let supervisor = AgentSupervisor()
    await supervisor.setMemoryBootstrapProvider { _, permissionMode in
      AgentBootstrapPacket(
        text: "# Otto agent bootstrap\npermissions: \(permissionMode.rawValue)",
        hash: "fixture-hash"
      )
    }
    let workspace = FileManager.default.temporaryDirectory
      .appending(path: "otto-bootstrap-\(UUID().uuidString)", directoryHint: .isDirectory).path
    try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: workspace) }

    let id = try await supervisor.spawnInteractive(
      adapter: CompletingInteractiveAdapter(),
      request: AgentLaunchRequest(workspacePath: workspace, permissionMode: .workspaceWrite)
    )
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.bootstrapHash == "fixture-hash")
    let inspectionCopy = (workspace as NSString)
      .appendingPathComponent(".otto/bootstrap/\(id.uuidString).md")
    let contents = FileManager.default.contents(atPath: inspectionCopy)
      .map { String(decoding: $0, as: UTF8.self) }
    #expect(contents?.contains("permissions: workspaceWrite") == true)
    try await supervisor.stop(agentID: id)
  }

  @Test("Claude workspace trust is confirmed inside the authorized interactive harness")
  func confirmsClaudeWorkspaceTrust() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawnInteractive(
      adapter: ClaudeTrustPromptAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        permissionMode: .workspaceWrite
      )
    )

    try await waitForOutput("trust-confirmed", id: id, supervisor: supervisor)
    // The output can land before the supervisor finishes clearing the trust prompt's attention
    // state; on a loaded runner, wait for the settled state rather than sampling it once.
    try await waitForState(.idle, id: id, supervisor: supervisor)
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.state == .idle)
    #expect(snapshot.attentionReason == nil)
    try await supervisor.stop(agentID: id)
  }

  @Test("Blocking update choices surface as agent attention and accept an answer")
  func surfacesInteractiveUpdateChoice() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawnInteractive(
      adapter: UpdatePromptAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        permissionMode: .workspaceWrite
      )
    )

    try await waitForState(.waitingUser, id: id, supervisor: supervisor)
    #expect(
      try await supervisor.snapshot(agentID: id).attentionReason == "Agent update choice required")
    try await supervisor.sendInput(agentID: id, text: "2")
    try await waitForOutput("choice:2", id: id, supervisor: supervisor)
    #expect(try await supervisor.snapshot(agentID: id).state == .working)
    try await supervisor.stop(agentID: id)
  }

  @Test("A trust screen footer read after the automatic answer is not a new prompt")
  func lateTrustFooterIsIgnored() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawnInteractive(
      adapter: SplitClaudeTrustPromptAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        permissionMode: .workspaceWrite
      )
    )

    try await waitForOutput("trust-confirmed", id: id, supervisor: supervisor)
    try await Task.sleep(for: .milliseconds(300))
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.state == .idle)
    #expect(snapshot.attentionReason == nil)
    try await supervisor.stop(agentID: id)
  }

  @Test("Codex MCP consent remains answerable after title animations and quiet output")
  func codexApprovalIsNotDone() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawnInteractive(
      adapter: CodexApprovalAdapter(),
      request: AgentLaunchRequest(workspacePath: FileManager.default.currentDirectoryPath))
    try await supervisor.sendInput(agentID: id, text: "inspect workspace")
    try await waitForState(.waitingPermission, id: id, supervisor: supervisor)
    try await Task.sleep(for: .seconds(2))
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.state == .waitingPermission)
    let choice = try #require(snapshot.pendingChoice)
    #expect(choice.choices.count == 4)
    try await supervisor.resolveChoice(agentID: id, answer: choice.choices[0])
    try await waitForOutput("approved", id: id, supervisor: supervisor)
    #expect(try await supervisor.snapshot(agentID: id).pendingChoice == nil)
    try await supervisor.stop(agentID: id)
  }

  @Test("A Kimi sign-in menu becomes a chat choice answered with cursor keys")
  func kimiLoginMenuAnsweredFromChat() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawnInteractive(
      adapter: KimiLoginPromptAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        permissionMode: .workspaceWrite
      )
    )

    try await waitForState(.waitingUser, id: id, supervisor: supervisor)
    // The menu can arrive over several PTY reads; wait (bounded) until every row has painted.
    let deadline = ContinuousClock.now + .seconds(10)
    var snapshot = try await supervisor.snapshot(agentID: id)
    while (snapshot.pendingChoice?.choices.count ?? 0) < 3, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
      snapshot = try await supervisor.snapshot(agentID: id)
    }
    #expect(snapshot.attentionToken == "kimi-login-platform")
    let choice = try #require(snapshot.pendingChoice)
    try #require(choice.choices.count == 3)
    #expect(choice.choices.first == "Kimi Code (OAuth)")

    // Answering the third option must reach the TUI as two downs and Enter. Typing the label
    // would leave the harness sitting on the first row.
    try await supervisor.resolveChoice(agentID: id, answer: choice.choices[2])
    // od renders the delivered bytes, so this matches the escape sequence itself rather than the
    // tty's echo of it: two cursor-down sequences, then the Enter that commits the row.
    try await waitForOutput("033[B033[B", id: id, supervisor: supervisor)
    #expect(try await supervisor.snapshot(agentID: id).pendingChoice == nil)
    try await supervisor.stop(agentID: id)
  }

  @Test("One-shot and terminal processes retain distinct execution modes")
  func executionModes() async throws {
    let supervisor = AgentSupervisor()
    let terminalID = try await supervisor.spawnTerminal(
      shell: "/bin/sh",
      command: "printf done",
      workingDirectory: FileManager.default.currentDirectoryPath
    )
    #expect(
      try await supervisor.snapshot(agentID: terminalID).executionMode == .terminal)

    let oneShotID = UUID()
    _ = try await supervisor.spawnOneShot(
      adapter: ScriptedOneShotAdapter(),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: "hello",
        permissionMode: .readOnly
      ),
      id: oneShotID
    )
    #expect(
      try await supervisor.snapshot(agentID: oneShotID).executionMode == .oneShotProvider)
    await supervisor.stopAll()
  }

  @Test("Terminal output search is case-insensitive, numbered, repeated, and bounded")
  func terminalOutputSearch() {
    let output = "alpha needle\n\u{001B}[31mNEEDLE\u{001B}[0m twice needle\nno match"
    let matches = TerminalOutputSearch.matches(query: "needle", in: output, limit: 2)
    #expect(
      matches == [
        TerminalSearchMatch(lineNumber: 1, column: 7, line: "alpha needle"),
        TerminalSearchMatch(lineNumber: 2, column: 1, line: "NEEDLE twice needle"),
      ])
    #expect(TerminalOutputSearch.matches(query: "   ", in: output).isEmpty)
    #expect(TerminalOutputSearch.plainText(output) == "alpha needle\nNEEDLE twice needle\nno match")
  }

  @Test("Terminal renderer appends deltas and resets after scrollback eviction or session changes")
  func terminalRenderDeltas() {
    let initial = TerminalRenderPlanner.update(
      output: "hello",
      startOffset: 0,
      endOffset: 5,
      sessionKey: "live",
      renderedSessionKey: nil,
      renderedEndOffset: 0
    )
    #expect(initial.resetsTerminal)
    #expect(String(decoding: initial.bytes, as: UTF8.self) == "hello")

    let appended = TerminalRenderPlanner.update(
      output: "hello world",
      startOffset: 0,
      endOffset: 11,
      sessionKey: "live",
      renderedSessionKey: "live",
      renderedEndOffset: 5
    )
    #expect(!appended.resetsTerminal)
    #expect(String(decoding: appended.bytes, as: UTF8.self) == " world")

    let evicted = TerminalRenderPlanner.update(
      output: "world",
      startOffset: 6,
      endOffset: 11,
      sessionKey: "live",
      renderedSessionKey: "live",
      renderedEndOffset: 5
    )
    #expect(evicted.resetsTerminal)
    let historical = TerminalRenderPlanner.update(
      output: "old run",
      startOffset: 0,
      endOffset: 7,
      sessionKey: "history",
      renderedSessionKey: "live",
      renderedEndOffset: 11
    )
    #expect(historical.resetsTerminal)

    let nativeReattach = TerminalRenderPlanner.update(
      output: "historical cursor-addressed TUI output",
      startOffset: 0,
      endOffset: 38,
      sessionKey: "native",
      renderedSessionKey: nil,
      renderedEndOffset: 0,
      replayExistingOutput: false
    )
    #expect(nativeReattach.resetsTerminal)
    #expect(nativeReattach.bytes.isEmpty)
    #expect(nativeReattach.renderedEndOffset == 38)
  }

  @Test("Supervisor retains bounded per-node run history across reused process IDs")
  func runHistory() async throws {
    let supervisor = AgentSupervisor(historyLimit: 2, historyOutputCapacity: 64)
    let nodeID = UUID()
    for marker in ["first", "second", "third"] {
      _ = try await supervisor.spawnTerminal(
        shell: "/bin/sh",
        command: "printf '\(marker)-run-output\\n'",
        workingDirectory: FileManager.default.currentDirectoryPath,
        id: nodeID
      )
      try await waitForExit(id: nodeID, supervisor: supervisor)
    }
    let history = await supervisor.history(agentID: nodeID)
    #expect(history.count == 2)
    #expect(history[0].output.contains("second-run-output"))
    #expect(history[1].output.contains("third-run-output"))
    #expect(history.allSatisfy { $0.output.utf8.count <= 64 })
  }

  @Test("Thirty concurrent terminal runtimes complete without output corruption")
  func thirtyConcurrentRuntimes() async throws {
    let supervisor = AgentSupervisor()
    var expected: [UUID: String] = [:]
    for index in 0..<30 {
      let id = UUID()
      let marker = "runtime-\(index)-\(id.uuidString.prefix(8))"
      expected[id] = marker
      _ = try await supervisor.spawn(
        provider: .shell,
        specification: ProcessLaunchSpec(
          executable: "/bin/sh",
          arguments: [
            "-c", "printf 'OTTO_RESULT:\(marker)\\nOTTO_STATUS:DONE\\n'",
          ],
          workingDirectory: FileManager.default.currentDirectoryPath
        ),
        id: id
      )
    }
    for (id, marker) in expected {
      try await waitForState(.done, id: id, supervisor: supervisor)
      try await waitForExit(id: id, supervisor: supervisor)
      let snapshot = try await supervisor.snapshot(agentID: id)
      #expect(snapshot.result == marker)
      #expect(snapshot.output.contains(marker))
      #expect(snapshot.exitCode == 0)
    }
    #expect(await supervisor.allSnapshots().count == 30)
  }

  @Test("High-volume PTY output remains bounded under backpressure")
  func highVolumeOutput() async throws {
    let supervisor = AgentSupervisor(scrollbackCapacity: 65_536)
    let id = try await supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "yes otto | head -c 500000"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      successfulExitState: .done
    )
    try await waitForState(
      .done,
      id: id,
      supervisor: supervisor,
      timeout: .seconds(15)
    )
    try await waitForExit(id: id, supervisor: supervisor)
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.output.utf8.count <= 65_536)
    #expect(snapshot.outputEndOffset >= 500_000)
    #expect(snapshot.outputStartOffset == snapshot.outputEndOffset - 65_536)
  }

  @Test("Deterministic agent traverses IDLE, WORKING, and DONE with a result")
  func deterministicLifecycle() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawnDeterministicMock()
    try await waitForState(.idle, id: id, supervisor: supervisor)
    try await supervisor.sendPrompt(agentID: id, prompt: "map authentication")
    try await waitForState(.done, id: id, supervisor: supervisor)

    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.state == .done)
    #expect(snapshot.confidence == 1)
    #expect(snapshot.result == "Completed map authentication")
    #expect(snapshot.output.contains("Working on: map authentication"))
    #expect(snapshot.transcript.map(\.role) == [.user, .assistant])
    #expect(
      snapshot.transcript.map(\.text) == [
        "map authentication", "Completed map authentication",
      ])
  }

  @Test("Hidden room turns do not appear in a bot's private transcript")
  func hiddenRoomTurnIsTranscriptIsolated() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawnDeterministicMock()
    try await waitForState(.idle, id: id, supervisor: supervisor)
    try await supervisor.sendPrompt(
      agentID: id,
      prompt: PromptSubmission.hiddenControlPrompt("Reply only in the Staff room")
    )
    try await waitForState(.done, id: id, supervisor: supervisor)

    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.transcript.isEmpty)
    let roomReply = await supervisor.consumeHiddenTurnReply(agentID: id)
    #expect(roomReply?.contains("Completed") == true)
    #expect(try await supervisor.snapshot(agentID: id).transcript.isEmpty)
  }

  @Test("Streaming deltas do not publish duplicate working lifecycle events")
  func streamingStateDeduplication() async throws {
    let supervisor = AgentSupervisor()
    let events = supervisor.events
    let collector = Task { () -> Int in
      var workingEvents = 0
      for await event in events {
        switch event {
        case .stateChanged(_, let state, _):
          if state == .working { workingEvents += 1 }
        case .exited:
          return workingEvents
        default:
          break
        }
      }
      return workingEvents
    }
    defer { collector.cancel() }
    let script = #"""
      printf '%s\n' '{"type":"message.start"}'
      i=0
      while [ "$i" -lt 100 ]; do
        printf '%s\n' '{"type":"message.delta","payload":{"text":"x"}}'
        i=$((i + 1))
      done
      printf '%s\n' '{"type":"message.complete","payload":{"text":"Finished"}}'
      """#
    let id = try await supervisor.spawn(
      provider: .hermes,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh", arguments: ["-c", script],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: .hermes(HermesOutputParser())
    )
    try await waitForState(.done, id: id, supervisor: supervisor)
    #expect(await collector.value == 1)
    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.result == "Finished")
    #expect(snapshot.transcript.contains { $0.text == "Finished" })
  }

  @Test("Structured provider output drives supervisor completion and result extraction")
  func structuredProviderLifecycle() async throws {
    let supervisor = AgentSupervisor()
    let script = #"""
      printf '%s\n' '{"type":"thread.started","thread_id":"fixture"}'
      printf '%s\n' '{"type":"turn.started"}'
      printf '%s\n' '{"type":"item.completed","item":{"type":"error","message":"nonfatal MCP warning"}}'
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Structured final result"}}'
      printf '%s\n' '{"type":"turn.completed"}'
      """#
    let id = try await supervisor.spawn(
      provider: .codex,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", script],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: .codex(CodexOutputParser())
    )
    try await waitForState(.done, id: id, supervisor: supervisor)

    let snapshot = try await supervisor.snapshot(agentID: id)
    #expect(snapshot.state == .done)
    #expect(snapshot.result == "Structured final result")
    #expect(snapshot.structuredResult?.summaryCandidate == "Structured final result")
    #expect(snapshot.output.contains("nonfatal MCP warning"))
    #expect(snapshot.transcript.last?.role == .assistant)
    #expect(snapshot.transcript.last?.text == "Structured final result")
  }

  @Test("A turn that adds no reply leaves the previous reply's time and tokens alone")
  func turnStatsStayOnTheirOwnTurn() async throws {
    let supervisor = AgentSupervisor()
    let id = UUID()
    func run(result: String, inputTokens: Int) async throws {
      let line =
        #"{"type":"result","subtype":"success","result":"\#(result)","duration_ms":1000,"#
        + #""usage":{"input_tokens":\#(inputTokens),"output_tokens":5}}"#
      _ = try await supervisor.spawn(
        provider: .claudeCode,
        specification: ProcessLaunchSpec(
          executable: "/bin/sh", arguments: ["-c", "printf '%s\\n' '\(line)'"],
          workingDirectory: FileManager.default.currentDirectoryPath),
        id: id, parser: .claude(ClaudeOutputParser()))
      try await waitForState(.done, id: id, supervisor: supervisor)
    }
    try await run(result: "First reply", inputTokens: 100)
    let first = try await supervisor.snapshot(agentID: id).transcript
    #expect(first.last?.text == "First reply")
    #expect(first.last?.turnStats?.inputTokens == 100)

    try await supervisor.appendLocalTranscript(
      agentID: id, role: .user, kind: .text, text: "Second question")
    try await run(result: "", inputTokens: 900)
    let transcript = try await supervisor.snapshot(agentID: id).transcript
    let reply = try #require(transcript.last { $0.role == .assistant && $0.kind == .text })
    #expect(reply.text == "First reply")
    #expect(reply.turnStats?.inputTokens == 100)
  }

  @Test("Hermes clarify surfaces a pending choice and resolveChoice answers via stdin")
  func hermesClarifyChoiceRoundTrip() async throws {
    let supervisor = AgentSupervisor()
    let script = #"""
      printf '%s\n' '{"type":"session.started","session_id":"h1"}'
      printf '%s\n' '{"type":"message.start"}'
      printf '%s\n' '{"type":"clarify.request","payload":{"question":"How should I draft it?","choices":["Subagent","Me directly"],"request_id":"r1"}}'
      IFS= read -r answer
      printf '%s\n' "{\"type\":\"message.complete\",\"payload\":{\"text\":\"Drafting via $answer\"}}"
      """#
    let id = try await supervisor.spawn(
      provider: .hermes,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", script],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: .hermes(HermesOutputParser())
    )
    try await waitForState(.waitingUser, id: id, supervisor: supervisor)
    let waiting = try await supervisor.snapshot(agentID: id)
    #expect(waiting.pendingChoice?.question == "How should I draft it?")
    #expect(waiting.pendingChoice?.choices == ["Subagent", "Me directly"])
    #expect(waiting.attentionToken == "agent-choice")
    #expect(await supervisor.hasPendingChoice(agentID: id))

    try await supervisor.resolveChoice(agentID: id, answer: "Me directly")
    try await waitForState(.done, id: id, supervisor: supervisor)
    let done = try await supervisor.snapshot(agentID: id)
    #expect(done.pendingChoice == nil)
    #expect(done.result == "Drafting via Me directly")
    #expect(done.transcript.contains { $0.role == .user && $0.text == "Me directly" })
  }

  @Test("Interactive input reaches the PTY and interrupt updates normalized state")
  func interactiveInputAndInterrupt() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "printf 'OTTO_STATUS:IDLE\\n'; IFS= read -r line; printf 'received:%s\\n' \"$line\"; sleep 5",
        ],
        workingDirectory: FileManager.default.currentDirectoryPath
      )
    )
    try await waitForState(.idle, id: id, supervisor: supervisor)
    try await supervisor.sendInput(agentID: id, text: "approve")
    try await waitForOutput("received:approve", id: id, supervisor: supervisor)
    try await supervisor.interrupt(agentID: id)
    #expect(try await supervisor.snapshot(agentID: id).state == .interrupted)
    try await waitForExit(id: id, supervisor: supervisor)
  }
}

private struct ScriptedInteractiveAdapter: AgentAdapter {
  let provider = AgentProvider.codex

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard request.prompt == nil else {
      throw RuntimeError.launchFailed("Interactive fixture received an initial prompt")
    }
    return ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: [
        "-c", "printf 'ready\\n'; while IFS= read -r line; do printf 'heard:%s\\n' \"$line\"; done",
      ],
      workingDirectory: request.workspacePath
    )
  }
}

private struct ClaudeTrustPromptAdapter: AgentAdapter {
  let provider = AgentProvider.claudeCode

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: [
        "-c",
        "printf 'Security guide\\n1. Yes, I trust this folder\\n2. No, exit\\nEnter to confirm · Esc to cancel\\n'; IFS= read -r answer; printf 'trust-confirmed\\n'; sleep 5",
      ],
      workingDirectory: request.workspacePath
    )
  }
}

/// Reproduces a PTY read that ends before the trust screen's footer: the footer only reaches the
/// supervisor together with the output that follows the automatic answer.
private struct SplitClaudeTrustPromptAdapter: AgentAdapter {
  let provider = AgentProvider.claudeCode

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: [
        "-c",
        "printf 'Security guide\\n1. Yes, I trust this folder\\n2. No, exit\\n'; IFS= read -r answer; printf 'Enter to confirm · Esc to cancel\\ntrust-confirmed\\n'; sleep 5",
      ],
      workingDirectory: request.workspacePath
    )
  }
}

private struct UpdatePromptAdapter: AgentAdapter {
  let provider = AgentProvider.codex

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: [
        "-c",
        "printf 'A new version is available\\n1. Update now\\n2. Later\\n'; IFS= read -r answer; printf 'choice:%s\\n' \"$answer\"; sleep 5",
      ],
      workingDirectory: request.workspacePath
    )
  }
}

/// Replays Kimi's `/login` platform picker, then reports the raw bytes it receives so the test can
/// assert Otto answered with cursor keys instead of typing the option's text.
private struct KimiLoginPromptAdapter: AgentAdapter {
  let provider = AgentProvider.kimi

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "0.34.0")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    let menu = [
      "  Select a platform",
      "  ↑↓ navigate · Enter select · Esc cancel",
      "",
      "   ❯ Kimi Code (OAuth)",
      "     Kimi Platform (API key · platform.kimi.com)",
      "     Kimi Platform (API key · platform.kimi.ai)",
      "",
    ].joined(separator: "\\n")
    return ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: [
        "-c",
        "printf '\(menu)'; printf 'keys:'; dd bs=1 count=7 2>/dev/null | od -An -c | tr -d ' \\n'; printf '\\n'; sleep 5",
      ],
      workingDirectory: request.workspacePath
    )
  }
}

private struct ScriptedOneShotAdapter: AgentAdapter {
  let provider = AgentProvider.codex

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard request.prompt != nil else {
      throw RuntimeError.launchFailed("One-shot fixture requires a prompt")
    }
    return ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: ["-c", "printf '{\"type\":\"turn.completed\"}\\n'"],
      workingDirectory: request.workspacePath
    )
  }
}

private struct CodexApprovalAdapter: AgentAdapter {
  let provider = AgentProvider.codex
  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }
  func availableModels() async -> [AgentModel] { [] }
  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: [
        "-c",
        #"""
        IFS= read -r prompt
        printf 'Allow the muse MCP server to run tool "node.list"?\n › 1. Allow\n   2. Allow for this session\n   3. Always allow\n   4. Cancel\nenter to submit | esc to cancel\n'
        i=0; while [ "$i" -lt 1000 ]; do printf '\033]0;Action Required\007'; i=$((i+1)); done
        IFS= read -r answer; printf 'approved\n'; sleep 5
        """#,
      ], workingDirectory: request.workspacePath)
  }
}

private struct CompletingInteractiveAdapter: AgentAdapter {
  let provider = AgentProvider.claudeCode

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: [
        "-c",
        "printf 'ready\\n'; IFS= read -r prompt; printf 'I finished the requested work.\\n❯ '; sleep 5",
      ],
      workingDirectory: request.workspacePath
    )
  }
}

private func waitForExit(
  id: UUID, supervisor: AgentSupervisor, timeout: Duration = .seconds(5)
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if try await supervisor.snapshot(agentID: id).exitCode != nil { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for PTY to exit")
}

private func collect(
  _ stream: AsyncStream<Data>,
  until marker: String,
  timeout: Duration
) async -> String {
  await withTaskGroup(of: String.self) { group in
    group.addTask {
      var result = ""
      for await data in stream {
        result += String(decoding: data, as: UTF8.self)
        if result.contains(marker) { break }
      }
      return result
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return ""
    }
    let first = await group.next() ?? ""
    group.cancelAll()
    return first
  }
}

#if os(macOS)
  private func collectExit(
    _ stream: AsyncStream<Int32>,
    timeout: Duration
  ) async -> Int32? {
    await withTaskGroup(of: Int32?.self) { group in
      group.addTask {
        for await exitCode in stream { return exitCode }
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  private func waitForOSProcessExit(_ processID: pid_t) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      errno = 0
      if Darwin.kill(processID, 0) == -1, errno == ESRCH { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for child process \(processID) to exit")
  }
#endif

private func waitForState(
  _ expected: AgentLifecycleState,
  id: UUID,
  supervisor: AgentSupervisor,
  timeout: Duration = .seconds(10)
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if try await supervisor.snapshot(agentID: id).state == expected { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for \(expected.rawValue)")
}

private func waitForOutput(
  _ marker: String,
  id: UUID,
  supervisor: AgentSupervisor
) async throws {
  let deadline = ContinuousClock.now + .seconds(10)
  while ContinuousClock.now < deadline {
    if try await supervisor.snapshot(agentID: id).output.contains(marker) { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for agent output: \(marker)")
}

private actor MemoryRequestCapture {
  private var request: AgentLaunchRequest?
  func record(_ value: AgentLaunchRequest) { request = value }
  func latest() -> AgentLaunchRequest? { request }
}

private struct MemoryCapturingAdapter: AgentAdapter {
  let provider = AgentProvider.codex
  let capture: MemoryRequestCapture
  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }
  func availableModels() async -> [AgentModel] { [] }
  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    await capture.record(request)
    return ProcessLaunchSpec(
      executable: "/bin/sh", arguments: ["-c", "exit 0"], workingDirectory: request.workspacePath)
  }
}

/// Prints the same Claude Code Bash call three times, 3 s apart (slow CI runners deliver PTY
/// output in bursts), the first one twice at once.
private struct RepeatingToolCallAdapter: AgentAdapter {
  let provider = AgentProvider.claudeCode

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    let line =
      #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Bash","#
      + #""input":{"command":"sleep 25; echo same"}}]}}"#
    let script =
      "l='\(line)'; echo \"$l\"; echo \"$l\"; sleep 3; echo \"$l\"; sleep 3; "
      + "echo \"$l\""
    return ProcessLaunchSpec(
      executable: "/bin/sh", arguments: ["-c", script], workingDirectory: request.workspacePath)
  }
}
