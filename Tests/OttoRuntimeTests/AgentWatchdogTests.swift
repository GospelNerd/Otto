import Foundation
import OttoModels
import OttoRuntime
import Testing

@Suite("Agent watchdog")
struct AgentWatchdogTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  private let agentID = UUID()
  private let runID = UUID()

  private func snapshot(
    state: AgentLifecycleState = .working,
    mode: AgentExecutionMode = .oneShotProvider,
    transcript: [AgentTranscriptEntry] = [],
    outputEnd: Int = 0,
    children: [AgentChildRun] = []
  ) -> AgentRuntimeSnapshot {
    AgentRuntimeSnapshot(
      id: agentID, runID: runID, provider: .codex, executionMode: mode, state: state,
      confidence: 1, outputEndOffset: outputEnd, transcript: transcript, childRuns: children,
      startedAt: start)
  }

  private func minutes(_ value: Double) -> Date { start.addingTimeInterval(value * 60) }

  private func call(_ name: String, _ arguments: String, at date: Date) -> AgentTranscriptEntry {
    AgentTranscriptEntry(
      role: .activity, kind: .toolCall, text: arguments, detail: name, createdAt: date)
  }

  @Test("A working agent with no progress for the stall window is reported once")
  func stalled() {
    var watchdog = AgentWatchdog()
    let quiet = snapshot(transcript: [AgentTranscriptEntry(role: .user, text: "Fix the build")])
    #expect(watchdog.evaluate([quiet], now: start).findings.isEmpty)
    #expect(watchdog.evaluate([quiet], now: minutes(14)).findings.isEmpty)
    let report = watchdog.evaluate([quiet], now: minutes(18))
    let finding = report.findings.first
    #expect(finding?.kind == .stalled)
    #expect(finding?.reason == "No progress for 18 min")
    #expect(report.newlyReported.count == 1)
  }

  @Test("New output resets the stall clock for an interactive session")
  func progressResets() {
    var watchdog = AgentWatchdog()
    let mode = AgentExecutionMode.interactiveProvider
    _ = watchdog.evaluate([snapshot(mode: mode, outputEnd: 10)], now: start)
    _ = watchdog.evaluate([snapshot(mode: mode, outputEnd: 20)], now: minutes(10))
    #expect(
      watchdog.evaluate([snapshot(mode: mode, outputEnd: 20)], now: minutes(20)).findings.isEmpty)
    #expect(
      watchdog.evaluate([snapshot(mode: mode, outputEnd: 20)], now: minutes(26)).findings.count
        == 1)
  }

  @Test("Keep-alive output from a one-shot provider is not progress, but transcript entries are")
  func heartbeatsAreNotProgress() {
    var watchdog = AgentWatchdog()
    let command = call("Bash", "sleep 1260; echo woke", at: start)
    // Claude Code streams a tool_progress heartbeat every 30 s while the command runs.
    _ = watchdog.evaluate([snapshot(transcript: [command], outputEnd: 100)], now: start)
    _ = watchdog.evaluate([snapshot(transcript: [command], outputEnd: 900)], now: minutes(10))
    let report = watchdog.evaluate(
      [snapshot(transcript: [command], outputEnd: 1_800)], now: minutes(16))
    #expect(report.findings.first?.kind == .stalled)

    var fresh = AgentWatchdog()
    _ = fresh.evaluate([snapshot(transcript: [command])], now: start)
    let next = call("Bash", "make test", at: minutes(10))
    _ = fresh.evaluate([snapshot(transcript: [command, next])], now: minutes(10))
    #expect(
      fresh.evaluate([snapshot(transcript: [command, next])], now: minutes(16)).findings.isEmpty)
  }

  @Test("Silence while a child runs or the agent is parked in a wait is not a stall")
  func notStalledWhileWaiting() {
    var watchdog = AgentWatchdog()
    let child = AgentChildRun(id: "c1", name: "Researcher", activity: "Reading", state: .working)
    let delegating = snapshot(children: [child])
    _ = watchdog.evaluate([delegating], now: start)
    #expect(watchdog.evaluate([delegating], now: minutes(40)).findings.isEmpty)

    var other = AgentWatchdog()
    let waiting = snapshot(transcript: [
      call("mcp__otto__terminal_wait", #"{"terminalID":"x"}"#, at: start)
    ])
    _ = other.evaluate([waiting], now: start)
    #expect(other.evaluate([waiting], now: minutes(40)).findings.isEmpty)
  }

  @Test("User shells are never judged, however quiet")
  func terminalsIgnored() {
    var watchdog = AgentWatchdog()
    let shell = snapshot(mode: .terminal)
    _ = watchdog.evaluate([shell], now: start)
    #expect(watchdog.evaluate([shell], now: minutes(120)).findings.isEmpty)
    #expect(watchdog.isIdle)
  }

  @Test("The same tool call repeated six times in a row is a loop")
  func looping() {
    var watchdog = AgentWatchdog()
    var transcript = [AgentTranscriptEntry(role: .user, text: "Fix it", createdAt: start)]
    for index in 0..<5 {
      transcript.append(call("Bash", "npm test", at: minutes(Double(index))))
      transcript.append(
        AgentTranscriptEntry(
          role: .assistant, kind: .reasoning, text: "Try again", createdAt: minutes(Double(index))))
    }
    #expect(watchdog.evaluate([snapshot(transcript: transcript)], now: minutes(5)).findings.isEmpty)
    transcript.append(call("Bash", "npm test", at: minutes(6)))
    let report = watchdog.evaluate([snapshot(transcript: transcript)], now: minutes(6))
    #expect(report.findings.first?.kind == .looping)
    #expect(report.findings.first?.repeatCount == 6)
    #expect(report.findings.first?.reason == "Repeating the same tool call (Bash ×6)")
  }

  @Test("Different arguments, a reply in between, or polling tools are not loops")
  func notLooping() {
    var watchdog = AgentWatchdog()
    let varied = (0..<8).map { call("Read", "file\($0).swift", at: minutes(Double($0))) }
    #expect(watchdog.evaluate([snapshot(transcript: varied)], now: minutes(8)).findings.isEmpty)

    var interrupted = (0..<4).map { call("Read", "a.swift", at: minutes(Double($0))) }
    interrupted.append(
      AgentTranscriptEntry(role: .assistant, text: "Found it", createdAt: minutes(4)))
    interrupted += (5..<8).map { call("Read", "a.swift", at: minutes(Double($0))) }
    #expect(
      watchdog.evaluate([snapshot(transcript: interrupted)], now: minutes(8)).findings.isEmpty)

    let polling = (0..<10).map { call("event.wait", #"{"types":["x"]}"#, at: minutes(Double($0))) }
    #expect(watchdog.evaluate([snapshot(transcript: polling)], now: minutes(10)).findings.isEmpty)
  }

  @Test("A persisting finding is reported once, again only much later or when its kind changes")
  func deduplication() {
    var watchdog = AgentWatchdog()
    let quiet = snapshot()
    _ = watchdog.evaluate([quiet], now: start)
    #expect(watchdog.evaluate([quiet], now: minutes(16)).newlyReported.count == 1)
    let later = watchdog.evaluate([quiet], now: minutes(30))
    #expect(later.findings.count == 1)
    #expect(later.newlyReported.isEmpty)

    // Progress clears it; a fresh stall in the same run inside the repeat window stays quiet.
    let step = [AgentTranscriptEntry(role: .assistant, text: "Checked the logs")]
    _ = watchdog.evaluate([snapshot(transcript: step)], now: minutes(31))
    #expect(watchdog.evaluate([snapshot(transcript: step)], now: minutes(32)).findings.isEmpty)
    let again = watchdog.evaluate([snapshot(transcript: step)], now: minutes(47))
    #expect(again.findings.count == 1)
    #expect(again.newlyReported.isEmpty)

    // After the repeat window it is worth saying again.
    #expect(
      watchdog.evaluate([snapshot(transcript: step)], now: minutes(140)).newlyReported.count == 1)

    // A change of kind is news straight away.
    let loop = step + (0..<6).map { _ in call("Bash", "ls", at: minutes(141)) }
    let looping = watchdog.evaluate([snapshot(transcript: loop)], now: minutes(141))
    #expect(looping.newlyReported.first?.kind == .looping)
  }

  @Test("Waiting on the person past the threshold gives one reminder")
  func waitingOnPerson() {
    var watchdog = AgentWatchdog()
    let asking = snapshot(state: .waitingUser)
    _ = watchdog.evaluate([asking], now: start)
    #expect(watchdog.evaluate([asking], now: minutes(19)).findings.isEmpty)
    // Before Claude Code abandons the request at 30 min.
    let report = watchdog.evaluate([asking], now: minutes(21))
    #expect(report.findings.first?.kind == .waitingOnPerson)
    #expect(report.findings.first?.reason == "Waiting for you for 21 min")
    #expect(report.newlyReported.count == 1)
    #expect(watchdog.evaluate([asking], now: minutes(60)).newlyReported.isEmpty)
    // Answered: the agent works again and the finding disappears.
    #expect(watchdog.evaluate([snapshot()], now: minutes(61)).findings.isEmpty)
  }

  @Test("Finished agents are forgotten")
  func forgetsFinished() {
    var watchdog = AgentWatchdog()
    _ = watchdog.evaluate([snapshot()], now: start)
    #expect(!watchdog.isIdle)
    _ = watchdog.evaluate([snapshot(state: .done)], now: minutes(1))
    #expect(watchdog.isIdle)
  }

  @Test("Durations read naturally")
  func durations() {
    #expect(AgentWatchdogFinding.durationText(30) == "1 min")
    #expect(AgentWatchdogFinding.durationText(18 * 60) == "18 min")
    #expect(AgentWatchdogFinding.durationText(120 * 60) == "2 h")
    #expect(AgentWatchdogFinding.durationText(125 * 60) == "2 h 5 min")
  }
}
