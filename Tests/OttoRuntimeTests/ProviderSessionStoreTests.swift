import Foundation
import OttoModels
import Testing

@testable import OttoRuntime

@Suite("Provider session store")
struct ProviderSessionStoreTests {
  @Test("Restored completion input is hidden while replies and user messages survive")
  func completionNoticeHarvest() {
    let notice =
      PromptSubmission.backgroundCompletionPrefix + "has finished.\n"
      + PromptSubmission.backgroundCompletionSuffix
    let reply = ProviderSessionStore.Turn(role: .assistant, text: "The tests passed.")
    let harvest = ProviderSessionStore.Harvest(turns: [
      .init(role: .user, text: PromptSubmission.contextualPrompt(notice, context: "memory")),
      reply,
      .init(
        role: .user, text: notice + PromptSubmission.queuedMessageSeparator + "Continue please"),
    ])
    #expect(harvest.turns == [reply, .init(role: .user, text: "Continue please")])
  }

  private func makeHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "muse-session-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func iso(secondsAgo: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date.now.addingTimeInterval(-secondsAgo))
  }

  private func codexSessionDirectory(home: URL, date: Date = .now) -> URL {
    let components = Calendar(identifier: .gregorian).dateComponents(
      [.year, .month, .day], from: date)
    return home.appending(
      path: String(
        format: ".codex/sessions/%04d/%02d/%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
      ))
  }

  @Test("Claude session turns harvest with meta, command, and stale lines filtered")
  func claudeHarvest() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = "/Users/max/Documents/Muse Workspace"
    let directory = ProviderSessionStore.claudeProjectDirectory(
      workingDirectory: workspace, home: home)
    #expect(directory.lastPathComponent == "-Users-max-Documents-Muse-Workspace")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let old = iso(secondsAgo: 7_200)
    let fresh = iso(secondsAgo: 60)
    let lines = [
      #"{"type":"user","timestamp":"\#(old)","message":{"role":"user","content":"earlier chat turn"}}"#,
      #"{"type":"user","isMeta":true,"timestamp":"\#(fresh)","message":{"role":"user","content":"<local-command-caveat>caveat</local-command-caveat>"}}"#,
      #"{"type":"user","timestamp":"\#(fresh)","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#,
      #"{"type":"user","timestamp":"\#(fresh)","message":{"role":"user","content":"hello"}}"#,
      #"{"type":"assistant","timestamp":"\#(fresh)","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"Hey Max!"}]}}"#,
      #"{"type":"mode","sessionId":"x"}"#,
    ]
    try Data(lines.joined(separator: "\n").utf8)
      .write(to: directory.appending(path: "d2ef4415-aaaa.jsonl"))

    let since = Date.now.addingTimeInterval(-600)
    let harvest = ProviderSessionStore.harvest(
      provider: .claudeCode, workingDirectory: workspace, since: since, sessionID: "d2ef4415-aaaa",
      home: home)
    #expect(harvest.sessionID == "d2ef4415-aaaa")
    #expect(
      harvest.turns == [
        ProviderSessionStore.Turn(role: .user, text: "hello"),
        ProviderSessionStore.Turn(role: .assistant, text: "Hey Max!"),
      ]
    )
  }

  @Test("Codex rollouts harvest only when the cwd matches, with developer lines skipped")
  func codexHarvest() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = "/Users/max/Documents/Muse Workspace"
    let directory = codexSessionDirectory(home: home)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let fresh = iso(secondsAgo: 60)
    let matching = [
      #"{"timestamp":"\#(fresh)","type":"session_meta","payload":{"id":"rollout-123","cwd":"/Users/max/Documents/Muse Workspace"}}"#,
      #"{"timestamp":"\#(fresh)","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<skills_instructions>ignore</skills_instructions>"}]}}"#,
      #"{"timestamp":"\#(fresh)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"run the tests"}]}}"#,
      #"{"timestamp":"\#(fresh)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"All green."}]}}"#,
    ]
    try Data(matching.joined(separator: "\n").utf8)
      .write(to: directory.appending(path: "rollout-2026-08-06T11-40-00-rollout-123.jsonl"))

    let foreign = [
      #"{"timestamp":"\#(fresh)","type":"session_meta","payload":{"id":"other","cwd":"/somewhere/else"}}"#,
      #"{"timestamp":"\#(fresh)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"wrong workspace"}]}}"#,
    ]
    let foreignURL = directory.appending(path: "rollout-2026-08-06T11-41-00-zzz.jsonl")
    try Data(foreign.joined(separator: "\n").utf8).write(to: foreignURL)
    // Make the foreign rollout newest so the matcher must skip past it by cwd.
    try FileManager.default.setAttributes(
      [.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: foreignURL.path)

    let since = Date.now.addingTimeInterval(-600)
    let harvest = ProviderSessionStore.harvest(
      provider: .codex, workingDirectory: workspace, since: since, sessionID: "rollout-123",
      home: home)
    #expect(harvest.sessionID == "rollout-123")
    #expect(
      harvest.turns == [
        ProviderSessionStore.Turn(role: .user, text: "run the tests"),
        ProviderSessionStore.Turn(role: .assistant, text: "All green."),
      ]
    )
  }

  @Test("Missing directories harvest empty rather than throwing")
  func missingDirectories() {
    let harvest = ProviderSessionStore.harvest(
      provider: .claudeCode,
      workingDirectory: "/nonexistent",
      since: .now,
      home: URL(fileURLWithPath: "/nonexistent-home")
    )
    #expect(harvest == ProviderSessionStore.Harvest())
  }

  @Test("Codex restoration uses clean conversation events from the exact saved session")
  func codexRestore() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = "/Users/max/Documents/Muse Workspace"
    let sessionID = "019fdb85-restore-fixture"
    let directory = home.appending(path: ".codex/sessions/2026/08/07")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lines = [
      #"{"type":"session_meta","payload":{"id":"019fdb85-restore-fixture","cwd":"/Users/max/Documents/Muse Workspace"}}"#,
      ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# Otto agent bootstrap\ninternal policy"}]}}"##,
      #"{"type":"event_msg","payload":{"type":"user_message","message":"implement it"}}"#,
      #"{"type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"working"}}"#,
      #"{"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"Implemented and tested."}}"#,
    ]
    try Data(lines.joined(separator: "\n").utf8).write(
      to: directory.appending(path: "rollout-2026-08-07T10-19-49-\(sessionID).jsonl")
    )

    let restored = ProviderSessionStore.restore(
      provider: .codex,
      workingDirectory: workspace,
      sessionID: sessionID,
      home: home
    )
    #expect(restored.sessionID == sessionID)
    #expect(
      restored.turns == [
        ProviderSessionStore.Turn(role: .user, text: "implement it"),
        ProviderSessionStore.Turn(role: .assistant, text: "Implemented and tested."),
      ]
    )
  }
  @Test("Codex restoration reads current response items and unwraps Otto context")
  func codexRestoreResponseItems() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = codexSessionDirectory(home: home)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let prompt = "where did we get with this 👋"
    let envelope = PromptSubmission.contextualPrompt(prompt, context: "private memory")
    let records: [[String: Any]] = [
      ["type": "session_meta", "payload": ["id": "current", "cwd": "/workspace"]],
      [
        "type": "response_item",
        "payload": [
          "type": "message", "role": "developer",
          "content": [["type": "input_text", "text": "internal instructions"]],
        ],
      ],
      [
        "type": "response_item",
        "payload": [
          "type": "message", "role": "user",
          "content": [
            ["type": "input_text", "text": "<environment_context>injected</environment_context>"]
          ],
        ],
      ],
      [
        "type": "response_item",
        "payload": [
          "type": "message", "role": "user",
          "content": [["type": "input_text", "text": envelope]],
        ],
      ],
      [
        "type": "response_item",
        "payload": [
          "type": "message", "role": "assistant",
          "phase": "commentary", "content": [["type": "output_text", "text": "working"]],
        ],
      ],
      [
        "type": "response_item",
        "payload": [
          "type": "message", "role": "assistant",
          "phase": "final_answer",
          "content": [["type": "output_text", "text": "We finished the design."]],
        ],
      ],
    ]
    let lines = try records.map {
      String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }
    try Data(lines.joined(separator: "\n").utf8).write(
      to: directory.appending(path: "rollout-current.jsonl"))
    let restored = ProviderSessionStore.restore(
      provider: .codex, workingDirectory: "/workspace",
      sessionID: "current", home: home)
    #expect(
      restored.turns == [
        .init(role: .user, text: prompt),
        .init(role: .assistant, text: "We finished the design."),
      ])
  }

  @Test("Codex restoration handles a format change without duplicated legacy messages")
  func codexRestoreMixedFormats() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = codexSessionDirectory(home: home)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lines = [
      #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"user","content":"old question"}}"#,
      #"{"type":"event_msg","payload":{"type":"user_message","message":"old question"}}"#,
      #"{"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"old answer"}}"#,
      #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"user","content":"new question"}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":"new answer"}}"#,
      #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"user","content":"[MUSE HIDDEN CONTROL PROMPT]\nroom task"}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":"hidden room reply"}}"#,
    ]
    try Data(lines.joined(separator: "\n").utf8).write(
      to: directory.appending(path: "rollout-mixed.jsonl"))
    let restored = ProviderSessionStore.restore(
      provider: .codex, workingDirectory: "/workspace",
      sessionID: "mixed", home: home)
    #expect(
      restored.turns.map(\.text) == ["old question", "old answer", "new question", "new answer"])
  }

  @Test(
    "Shared workspaces never determine provider session ownership",
    arguments: [AgentProvider.codex, .claudeCode])
  func sharedWorkspaceIsolation(provider: AgentProvider) throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = "/shared/workspace"
    // A resumed session may live in an older date directory even though it was just updated.
    let directory =
      provider == .codex
      ? home.appending(path: ".codex/sessions/2025/01/01")
      : ProviderSessionStore.claudeProjectDirectory(workingDirectory: workspace, home: home)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fresh = iso(secondsAgo: 1)
    for id in ["mine", "neighbour"] {
      let lines: [String]
      if provider == .codex {
        lines = [
          #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/shared/workspace"}}"#,
          #"{"timestamp":"\#(fresh)","type":"response_item","payload":{"type":"message","role":"user","content":"\#(id) question"}}"#,
        ]
      } else {
        lines = [
          #"{"timestamp":"\#(fresh)","type":"user","message":{"role":"user","content":"\#(id) question"}}"#
        ]
      }
      let file = directory.appending(
        path: provider == .codex ? "rollout-\(id).jsonl" : "\(id).jsonl")
      try Data(lines.joined(separator: "\n").utf8).write(to: file)
      try FileManager.default.setAttributes(
        [.modificationDate: Date.now.addingTimeInterval(id == "neighbour" ? 60 : 0)],
        ofItemAtPath: file.path)
    }
    let since = Date.now.addingTimeInterval(-60)
    let mine = ProviderSessionStore.harvest(
      provider: provider, workingDirectory: workspace,
      since: since, sessionID: "mine", home: home)
    #expect(mine.sessionID == "mine")
    #expect(mine.turns.map(\.text) == ["mine question"])
    for id: String? in [nil, "", "missing", "neigh"] {
      #expect(
        ProviderSessionStore.harvest(
          provider: provider, workingDirectory: workspace,
          since: since, sessionID: id, home: home) == ProviderSessionStore.Harvest())
    }
  }

}
