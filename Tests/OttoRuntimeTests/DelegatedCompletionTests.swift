import Foundation
import OttoModels
import Testing

@testable import OttoRuntime

@Suite("Delegated completion bookkeeping")
struct DelegatedCompletionTests {
  private func command(_ text: String, on supervisor: AgentSupervisor) async throws -> UUID {
    try await supervisor.spawnTerminal(
      shell: "/bin/sh", command: text,
      workingDirectory: FileManager.default.currentDirectoryPath)
  }

  private func waitFor(
    _ id: UUID, on supervisor: AgentSupervisor,
    _ condition: (AgentLifecycleState) -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if condition(try await supervisor.snapshot(agentID: id).state) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(id)")
  }

  @Test("Completions wait for an idle parent, arrive together, and are handed over once")
  func batchesForIdleParent() async throws {
    let supervisor = AgentSupervisor()
    defer { Task { await supervisor.stopAll() } }
    // The parent stays busy until the test releases it, however slow the machine is.
    let release = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-release-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: release) }
    let parent = try await command(
      "while [ ! -e '\(release.path)' ]; do sleep 0.05; done", on: supervisor)
    let first = try await command("printf first-ok", on: supervisor)
    let second = try await command("printf second-bad; exit 3", on: supervisor)
    await supervisor.registerDelegatedChild(
      parentID: parent, childID: first, name: "First", kind: "command")
    await supervisor.registerDelegatedChild(
      parentID: parent, childID: second, name: "Second", kind: "command")
    try await waitFor(first, on: supervisor) { $0 == .done }
    try await waitFor(second, on: supervisor) { $0 == .failed }
    #expect(await supervisor.delegatingParentID(of: first) == parent)

    // The parent is still busy: nothing is handed over yet.
    #expect(await supervisor.takeDelegatedCompletions(parentID: parent).isEmpty)

    FileManager.default.createFile(atPath: release.path, contents: nil)
    try await waitFor(parent, on: supervisor) { $0 == .done }
    let completions = await supervisor.takeDelegatedCompletions(parentID: parent)
    #expect(Set(completions.map(\.childID)) == [first, second])
    let failed = try #require(completions.first { $0.childID == second })
    #expect(failed.state == .failed)
    #expect(failed.exitCode == 3)
    #expect(failed.kind == "command")
    #expect(failed.excerpt.contains("second-bad"))
    #expect(await supervisor.takeDelegatedCompletions(parentID: parent).isEmpty)
  }

  @Test("A completion the parent already read in its turn is not handed over")
  func consumedCompletionIsSkipped() async throws {
    let supervisor = AgentSupervisor()
    defer { Task { await supervisor.stopAll() } }
    let parent = try await supervisor.spawnDeterministicMock()
    let child = try await command("printf done", on: supervisor)
    await supervisor.registerDelegatedChild(
      parentID: parent, childID: child, name: "Build", kind: "command")
    try await waitFor(child, on: supervisor) { $0 == .done }
    try await waitFor(parent, on: supervisor) { $0 == .idle }

    // Someone else reading it does not count as the parent seeing it.
    await supervisor.markDelegatedCompletionConsumed(childID: child, by: UUID())
    await supervisor.markDelegatedCompletionConsumed(childID: child, by: nil)
    await supervisor.markDelegatedCompletionConsumed(childID: child, by: parent)
    #expect(await supervisor.takeDelegatedCompletions(parentID: parent).isEmpty)
  }

  @Test("Reading a child that is still running does not suppress its later completion")
  func earlyReadDoesNotConsume() async throws {
    let supervisor = AgentSupervisor()
    defer { Task { await supervisor.stopAll() } }
    let parent = try await supervisor.spawnDeterministicMock()
    let child = try await command("sleep 2; printf late", on: supervisor)
    await supervisor.registerDelegatedChild(
      parentID: parent, childID: child, name: "Slow", kind: "command")
    await supervisor.markDelegatedCompletionConsumed(childID: child, by: parent)
    try await waitFor(child, on: supervisor) { $0 == .done }
    try await waitFor(parent, on: supervisor) { $0 == .idle }
    let completions = await supervisor.takeDelegatedCompletions(parentID: parent)
    #expect(completions.map(\.childID) == [child])
  }

  @Test("A stopped parent is never woken and its pending completions are dropped")
  func stoppedParentIsNotWoken() async throws {
    let supervisor = AgentSupervisor()
    defer { Task { await supervisor.stopAll() } }
    let parent = try await command("sleep 30", on: supervisor)
    let child = try await command("printf ok", on: supervisor)
    await supervisor.registerDelegatedChild(
      parentID: parent, childID: child, name: "Child", kind: "command")
    try await waitFor(child, on: supervisor) { $0 == .done }
    try await supervisor.stop(agentID: parent)
    #expect(await supervisor.takeDelegatedCompletions(parentID: parent).isEmpty)
    #expect(await supervisor.takeDelegatedCompletions(parentID: UUID()).isEmpty)
  }

  @Test("Children the person started directly are not tracked")
  func undelegatedChildIsIgnored() async throws {
    let supervisor = AgentSupervisor()
    defer { Task { await supervisor.stopAll() } }
    let parent = try await supervisor.spawnDeterministicMock()
    let other = try await command("printf mine", on: supervisor)
    try await waitFor(other, on: supervisor) { $0 == .done }
    try await waitFor(parent, on: supervisor) { $0 == .idle }
    #expect(await supervisor.delegatingParentID(of: other) == nil)
    #expect(await supervisor.takeDelegatedCompletions(parentID: parent).isEmpty)
  }
}
