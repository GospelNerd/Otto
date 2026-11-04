import Foundation
import OttoModels
import OttoRuntime

#if canImport(AppKit)
  import AppKit
#endif

/// The in-app watchdog: once a minute it looks over running agents for ones that look stuck,
/// loop on one tool call, or have waited on the person for a long time, and surfaces them on
/// Home (and, through `watchdogAlertHandler`, as notifications). It never stops or restarts an
/// agent; the person decides.
extension ApplicationServices {
  func startAgentWatchdog() {
    stopAgentWatchdog()
    observeSystemSleep()
    let interval = agentWatchdog.configuration.evaluationInterval
    watchdogTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled, let self else { return }
        await self.runAgentWatchdogPass(now: .now)
      }
    }
  }

  func stopAgentWatchdog() {
    watchdogTask?.cancel()
    watchdogTask = nil
    #if canImport(AppKit)
      let center = NSWorkspace.shared.notificationCenter
      for observer in systemSleepObservers { center.removeObserver(observer) }
    #endif
    systemSleepObservers.removeAll()
  }

  /// One pass over the live fleet. Cheap enough for dozens of agents: it only compares counters
  /// and scans the tail of each transcript, and does nothing at all while no agent is running.
  func runAgentWatchdogPass(now: Date) async {
    let snapshots = await supervisor.allSnapshots()
    let live = snapshots.contains { snapshot in
      snapshot.executionMode != .terminal
        && [.starting, .working, .waitingPermission, .waitingUser].contains(snapshot.state)
    }
    guard live || !agentWatchdog.isIdle || !watchdogFindings.isEmpty else { return }
    evaluateAgentWatchdog(snapshots: snapshots, now: now)
  }

  /// Runs the evaluator over `snapshots` and publishes what it found. Only agents that are
  /// conversations on a canvas are surfaced; isolated team runs have nowhere to open.
  func evaluateAgentWatchdog(snapshots: [AgentRuntimeSnapshot], now: Date) {
    let report = agentWatchdog.evaluate(snapshots, now: now)
    let agentNodes = Set(
      store.snapshot.canvases.flatMap(\.nodes).filter { $0.kind == .agent }.map(\.id))
    let surfaced = report.findings.filter { agentNodes.contains($0.agentID) }
    let findings = Dictionary(uniqueKeysWithValues: surfaced.map { ($0.agentID, $0) })
    if findings != watchdogFindings { watchdogFindings = findings }
    let alerts = report.newlyReported.filter { agentNodes.contains($0.agentID) }
    if !alerts.isEmpty { watchdogAlertHandler?(alerts) }
  }

  /// Home lines for agents that look stuck or loop. Waiting-too-long reminders amend the existing
  /// "has a question / needs your OK" line instead (see `watchdogWaitingNote`).
  func watchdogBriefItems(excluding nodeIDs: Set<UUID>, nodeName: (UUID) -> String?)
    -> [BriefItem]
  {
    watchdogFindings.values
      .filter { $0.kind != .waitingOnPerson && !nodeIDs.contains($0.agentID) }
      .sorted { $0.since < $1.since }
      .map { finding in
        let name = nodeName(finding.agentID) ?? "Your assistant"
        let title =
          finding.kind == .looping
          ? "\(name) may be going in circles" : "\(name) looks stuck"
        return BriefItem(
          id: "watchdog:\(finding.agentID)", kind: .todo, title: title,
          reason: "\(finding.reason). Open the chat to check on it, or stop it.",
          source: name, needsYou: true, projectID: projectID(forNode: finding.agentID),
          origin: .otto, action: .openAgent(finding.agentID),
          secondaryAction: .stopAgent(finding.agentID), createdAt: finding.detectedAt)
      }
  }

  /// "Waiting for you for 42 min." when the watchdog has flagged a long wait on this agent.
  func watchdogWaitingNote(nodeID: UUID) -> String? {
    guard let finding = watchdogFindings[nodeID], finding.kind == .waitingOnPerson else {
      return nil
    }
    return "\(finding.reason)."
  }

  /// The most specific account of why an automation's agent run failed, for the retry
  /// classifier and the run history.
  nonisolated static func routineFailureDetail(_ snapshot: AgentRuntimeSnapshot) -> String? {
    let lastMessage = snapshot.transcript.last { $0.role == .assistant && $0.kind == .text }?.text
    for candidate in [snapshot.attentionReason, snapshot.result, lastMessage] {
      if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        return text
      }
    }
    var output = String(snapshot.output.suffix(4_000))
    if snapshot.executionMode == .oneShotProvider {
      // A structured provider's stream is JSON events, whose fields ("rejected", "rate_limit")
      // would decide the retry by accident. Only plain lines, such as a crash message, count.
      output = output.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        .joined(separator: "\n")
    }
    let tail = TerminalOutputSearch.sanitizedExcerpt(String(output.suffix(2_000)))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return tail.isEmpty ? nil : String(tail.suffix(400))
  }

  private func observeSystemSleep() {
    #if canImport(AppKit)
      let center = NSWorkspace.shared.notificationCenter
      systemSleepObservers = [
        center.addObserver(
          forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.systemIsSleeping = true }
        },
        center.addObserver(
          forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.systemIsSleeping = false }
        },
      ]
    #endif
  }
}
