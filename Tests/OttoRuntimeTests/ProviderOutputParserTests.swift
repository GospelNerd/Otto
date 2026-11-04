import Foundation
import OttoRuntime
import Testing

@Suite("Provider output golden fixtures")
struct ProviderOutputParserTests {
  @Test("Every provider has a readable golden projection and terminal recovery surface")
  func conversationProjectionAndTerminalEscape() throws {
    let claude = try fixtureText("claude_success", extension: "jsonl")
    let codex = try fixtureText("codex_success", extension: "jsonl")
    let kimi = try fixtureText("kimi_success", extension: "jsonl")
    let grok = try fixtureText("grok_success", extension: "jsonl")
    let shell = try fixtureText("shell_success", extension: "txt")

    #expect(
      ProviderConversationProjection.liveText(from: claude, provider: .claudeCode)
        == "Authentication uses signed sessions.")
    #expect(
      ProviderConversationProjection.liveText(from: codex, provider: .codex)
        == "Added authentication coverage.")
    #expect(
      ProviderConversationProjection.liveText(from: kimi, provider: .kimi)
        == "Authentication uses signed sessions.")
    #expect(
      ProviderConversationProjection.liveText(from: grok, provider: .grok)
        == "Authentication uses signed sessions.")
    #expect(ProviderConversationProjection.liveText(from: shell, provider: .shell) == nil)
    #expect(Set(AgentPresentationSurface.allCases) == [.conversation, .terminal])
  }

  @Test("Conversation projection streams structured deltas without leaking terminal text")
  func structuredStreamingProjection() {
    let claude = """
      raw terminal banner that must stay in Terminal
      {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Building "}}}
      {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"the feature…"}}}
      """
    #expect(
      ProviderConversationProjection.liveText(from: claude, provider: .claudeCode)
        == "Building the feature…"
    )

    let terminalOnly = "\u{001B}[2JClaude Code native terminal output ❯"
    #expect(
      ProviderConversationProjection.liveText(from: terminalOnly, provider: .claudeCode) == nil
    )
  }

  @Test("Claude structured result preserves commands, files, and final response")
  func claudeSuccess() throws {
    var parser = ClaudeOutputParser()
    let events = try fixtureLines("claude_success", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }
    let result = try #require(events.compactMap(\.result).last)
    #expect(result.status == .done)
    #expect(result.summaryCandidate == "Authentication uses signed sessions.")
    #expect(result.commandsRun == ["swift test"])
    #expect(result.filesChanged == ["Sources/Auth.swift"])
    #expect(events.contains(.state(.done, confidence: 0.99)))
  }

  @Test("A provider auth failure in plain prose reads as a failed run, not a prompt")
  func providerAuthFailureProse() {
    // Claude Code prints this and settles at its idle prompt. Answering the sign-in inside the
    // chat never resolves it, so attention must not raise "Needs you" on top of the dead run.
    var parser = ClaudeOutputParser()
    let events = parser.ingest(
      line: "Failed to authenticate: OAuth session expired and could not be refreshed")
    #expect(
      events == [
        .diagnostic("Failed to authenticate: OAuth session expired and could not be refreshed"),
        .state(.failed, confidence: 0.8),
      ])

    var codex = CodexOutputParser()
    let codexEvents = codex.ingest(line: "Failed to authenticate: OAuth session expired")
    #expect(codexEvents.contains(.state(.failed, confidence: 0.8)))
    #expect(
      codexEvents.contains { event in
        if case .waitingForUser = event { return true }
        return false
      } == false)
  }

  @Test("Grok messages-json is parsed through the Claude stream shape")
  func grokSuccess() throws {
    var parser = ProviderParser.forProvider(.grok)
    let events = try fixtureLines("grok_success", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }
    #expect(events.contains(.sessionStarted("grok-fixture")))
    let result = try #require(events.compactMap(\.result).last)
    #expect(result.status == .done)
    #expect(result.summaryCandidate == "Authentication uses signed sessions.")
    #expect(events.contains(.toolInvoked(name: "read_file", detail: "Sources/Auth.swift")))
    #expect(events.contains(.state(.done, confidence: 0.99)))
  }

  @Test("Claude ToolSearch schema loading stays out of the conversation")
  func claudeToolSearchHidden() {
    var parser = ClaudeOutputParser()
    let events = parser.ingest(
      line:
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ToolSearch","input":{"query":"select:mcp__muse__browser_type"}},{"type":"tool_use","name":"mcp__muse__browser_type","input":{"text":"Hello"}}]}}"#
    )
    let tools = events.compactMap { event -> String? in
      if case .toolInvoked(let name, _) = event { return name }
      return nil
    }
    #expect(tools == ["mcp__muse__browser_type"])
  }

  @Test("Claude native agents produce canonical child lifecycle events")
  func claudeChildLifecycle() {
    var parser = ClaudeOutputParser()
    let start = parser.ingest(
      line:
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_child","name":"Agent","input":{"description":"Review security","prompt":"Audit authentication","model":"sonnet"}}]}}"#
    )
    let finish = parser.ingest(
      line:
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_child","content":"Done"}]}}"#
    )
    let child = start.compactMap(\.childRun).first
    #expect(child?.id == "toolu_child")
    #expect(child?.name == "Review security")
    #expect(child?.activity == "Audit authentication")
    #expect(child?.model == "sonnet")
    #expect(child?.state == .working)
    #expect(finish.compactMap(\.childRun).last?.state == .done)
  }

  @Test("Codex native agents produce canonical child lifecycle and usage events")
  func codexChildLifecycle() {
    var parser = CodexOutputParser()
    let start = parser.ingest(
      line:
        #"{"type":"item.started","item":{"type":"agent_task","id":"child-1","name":"Tests","prompt":"Run focused tests","model":"gpt-5.6-sol","effort":"high"}}"#
    )
    let finish = parser.ingest(
      line:
        #"{"type":"item.completed","item":{"type":"agent_task","id":"child-1","status":"completed","usage":{"input_tokens":120,"output_tokens":30}}}"#
    )
    let child = start.compactMap(\.childRun).first
    #expect(child?.id == "child-1")
    #expect(child?.name == "Tests")
    #expect(child?.activity == "Run focused tests")
    #expect(child?.model == "gpt-5.6-sol")
    #expect(child?.effort == "high")
    #expect(finish.compactMap(\.childRun).last?.state == .done)
    #expect(finish.compactMap(\.childRun).last?.inputTokens == 120)
    #expect(finish.compactMap(\.childRun).last?.outputTokens == 30)
  }

  @Test("Claude remains working from its system handshake until the terminal result")
  func claudeSystemHandshakeDoesNotLookReady() {
    var parser = ClaudeOutputParser()
    let lines = [
      #"{"type":"system","subtype":"init","session_id":"claude-123"}"#,
      #"{"type":"system","subtype":"status","status":"compacting"}"#,
      #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"Sources/Auth.swift"}}]}}"#,
      #"{"type":"result","subtype":"success","is_error":false,"result":"Finished."}"#,
    ]
    let eventsByLine = lines.map { parser.ingest(line: $0) }

    #expect(
      eventsByLine[0] == [
        .sessionStarted("claude-123"),
        .state(.working, confidence: 0.99),
      ])
    #expect(eventsByLine[1] == [.state(.working, confidence: 0.99)])
    #expect(
      eventsByLine.dropLast().flatMap { $0 }.contains { event in
        if case .state(.idle, _) = event { return true }
        return false
      } == false)
    #expect(eventsByLine.last?.contains(.state(.done, confidence: 0.99)) == true)
  }

  @Test("Hermes gateway events project session, tools, approvals, and final response")
  func hermesGatewayEvents() {
    var parser = HermesOutputParser()
    let lines = [
      #"{"type":"session.started","session_id":"hermes-123"}"#,
      #"{"type":"message.start","session_id":"runtime"}"#,
      #"{"type":"message.delta","payload":{"text":"Implemented "}}"#,
      #"{"type":"tool.start","payload":{"name":"terminal","description":"swift test"}}"#,
      #"{"type":"approval.request","payload":{"reason":"Run a migration"}}"#,
      #"{"type":"message.complete","payload":{"text":"Implemented Hermes support."}}"#,
    ]
    let events = lines.flatMap { parser.ingest(line: $0) }
    #expect(events.contains(.sessionStarted("hermes-123")))
    #expect(events.contains(.toolInvoked(name: "terminal", detail: "swift test")))
    #expect(events.contains(.permissionRequested("Run a migration")))
    #expect(events.contains(.state(.done, confidence: 0.99)))
    #expect(events.compactMap(\.result).last?.summaryCandidate == "Implemented Hermes support.")

    let output = lines.joined(separator: "\n")
    #expect(
      ProviderConversationProjection.liveText(from: output, provider: .hermes)
        == "Implemented Hermes support."
    )
  }

  @Test("Hermes clarify requests surface question, choices, and request id as a choice prompt")
  func hermesClarifyRequest() {
    var parser = HermesOutputParser()
    let events = parser.ingest(
      line: #"""
        {"type":"clarify.request","session_id":"a7fe49bc","payload":{"question":"How do you want me to draft it?","choices":["Subagent","Claude Code","Me directly"],"request_id":"ff4f3efb"}}
        """#
    )
    #expect(
      events == [
        .choiceRequested(
          AgentChoicePrompt(
            requestID: "ff4f3efb",
            question: "How do you want me to draft it?",
            choices: ["Subagent", "Claude Code", "Me directly"],
            multiSelect: false
          ))
      ]
    )

    // Open-ended clarify: no choices, still a choice prompt so the composer answers through
    // the clarify channel rather than starting a fresh run.
    let openEnded = parser.ingest(
      line:
        #"{"type":"clarify.request","payload":{"question":"What should the title be?","request_id":"ab12"}}"#
    )
    #expect(
      openEnded == [
        .choiceRequested(
          AgentChoicePrompt(requestID: "ab12", question: "What should the title be?", choices: []))
      ]
    )
  }

  @Test("Codex nonfatal diagnostics do not mask a successful final response")
  func codexSuccessWithNoise() throws {
    var parser = CodexOutputParser()
    let events = try fixtureLines("codex_success", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }
    let result = try #require(events.compactMap(\.result).last)
    #expect(result.summaryCandidate == "Added authentication coverage.")
    #expect(result.commandsRun == ["swift test"])
    #expect(result.filesChanged == ["Tests/AuthTests.swift"])
    #expect(events.contains(.diagnostic("An unrelated MCP server requires authentication")))
    #expect(events.contains(.state(.done, confidence: 0.99)))
  }

  @Test("Kimi print-mode messages project tools, files, and the turn's final answer")
  func kimiPrintModeStream() throws {
    var parser = KimiOutputParser()
    let events = try fixtureLines("kimi_success", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }
    // Print mode announces no session id, so the run reports the token that means `--continue`.
    #expect(events.contains(.sessionStarted(KimiAdapter.continuationSessionToken)))
    #expect(events.contains(.toolInvoked(name: "Shell", detail: "swift test")))
    #expect(events.contains(.toolInvoked(name: "Edit", detail: "Sources/Auth.swift")))
    #expect(events.contains(.assistantMessage("Checking the test suite.")))
    let result = try #require(events.compactMap(\.result).last)
    #expect(result.status == .done)
    #expect(result.summaryCandidate == "Authentication uses signed sessions.")
    #expect(result.commandsRun == ["swift test"])
    #expect(result.filesChanged == ["Sources/Auth.swift"])
    #expect(events.contains(.state(.done, confidence: 0.99)))
    // A tool-calling message is mid-turn: only the final tool-free message ends the run.
    #expect(events.compactMap(\.result).count == 1)
  }

  @Test("Kimi reasoning and error records reach the conversation")
  func kimiReasoningAndErrors() throws {
    var parser = KimiOutputParser()
    let reasoning = parser.ingest(
      line:
        #"{"role":"assistant","reasoning_content":"Check the auth module first.","content":[{"type":"text","text":"Reading Auth.swift."}],"tool_calls":[{"type":"function","id":"tc_1","function":{"name":"Read","arguments":{"file_path":"Sources/Auth.swift"}}}]}"#
    )
    #expect(reasoning.contains(.reasoning("Check the auth module first.")))
    #expect(reasoning.contains(.assistantMessage("Reading Auth.swift.")))
    // Arguments arrive as a JSON string or, in some builds, an object; both must read the same.
    #expect(reasoning.contains(.toolInvoked(name: "Read", detail: "Sources/Auth.swift")))

    var failing = KimiOutputParser()
    let events = try fixtureLines("kimi_error", extension: "jsonl")
      .flatMap { failing.ingest(line: $0) }
    #expect(events.contains(.diagnostic("Rate limited by the Kimi API")))
    #expect(events.contains(.state(.failed, confidence: 0.99)))
    #expect(events.compactMap(\.result).isEmpty)
  }

  @Test("Claude thinking, tool calls, and finished messages project as conversation events")
  func claudeConversationEvents() {
    var parser = ClaudeOutputParser()
    let line = """
      {"type":"assistant","message":{"content":[\
      {"type":"thinking","thinking":"I should inspect the auth module first."},\
      {"type":"tool_use","name":"Grep","input":{"pattern":"session_token"}},\
      {"type":"text","text":"Auth uses **signed** sessions."}]}}
      """
    let events = parser.ingest(line: line)
    #expect(events.contains(.reasoning("I should inspect the auth module first.")))
    #expect(events.contains(.toolInvoked(name: "Grep", detail: "session_token")))
    #expect(events.contains(.assistantMessage("Auth uses **signed** sessions.")))
  }

  @Test("Claude permission denials surface as readable notices in the conversation")
  func claudePermissionDenials() {
    var parser = ClaudeOutputParser()
    let line = """
      {"type":"result","subtype":"success","is_error":false,"result":"Partial work done",\
      "permission_denials":[{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}]}
      """
    let events = parser.ingest(line: line)
    let notice = events.compactMap { event -> String? in
      guard case .diagnostic(let message) = event else { return nil }
      return message
    }.first
    #expect(notice?.contains("Permission denied for Bash") == true)
    #expect(notice?.contains("rm -rf build") == true)
    #expect(events.contains(.state(.done, confidence: 0.99)))
  }

  @Test("Codex announces each tool once across started and completed items")
  func codexToolAnnouncementDedupe() {
    var parser = CodexOutputParser()
    let started =
      #"{"type":"item.started","item":{"type":"command_execution","command":"swift test"}}"#
    let completed =
      #"{"type":"item.completed","item":{"type":"command_execution","command":"swift test"}}"#
    let reasoning =
      #"{"type":"item.completed","item":{"type":"reasoning","text":"Check the failing suite."}}"#
    let first = parser.ingest(line: started)
    let second = parser.ingest(line: completed)
    let third = parser.ingest(line: reasoning)
    #expect(first == [.toolInvoked(name: "Shell", detail: "swift test")])
    #expect(second.isEmpty)
    #expect(third == [.reasoning("Check the failing suite.")])
  }

  @Test("Live projection prefers deltas streamed after the last completed message")
  func liveProjectionAfterCompletedMessage() {
    let claude = """
      {"type":"assistant","message":{"content":[{"type":"text","text":"First reply."}]}}
      {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Second reply "}}}
      {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"underway…"}}}
      """
    #expect(
      ProviderConversationProjection.liveText(from: claude, provider: .claudeCode)
        == "Second reply underway…"
    )
  }

  @Test("MCP server login warnings never masquerade as a blocked provider sign-in")
  func mcpLoginWarningIsNotProviderAuthentication() {
    let banner = """
      Tip: You can run any shell command from Codex using !
      The trigify MCP server is not logged in. Run `codex mcp login trigify`.
      MCP startup incomplete (failed: gtmgrid, muse, trigify)
      Hello! What can I help you with?
      """
    #expect(InteractivePromptDetector.detect(in: banner, provider: .codex) == nil)

    let realSignIn = "Sign in to continue using Codex"
    #expect(
      InteractivePromptDetector.detect(in: realSignIn, provider: .codex)?.token
        == "provider-authentication"
    )
  }

  @Test("Cursor events project session, thinking, typed tool calls, and the final answer")
  func cursorSuccess() throws {
    var parser = CursorOutputParser()
    let events = try fixtureLines("cursor_success", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }

    #expect(events.contains(.sessionStarted("d10d535f-5a2d-4a5a-bf07-2630a7c3ce83")))
    // Thinking arrives as deltas and is only worth surfacing once its closing record lands.
    #expect(events.contains(.reasoning("I should inspect the auth module first.")))
    // Tool calls are typed by key, not by a name field.
    #expect(events.contains(.toolInvoked(name: "Shell", detail: "swift test")))
    #expect(events.contains(.toolInvoked(name: "Read", detail: "/tmp/probe/Sources/Auth.swift")))
    #expect(events.contains(.assistantMessage("Authentication uses signed sessions.")))

    // Every call is reported started-then-completed; the transcript must announce it once.
    let shellAnnouncements = events.filter {
      $0 == .toolInvoked(name: "Shell", detail: "swift test")
    }
    #expect(shellAnnouncements.count == 1)

    let result = try #require(events.compactMap(\.result).last)
    #expect(result.status == .done)
    #expect(result.summaryCandidate == "Authentication uses signed sessions.")
    #expect(result.commandsRun == ["swift test"])
    // A read is not a change: only the edited path counts as a file the run touched.
    #expect(result.filesChanged == ["/tmp/probe/Tests/AuthTests.swift"])
    #expect(events.contains(.state(.done, confidence: 0.99)))
  }

  @Test("A Cursor edit reports its path, never the file body it is writing")
  func cursorEditDetailExcludesContent() {
    var parser = CursorOutputParser()
    // streamContent carries the whole new file. A longest-string fallback would drag that into
    // the transcript, so the detail has to name the path explicitly.
    let events = parser.ingest(
      line: #"""
        {"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"editToolCall":{"args":{"path":"/tmp/a.swift","streamContent":"a very long file body that must never be shown as the tool detail"}}}}
        """#
    )
    #expect(events == [.toolInvoked(name: "Edit", detail: "/tmp/a.swift")])
  }

  @Test("A failed Cursor result surfaces as a diagnostic rather than an answer")
  func cursorError() throws {
    var parser = CursorOutputParser()
    let events = try fixtureLines("cursor_error", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }
    #expect(events.contains(.diagnostic("Model request failed: rate limited")))
    #expect(events.contains(.state(.failed, confidence: 0.99)))
    #expect(events.compactMap(\.result).isEmpty)
  }

  @Test("Cursor's account model list is read from the CLI rather than hardcoded")
  func cursorModelParsing() {
    let output = """
      Available models

      auto - Auto (default)
      composer-2.5 - Composer 2.5 (current)
      cursor-grok-4.5-high - Cursor Grok 4.5
      claude-opus-5-thinking-high - Opus 5 1M Thinking
      """
    let models = CursorAdapter.parseModels(output)
    #expect(models.count == 4)
    // The annotations are display noise; the id must round-trip through --model unchanged.
    #expect(models.first?.id == "auto")
    #expect(models.first?.displayName == "Auto")
    #expect(models[1].displayName == "Composer 2.5")
    #expect(models.contains { $0.id == "cursor-grok-4.5-high" })
    // The banner and blank lines are not models.
    #expect(!models.contains { $0.id.contains("Available") })
  }

  @Test("OpenCode events project a session, tools, files, and the turn's final answer")
  func openCodeSuccess() throws {
    var parser = OpenCodeOutputParser()
    let events = try fixtureLines("opencode_success", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }

    // Every event carries the session id, so the first line is enough to make the run resumable.
    #expect(events.contains(.sessionStarted("ses_0232a9e4dffejY60mWFaqfUUrP")))
    #expect(events.contains(.reasoning("I should read the auth module before answering.")))
    #expect(events.contains(.toolInvoked(name: "bash", detail: "swift test")))
    #expect(events.contains(.assistantMessage("Authentication uses signed sessions.")))

    // No line in the stream terminates the turn: a step that ran a tool is followed by another
    // step, so the result only exists once output closes.
    #expect(events.compactMap(\.result).isEmpty)
    let closing = parser.finish()
    let result = try #require(closing.compactMap(\.result).last)
    #expect(result.status == .done)
    #expect(result.summaryCandidate == "Authentication uses signed sessions.")
    #expect(result.commandsRun == ["swift test"])
    #expect(result.filesChanged == ["Sources/Auth.swift"])
    #expect(closing.contains(.state(.done, confidence: 0.99)))
  }

  @Test("An OpenCode error record fails the run and suppresses a result at end of stream")
  func openCodeError() throws {
    var parser = OpenCodeOutputParser()
    let events = try fixtureLines("opencode_error", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }
    #expect(events.contains(.diagnostic("default agent \"build\" is a subagent")))
    #expect(events.contains(.state(.failed, confidence: 0.99)))
    // A failed run must not also report success when the stream closes.
    #expect(parser.finish().isEmpty)
  }

  @Test("An OpenCode turn with no assistant text fails rather than reporting an empty answer")
  func openCodeSilentTurn() {
    var parser = OpenCodeOutputParser()
    _ = parser.ingest(
      line:
        #"{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}"#
    )
    let closing = parser.finish()
    #expect(closing.contains(.state(.failed, confidence: 0.9)))
    #expect(closing.compactMap(\.result).isEmpty)
  }

  @Test("Pi events project a session, reasoning, tools, files, and the settled answer")
  func piSuccess() throws {
    var parser = PiOutputParser()
    let events = try fixtureLines("pi_success", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }

    // The session header is the first record and carries the id `--session` resumes by.
    #expect(events.first == .sessionStarted("01a181cc-561f-75f3-b9b5-889ecc5ce8b6"))
    #expect(events.contains(.state(.working, confidence: 0.99)))
    #expect(events.contains(.reasoning("I should read the auth module before answering.")))
    #expect(events.contains(.toolInvoked(name: "bash", detail: "swift test")))
    #expect(events.contains(.toolInvoked(name: "edit", detail: "sign(token, key: sessionKey)")))
    #expect(events.contains(.assistantMessage("Authentication uses signed sessions.")))
    // Streaming deltas never post as messages of their own.
    #expect(!events.contains(.assistantMessage("Authentication ")))

    // `agent_settled` closes the run on its own line, so the result exists before output ends
    // and the end-of-stream hook has nothing left to add.
    let result = try #require(events.compactMap(\.result).last)
    #expect(result.status == .done)
    #expect(result.summaryCandidate == "Authentication uses signed sessions.")
    #expect(result.commandsRun == ["swift test"])
    #expect(result.filesChanged == ["Sources/Auth.swift"])
    #expect(events.contains(.state(.done, confidence: 0.99)))
    #expect(parser.finish().isEmpty)
  }

  @Test("A real Pi 1.4.0 JSON run (gpt-5.6-luna over a PTY) projects the read tool and answer")
  func piLiveCapture() throws {
    // Captured on 28 Oct 2026 from `pi --mode json --model openai/gpt-5.6-luna` under `script`,
    // the way Otto's PTY launches it; `message_update` deltas included.
    var parser = PiOutputParser()
    let events = try fixtureLines("pi_live", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }
    #expect(events.first == .sessionStarted("01a18263-a7c9-758d-b8f8-aa9d7a476eb7"))
    #expect(events.contains(.toolInvoked(name: "read", detail: "note.txt")))
    #expect(events.contains(.assistantMessage("The launch code is otter-42.")))
    let result = try #require(events.compactMap(\.result).last)
    #expect(result.summaryCandidate == "The launch code is otter-42.")
    #expect(result.filesChanged.isEmpty)
    #expect(events.last == .state(.done, confidence: 0.99))
    #expect(parser.finish().isEmpty)
  }

  @Test("A Pi assistant message that stopped with an error fails the run")
  func piError() throws {
    var parser = PiOutputParser()
    let events = try fixtureLines("pi_error", extension: "jsonl")
      .flatMap { parser.ingest(line: $0) }
    #expect(events.contains(.diagnostic("401 Unauthorized: invalid x-api-key")))
    #expect(events.contains(.state(.failed, confidence: 0.99)))
    #expect(events.compactMap(\.result).isEmpty)
    #expect(parser.finish().isEmpty)
  }

  @Test("A Pi run that dies before settling reports its last stderr line as the reason")
  func piUnsettledExit() {
    var parser = PiOutputParser()
    _ = parser.ingest(
      line:
        #"{"type":"session","version":3,"id":"01a1","timestamp":"2026-10-28T09:16:24.936Z","cwd":"/w"}"#
    )
    // Pi's stdout is JSON only; this is its stderr, interleaved by the shared terminal.
    _ = parser.ingest(line: "No API key found for the selected model.")
    _ = parser.ingest(line: "")
    let closing = parser.finish()
    #expect(closing.contains(.diagnostic("No API key found for the selected model.")))
    #expect(closing.contains(.state(.failed, confidence: 0.9)))
    #expect(closing.compactMap(\.result).isEmpty)
    // Finishing is idempotent.
    #expect(parser.finish().isEmpty)
  }

  @Test("A Pi turn with text but no settle record still yields its answer at end of stream")
  func piFinishWithText() {
    var parser = PiOutputParser()
    _ = parser.ingest(
      line:
        #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],"stopReason":"stop","timestamp":1}}"#
    )
    let closing = parser.finish()
    #expect(closing.compactMap(\.result).last?.summaryCandidate == "Done.")
    #expect(closing.contains(.state(.done, confidence: 0.99)))
  }

  @Test("Kimi's workspace trust prompt answers itself so project MCP servers stay enabled")
  func kimiWorkspaceTrust() throws {
    let frame = """
      ──────────────────────────────────────────────────────────────────
        Trust this folder?
        ↑↓ navigate · Enter select · Esc exit

        /Users/max/Documents/Muse Workspace

        Kimi Code loads project-level MCP servers (.mcp.json, .kimi-code/mcp.json) only in
        trusted folders. They run as local processes on your machine.

         ❯ Trust this folder
           Enable project MCP servers. Remembered for this folder.

           Don't trust
           Exit Kimi Code. Asked again next launch.
      ──────────────────────────────────────────────────────────────────
      """
    let prompt = try #require(InteractivePromptDetector.detect(in: frame, provider: .kimi))
    #expect(prompt.token == "kimi-workspace-trust")
    #expect(prompt.automaticResponse == "\r")

    // Claude's differently-worded trust prompt must not be captured by the Kimi branch.
    #expect(
      InteractivePromptDetector.detect(in: frame, provider: .claudeCode)?.token
        != "kimi-workspace-trust")
  }

  @Test("Kimi's sign-in platform picker reaches chat as answerable choices")
  func kimiLoginPlatformChoices() throws {
    let frame = """
        Select a platform
        ↑↓ navigate · Enter select · Esc cancel

         ❯ Kimi Code (OAuth)
           Kimi Platform (API key · platform.kimi.com)
           Kimi Platform (API key · platform.kimi.ai)
      """
    let prompt = try #require(InteractivePromptDetector.detect(in: frame, provider: .kimi))
    #expect(prompt.token == "kimi-login-platform")
    #expect(prompt.state == .waitingUser)

    let menu = try #require(prompt.menu)
    #expect(
      menu.options == [
        "Kimi Code (OAuth)",
        "Kimi Platform (API key · platform.kimi.com)",
        "Kimi Platform (API key · platform.kimi.ai)",
      ])
    #expect(menu.selectedIndex == 0)

    // Answering the third row means two moves down, then Enter — never typed text.
    #expect(menu.keystrokes(toSelect: 2) == "\u{1B}[B\u{1B}[B\r")
    #expect(menu.keystrokes(toSelect: 0) == "\r")
  }

  @Test("A menu is read from the newest repaint, not the stale frames above it")
  func menuUsesLatestRepaint() throws {
    // A TUI redraws the whole list on every keystroke, so the scan buffer holds the menu several
    // times over. Reading an older copy would move the highlight from the wrong starting row.
    let buffer = """
        Select a platform
        ↑↓ navigate · Enter select · Esc cancel

         ❯ Kimi Code (OAuth)
           Kimi Platform (API key · platform.kimi.com)
           Kimi Platform (API key · platform.kimi.ai)

        Select a platform
        ↑↓ navigate · Enter select · Esc cancel

           Kimi Code (OAuth)
         ❯ Kimi Platform (API key · platform.kimi.com)
           Kimi Platform (API key · platform.kimi.ai)
      """
    let menu = try #require(InteractiveMenuParser.parse(buffer))
    #expect(menu.options.count == 3)
    #expect(menu.selectedIndex == 1)
    #expect(menu.keystrokes(toSelect: 0) == "\u{1B}[A\r")
  }

  @Test("Kimi's navigation wording surfaces a generic menu the same way Claude's does")
  func kimiGenericMenuWording() throws {
    let frame = """
        Pick an option
        ↑↓ navigate · Enter select · Esc cancel

         ❯ First option
           Second option
      """
    let prompt = try #require(InteractivePromptDetector.detect(in: frame, provider: .kimi))
    #expect(prompt.token == "provider-choice")
    #expect(prompt.menu?.options == ["First option", "Second option"])
  }

  @Test("Split terminal titles cannot displace an unanswered permission prompt")
  func splitTerminalTitles() {
    var filter = InteractiveTextFilter()
    #expect(filter.ingest("Approval\n\u{1B}]0;[ ! ] Action") == "Approval\n")
    #expect(filter.ingest(" Required\u{7}") == "")
    #expect(filter.ingest("\u{1B}]0;Still waiting\u{1B}") == "")
    #expect(filter.ingest("\\\u{1B}[32m›\u{1B}[0m") == "›")
  }

  @Test("Codex MCP approval is an answerable permission, never completion")
  func codexMCPApproval() throws {
    let frame = """
      Allow the muse MCP server to run tool "node.list"?
       › 1. Allow                   Run the tool and continue.
         2. Allow for this session  Remember this choice for this session.
         3. Always allow            Remember this choice for future calls.
         4. Cancel                  Cancel this tool call
      enter to submit | esc to cancel
      """
    let prompt = try #require(InteractivePromptDetector.detect(in: frame, provider: .codex))
    #expect(prompt.state == .waitingPermission)
    #expect(prompt.reason.contains("node.list"))
    #expect(prompt.menu?.options.count == 4)
    #expect(prompt.menu?.keystrokes(toSelect: 3) == "\u{1B}[B\u{1B}[B\u{1B}[B\r")
    #expect(
      !InteractiveCompletionDetector.isReadyForNextPrompt(
        recentText: frame, rawChunk: "\u{1B}]0;[ ! ] Action Required | Muse Workspace\u{7}",
        provider: .codex))
  }

  @Test("Terminal titles, bells and menu carets cannot complete a turn")
  func terminalNotificationsAreNotCompletion() {
    for text in ["Still working", " › 1. Allow", "An example uses › in prose"] {
      #expect(
        !InteractiveCompletionDetector.isReadyForNextPrompt(
          recentText: text, rawChunk: "\u{1B}]0;Action Required\u{7}", provider: .codex))
    }
    #expect(
      InteractiveCompletionDetector.isReadyForNextPrompt(
        recentText: "Finished the work\n›\n", rawChunk: "›", provider: .codex))
    #expect(
      !InteractiveCompletionDetector.isReadyForNextPrompt(
        recentText: "›\nWorking (esc to interrupt)", rawChunk: "", provider: .codex))
  }

  @Test("Permission and user-waiting states remain distinct")
  func waitingStates() throws {
    var claude = ClaudeOutputParser()
    let claudeEvents = try fixtureLines("claude_waiting", extension: "txt")
      .flatMap { claude.ingest(line: $0) }
    #expect(claudeEvents.contains(.state(.waitingPermission, confidence: 0.7)))
    #expect(claudeEvents.contains(.state(.waitingUser, confidence: 0.7)))

    var codex = CodexOutputParser()
    let codexEvents = try fixtureLines("codex_waiting", extension: "jsonl")
      .flatMap { codex.ingest(line: $0) }
    #expect(codexEvents.contains(.state(.waitingPermission, confidence: 0.99)))
    #expect(codexEvents.contains(.state(.waitingUser, confidence: 0.99)))
  }

  @Test("Explicit provider failures are classified with high confidence")
  func failures() throws {
    var claude = ClaudeOutputParser()
    let claudeEvents = try fixtureLines("claude_error", extension: "jsonl")
      .flatMap { claude.ingest(line: $0) }
    #expect(claudeEvents.contains(.state(.failed, confidence: 0.99)))

    var codex = CodexOutputParser()
    let codexEvents = try fixtureLines("codex_error", extension: "jsonl")
      .flatMap { codex.ingest(line: $0) }
    #expect(codexEvents.contains(.state(.failed, confidence: 0.99)))
  }

  @Test("Scrollback remains bounded and retains absolute offsets")
  func boundedScrollback() {
    var ring = TerminalScrollbackRing(capacity: 8)
    ring.append(Data("12345".utf8))
    ring.append(Data("67890".utf8))
    #expect(ring.text == "34567890")
    #expect(ring.startOffset == 2)
    #expect(ring.endOffset == 10)
  }

  @Test("Sanitized excerpts strip terminal escapes, control bytes, and bound the tail")
  func sanitizedExcerpt() {
    let raw =
      "\u{001B}]0;* Claude Code\u{0007}"
      + "\u{001B}[38;5;174m\u{001B}[1mWelcome\u{001B}[28Gback\u{001B}[33GMax!\u{001B}[0m\r\r\n"
      + "\u{001B}c\u{001B}[?25h\u{001B}[2K"
      + "What is the weather forecast?\r\n\n\n\n\nDone."
    let cleaned = TerminalOutputSearch.sanitizedExcerpt(raw)
    #expect(!cleaned.contains("\u{001B}"))
    #expect(!cleaned.contains("\r"))
    #expect(!cleaned.contains("\u{0007}"))
    #expect(cleaned.contains("WelcomebackMax!"))
    #expect(cleaned.contains("What is the weather forecast?"))
    #expect(!cleaned.contains("\n\n\n"))

    let long = String(repeating: "x", count: 10_000) + "tail-marker"
    let bounded = TerminalOutputSearch.sanitizedExcerpt(long)
    #expect(bounded.count == 4_096)
    #expect(bounded.hasSuffix("tail-marker"))
  }
}

extension ParsedAgentEvent {
  fileprivate var childRun: AgentChildRun? {
    guard case .childStarted(let child) = self else { return nil }
    return child
  }
}

extension ParsedAgentEvent {
  fileprivate var result: AgentResult? {
    guard case .result(let result) = self else { return nil }
    return result
  }
}

private func fixtureLines(_ name: String, extension fileExtension: String) throws -> [String] {
  try fixtureText(name, extension: fileExtension)
    .split(whereSeparator: \.isNewline)
    .map(String.init)
}

private func fixtureText(_ name: String, extension fileExtension: String) throws -> String {
  let url = try #require(
    Bundle.module.url(
      forResource: name,
      withExtension: fileExtension,
      subdirectory: "Fixtures"
    ))
  return try String(contentsOf: url, encoding: .utf8)
}
