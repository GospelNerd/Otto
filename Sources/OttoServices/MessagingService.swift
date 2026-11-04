import Combine
import Foundation
import OttoModels
import OttoSecurity

@MainActor
public final class MessagingService: ObservableObject {
  @Published public private(set) var status = "Disconnected"
  @Published public private(set) var cleanupRequired = false
  @Published public private(set) var pairingCode: String?
  @Published public private(set) var lastActivity: Date?
  @Published public private(set) var revision = 0
  private weak var services: ApplicationServices?
  private let simulation: Bool
  private let secrets: any SecretStore
  private let adapter: any MessagingProviderAdapter
  private var store: MessagingStore?
  private var timer: Task<Void, Never>?
  private var ready = false
  private var checkingApprovals: Set<UUID> = []
  private var awaitingApproval: Set<UUID> = []
  private var typingBinding: MessagingBinding?
  private var nextTyping = Date.distantPast
  private var connecting = false
  private var privateNotices: [UUID: String] = [:]
  var privatePhoneJobs: Set<UUID> = []
  private var epoch = UUID()
  private static let secretKey = "photon.project-secret"
  public var binding: MessagingBinding? { store?.binding }
  public var jobs: [MessagingJob] { store?.jobs ?? [] }
  public var teams: [BotChannel] {
    services?.botChannels.channels.filter {
      !$0.archived && $0.kind == .group && !$0.name.orEmpty.hasPrefix("Messaging · ")
    } ?? []
  }
  public func ownsRoom(_ id: UUID) -> Bool { binding?.enabled == true && binding?.roomID == id }
  public var projectPath: String { services?.defaultWorkspacePath ?? "" }
  public var projectName: String { (projectPath as NSString).lastPathComponent }
  public func coordinatorName(_ team: BotChannel) -> String {
    team.orchestratorProfileID.flatMap { services?.agentProfiles.profile(id: $0)?.name }
      ?? "Select a coordinator in team settings"
  }
  public init(
    services: ApplicationServices, adapter: (any MessagingProviderAdapter)? = nil,
    secrets: any SecretStore = makeKeychainSecretStore(service: OttoSecretService.messaging),
    url: URL? = nil,
    simulation: Bool = false
  ) {
    self.services = services
    self.secrets = secrets
    self.simulation = simulation
    self.adapter = adapter ?? PhotonMessagingAdapter()
    let url =
      url
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Otto/Messaging/state.json")
    do {
      store = try MessagingStore(url: url)
      lastActivity = store?.jobs.filter { !$0.text.isEmpty }.compactMap(\.acceptedAt).max()
    } catch { status = "Messaging storage is unavailable. Existing state was preserved." }
    self.adapter.onEvent = { [weak self] data in self?.receive(data) }
  }

  func privateJob(for nodeID: UUID) -> MessagingJob? {
    guard let services, let binding, binding.enabled, binding.sender != nil, ready else {
      return nil
    }
    return jobs.first {
      $0.state == .running && $0.binding.id == binding.id
        && services.activeTeamRuntimeID(channelID: $0.binding.roomID) == nodeID
    }
  }

  func sendPrivateLink(_ url: URL, for job: MessagingJob, nodeID: UUID) async throws {
    guard privateJob(for: nodeID)?.id == job.id else {
      throw PrivatePhoneConnection.Failure.unavailable
    }
    // Deliberately bypass durable text history. Only provider acceptance state is retained in memory.
    let notice = MessagingJob(
      binding: job.binding, eventKey: "private-sign-in", text: "",
      reply: "Continue privately on your phone: " + url.absoluteString, state: .sending)
    privateNotices[notice.id] = "sending"
    defer { privateNotices.removeValue(forKey: notice.id) }
    try adapter.send(notice)
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      try Task.checkCancellation()
      guard privateJob(for: nodeID)?.id == job.id else {
        throw PrivatePhoneConnection.Failure.interrupted
      }
      switch privateNotices[notice.id] {
      case "accepted": return
      case "retry", "uncertain": throw PrivatePhoneConnection.Failure.interrupted
      default: try await Task.sleep(for: .milliseconds(100))
      }
    }
    throw PrivatePhoneConnection.Failure.interrupted
  }

  public func start() {
    guard timer == nil else { return }
    timer = Task { [weak self] in
      if self?.binding?.enabled == false {
        await self?.disconnect()
      } else {
        await self?.reconnect()
      }
      while !Task.isCancelled {
        self?.tick()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
  public func stop() {
    services?.privatePhone.stop()
    updateFeedback(active: nil)
    PhotonMessagingAdapter.cancelInstallation()
    epoch = UUID()
    timer?.cancel()
    timer = nil
    ready = false
    adapter.disconnect()
  }

  public func install() async {
    guard !simulation else {
      status = "Simulated connector is ready; no installation or network is used."
      return
    }
    status = "Installing Photon connector…"
    do {
      try await PhotonMessagingAdapter.install()
      status = "Connector installed. Connect your Photon account."
    } catch { status = MessagingError.runtimeMissing.localizedDescription }
  }

  public func connect(
    accountID: String, secret: String, sender: String, destination: String, teamID: UUID
  ) async {
    guard !connecting else { return }
    connecting = true
    defer { connecting = false }
    do {
      guard let services, let store, let team = teams.first(where: { $0.id == teamID }),
        let lead = team.orchestratorProfileID,
        team.memberProfileIDs.contains(lead),
        services.agentProfiles.profile(id: lead)?.isArchived == false,
        services.connectorAccess.canUse(.iMessage, profileID: lead),
        !accountID.isEmpty, !secret.isEmpty,
        sender.range(of: #"^\+[1-9][0-9]{6,14}$"#, options: .regularExpression) != nil,
        destination.range(of: #"^\+[1-9][0-9]{6,14}$"#, options: .regularExpression) != nil
      else { throw MessagingError.invalidConfiguration }
      ready = false
      adapter.disconnect()
      epoch = UUID()
      let currentEpoch = epoch
      // Invalidate old delivery before replacing credentials.
      try store.disconnect()
      try await secrets.set(secret, for: Self.secretKey)
      guard currentEpoch == epoch else {
        try await secrets.delete(Self.secretKey)
        return
      }
      try store.configure(
        MessagingBinding(
          accountID: accountID, projectPath: projectPath,
          teamID: teamID, coordinatorID: lead, expectedSender: sender, destination: destination))
      pairingCode = try store.issuePairing()
      try adapter.connect(accountID: accountID, secret: secret)
      status = "Connecting to Photon…"
      revision += 1
    } catch {
      status =
        error is MessagingError
        ? error.localizedDescription : "Could not save connection securely. Retry in Otto."
    }
  }

  public func reconnect() async {
    guard let binding, binding.enabled else { return }
    do {
      guard valid(binding) else { throw MessagingError.invalidConfiguration }
      if binding.sender != nil { try ensureRoom(binding) }
      let currentEpoch = epoch
      guard let secret = try await secrets.value(for: Self.secretKey) else {
        throw MessagingError.providerUnavailable
      }
      guard currentEpoch == epoch, self.binding?.enabled == true else { return }
      ready = false
      try adapter.connect(accountID: binding.accountID, secret: secret)
      if binding.sender == nil { pairingCode = try store?.issuePairing() }
      status = "Connecting to Photon…"
    } catch {
      status =
        error is MessagingError
        ? error.localizedDescription : "Keychain access failed. Reconnect in Otto."
    }
  }

  public func newPairingCode() {
    do {
      pairingCode = try store?.issuePairing()
      status = "Send the pairing message within five minutes."
    } catch { status = error.localizedDescription }
  }

  public func disconnect() async {
    services?.privatePhone.stop()
    updateFeedback(active: nil)
    epoch = UUID()
    ready = false
    pairingCode = nil
    adapter.disconnect()
    do {
      try store?.disconnect()
      try await secrets.delete(Self.secretKey)
      cleanupRequired = false
      status =
        "Disconnected. Local credentials and pairing removed. History retained. Revoke the project secret in Photon if needed."
    } catch {
      cleanupRequired = true
      status = "Delivery stopped. Credential or state cleanup failed; retry Disconnect."
    }
    revision += 1
  }

  public func openTeam() {
    if let binding, binding.enabled, binding.sender != nil {
      do {
        try ensureRoom(binding)
        _ = try services?.controlOpenTeam(binding.roomID.uuidString)
      } catch {
        status = "Messaging conversation unavailable. Review the saved team configuration."
      }
      return
    }
    if let id = binding?.teamID ?? teams.first?.id {
      _ = try? services?.controlOpenTeam(id.uuidString)
    } else {
      _ = try? services?.controlOpenChat(section: "bots")
    }
  }

  private func ensureRoom(_ binding: MessagingBinding) throws {
    guard valid(binding), let services,
      let team = services.botChannels.channel(id: binding.teamID)
    else { throw MessagingError.invalidConfiguration }
    let instructions =
      (team.instructions ?? "")
      + "\nOnly the coordinator synthesizes the final messaging response. Specialists work internally. Website-account sign-in and click approvals use private links in the paired conversation. Other permission requests and interrupted work require review in Otto."
    if var room = services.botChannels.channel(id: binding.roomID) {
      guard !room.archived else { throw MessagingError.invalidConfiguration }
      room.memberProfileIDs = team.memberProfileIDs
      room.orchestratorProfileID = binding.coordinatorID
      room.instructions = instructions
      _ = try services.botChannels.save(room)
    } else {
      _ = try services.botChannels.save(
        BotChannel(
          id: binding.roomID, profileID: binding.coordinatorID,
          kind: .group, memberProfileIDs: team.memberProfileIDs,
          name: "Messaging · " + (team.name ?? "Team"), instructions: instructions,
          orchestratorProfileID: binding.coordinatorID))
    }
  }

  private func valid(_ binding: MessagingBinding) -> Bool {
    guard binding.projectPath == projectPath,
      let team = services?.botChannels.channel(id: binding.teamID), !team.archived,
      team.orchestratorProfileID == binding.coordinatorID,
      team.memberProfileIDs.contains(binding.coordinatorID),
      team.memberProfileIDs.count >= BotGroupSession.minMembers,
      team.memberProfileIDs.allSatisfy({
        services?.agentProfiles.profile(id: $0)?.isArchived == false
      }),
      services?.agentProfiles.profile(id: binding.coordinatorID)?.isArchived == false,
      // Revoking iMessage access for the coordinator stops the binding everywhere it is checked.
      services?.connectorAccess.canUse(.iMessage, profileID: binding.coordinatorID) == true
    else { return false }
    return true
  }

  private func receive(_ data: Data) {
    guard let store, binding?.enabled == true,
      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = event["kind"] as? String
    else { return }
    if let id = (event["id"] as? String).flatMap(UUID.init(uuidString:)),
      privateNotices[id] != nil, ["accepted", "uncertain", "retry"].contains(kind)
    {
      privateNotices[id] = kind
      return
    }
    switch kind {
    case "ready":
      ready = true
      status =
        binding?.sender == nil
        ? "Photon initialized. Pair your phone to verify delivery."
        : "Photon initialized. Waiting for a text exchange."
    case "offline", "connectionFailed":
      typingBinding = nil
      nextTyping = .distantPast
      ready = false
      switch event["reason"] as? String {
      case "credentialExpired":
        status = "Photon rejected the credentials. Check your account and reconnect."
      case "throttled": status = "Photon is throttling this account. Wait before reconnecting."
      default: status = "Photon unavailable. Check credentials and network, then reconnect."
      }
      for var job in store.jobs where job.state == .sending {
        job.state = .uncertain
        try? store.update(job)
      }
    case "inbound":
      guard ready, let binding, valid(binding),
        let inbound = try? JSONDecoder().decode(MessagingInbound.self, from: data)
      else { return }
      do {
        if try store.accept(inbound) {
          if store.binding?.sender != nil { pairingCode = nil }
          if let paired = store.binding, paired.sender != nil {
            try? adapter.signal("read", binding: paired, eventID: inbound.eventID)
          }
          status = "Message received. Preparing your response."
        }
      } catch {
        ready = false
        adapter.disconnect()
        status = "Delivery paused: could not persist the inbound message."
      }
    case "accepted", "uncertain", "retry":
      guard let id = (event["id"] as? String).flatMap(UUID.init(uuidString:)),
        var job = store.jobs.first(where: { $0.id == id }), job.state == .sending
      else { return }
      if kind == "accepted" {
        job.state = .accepted
        job.acceptedAt = .now
        if !job.text.isEmpty {
          lastActivity = .now
          status = "Text exchange complete · Photon accepted the response"
        } else if job.progressParentID != nil {
          status = "Your team is working. Acknowledgement accepted by Photon."
        } else {
          status =
            job.reply?.hasPrefix("Paired") == true
            ? "Paired. Send a text request to test your team."
            : "Review notice accepted by Photon. Open Otto to continue."
        }
      } else if kind == "retry", job.attempts < 4 {
        job.state = .ready
        job.nextAttempt = Date().addingTimeInterval(pow(2, Double(job.attempts)) * 5)
        status = "Provider unavailable before send. Retry scheduled."
      } else {
        job.state = kind == "retry" ? .failed : .uncertain
        status =
          kind == "retry"
          ? "Delivery failed after four attempts. Open Otto to review."
          : "Delivery uncertain. Check the conversation; Otto will not resend automatically."
      }
      if event["reason"] as? String == "credentialExpired" {
        ready = false
        adapter.disconnect()
        status =
          "Photon rejected the credentials. Reconnect in Otto; review any uncertain send before resending."
      } else if event["reason"] as? String == "throttled" {
        status =
          job.state == .ready
          ? "Photon is throttling this account. Retry scheduled."
          : "Photon throttled the send. Its outcome is uncertain; review before resending."
      }
      do { try store.update(job) } catch {
        ready = false
        adapter.disconnect()
        status = "Delivery paused: could not persist the send outcome."
      }
    default: break
    }
    revision += 1
  }

  func updateFeedback(active: MessagingJob?, now: Date = .now) {
    guard let active else {
      if let typingBinding {
        try? adapter.signal("typingStop", binding: typingBinding, eventID: nil)
      }
      typingBinding = nil
      nextTyping = .distantPast
      return
    }
    if now >= nextTyping {
      try? adapter.signal("typingStart", binding: active.binding, eventID: nil)
      typingBinding = active.binding
      nextTyping = now.addingTimeInterval(8)
    }
    if now.timeIntervalSince(active.createdAt) >= 15 {
      try? store?.enqueueProgress(for: active)
    }
  }

  func tick(now: Date = .now) {
    guard let store, let binding, binding.enabled, let services else { return }
    guard valid(binding) else {
      updateFeedback(active: nil)
      ready = false
      adapter.disconnect()
      status = "Routing paused. Open team settings to select an available coordinator."
      return
    }
    for var job in store.jobs where job.state == .sending && job.nextAttempt <= now {
      job.state = .uncertain
      do { try store.update(job) } catch {
        ready = false
        adapter.disconnect()
      }
      status = "Delivery uncertain after timeout. Check the conversation before sending again."
    }
    // Recover work by its persisted request ID; never start a second run after an ambiguous crash.
    for var job in store.jobs where job.state == .running {
      let matches = services.botGroups.allSessions.filter {
        $0.channelID == job.binding.roomID && $0.messages.contains(where: { $0.id == job.id })
      }
      let session = matches.count == 1 ? matches.first : nil
      guard let index = session?.messages.firstIndex(where: { $0.id == job.id }) else {
        job.state = .uncertain
        try? store.update(job)
        status = "Task dispatch uncertain after restart. Open Otto to review."
        continue
      }
      if services.isTeamRunning(channelID: job.binding.roomID) {
        if let runtimeID = services.activeTeamRuntimeID(channelID: job.binding.roomID),
          checkingApprovals.insert(job.id).inserted
        {
          let checking = job
          Task { [weak self] in
            defer { self?.checkingApprovals.remove(checking.id) }
            if await services.supervisor.pendingPermission(agentID: runtimeID) != nil {
              self?.awaitingApproval.insert(checking.id)
              self?.updateFeedback(active: nil)
              do { try self?.store?.enqueueReview(for: checking) } catch {
                self?.ready = false
                self?.adapter.disconnect()
              }
            } else {
              self?.awaitingApproval.remove(checking.id)
            }
          }
        }
        continue
      }
      if session?.needsUser == true || session?.teamCheckpoint != nil {
        try? store.enqueueReview(for: job)
        status = "Team paused for desktop review. Queued requests will wait."
        continue
      }
      // A desktop turn may have arrived before the outbox captured this result.
      // Never cross the next user-message boundary or borrow a different session's answer.
      let turn = session?.messages.dropFirst(index + 1).prefix { $0.author != .user }
      if let answer = turn?.last,
        answer.author == .bot(job.binding.coordinatorID),
        !answer.text.contains("→ Handed to @"),
        !answer.text.localizedCaseInsensitiveContains("@user")
      {
        // iMessage shows plain text: no diagrams, tables, details divider or cards.
        job.reply = ChatChannelReplyFormatter.plainText(answer.text)
        job.state = .ready
      } else {
        job.state = .uncertain
        try? store.enqueueReview(for: job)
        status = "Response attribution needs desktop review. No answer was forwarded."
      }
      try? store.update(job)
    }
    let active =
      ready && services.isOnline
      ? store.jobs.first {
        $0.state == .running && !awaitingApproval.contains($0.id)
          && !privatePhoneJobs.contains($0.id)
          && services.isTeamRunning(channelID: $0.binding.roomID)
          && services.botGroups.latestSession(forChannel: $0.binding.roomID)?.needsUser != true
      } : nil
    updateFeedback(active: active, now: now)
    // Never emit a delayed "working" notice after completion, review, or interruption.
    for var notice in store.jobs where notice.progressParentID != nil && notice.state == .ready {
      if notice.progressParentID != active?.id {
        notice.state = .cancelled
        try? store.update(notice)
      }
    }
    guard ready, services.isOnline else { return }
    let roomSession = services.botGroups.latestSession(forChannel: binding.roomID)
    if roomSession?.needsUser != true, roomSession?.teamCheckpoint == nil,
      !services.isTeamRunning(channelID: binding.roomID),
      !store.jobs.contains(where: { $0.state == .running }),
      var job = store.jobs.first(where: { $0.state == .queued })
    {
      do {
        guard valid(job.binding), job.binding.id == binding.id else {
          throw MessagingError.invalidConfiguration
        }
        try ensureRoom(binding)
        job.state = .running
        try store.update(job)
        let dispatched = job
        Task { [weak self] in
          guard self?.binding?.enabled == true, self?.binding?.id == dispatched.binding.id,
            self?.valid(dispatched.binding) == true
          else { return }
          let session = services.botGroups.latestSession(forChannel: dispatched.binding.roomID)
          guard session?.needsUser != true, session?.teamCheckpoint == nil,
            !services.isTeamRunning(channelID: dispatched.binding.roomID)
          else {
            // No dispatch occurred: retain accepted work for after desktop review.
            guard let self, var waiting = self.store?.jobs.first(where: { $0.id == dispatched.id }),
              waiting.state == .running
            else { return }
            waiting.state = .queued
            do {
              try self.store?.update(waiting)
              self.status = "Team dispatch paused for desktop review."
            } catch {
              self.ready = false
              self.adapter.disconnect()
              self.status = "Delivery paused: could not persist the queued request."
            }
            self.revision += 1
            return
          }
          do {
            try await services.sendTeamMessage(
              channelID: dispatched.binding.roomID, text: dispatched.text,
              at: WorldPoint(x: 0, y: 0), requestID: dispatched.id, coordinatorOnly: true)
          } catch {
            self?.status =
              "Team dispatch needs review in Otto. It will not be automatically repeated."
          }
        }
      } catch {
        job.state = .failed
        try? store.update(job)
        status = "Routing failed. Review the selected team in Otto."
      }
    }
    if !store.jobs.contains(where: { $0.state == .sending }),
      var job = store.jobs.first(where: { $0.state == .ready && $0.nextAttempt <= now })
    {
      do {
        job.state = .sending
        job.attempts += 1
        job.nextAttempt = Date().addingTimeInterval(60)
        try store.update(job)
        try adapter.send(job)
      } catch {
        job.state = .uncertain
        try? store.update(job)
        status = "Delivery uncertain. Open Otto to review."
      }
    }
    revision += 1
  }
}

extension Optional where Wrapped == String { fileprivate var orEmpty: String { self ?? "" } }
