import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("Background completions the parent already saw")
struct DelegatedCompletionConsumptionTests {
  @Test("terminal.wait and event.wait inside the turn replace the completion notice")
  func waitingConsumesTheCompletion() async throws {
    let canvas = OttoCanvas(name: "Background work")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    defer { Task { await supervisor.stopAll() } }
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(in: registry, store: store, supervisor: supervisor)
    let parent = await store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
      .affectedNodeIDs[0]
    _ = try await supervisor.spawnDeterministicMock(id: parent, canvasID: canvas.id)
    let context = ToolContext(
      actorID: "background-parent",
      scopes: [.canvasRead, .canvasWrite, .terminalControl, .agentRead],
      source: .agent, sourceNodeID: parent, sourceCanvasID: canvas.id)

    func run(_ command: String) async throws -> UUID {
      try await registry.call(
        name: "terminal.run",
        input: try JSONValue.encode(
          TerminalRunInput(command: command, x: 0, y: 0, shell: "/bin/sh")),
        context: context
      ).decode(TerminalOutput.self).terminalID
    }

    let waited = try await run("sleep 0.2; printf waited")
    let eventWaited = try await run("sleep 0.2; printf evented")
    let unseen = try await run("printf unseen")

    let done = try await registry.call(
      name: "terminal.wait",
      input: try JSONValue.encode(
        TerminalWaitInput(terminalID: waited, timeoutMilliseconds: 10_000)),
      context: context
    ).decode(TerminalOutput.self)
    #expect(done.state == .done)

    let afterSequence = supervisor.eventBus.latestSequence
    if try await supervisor.snapshot(agentID: eventWaited).state != .done {
      let event = try await registry.call(
        name: "event.wait",
        input: try JSONValue.encode(
          EventWaitInput(
            types: [.agentRunCompleted, .agentRunFailed, .agentExited], nodeID: eventWaited,
            afterSequence: afterSequence, timeoutMilliseconds: 10_000)),
        context: context
      ).decode(OttoEvent.self)
      #expect(event.nodeID == eventWaited)
    } else {
      // Already finished: replay its completion from the start of the bus.
      _ = try await registry.call(
        name: "event.wait",
        input: try JSONValue.encode(
          EventWaitInput(
            types: [.agentExited], nodeID: eventWaited, afterSequence: 0,
            timeoutMilliseconds: 10_000)),
        context: context)
    }

    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if try await supervisor.snapshot(agentID: unseen).state == .done,
        try await supervisor.snapshot(agentID: parent).state == .idle
      {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let completions = await supervisor.takeDelegatedCompletions(parentID: parent)
    #expect(completions.map(\.childID) == [unseen])
    #expect(completions.first?.excerpt.contains("unseen") == true)
  }
}
