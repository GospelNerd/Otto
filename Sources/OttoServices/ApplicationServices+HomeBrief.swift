import Foundation
import OttoModels
import OttoRuntime

extension ApplicationServices {
  public var legacyProjectID: UUID? {
    conversationProjects.projects.first { $0.isLegacyWorkspace }?.id
  }

  public func projectID(forNode nodeID: UUID) -> UUID? {
    projectChannel(nodeID: nodeID).flatMap { conversationProjects.context(channelID: $0).projectID }
  }

  /// Brief items computed from Otto's own state: decisions waiting on the user and background
  /// work that finished or failed. Sessions the user drove themselves are not news.
  public func derivedBriefItems(now: Date = .now) -> [BriefItem] {
    var items: [BriefItem] = []
    let nodes = store.snapshot.canvases.flatMap(\.nodes)
    func nodeName(_ id: UUID) -> String? { nodes.first { $0.id == id }?.displayName }
    func botName(_ id: UUID?) -> String? { id.flatMap { agentProfiles.profile(id: $0)?.name } }

    var liveAttentionNodes = Set<UUID>()
    for attention in attentionItems
    where attention.state == .waitingPermission || attention.state == .waitingUser {
      guard nodes.first(where: { $0.id == attention.nodeID })?.kind == .agent else { continue }
      liveAttentionNodes.insert(attention.nodeID)
      let name = nodeName(attention.nodeID) ?? "Your assistant"
      let asking = attention.state == .waitingUser
      let reason =
        asking
        ? (Self.briefSnippet(attention.reason) ?? "Open the chat to reply.")
        : "It paused before doing something that needs your permission. Open the chat to allow or decline."
      items.append(
        BriefItem(
          id: "attention:\(attention.nodeID)", kind: .todo,
          title: asking ? "\(name) has a question for you" : "\(name) needs your OK",
          reason: watchdogWaitingNote(nodeID: attention.nodeID).map { "\($0) \(reason)" }
            ?? reason,
          source: name, needsYou: true,
          projectID: projectID(forNode: attention.nodeID), origin: .otto,
          action: .openAgent(attention.nodeID), createdAt: attention.createdAt))
    }

    // Agents the watchdog flags as stuck or looping. A live question or approval already has
    // its own line, so the same agent is not listed twice.
    items += watchdogBriefItems(excluding: liveAttentionNodes, nodeName: nodeName)

    for activity in botActivity.items {
      let nodeID: UUID? = {
        if case .agent(let id) = activity.deepLink { return id }
        return nil
      }()
      if let nodeID, liveAttentionNodes.contains(nodeID) { continue }
      let projectID =
        activity.channelID.flatMap { conversationProjects.context(channelID: $0).projectID }
        ?? nodeID.flatMap(projectID(forNode:))
      switch activity.state {
      case .needsUser:
        let name = botName(activity.profileID) ?? nodeID.flatMap(nodeName) ?? "A bot"
        items.append(
          BriefItem(
            id: "activity:\(activity.id)", kind: .todo, title: "Decide on \(name)’s request",
            reason: activity.detail ?? "It paused and is waiting for your decision.",
            source: name, needsYou: true, projectID: projectID, origin: .otto,
            action: nodeID.map(BriefAction.openAgent) ?? .openActivity,
            createdAt: activity.updatedAt))
      case .completed, .failed:
        guard now.timeIntervalSince(activity.updatedAt) <= DailyBriefComposer.updateWindow
        else { continue }
        let failed = activity.state == .failed
        if case .routine(let routineID, _) = activity.deepLink {
          guard let routine = routines.routine(id: routineID) else { continue }
          var profileID: UUID?
          if case .brief(let owner) = routine.delivery {
            // Its findings are already in the brief; only a failure is worth a line.
            guard failed else { continue }
            profileID = owner
          }
          items.append(
            BriefItem(
              id: "activity:\(activity.id)", kind: .update,
              title: failed ? "“\(routine.name)” didn’t finish" : "“\(routine.name)” ran",
              reason: failed
                ? "Open Routines to see what went wrong and run it again."
                : nodeID.flatMap { Self.briefSnippet(fleet[$0]?.result) },
              source: "Routine", needsYou: failed, projectID: projectID, profileID: profileID,
              origin: .otto, action: .openRoutine(routineID), createdAt: activity.updatedAt))
          continue
        }
        // Only work done by the user's bots is news. Sessions they drove, terminals and
        // background processes are plumbing: their exits never reach the brief.
        let profileID =
          activity.profileID
          ?? nodeID.flatMap { id in nodes.first { $0.id == id }?.agentDefinition?.profileID }
        guard let name = botName(profileID) else { continue }
        if let nodeID, nodes.first(where: { $0.id == nodeID })?.kind != .agent { continue }
        let snapshot = nodeID.flatMap { fleet[$0] }
        // A launch prompt can still carry Otto's context envelope; the title is the person's ask.
        let task = Self.briefSnippet(
          snapshot?.lastPrompt.map(PromptSubmission.originalUserText), limit: 70)
        items.append(
          BriefItem(
            id: "activity:\(activity.id)", kind: .update,
            title: failed
              ? "\(name) couldn’t finish"
              : task.map { "\(name) finished: \($0)" } ?? "\(name) finished a task",
            reason: failed
              ? "It stopped partway through. Open the chat to see what happened and try again."
              : Self.briefSnippet(snapshot?.result),
            source: name, needsYou: failed, projectID: projectID, origin: .otto,
            action: nodeID.map(BriefAction.openAgent) ?? .openActivity,
            createdAt: activity.updatedAt))
      case .working, .cancelled:
        continue
      }
    }
    return items
  }

  /// Creates or re-targets a profile's Otto-managed morning routine and links it to the profile.
  @discardableResult
  public func setUpMorningBrief(
    profileID: UUID, target: RoutineTarget, cron: String = "30 7 * * *"
  ) async throws -> Routine {
    guard var profile = dailyBrief.profile(id: profileID) else {
      throw DailyBriefStore.BriefError.unknownProfile
    }
    var routine =
      profile.briefRoutineID.flatMap { routines.routine(id: $0) }
      ?? Routine(
        name: "\(profile.name) morning brief",
        instruction: Self.morningBriefInstruction(profileName: profile.name),
        trigger: .schedule(cron: cron, intervalSeconds: nil), target: target)
    routine.target = target
    routine.trigger = .schedule(cron: cron, intervalSeconds: nil)
    routine.delivery = .brief(profileID: profileID)
    routine.enabled = true
    routine.permissionMode = AgentPermissionMode.readOnly.rawValue
    routine.quietWhenUnchanged = true
    let saved = try await saveRoutine(routine)
    profile = dailyBrief.profile(id: profileID) ?? profile
    profile.briefRoutineID = saved.id
    try dailyBrief.updateProfile(profile)
    try await syncMorningBriefAccounts(profileID: profileID)
    return saved
  }

  static func briefSnippet(_ text: String?, limit: Int = 220) -> String? {
    guard let text else { return nil }
    let flattened = text.split(whereSeparator: \.isNewline)
      .map { BriefOutputParser.cleanLine(String($0)) }
      .filter { !$0.isEmpty && !$0.hasPrefix("```") }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !flattened.isEmpty else { return nil }
    return flattened.count > limit ? String(flattened.prefix(limit - 1)) + "…" : flattened
  }
}
