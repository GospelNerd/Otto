#if DEBUG
  import OttoModels
  import OttoRuntime
  import OttoServices
  import SwiftUI

  /// Exercises the production composer with a simulated provider and an isolated queue.
  @MainActor
  private final class QueuePreviewProvider: ObservableObject {
    let node = OttoNode(
      kind: .agent, displayName: "Queue preview", subtitle: "Simulated provider",
      frame: WorldRect(x: 0, y: 0, width: 800, height: 600), zIndex: 0)
    @Published var state: AgentLifecycleState = .working
    @Published var sent: [String] = []
    lazy var queue = AgentMessageQueue(
      state: { [weak self] _ in self?.state },
      send: { [weak self] _, text in
        self?.sent.append(text)
        self?.state = .working
      })
    private var checksBackgroundNotices: Bool {
      ProcessInfo.processInfo.arguments.contains("--background-notice-preview")
    }
    private var notice: String {
      PromptSubmission.backgroundCompletionPrefix + "has finished.\nTests passed.\n"
        + PromptSubmission.backgroundCompletionSuffix
    }
    init() {
      if checksBackgroundNotices {
        queue.enqueue(agentID: node.id, text: notice)
        queue.enqueue(agentID: node.id, text: "Continue with the next step")
      }
    }
    var snapshot: AgentRuntimeSnapshot {
      AgentRuntimeSnapshot(
        id: node.id, provider: .codex, state: state, confidence: 1,
        transcript: checksBackgroundNotices
          ? [
            AgentTranscriptEntry(role: .user, text: "Run the tests"),
            AgentTranscriptEntry(role: .user, text: notice),
            AgentTranscriptEntry(role: .assistant, text: "The tests passed. Continuing the task."),
          ] : [])
    }

    func finish() {
      state = .done
      queue.observe(agentID: node.id, state: .done)
    }
    func stop() {
      queue.pause(node.id)
      state = .interrupted
    }
  }

  struct MessageQueuePreview: View {
    @StateObject private var provider = QueuePreviewProvider()
    var body: some View {
      VStack {
        HStack {
          Text("SIMULATED PROVIDER · Message queue")
          Button("Finish current run") { provider.finish() }
          Text("Sent: \(provider.sent.count)")
        }.padding()
        AgentConversationBody(
          node: provider.node,
          snapshot: provider.snapshot,
          turnChanges: nil, turnDiff: { _ in nil }, revertTurn: {}, history: [],
          scale: 1, isSelected: true, presentation: .conversation, isStageMode: false,
          hidesSurfaceBar: true, enterStage: {}, focus: {}, setPresentation: { _ in },
          send: { text, _ in
            provider.sent.append(text)
            provider.state = .working
          },
          sendBytes: { _ in }, resize: { _, _ in }, interrupt: { provider.stop() },
          stop: { provider.stop() }, restart: { provider.state = .idle },
          resolvePermission: { _ in }, alwaysAllowPermission: {}, resolveChoice: { _ in },
          setPermissionMode: { _ in }, setModel: { _, _ in }, setExecutionStrategy: { _ in },
          handoffTargets: { [] }, handoff: { _, _ in }, openBrowser: { _ in }
        ).environmentObject(provider.queue)
      }.frame(width: 880, height: 680)
    }
  }
#endif
