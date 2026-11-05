import Combine
import Foundation
import OttoModels
import OttoRuntime

/// App-owned FIFO queues survive navigation. Restored queues require an explicit resume.
/// When the agent becomes ready, every pending message is sent together as one prompt, in
/// order, so several messages typed during a long turn cost one new turn rather than one each.
/// Slash commands are the exception: each is sent on its own because the command parser reads
/// the whole prompt.
@MainActor
public final class AgentMessageQueue: ObservableObject {
  public struct Message: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
  }

  @Published public private(set) var messages: [UUID: [Message]] = [:]
  @Published public private(set) var paused: Set<UUID> = []
  @Published public private(set) var errors: [UUID: String] = [:]
  private var claimed: [UUID: [Message]] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private let url: URL?
  private let state: @MainActor (UUID) async -> AgentLifecycleState?
  private let send: @MainActor (UUID, String) async throws -> Void

  public init(
    url: URL? = nil,
    state: @escaping @MainActor (UUID) async -> AgentLifecycleState?,
    send: @escaping @MainActor (UUID, String) async throws -> Void
  ) {
    self.url = url
    self.state = state
    self.send = send
    if let url, let data = try? Data(contentsOf: url),
      let restored = try? JSONDecoder().decode([UUID: [Message]].self, from: data)
    {
      messages = restored
      paused = Set(restored.filter { !$0.value.isEmpty }.keys)
    }
  }

  public func enqueue(agentID: UUID, text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    messages[agentID, default: []].append(Message(id: UUID(), text: text))
    persist(agentID)
    schedule(agentID)
  }

  /// Pending internal notices still dispatch and persist, but never appear as user drafts.
  public func visibleMessages(agentID: UUID) -> [Message] {
    messages[agentID, default: []].compactMap { message in
      guard let text = PromptSubmission.visibleUserText(message.text) else { return nil }
      return Message(id: message.id, text: text)
    }
  }

  public func remove(agentID: UUID, messageID: UUID) {
    // A claimed item is already being dispatched; it is no longer in the pending list.
    messages[agentID]?.removeAll { $0.id == messageID }
    if messages[agentID]?.isEmpty != false, claimed[agentID]?.isEmpty != false {
      paused.remove(agentID)
      errors[agentID] = nil
    }
    persist(agentID)
  }

  public func pause(_ agentID: UUID) {
    guard messages[agentID]?.isEmpty == false || claimed[agentID]?.isEmpty == false else { return }
    paused.insert(agentID)
    tasks[agentID]?.cancel()
  }

  public func pauseAll() {
    for id in Set(messages.keys).union(tasks.keys) { pause(id) }
  }

  public func resume(_ agentID: UUID) {
    paused.remove(agentID)
    errors[agentID] = nil
    schedule(agentID, restarting: true)
  }

  public func observe(agentID: UUID, state: AgentLifecycleState) {
    switch state {
    case .failed, .interrupted, .stopped: pause(agentID)
    case .done, .idle: schedule(agentID)
    default: break
    }
  }

  private func schedule(_ agentID: UUID, restarting: Bool = false) {
    guard tasks[agentID] == nil, !paused.contains(agentID),
      messages[agentID]?.isEmpty == false
    else { return }
    tasks[agentID] = Task { [weak self] in
      guard let self else { return }
      var delivered = false
      defer {
        self.tasks[agentID] = nil
        if delivered {
          self.schedule(agentID)
        } else if Task.isCancelled && !self.paused.contains(agentID) {
          self.schedule(agentID, restarting: true)
        }
      }
      let current = await self.state(agentID)
      guard !Task.isCancelled, !self.paused.contains(agentID) else { return }
      let ready =
        current == .idle || current == .done
        || (restarting
          && (current == nil || current == .interrupted
            || current == .stopped || current == .failed))
      guard ready, let pending = self.messages[agentID], !pending.isEmpty else { return }
      let batch = Self.batch(pending)
      self.claimed[agentID] = batch
      self.messages[agentID]?.removeFirst(batch.count)
      // Keep the claimed messages on disk until the provider accepts them.
      do {
        try await self.send(agentID, Self.prompt(joining: batch))
        self.claimed[agentID] = nil
        delivered = true
        self.persist(agentID)
      } catch {
        self.claimed[agentID] = nil
        self.messages[agentID, default: []].insert(contentsOf: batch, at: 0)
        if !(error is CancellationError) {
          self.paused.insert(agentID)
          self.errors[agentID] =
            "Could not send queued \(batch.count == 1 ? "message" : "messages"): \(error.localizedDescription)"
        }
        self.persist(agentID)
      }
    }
  }

  /// Separates merged messages so the agent can tell where one ends and the next begins.
  public nonisolated static let mergedMessageSeparator = PromptSubmission.queuedMessageSeparator

  /// The leading run of messages to send as one prompt: everything up to the next slash command,
  /// or a single slash command on its own.
  nonisolated static func batch(_ pending: [Message]) -> [Message] {
    guard let first = pending.first else { return [] }
    if isSlashCommand(first.text) { return [first] }
    return Array(pending.prefix { !isSlashCommand($0.text) })
  }

  nonisolated static func prompt(joining batch: [Message]) -> String {
    batch.map(\.text).joined(separator: mergedMessageSeparator)
  }

  private nonisolated static func isSlashCommand(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
  }

  private func persist(_ agentID: UUID) {
    guard let url else { return }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      var saved = messages
      for (id, batch) in claimed { saved[id, default: []].insert(contentsOf: batch, at: 0) }
      try JSONEncoder().encode(saved).write(to: url, options: .atomic)
    } catch {
      errors[agentID] = "Queue could not be saved: \(error.localizedDescription)"
    }
  }
}
