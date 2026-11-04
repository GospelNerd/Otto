import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import Testing

@testable import OttoServices

@MainActor
@Suite("Agent watchdog on Home")
struct AgentWatchdogHomeTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func snapshot(
    _ id: UUID, state: AgentLifecycleState = .working, transcript: [AgentTranscriptEntry] = []
  ) -> AgentRuntimeSnapshot {
    AgentRuntimeSnapshot(
      id: id, runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"), provider: .codex,
      state: state, confidence: 1, transcript: transcript, startedAt: start)
  }

  @Test("A stuck agent gets a Needs-you line with open and stop, and one alert")
  func stuckAgentSurfaces() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "watchdog-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: root.path)
    let agent = try #require(
      canvas.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    let offCanvas = UUID()
    var alerts: [AgentWatchdogFinding] = []
    services.watchdogAlertHandler = { alerts += $0 }

    let snapshots = [snapshot(agent), snapshot(offCanvas)]
    services.evaluateAgentWatchdog(snapshots: snapshots, now: start)
    #expect(services.derivedBriefItems().allSatisfy { !$0.id.hasPrefix("watchdog:") })

    services.evaluateAgentWatchdog(snapshots: snapshots, now: start.addingTimeInterval(18 * 60))
    let item = try #require(services.derivedBriefItems().first { $0.id == "watchdog:\(agent)" })
    #expect(item.title.hasSuffix("looks stuck"))
    #expect(item.reason?.hasPrefix("No progress for 18 min.") == true)
    #expect(item.needsYou)
    #expect(item.action == .openAgent(agent))
    #expect(item.secondaryAction == .stopAgent(agent))
    // Only conversations on a canvas are surfaced.
    #expect(services.watchdogFindings.keys.sorted() == [agent])
    #expect(alerts.map(\.agentID) == [agent])

    // Still stuck a minute later: still listed, no second alert.
    services.evaluateAgentWatchdog(snapshots: snapshots, now: start.addingTimeInterval(19 * 60))
    #expect(services.derivedBriefItems().contains { $0.id == "watchdog:\(agent)" })
    #expect(alerts.count == 1)

    // It finishes: the line goes away on its own.
    services.evaluateAgentWatchdog(
      snapshots: [snapshot(agent, state: .done)], now: start.addingTimeInterval(20 * 60))
    #expect(services.watchdogFindings.isEmpty)
    #expect(!services.derivedBriefItems().contains { $0.id == "watchdog:\(agent)" })
  }

  @Test("A long wait on the person becomes a note on its existing line, not a new one")
  func waitingNote() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "watchdog-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: root.path)
    let agent = try #require(
      canvas.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    let asking = [snapshot(agent, state: .waitingUser)]
    services.evaluateAgentWatchdog(snapshots: asking, now: start)
    services.evaluateAgentWatchdog(snapshots: asking, now: start.addingTimeInterval(35 * 60))
    #expect(services.watchdogWaitingNote(nodeID: agent) == "Waiting for you for 35 min.")
    #expect(!services.derivedBriefItems().contains { $0.id.hasPrefix("watchdog:") })
  }

  @Test("Brief items written before secondary actions existed still decode")
  func briefItemDecodes() throws {
    let item = BriefItem(
      id: "x", kind: .todo, title: "Stuck", origin: .otto, action: .openAgent(UUID()),
      secondaryAction: .stopAgent(UUID()))
    let data = try JSONEncoder().encode(item)
    #expect(try JSONDecoder().decode(BriefItem.self, from: data) == item)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "secondaryAction")
    let old = try JSONDecoder().decode(
      BriefItem.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.secondaryAction == nil)
  }
}
