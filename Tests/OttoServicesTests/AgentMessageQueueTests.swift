import Foundation
import OttoModels
import OttoRuntime
import Testing

@testable import OttoServices

@MainActor
@Suite("Queued conversation messages")
struct AgentMessageQueueTests {
  @MainActor
  final class Provider {
    var state: AgentLifecycleState = .working
    var sent: [String] = []
    var rejects = false
    var gate: CheckedContinuation<Void, Never>?
    var waits = false
    func queue(url: URL? = nil) -> AgentMessageQueue {
      AgentMessageQueue(
        url: url, state: { _ in self.state },
        send: { _, text in
          MainActor.assertIsolated()
          if self.waits { await withCheckedContinuation { self.gate = $0 } }
          try Task.checkCancellation()
          if self.rejects { throw CocoaError(.fileReadUnknown) }
          self.sent.append(text)
          self.state = .working
        })
    }
  }

  private func settle(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition())
  }

  @Test func pendingMessagesMergeIntoOnePromptAndIgnoreDuplicateEvents() async throws {
    let p = Provider()
    let id = UUID()
    let other = UUID()
    let q = p.queue()
    q.enqueue(agentID: id, text: "first")
    q.enqueue(agentID: id, text: "second")
    q.enqueue(agentID: other, text: "other session")
    try await Task.sleep(for: .milliseconds(20))
    #expect(p.sent.isEmpty)
    p.state = .done
    q.observe(agentID: id, state: .done)
    q.observe(agentID: id, state: .done)
    let separator = AgentMessageQueue.mergedMessageSeparator
    try await settle { p.sent == ["first\(separator)second"] }
    try await Task.sleep(for: .milliseconds(20))
    #expect(p.sent.count == 1)
    #expect(q.messages[id, default: []].isEmpty)
    #expect(q.messages[other]?.map(\.text) == ["other session"])
    q.enqueue(agentID: id, text: "third")
    p.state = .done
    q.observe(agentID: id, state: .done)
    try await settle { p.sent.last == "third" }
  }

  @Test func slashCommandsAreNeverMergedWithOtherMessages() async throws {
    let p = Provider()
    let id = UUID()
    let q = p.queue()
    for text in ["one", "two", "/goal ship it", "three"] { q.enqueue(agentID: id, text: text) }
    let separator = AgentMessageQueue.mergedMessageSeparator
    for expected in ["one\(separator)two", "/goal ship it", "three"] {
      p.state = .done
      q.observe(agentID: id, state: .done)
      try await settle { p.sent.last == expected }
    }
    #expect(p.sent.count == 3)
  }

  @Test func failedMergedSendReturnsEveryMessageToTheFrontInOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "queue.json")
    let p = Provider()
    let id = UUID()
    p.rejects = true
    let q = p.queue(url: url)
    q.enqueue(agentID: id, text: "a")
    q.enqueue(agentID: id, text: "b")
    q.enqueue(agentID: id, text: "c")
    p.state = .done
    q.observe(agentID: id, state: .done)
    try await settle { q.errors[id] != nil }
    #expect(q.messages[id]?.map(\.text) == ["a", "b", "c"])
    #expect(q.paused.contains(id))
    #expect(q.errors[id]?.contains("queued messages") == true)
    #expect(p.queue(url: url).messages[id]?.map(\.text) == ["a", "b", "c"])
    q.enqueue(agentID: id, text: "d")
    p.rejects = false
    q.resume(id)
    let separator = AgentMessageQueue.mergedMessageSeparator
    try await settle { p.sent == [["a", "b", "c", "d"].joined(separator: separator)] }
  }

  @Test func interruptionPausesUntilExplicitResumeAndRemovalWorks() async throws {
    let p = Provider()
    let id = UUID()
    let q = p.queue()
    q.enqueue(agentID: id, text: "remove")
    q.enqueue(agentID: id, text: "keep")
    q.remove(agentID: id, messageID: try #require(q.messages[id]?.first?.id))
    q.pause(id)
    p.state = .interrupted
    q.observe(agentID: id, state: .interrupted)
    p.state = .done
    q.observe(agentID: id, state: .done)
    try await Task.sleep(for: .milliseconds(20))
    #expect(p.sent.isEmpty)
    q.resume(id)
    try await settle { p.sent == ["keep"] }
  }

  @Test func failedSendRetainsMessageAndPauses() async throws {
    let p = Provider()
    let id = UUID()
    p.state = .done
    p.rejects = true
    let q = p.queue()
    q.enqueue(agentID: id, text: "retry me")
    try await settle { q.errors[id] != nil }
    #expect(q.messages[id]?.map(\.text) == ["retry me"])
    #expect(q.paused.contains(id))
    p.rejects = false
    q.resume(id)
    try await settle { p.sent == ["retry me"] }
  }

  @Test func stopDuringPreparationPreventsSend() async throws {
    let p = Provider()
    let id = UUID()
    p.state = .done
    p.waits = true
    let q = p.queue()
    q.enqueue(agentID: id, text: "still pending")
    try await settle { p.gate != nil }
    q.pause(id)
    p.gate?.resume()
    try await settle { q.messages[id]?.count == 1 }
    #expect(p.sent.isEmpty)
    #expect(q.paused.contains(id))
  }

  @Test func restoredQueuesArePausedAndRetainInFlightMessage() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "queue.json")
    let id = UUID()
    let p = Provider()
    p.state = .done
    p.waits = true
    let q = p.queue(url: url)
    q.enqueue(agentID: id, text: "preparing")
    try await settle { p.gate != nil }
    q.enqueue(agentID: id, text: "next")
    let restored = p.queue(url: url)
    #expect(restored.messages[id]?.map(\.text) == ["preparing", "next"])
    #expect(restored.paused.contains(id))
    q.pause(id)
    p.gate?.resume()
    try await settle { q.messages[id]?.count == 2 }
  }
}
