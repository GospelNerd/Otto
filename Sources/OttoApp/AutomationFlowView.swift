import OttoCore
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

/// Flow view for Automations: one automation and the steps chained after it, drawn as a tree
/// so you can see who started whom, how each step is doing, and change how it runs.
extension AutomationsView {
  /// What a step is doing right now, worked out from its latest run and its agent.
  enum StepState: Equatable {
    case running, needsYou, done, failed, nothingNew, paused, idle

    var label: String {
      switch self {
      case .running: "Running"
      case .needsYou: "Needs you"
      case .done: "Done"
      case .failed: "Failed"
      case .nothingNew: "Nothing new"
      case .paused: "Paused"
      case .idle: "Not run yet"
      }
    }

    var symbol: String {
      switch self {
      case .running: "circle.dotted"
      case .needsYou: "hand.raised"
      case .done: "checkmark"
      case .failed: "exclamationmark.triangle"
      case .nothingNew: "minus"
      case .paused: "pause"
      case .idle: "circle"
      }
    }

    var isLive: Bool { self == .running || self == .needsYou }
  }

  /// One render's worth of flow data, so run history is read from disk once per update.
  struct FlowSnapshot {
    let steps: [Routine]
    let runs: [UUID: [RoutineRunRecord]]
    /// Status of each agent node that still exists.
    let nodes: [UUID: NodeStatus]
    /// Runs whose answer is waiting on Home for the person to approve.
    var runsAwaitingApproval: Set<UUID> = []

    func children(of id: UUID) -> [Routine] {
      steps.filter { $0.runAfter?.routineID == id }
        .sorted { $0.createdAt < $1.createdAt }
    }

    /// Automations that start a flow: their own trigger, or a step whose parent is gone.
    var roots: [Routine] {
      let ids = Set(steps.map(\.id))
      return steps.filter { step in
        guard let parent = step.runAfter?.routineID else { return true }
        return !ids.contains(parent)
      }
    }

    func tree(from root: Routine) -> [Routine] {
      var result: [Routine] = []
      var queue = [root]
      var seen: Set<UUID> = []
      while !queue.isEmpty {
        let next = queue.removeFirst()
        guard seen.insert(next.id).inserted else { continue }
        result.append(next)
        queue += children(of: next.id)
      }
      return result
    }

    func latestRun(_ id: UUID) -> RoutineRunRecord? {
      runs[id]?.first { $0.outcome != .skipped } ?? runs[id]?.first
    }

    /// Its latest answer is waiting on Home: done working, but the flow is held for the person.
    func isAwaitingApproval(_ routine: Routine) -> Bool {
      latestRun(routine.id).map { runsAwaitingApproval.contains($0.runID) } ?? false
    }

    func state(of routine: Routine) -> StepState {
      if let run = latestRun(routine.id) {
        switch run.outcome {
        case .running:
          if let nodeID = run.agentNodeID, nodes[nodeID] == .waiting { return .needsYou }
          return .running
        case .completed where runsAwaitingApproval.contains(run.runID): return .needsYou
        case .completed where routine.enabled: return .done
        case .failed where routine.enabled: return .failed
        case .noChange where routine.enabled: return .nothingNew
        default: break
        }
      }
      return routine.enabled ? .idle : .paused
    }
  }

  var flowSnapshot: FlowSnapshot {
    _ = routines.runsRevision
    let steps = sorted
    let ids = Set(steps.map(\.id))
    let runs = Dictionary(
      grouping: routines.recentRuns(limit: 800).filter { ids.contains($0.routineID) },
      by: \.routineID)
    return FlowSnapshot(
      steps: steps, runs: runs, nodes: live.statuses,
      runsAwaitingApproval: Set(services.homeReviews.open.compactMap(\.runID)))
  }

  // MARK: Layout

  var flowLayout: some View {
    let snapshot = flowSnapshot
    let roots = snapshot.roots.filter(isAdvanced)
    let root =
      roots.first { $0.id == selectedFlowID }
      ?? selectedStepID.flatMap { id in
        roots.first { root in snapshot.tree(from: root).contains { $0.id == id } }
      }
      ?? roots.first
    let tree = root.map(snapshot.tree(from:)) ?? []
    let selected = tree.first { $0.id == selectedStepID } ?? root
    return VStack(spacing: 0) {
      if let root {
        boardBar(root: root, roots: roots, tree: tree, snapshot: snapshot)
        Rectangle().fill(palette.paper.opacity(0.07)).frame(height: 1)
        HStack(spacing: 0) {
          ZStack(alignment: .bottom) {
            AutomationDotGrid()
            GeometryReader { viewport in
              ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 34) {
                  triggerPill(root)
                    .anchorPreference(key: FlowAnchorKey.self, value: .bounds) {
                      [Self.triggerAnchorID: $0]
                    }
                  subtree(root, snapshot: snapshot, selectedID: selected?.id)
                }
                .backgroundPreferenceValue(FlowAnchorKey.self) { anchors in
                  GeometryReader { proxy in
                    wires(
                      tree: tree, root: root, anchors: anchors, proxy: proxy, snapshot: snapshot)
                  }
                }
                .padding(.top, 28).padding(.bottom, 96)
                .padding(.horizontal, 24)
                .frame(
                  minWidth: viewport.size.width, minHeight: viewport.size.height,
                  alignment: .top)
              }
              .scrollIndicators(.automatic)
            }
            runBar(root: root, tree: tree, snapshot: snapshot)
              .padding(.bottom, 18)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          if let selected {
            Rectangle().fill(palette.paper.opacity(0.07)).frame(width: 1)
            Group {
              if let watchingRun, let runConversation, snapshot.nodes[watchingRun] != nil {
                runPanel(selected, nodeID: watchingRun, conversation: runConversation)
                  .frame(width: 440)
              } else {
                inspector(selected, tree: tree, snapshot: snapshot)
                  .frame(width: 340)
              }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(palette.raised)
          }
        }
      }
    }
    .automationBoard(palette)
    .padding(.horizontal, 24)
    .padding(.top, 10)
    .padding(.bottom, 22)
    .onAppear {
      if selectedFlowID == nil { selectedFlowID = root?.id }
    }
  }

  private func boardBar(
    root: Routine, roots: [Routine], tree: [Routine], snapshot: FlowSnapshot
  ) -> some View {
    let states = tree.map(snapshot.state(of:))
    let runningCount = states.filter { $0 == .running }.count
    let needsYouCount = states.filter { $0 == .needsYou }.count
    let failedCount = states.filter { $0 == .failed }.count
    let anyOn = tree.contains(where: \.enabled)
    return HStack(spacing: 10) {
      Image(systemName: "clock").font(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.muted)
      Text(triggerLabel(root)).font(.ottoMono(10.5)).foregroundStyle(palette.muted)
        .lineLimit(1)
      if !anyOn {
        Text("PAUSED").font(.ottoMicro).tracking(1.4).foregroundStyle(palette.muted)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(palette.paper.opacity(0.07), in: Capsule())
      }
      Spacer(minLength: 12)
      Text("\(tree.count) agent\(tree.count == 1 ? "" : "s")")
        .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
      if runningCount > 0 {
        Text("\(runningCount) running").font(.ottoDisplay(12).weight(.medium))
          .foregroundStyle(palette.signal)
      }
      if needsYouCount > 0 { chip("\(needsYouCount) needs you", color: palette.amber) }
      if failedCount > 0 { chip("\(failedCount) failed", color: palette.red) }
      Rectangle().fill(palette.paper.opacity(0.12)).frame(width: 1, height: 14)
      Button {
        builder = AutomationFlowDraft(flowFrom: root, in: routines.routines)
      } label: {
        Label("Edit in canvas", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.ottoDisplay(12).weight(.medium))
      }
      .buttonStyle(.plain).foregroundStyle(palette.paper.opacity(0.85))
      .accessibilityIdentifier("automations.flow.editCanvas")
      Button {
        for step in tree where step.enabled == anyOn { setEnabled(step, !anyOn) }
      } label: {
        Image(systemName: anyOn ? "pause" : "play").font(.system(size: 11, weight: .semibold))
          .frame(width: 26, height: 22)
      }
      .buttonStyle(.plain).foregroundStyle(palette.paper.opacity(0.85))
      .help(anyOn ? "Pause the flow" : "Turn the flow on")
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
  }

  /// The floating bar under the canvas: run the flow, or see that it is running.
  private func runBar(root: Routine, tree: [Routine], snapshot: FlowSnapshot) -> some View {
    // A step waiting for approval isn't working, so it doesn't count as running.
    let live = tree.filter {
      snapshot.state(of: $0).isLive && !snapshot.isAwaitingApproval($0)
    }
    let started = tree.compactMap { snapshot.latestRun($0.id) }
      .filter { $0.outcome == .running }.map(\.firedAt).min()
    return HStack(spacing: 10) {
      Button {
        if live.isEmpty { run(root) }
      } label: {
        HStack(spacing: 8) {
          if live.isEmpty {
            Image(systemName: "play.fill").font(.system(size: 10))
            Text(running.contains(root.id) ? "Starting…" : "Run flow")
              .font(.ottoDisplay(12.5).weight(.semibold))
          } else {
            AutomationSpinner(color: palette.onSignal, size: 13, lineWidth: 2)
            VStack(alignment: .leading, spacing: 0) {
              Text("Running").font(.ottoDisplay(12.5).weight(.semibold))
              TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(
                  "\(live.count) agent\(live.count == 1 ? "" : "s") working · \(Self.duration(context.date.timeIntervalSince(started ?? context.date)))"
                )
                .font(.ottoDisplay(10.5)).opacity(0.65)
              }
            }
          }
        }
        .foregroundStyle(palette.onSignal)
        .padding(.horizontal, 15).padding(.vertical, live.isEmpty ? 9 : 7)
        .background(palette.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
      }
      .buttonStyle(.plain)
      .foregroundStyle(palette.ink)
      .help("Runs “\(root.name)”; the agents after it follow on their own")
      .accessibilityIdentifier("automations.flow.run")
      Button {
        editing = .newStep(after: tree.first { $0.id == selectedStepID } ?? root)
      } label: {
        Label("AI agent", systemImage: "plus")
          .font(.ottoDisplay(12).weight(.semibold))
          .foregroundStyle(palette.signal)
          .padding(.horizontal, 12).padding(.vertical, 9)
          .background(palette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(palette.paper.opacity(0.1))
          )
          .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
      }
      .buttonStyle(.plain)
      .help("Add an AI agent after the selected one")
    }
  }

  private func chip(_ text: String, color: Color) -> some View {
    Text(text).font(.ottoDisplay(11.5).weight(.medium))
      .foregroundStyle(color)
      .padding(.horizontal, 9).padding(.vertical, 3)
      .background(color.opacity(0.12), in: Capsule())
      .fixedSize()
  }

  // MARK: Tree

  private func subtree(_ routine: Routine, snapshot: FlowSnapshot, selectedID: UUID?) -> AnyView {
    let children = snapshot.children(of: routine.id)
    return AnyView(
      VStack(spacing: 46) {
        stepCard(
          routine, state: snapshot.state(of: routine),
          run: snapshot.latestRun(routine.id), childCount: children.count,
          selected: routine.id == selectedID)
        if !children.isEmpty {
          HStack(alignment: .top, spacing: 22) {
            ForEach(children) { child in
              subtree(child, snapshot: snapshot, selectedID: selectedID)
            }
          }
        }
      })
  }

  static let triggerAnchorID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

  /// Every connector in one layer behind the cards: down from the parent, across with a
  /// rounded elbow, and down into the child. Live branches are drawn in the signal colour.
  private func wires(
    tree: [Routine], root: Routine, anchors: [UUID: Anchor<CGRect>], proxy: GeometryProxy,
    snapshot: FlowSnapshot
  ) -> some View {
    let edges: [(from: UUID, to: Routine)] = tree.map { step in
      (step.id == root.id ? Self.triggerAnchorID : step.runAfter?.routineID ?? root.id, step)
    }
    return ZStack(alignment: .topLeading) {
      ForEach(edges, id: \.to.id) { edge in
        if let fromAnchor = anchors[edge.from], let toAnchor = anchors[edge.to.id] {
          let from = proxy[fromAnchor]
          let to = proxy[toAnchor]
          let live = snapshot.state(of: edge.to).isLive
          let condition = edge.to.runAfter?.when ?? .succeeded
          AutomationWire(from: from, to: to, live: live, failedBranch: condition == .failed)
          if condition != .succeeded {
            conditionTag(condition)
              .position(x: to.midX, y: to.minY - 13)
          }
        }
      }
    }
    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
  }

  static func wirePath(from: CGRect, to: CGRect) -> Path {
    Path { path in
      let start = CGPoint(x: from.midX, y: from.maxY)
      let end = CGPoint(x: to.midX, y: to.minY)
      let bend = start.y + min(22, (end.y - start.y) / 2)
      path.move(to: start)
      let dx = end.x - start.x
      guard abs(dx) > 1 else {
        path.addLine(to: end)
        return
      }
      let radius = min(10, abs(dx) / 2, (end.y - bend) / 2)
      let sign: CGFloat = dx > 0 ? 1 : -1
      path.addLine(to: CGPoint(x: start.x, y: bend - radius))
      path.addQuadCurve(
        to: CGPoint(x: start.x + sign * radius, y: bend), control: CGPoint(x: start.x, y: bend))
      path.addLine(to: CGPoint(x: end.x - sign * radius, y: bend))
      path.addQuadCurve(
        to: CGPoint(x: end.x, y: bend + radius), control: CGPoint(x: end.x, y: bend))
      path.addLine(to: end)
    }
  }

  private func conditionTag(_ condition: RoutineChainCondition) -> some View {
    let failed = condition == .failed
    return Text(failed ? "IF IT FAILS" : "EITHER WAY")
      .font(.ottoMono(8.5, weight: .medium)).tracking(1.2)
      .foregroundStyle(failed ? palette.red : palette.muted)
      .padding(.horizontal, 7).padding(.vertical, 2)
      .background(palette.surface, in: Capsule())
      .overlay(Capsule().strokeBorder(palette.paper.opacity(0.14)))
      .fixedSize()
  }

  private func triggerPill(_ root: Routine) -> some View {
    HStack(spacing: 8) {
      Image(systemName: root.runAfter == nil ? "clock" : "link")
        .font(.system(size: 11, weight: .medium))
        .frame(width: 24, height: 24)
        .background(palette.surface, in: Circle())
      Text(triggerLabel(root)).font(.ottoDisplay(12.5).weight(.semibold)).lineLimit(1)
      if let next = root.enabled ? RoutineEngine.nextScheduledFire(for: root, after: .now) : nil {
        Text("next \(next.formatted(.relative(presentation: .named)))")
          .font(.ottoMono(10)).foregroundStyle(palette.muted)
      }
    }
    .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
    .background(palette.raised, in: Capsule())
    .overlay(Capsule().strokeBorder(palette.paper.opacity(0.1)))
    .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
  }

  private func stepCard(
    _ routine: Routine, state: StepState, run: RoutineRunRecord?, childCount: Int, selected: Bool
  ) -> some View {
    TimelineView(.periodic(from: .now, by: state.isLive ? 1 : 3600)) { context in
      AutomationNodeCard(
        title: routine.name, subtitle: subtitle(routine),
        logo: AnyView(nodeLogo(routine.target)),
        badge: .state(state), task: Self.firstLine(of: routine.instruction),
        meta: runMeta(run, now: context.date), trailing: deliveryLabel(routine.delivery),
        childCount: childCount, selected: selected, dimmed: !routine.enabled)
    }
    .contentShape(RoundedRectangle(cornerRadius: 11))
    .onTapGesture(count: 2) { editing = .edit(routine) }
    .onTapGesture {
      selectedStepID = routine.id
      watchingRun = nil
    }
    .overlay(alignment: .bottom) {
      if selected {
        Button {
          editing = .newStep(after: routine)
        } label: {
          Image(systemName: "plus").font(.system(size: 9, weight: .bold))
            .foregroundStyle(palette.onSignal)
            .frame(width: 20, height: 20)
            .background(palette.signal, in: Circle())
            .overlay(Circle().strokeBorder(palette.raised, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help("Add an AI agent after this one")
        .offset(y: 10)
        .accessibilityLabel("Add an agent after \(routine.name)")
      }
    }
    .anchorPreference(key: FlowAnchorKey.self, value: .bounds) { [routine.id: $0] }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(routine.name), \(state.label)")
  }

  @ViewBuilder func nodeLogo(_ target: RoutineTarget) -> some View {
    if case .spawnProvider(let raw) = target {
      AgentProviderLogo(
        provider: AgentProvider(rawValue: raw), size: 13, color: palette.paper.opacity(0.9))
    } else {
      agentBadge(target, size: 22).clipShape(Circle())
    }
  }

  /// The second line on a card: the model it runs on, or who runs it.
  func subtitle(_ routine: Routine) -> String {
    switch routine.target {
    case .spawnProfile: return "\(agentName(routine.target)) · your bot"
    case .existingAgent: return agentName(routine.target)
    case .spawnProvider(let raw):
      guard let provider = AgentProvider(rawValue: raw) else { return raw }
      return AutomationModels.displayName(
        routine.model, provider: provider, accountID: routine.accountID,
        catalog: .shared) ?? raw
    }
  }

  func stateColor(_ state: StepState) -> Color {
    switch state {
    case .running: palette.signal
    case .needsYou: palette.amber
    case .done: Color(red: 0.18, green: 0.54, blue: 0.34)
    case .failed: palette.red
    case .nothingNew, .paused, .idle: palette.muted
    }
  }

  private func runMeta(_ run: RoutineRunRecord?, now: Date) -> String? {
    guard let run else { return nil }
    if run.outcome == .running { return Self.duration(now.timeIntervalSince(run.firedAt)) }
    return [
      run.retryOfRunID == nil ? nil : "retry", run.durationMs.map { Self.duration($0 / 1000) },
      Self.ago(run.firedAt),
    ]
    .compactMap { $0 }.joined(separator: " · ")
  }

  // MARK: Inspector

  private func inspector(_ routine: Routine, tree: [Routine], snapshot: FlowSnapshot)
    -> some View
  {
    let state = snapshot.state(of: routine)
    let runs = snapshot.runs[routine.id] ?? []
    let latest = snapshot.latestRun(routine.id)
    let session: UUID? =
      services.automationRunSession(routineID: routine.id)
      ?? latest?.agentNodeID.flatMap { snapshot.nodes[$0] == nil ? nil : $0 }
    let index = (tree.firstIndex { $0.id == routine.id } ?? 0) + 1
    return VStack(alignment: .leading, spacing: 20) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 5) {
            Text(tree.count > 1 ? "STEP \(index) OF \(tree.count)" : "AUTOMATION")
              .font(.ottoMicro).tracking(2).foregroundStyle(palette.muted)
            Text(routine.name).font(.ottoDisplay(20).weight(.semibold)).lineLimit(2)
            Text("\(agentName(routine.target)) · \(triggerLabel(routine))")
              .font(.ottoDisplay(12)).foregroundStyle(palette.muted).lineLimit(2)
          }
          if state == .needsYou, snapshot.isAwaitingApproval(routine) {
            callout(
              title: "Waiting for your approval",
              detail:
                "Its answer is on Home to approve, comment on or reject. The steps after it start once you approve.",
              color: palette.amber, action: nil)
          } else if state == .needsYou {
            callout(
              title: "Waiting for you",
              detail: "\(routine.name) has a question or wants approval before it carries on.",
              color: palette.amber,
              action: session.map { node in ("View run", { watchingRun = node }) })
          } else if state == .failed {
            callout(
              title: "Last run failed",
              detail: latest?.error ?? routine.lastError ?? "The agent stopped with an error.",
              color: palette.red, action: ("Retry", { run(routine) }))
          }
          latestOutput(
            routine, state: state, latest: latest, session: session,
            awaitingApproval: snapshot.isAwaitingApproval(routine))
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("INSTRUCTION").font(.ottoMicro).tracking(2).foregroundStyle(palette.muted)
              Spacer()
              Button("Edit") { editing = .edit(routine) }
                .buttonStyle(.plain).font(.ottoDisplay(11.5).weight(.medium))
                .foregroundStyle(palette.signal)
            }
            Text(routine.instruction)
              .font(.ottoDisplay(12.5)).lineLimit(7)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
              .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
          }
          VStack(alignment: .leading, spacing: 0) {
            Text("HOW IT RUNS").font(.ottoMicro).tracking(2).foregroundStyle(palette.muted)
              .padding(.bottom, 4)
            settingRow("Harness") { harnessMenu(routine) }
            if case .spawnProvider(let raw) = routine.target,
              let provider = AgentProvider(rawValue: raw)
            {
              settingRow("Model") {
                AutomationModelPicker(
                  provider: provider, accountID: routine.accountID,
                  model: Binding(
                    get: { routine.model },
                    set: { model in update(routine) { $0.model = model } }))
              }
            }
            settingRow("Starts") { startsControl(routine) }
            settingRow("If still running") {
              Menu(routine.concurrency == .skip ? "Skip that run" : "Run once it’s free") {
                Button("Skip that run") { update(routine) { $0.concurrency = .skip } }
                Button("Run once it’s free") { update(routine) { $0.concurrency = .queueLatest } }
              }
            }
            settingRow("Approval") {
              Menu(routine.needsReview ? "Ask me on Home first" : "Carry straight on") {
                Button("Carry straight on") { update(routine) { $0.reviewOnHome = nil } }
                Button("Ask me on Home first") { update(routine) { $0.reviewOnHome = true } }
              }
              .help("Each answer waits on Home for your approval before the next step")
            }
            settingRow("Permissions") {
              Menu(canWrite(routine) ? "Can make changes" : "Read only") {
                Button("Read only") {
                  update(routine) { $0.permissionMode = AgentPermissionMode.readOnly.rawValue }
                }
                Button("Can make changes") {
                  update(routine) {
                    $0.permissionMode = AgentPermissionMode.workspaceWrite.rawValue
                  }
                }
              }
            }
            settingRow("Account") {
              Button(accountName(routine) ?? "Default") { editing = .edit(routine) }
                .buttonStyle(.plain)
            }
            settingRow("Results go to") {
              Button(deliveryLabel(routine.delivery) ?? "Passed to the next step") {
                editing = .edit(routine)
              }
              .buttonStyle(.plain)
            }
          }
          if !runs.isEmpty { runStrip(Array(runs.prefix(14))) }
        }
        .padding(.top, 22)
      }
      .scrollIndicators(.never)
      HStack(spacing: 8) {
        if let session, runConversation != nil {
          Button("View run") { watchingRun = session }
            .buttonStyle(.bordered)
            .help("See what the agent did, without leaving Automations")
        }
        Button {
          run(routine)
        } label: {
          HStack(spacing: 5) {
            if running.contains(routine.id) { ProgressView().controlSize(.mini) }
            Text(routine.runAfter == nil ? "Run now" : "Run this step")
          }
        }
        .buttonStyle(.bordered)
        .help(
          routine.runAfter == nil
            ? "Runs it now; the steps after it follow on their own"
            : "Runs only this step, without the answer from the step before")
        Spacer()
        Button {
          setEnabled(routine, !routine.enabled)
        } label: {
          Image(systemName: routine.enabled ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.bordered)
        .help(routine.enabled ? "Pause this step" : "Turn this step on")
        Menu {
          Button("Add a step after this") { editing = .newStep(after: routine) }
          if let root = routines.flowRoot(of: routine.id) {
            Button("Edit flow in canvas") {
              builder = AutomationFlowDraft(flowFrom: root, in: routines.routines)
            }
          }
          Button("Advanced settings…") { advancedRoutineID = routine.id }
          Divider()
          Button("Delete", role: .destructive) { stageDelete(routine) }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden).fixedSize()
      }
      .controlSize(.regular)
      .padding(.vertical, 14)
      .overlay(alignment: .top) { Rectangle().fill(palette.paper.opacity(0.08)).frame(height: 1) }
    }
    .padding(.horizontal, 22)
  }

  /// What the step produced last time, or that it is working right now.
  @ViewBuilder private func latestOutput(
    _ routine: Routine, state: StepState, latest: RoutineRunRecord?, session: UUID?,
    awaitingApproval: Bool = false
  ) -> some View {
    // A finished answer waiting on Home shows the answer, not a "working" timer.
    let working = state.isLive && !awaitingApproval
    if state == .running || state == .needsYou || latest?.result != nil {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(working ? "RUNNING NOW" : awaitingApproval ? "AWAITING APPROVAL" : "LATEST OUTPUT")
            .font(.ottoMicro).tracking(2).foregroundStyle(palette.muted)
          Spacer()
          if let latest, !working {
            Text(Self.ago(latest.firedAt)).font(.ottoMono(10.5)).foregroundStyle(palette.muted)
          }
        }
        if working, let latest {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            TimelineView(.periodic(from: .now, by: 1)) { context in
              Text("Working · \(Self.duration(context.date.timeIntervalSince(latest.firedAt)))")
                .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
            }
            Spacer()
            if let session, runConversation != nil {
              Button("Watch live") { watchingRun = session }
                .buttonStyle(.bordered).controlSize(.small)
            }
          }
          .padding(10)
          .background(stateColor(state).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else if let result = latest?.result {
          ScrollView {
            Text(result)
              .font(.ottoDisplay(12.5))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 180)
          .padding(10)
          .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
  }

  /// A run's conversation beside the flow, like opening an execution in a workflow tool.
  private func runPanel(
    _ routine: Routine, nodeID: UUID, conversation: (UUID) -> AnyView
  ) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button {
          watchingRun = nil
        } label: {
          Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .help("Back to the step")
        VStack(alignment: .leading, spacing: 1) {
          Text("RUN").font(.ottoMicro).tracking(2).foregroundStyle(palette.muted)
          Text(routine.name).font(.ottoDisplay(14).weight(.semibold)).lineLimit(1)
        }
        Spacer()
        Button {
          watchingRun = nil
        } label: {
          Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain).foregroundStyle(palette.muted)
        .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
      Rectangle().fill(palette.paper.opacity(0.08)).frame(height: 1)
      conversation(nodeID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func harnessMenu(_ routine: Routine) -> some View {
    let current: String =
      switch routine.target {
      case .spawnProvider(let raw): raw
      case .spawnProfile: "\(agentName(routine.target)) (bot)"
      case .existingAgent: agentName(routine.target)
      }
    return Menu(current) {
      ForEach(AutomationHarnesses.all, id: \.self) { provider in
        Button(provider.rawValue) {
          update(routine) {
            $0.target = .spawnProvider(provider: provider.rawValue)
            $0.model = nil
          }
        }
      }
      let bots = services.botRoster()
      if !bots.isEmpty {
        Divider()
        ForEach(bots) { entry in
          Button("\(entry.profile.name) (bot)") {
            update(routine) {
              $0.target = .spawnProfile(profileID: entry.profile.id)
              $0.model = nil
            }
          }
        }
      }
    }
  }

  @ViewBuilder private func startsControl(_ routine: Routine) -> some View {
    if let link = routine.runAfter {
      let parent = routines.routine(id: link.routineID)?.name ?? "the previous step"
      Menu(Self.chainLabel(parent: parent, when: link.when)) {
        ForEach(RoutineChainCondition.allCases, id: \.self) { condition in
          Button(Self.chainLabel(parent: parent, when: condition)) {
            update(routine) { $0.runAfter?.when = condition }
          }
        }
      }
    } else {
      Button(Self.scheduleLabel(routine)) { editing = .edit(routine) }.buttonStyle(.plain)
    }
  }

  private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    HStack(spacing: 10) {
      Text(title).font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        .frame(width: 104, alignment: .leading)
      content()
        .font(.ottoDisplay(12.5).weight(.medium))
        .menuStyle(.borderlessButton)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 9)
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.paper.opacity(0.07)).frame(height: 1)
    }
  }

  private func callout(
    title: String, detail: String, color: Color, action: (String, () -> Void)?
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.ottoDisplay(13).weight(.semibold))
        Text(detail).font(.ottoDisplay(12)).lineLimit(4)
      }
      .foregroundStyle(color)
      if let action {
        Button(action.0, action: action.1).buttonStyle(.borderedProminent).controlSize(.small)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.25)))
  }

  /// Newest run on the right; bar height is how long it took.
  private func runStrip(_ runs: [RoutineRunRecord]) -> some View {
    let ordered = Array(runs.reversed())
    let longest = max(1, ordered.compactMap(\.durationMs).max() ?? 1)
    let timed = ordered.compactMap(\.durationMs)
    let average = timed.isEmpty ? nil : timed.reduce(0, +) / Double(timed.count)
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("LAST \(ordered.count) RUN\(ordered.count == 1 ? "" : "S")")
          .font(.ottoMicro).tracking(2).foregroundStyle(palette.muted)
        Spacer()
        if let average {
          Text("avg \(Self.duration(average / 1000))").font(.ottoMono(10.5))
            .foregroundStyle(palette.muted)
        }
      }
      HStack(alignment: .bottom, spacing: 4) {
        ForEach(ordered) { run in
          RoundedRectangle(cornerRadius: 3)
            .fill(runColor(run.outcome).opacity(run.outcome == .running ? 1 : 0.55))
            .frame(maxWidth: 18)
            .frame(height: max(6, 28 * CGFloat((run.durationMs ?? longest * 0.4) / longest)))
            .help(
              "\(Self.outcomeLabel(run.outcome).capitalized) · \(run.firedAt.formatted(date: .abbreviated, time: .shortened))"
            )
        }
      }
      .frame(height: 28, alignment: .bottom)
    }
  }

  private func runColor(_ outcome: RoutineRunOutcome) -> Color {
    switch outcome {
    case .running: palette.signal
    case .completed: Color(red: 0.24, green: 0.6, blue: 0.4)
    case .failed: palette.red
    case .skipped, .noChange: palette.muted
    }
  }

  // MARK: Helpers

  private func update(_ routine: Routine, _ change: (inout Routine) -> Void) {
    var copy = routine
    change(&copy)
    Task {
      do { _ = try await services.saveRoutine(copy) } catch {
        status = OttoStatusToast(
          kind: .error, title: "Couldn’t update", detail: error.localizedDescription)
      }
    }
  }

  private func canWrite(_ routine: Routine) -> Bool {
    routine.permissionMode == AgentPermissionMode.workspaceWrite.rawValue
  }

  private func doerDetail(_ routine: Routine) -> String {
    switch routine.target {
    case .spawnProfile: "\(agentName(routine.target)) · your bot"
    case .spawnProvider(let raw): accountName(routine).map { "\(raw) · \($0)" } ?? raw
    case .existingAgent: agentName(routine.target)
    }
  }

  func deliveryLabel(_ delivery: RoutineDelivery) -> String? {
    switch delivery {
    case .brief: "Home brief"
    case .homeCard(let id): services.homeCards.card(id: id)?.title ?? "Home card"
    case .botChannel, .origin: "Bot chat"
    case .document(let path): (path as NSString).lastPathComponent
    case .canvas: nil
    }
  }

  static func duration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return "\(max(0, total))s" }
    if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
    return "\(total / 3600)h \(total % 3600 / 60)m"
  }

  static func ago(_ date: Date) -> String {
    date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
  }
}

/// Where each step card (and the trigger) sits, so the wire layer can join them up.
struct FlowAnchorKey: PreferenceKey {
  static let defaultValue: [UUID: Anchor<CGRect>] = [:]
  static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
    value.merge(nextValue()) { $1 }
  }
}

extension View {
  /// Flow cards and bars: the same quiet raised plate the Automations list uses.
  fileprivate func automationFlowSurface(_ palette: OttoPalette, cornerRadius: CGFloat)
    -> some View
  {
    background(
      palette.raised.opacity(0.9),
      in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    )
    .ottoElevated(cornerRadius: cornerRadius)
  }
}
