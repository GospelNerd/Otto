import Foundation
import OttoModels
import Testing

@testable import OttoRuntime

@Suite("Terminal waiting-for-input detection")
struct TerminalInputWaitTests {
  @Test(
    "Prompts left on the cursor line are waiting",
    arguments: [
      "Starting setup\nPaste your Cloudflare API token: ",
      "Project name? ",
      "Overwrite existing config? [y/N] ",
      "Continue (y/n)",
      "Press any key to continue…",
      "Press Enter to open your browser...",
      "\u{001B}[1;32m?\u{001B}[0m Pick a region ›",
      "Enter passphrase for key '/Users/me/.ssh/id_ed25519': ",
    ])
  func partialPrompts(_ output: String) {
    #expect(TerminalInputWaitDetector.waitingPrompt(in: output) != nil)
  }

  @Test(
    "Finished question lines count when they ask for something",
    arguments: [
      "Step 2 of 3\nPaste the token below:\n",
      "Which account should we use?\n",
      "Do you want to continue? [Y/n]\n",
    ])
  func finishedPrompts(_ output: String) {
    #expect(TerminalInputWaitDetector.waitingPrompt(in: output) != nil)
  }

  @Test(
    "Quiet progress and log output is not mistaken for a prompt",
    arguments: [
      "",
      "Compiling 42 files\n",
      "Installing dependencies...",
      "Downloading [=====>     ] 40%",
      "Ready on http://localhost:3000\n",
      "Saved API token to ~/.config/tool\n",
      "Results:\n",
      "Building\r\u{001B}[2K",
    ])
  func notPrompts(_ output: String) {
    #expect(TerminalInputWaitDetector.waitingPrompt(in: output) == nil)
  }

  @Test("Menus that repaint above the cursor are waiting")
  func menuPrompt() {
    let output = "? Select an account (Use arrow keys)\n❯ Personal\n  Work\n"
    #expect(
      TerminalInputWaitDetector.waitingPrompt(in: output)
        == "? Select an account (Use arrow keys)")
  }

  @Test("With echo off any text on the cursor line is a prompt")
  func hiddenInput() {
    #expect(TerminalInputWaitDetector.waitingPrompt(in: "Secret", echoDisabled: false) == nil)
    #expect(TerminalInputWaitDetector.waitingPrompt(in: "Secret", echoDisabled: true) == "Secret")
    #expect(TerminalInputWaitDetector.waitingPrompt(in: "done\n", echoDisabled: true) == nil)
  }

  @Test("The returned prompt is plain text without escape sequences")
  func promptIsSanitized() {
    let output = "\u{001B}]0;title\u{0007}\u{001B}[33mPaste your token:\u{001B}[0m "
    #expect(TerminalInputWaitDetector.waitingPrompt(in: output) == "Paste your token:")
  }

  @Test(
    "Terminal titles read like what the command is",
    arguments: [
      ("bash scripts/setup.sh", "Setup script"),
      ("cd ~/app && ./install-wrangler.sh --yes", "Install wrangler script"),
      ("npx -y wrangler login", "Wrangler login"),
      ("FOO=1 python3 tools/seed_db.py", "Seed db script"),
      ("npm run dev", "Npm run dev"),
      ("", "Terminal"),
    ])
  func friendlyTitles(_ command: String, _ title: String) {
    #expect(TerminalInputWaitDetector.friendlyTitle(forCommand: command) == title)
  }

  @Test("A command terminal waits at a prompt, then resumes when answered")
  func supervisorWaitsAndResumes() async throws {
    let supervisor = AgentSupervisor()
    await supervisor.setTerminalInputQuietInterval(.milliseconds(250))
    let id = try await supervisor.spawnTerminal(
      shell: "/bin/bash",
      command: "printf 'Paste your token: '; read -r token; echo \"got-$token\"; sleep 0.3",
      workingDirectory: FileManager.default.currentDirectoryPath
    )
    defer { Task { await supervisor.stopAll() } }

    let waiting = try await waitFor(supervisor, id) { $0.state == .waitingUser }
    #expect(waiting.attentionToken == TerminalInputWaitDetector.inputToken)
    #expect(waiting.attentionReason == "Paste your token:")

    try await supervisor.sendBytes(agentID: id, data: Data("abc\r".utf8))
    let finished = try await waitFor(supervisor, id) { $0.state == .done }
    #expect(finished.attentionReason == nil)
    #expect(finished.output.contains("got-abc"))
  }

  @Test("Hidden input is flagged and what the person types never reaches the output")
  func hiddenInputStaysOutOfOutput() async throws {
    let supervisor = AgentSupervisor()
    await supervisor.setTerminalInputQuietInterval(.milliseconds(250))
    let id = try await supervisor.spawnTerminal(
      shell: "/bin/bash",
      command: "read -r -s -p 'API key: ' key; echo; echo \"length=${#key}\"",
      workingDirectory: FileManager.default.currentDirectoryPath
    )
    defer { Task { await supervisor.stopAll() } }

    let waiting = try await waitFor(supervisor, id) { $0.state == .waitingUser }
    #expect(waiting.attentionToken == TerminalInputWaitDetector.hiddenInputToken)

    try await supervisor.sendBytes(agentID: id, data: Data("sk-very-secret\r".utf8))
    let finished = try await waitFor(supervisor, id) { $0.state == .done }
    #expect(finished.output.contains("length=14"))
    #expect(!finished.output.contains("sk-very-secret"))
    #expect(!finished.transcript.contains { $0.text.contains("sk-very-secret") })
  }

  @Test("A quiet command without a prompt keeps running, and bare shells are never flagged")
  func quietWorkIsNotWaiting() async throws {
    let supervisor = AgentSupervisor()
    await supervisor.setTerminalInputQuietInterval(.milliseconds(150))
    let command = try await supervisor.spawnTerminal(
      shell: "/bin/sh", command: "echo building; sleep 10",
      workingDirectory: FileManager.default.currentDirectoryPath)
    let shell = try await supervisor.spawnTerminal(
      shell: "/bin/sh", workingDirectory: FileManager.default.currentDirectoryPath)
    defer { Task { await supervisor.stopAll() } }
    // Start the clock once both are running, so a slow machine's startup is not the test.
    _ = try await waitFor(supervisor, command) { $0.state == .working }
    _ = try await waitFor(supervisor, shell) { $0.state == .working }
    try await Task.sleep(for: .milliseconds(700))
    #expect(try await supervisor.snapshot(agentID: command).state == .working)
    #expect(try await supervisor.snapshot(agentID: shell).state == .working)
  }

  private func waitFor(
    _ supervisor: AgentSupervisor, _ id: UUID,
    timeout: Duration = .seconds(10),
    until predicate: (AgentRuntimeSnapshot) -> Bool
  ) async throws -> AgentRuntimeSnapshot {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      let snapshot = try await supervisor.snapshot(agentID: id)
      if predicate(snapshot) { return snapshot }
      try await Task.sleep(for: .milliseconds(20))
    }
    let snapshot = try await supervisor.snapshot(agentID: id)
    Issue.record("Timed out in state \(snapshot.state): \(snapshot.output)")
    return snapshot
  }
}
