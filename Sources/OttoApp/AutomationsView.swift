import AppKit
import OttoCore
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

/// Automations: tasks Otto runs for you on a schedule. One screen lists them all with what
/// they do, who does them and when; "New automation" walks through the same four questions.
/// Routine is still the model underneath; the advanced editor stays one click away.
struct AutomationsView: View {
  // Not observed: the canvas and services publish on every streamed token, which would rebuild
  // this whole screen constantly. `live` and `routines` carry the changes it shows.
  let store: CanvasStore
  let services: ApplicationServices
  @ObservedObject var routines: RoutineStore
  @StateObject var live: AutomationLiveNodes
  @Environment(\.ottoPalette) var palette

  init(
    store: CanvasStore, services: ApplicationServices, routines: RoutineStore,
    onOpenSession: ((OttoNode) -> Void)? = nil, runConversation: ((UUID) -> AnyView)? = nil,
    initialFlowID: UUID? = nil
  ) {
    self.store = store
    self.services = services
    self.routines = routines
    self.onOpenSession = onOpenSession
    self.runConversation = runConversation
    self.initialFlowID = initialFlowID
    _live = StateObject(wrappedValue: AutomationLiveNodes(store: store))
  }

  /// Opens the session an automation's agent ran in.
  var onOpenSession: ((OttoNode) -> Void)?
  /// Draws an agent's conversation, so a run can be watched without leaving Automations.
  var runConversation: ((UUID) -> AnyView)?

  @State var editing: EditorTarget?
  @State var advancedRoutineID: UUID?
  @State var status: OttoStatusToast?
  @State private var undo: OttoUndoToast?
  /// Hidden from the list while its undo countdown runs; deleted for real when it ends.
  @State var pendingDelete: Routine?
  @State var running: Set<UUID> = []
  /// Opens straight into a flow, e.g. after it was just built.
  var initialFlowID: UUID?
  /// The advanced flow open on its board, by the automation that starts it. Nil shows the list.
  @State var openFlowID: UUID?
  /// The flow shown on the board, by the id of the automation that starts it.
  @State var selectedFlowID: UUID?
  /// The step the Flow inspector is showing.
  @State var selectedStepID: UUID?
  /// The run being watched in Flow view's side panel, by its agent node.
  @State var watchingRun: UUID?
  /// The advanced canvas builder, while it is open.
  @State var builder: AutomationFlowDraft?
  @State private var choosingMode = false

  enum EditorTarget: Identifiable {
    case new(template: AutomationTemplate?)
    case edit(Routine)
    /// A new step that runs after `parent` finishes.
    case newStep(after: Routine)
    var id: String {
      switch self {
      case .new(let template): "new-\(template?.title ?? "")"
      case .edit(let routine): routine.id.uuidString
      case .newStep(let parent): "after-\(parent.id.uuidString)"
      }
    }
  }

  /// What the list shows: each simple automation, and each advanced flow once (by its start).
  var listed: [Routine] {
    let ids = Set(sorted.map(\.id))
    return sorted.filter { routine in
      guard let parent = routine.runAfter?.routineID else { return true }
      return !ids.contains(parent)
    }
  }

  /// Built in the canvas, or has agents chained after it.
  func isAdvanced(_ routine: Routine) -> Bool {
    routine.advanced == true || !routines.followers(of: routine.id).isEmpty
  }

  func openFlow(_ root: Routine) {
    openFlowID = root.id
    selectedFlowID = root.id
    selectedStepID = root.id
    watchingRun = nil
  }

  var sorted: [Routine] {
    routines.routines.filter { $0.id != pendingDelete?.id }.sorted { lhs, rhs in
      if lhs.enabled != rhs.enabled { return lhs.enabled }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  var body: some View {
    Group {
      if let builder {
        AutomationFlowBuilder(services: services, initial: builder) { rootID in
          self.builder = nil
          if let rootID, let root = routines.routine(id: rootID) {
            openFlow(root)
            status = OttoStatusToast(
              kind: .success, title: "Flow saved",
              detail: "“\(routines.routine(id: rootID)?.name ?? "Flow")” is ready.")
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 0) {
          if let openFlowID, let root = routines.routine(id: openFlowID) {
            flowHeader(root)
            flowLayout
          } else {
            header
            listLayout
          }
        }
      }
    }
    .foregroundStyle(palette.paper)
    .onAppear {
      if openFlowID == nil, let initialFlowID, let root = routines.routine(id: initialFlowID) {
        openFlow(root)
      }
    }
    .sheet(isPresented: $choosingMode) {
      AutomationModeChooser { mode in
        choosingMode = false
        switch mode {
        case .simple: editing = .new(template: nil)
        case .advanced: builder = AutomationFlowDraft()
        case nil: break
        }
      }
      .environment(\.ottoPalette, palette)
    }
    .sheet(item: $editing) { target in
      AutomationEditor(services: services, target: target) { saved in
        editing = nil
        if let saved {
          if saved.runAfter != nil { selectedStepID = saved.id }
          status = OttoStatusToast(
            kind: .success, title: "Saved", detail: "“\(saved.name)” \(triggerLabel(saved)).")
        }
      }
      .environment(\.ottoPalette, palette)
    }
    .sheet(
      isPresented: Binding(
        get: { advancedRoutineID != nil }, set: { if !$0 { advancedRoutineID = nil } })
    ) {
      RoutineManagerView(
        store: store, services: services, style: .embedded,
        initialRoutineID: advancedRoutineID, prefillProfileID: nil
      )
      .frame(minWidth: 860, minHeight: 620)
      .overlay(alignment: .topTrailing) {
        Button("Done") { advancedRoutineID = nil }.padding(14)
      }
    }
    .ottoStatusToast($status)
    .ottoUndoToast($undo, onUndo: { pendingDelete = nil }, onExpire: commitPendingDelete)
  }

  private var listLayout: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if sorted.isEmpty {
          emptyState
        } else {
          let snapshot = flowSnapshot
          ForEach(listed) { routine in
            if isAdvanced(routine) {
              flowCard(routine, snapshot: snapshot)
            } else {
              card(routine)
            }
          }
        }
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 20)
      .frame(maxWidth: 880, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.never)
  }

  // MARK: Header and empty state

  private var header: some View {
    HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 6) {
        Text("AUTOMATIONS · \(routines.routines.filter(\.enabled).count) ON")
          .font(.ottoMono(10, weight: .medium)).tracking(2)
          .foregroundStyle(palette.muted)
        Text("Work that runs itself")
          .font(.ottoDisplay(28).weight(.semibold))
        Text("Give agents a task and a time, or chain them into a flow. They report back.")
          .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
      }
      Spacer()
      Button {
        choosingMode = true
      } label: {
        Label("New automation", systemImage: "plus")
          .font(.ottoDisplay(13).weight(.semibold))
          .padding(.horizontal, 14).padding(.vertical, 8)
          .foregroundStyle(palette.onSignal)
          .background(palette.signal, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      }
      .buttonStyle(.plain)
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .accessibilityIdentifier("automations.new")
    }
    .padding(.horizontal, 28)
    .padding(.top, 26)
    .padding(.bottom, 8)
    .frame(maxWidth: 880, alignment: .leading)
    .frame(maxWidth: .infinity)
  }

  /// Above an open flow: back to the list, and what this flow is.
  private func flowHeader(_ root: Routine) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Button {
        openFlowID = nil
        watchingRun = nil
      } label: {
        Label("Automations", systemImage: "chevron.left")
          .font(.ottoDisplay(12.5).weight(.medium))
      }
      .buttonStyle(.plain).foregroundStyle(palette.muted)
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("automations.flow.back")
      Rectangle().fill(palette.paper.opacity(0.14)).frame(width: 1, height: 16)
      Text(root.name).font(.ottoDisplay(20).weight(.semibold)).lineLimit(1)
      AdvancedTag()
      Spacer()
    }
    .padding(.horizontal, 28)
    .padding(.top, 22)
    .padding(.bottom, 4)
  }

  /// An advanced flow in the list: its agents in order, live status, and a way in.
  private func flowCard(_ root: Routine, snapshot: FlowSnapshot) -> some View {
    let tree = snapshot.tree(from: root)
    let states = tree.map(snapshot.state(of:))
    let live = states.filter(\.isLive).count
    let failed = states.filter { $0 == .failed }.count
    return Button {
      openFlow(root)
    } label: {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(palette.signal)
          .frame(width: 36, height: 36)
          .background(palette.signal.opacity(0.12), in: Circle())
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 8) {
            Text(root.name).font(.ottoDisplay(15).weight(.semibold)).lineLimit(1)
            AdvancedTag()
            if !root.enabled {
              Text("PAUSED").font(.ottoMono(9, weight: .medium)).tracking(1.5)
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(palette.paper.opacity(0.08), in: Capsule())
            }
          }
          HStack(spacing: 5) {
            ForEach(Array(tree.prefix(6).enumerated()), id: \.element.id) { index, step in
              if index > 0 {
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold))
                  .foregroundStyle(palette.muted.opacity(0.7))
              }
              HStack(spacing: 4) {
                nodeLogo(step.target).frame(width: 12, height: 12)
                Text(step.name).font(.ottoDisplay(11.5)).lineLimit(1)
              }
              .padding(.horizontal, 7).padding(.vertical, 3)
              .background(palette.paper.opacity(0.06), in: Capsule())
            }
            if tree.count > 6 {
              Text("+\(tree.count - 6)").font(.ottoDisplay(11)).foregroundStyle(palette.muted)
            }
          }
          HStack(spacing: 10) {
            Label(triggerLabel(root), systemImage: "clock")
            Text("\(tree.count) agent\(tree.count == 1 ? "" : "s")")
            if live > 0 { AutomationStatusPill(state: .running) }
            if failed > 0 {
              Text("\(failed) failed").foregroundStyle(palette.red)
            }
          }
          .font(.ottoMono(9.5, weight: .medium))
          .foregroundStyle(palette.muted)
        }
        Spacer(minLength: 12)
        HStack(spacing: 6) {
          Button {
            run(root)
          } label: {
            Image(systemName: "play.fill").frame(width: 26, height: 26)
          }
          .help("Run the flow")
          Button {
            builder = AutomationFlowDraft(flowFrom: root, in: routines.routines)
          } label: {
            Image(systemName: "pencil").frame(width: 26, height: 26)
          }
          .help("Edit in canvas")
          Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.muted).frame(width: 18)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(palette.paper.opacity(0.8))
      }
      .padding(16)
      .automationCard(palette)
      .opacity(root.enabled ? 1 : 0.72)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("automations.flowCard")
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Nothing automated yet.")
          .font(.ottoDisplay(20).weight(.semibold))
        Text("Start from one of these, or write your own.")
          .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
        Button {
          builder = AutomationFlowDraft()
        } label: {
          Label(
            "Or build a flow of agents on a canvas",
            systemImage: "point.3.connected.trianglepath.dotted"
          )
          .font(.ottoDisplay(12.5).weight(.medium))
        }
        .buttonStyle(.plain).foregroundStyle(palette.signal)
        .padding(.top, 2)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
        ForEach(AutomationTemplate.all) { template in
          Button {
            editing = .new(template: template)
          } label: {
            VStack(alignment: .leading, spacing: 8) {
              Image(systemName: template.symbol)
                .font(.system(size: 16))
                .foregroundStyle(palette.signal)
                .frame(width: 32, height: 32)
                .background(palette.signal.opacity(0.14), in: Circle())
              Text(template.title).font(.ottoDisplay(14).weight(.semibold))
              Text(template.task)
                .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
                .lineLimit(3).multilineTextAlignment(.leading)
              Text(
                template.frequency.label(at: template.time, weekday: template.weekday).uppercased()
              )
              .font(.ottoMono(9, weight: .medium)).tracking(1.5)
              .foregroundStyle(palette.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .automationCard(palette)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.top, 12)
  }

  // MARK: Card

  private func card(_ routine: Routine) -> some View {
    let lastRun = routines.recentRuns(routineID: routine.id, limit: 1).first
    let next = routine.enabled ? RoutineEngine.nextScheduledFire(for: routine, after: .now) : nil
    return HStack(alignment: .top, spacing: 14) {
      agentBadge(routine.target)
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(routine.name).font(.ottoDisplay(15).weight(.semibold)).lineLimit(1)
          if !routine.enabled {
            Text("PAUSED").font(.ottoMono(9, weight: .medium)).tracking(1.5)
              .foregroundStyle(palette.muted)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(palette.paper.opacity(0.08), in: Capsule())
          }
        }
        Text(Self.firstLine(of: routine.instruction))
          .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
          .lineLimit(2)
        HStack(spacing: 10) {
          Label(
            triggerLabel(routine),
            systemImage: routine.runAfter == nil ? "clock" : "arrow.turn.down.right")
          Label(agentName(routine.target), systemImage: "person.crop.circle")
          if let account = accountName(routine) {
            Label(account, systemImage: "key")
          }
        }
        .font(.ottoMono(9.5, weight: .medium))
        .foregroundStyle(palette.muted)
        .padding(.top, 2)
        HStack(spacing: 10) {
          if let lastRun {
            Text(
              "Last run \(lastRun.firedAt.formatted(.relative(presentation: .named))) · \(Self.outcomeLabel(lastRun.outcome))"
            )
          } else {
            Text("Hasn’t run yet")
          }
          if let next {
            Text("Next \(next.formatted(.relative(presentation: .named)))")
          }
        }
        .font(.ottoDisplay(11)).foregroundStyle(palette.muted.opacity(0.9))
        if let error = routine.lastError {
          Text(error).font(.ottoDisplay(11)).foregroundStyle(palette.red).lineLimit(2)
        }
      }
      Spacer(minLength: 12)
      VStack(alignment: .trailing, spacing: 10) {
        Toggle(
          "",
          isOn: Binding(
            get: { routine.enabled },
            set: { on in setEnabled(routine, on) })
        )
        .toggleStyle(.switch).labelsHidden().controlSize(.small)
        .help(routine.enabled ? "Pause" : "Turn on")
        HStack(spacing: 6) {
          Button {
            run(routine)
          } label: {
            Group {
              if running.contains(routine.id) {
                ProgressView().controlSize(.mini)
              } else {
                Image(systemName: "play.fill")
              }
            }
            .frame(width: 26, height: 26)
          }
          .help("Run now")
          Button {
            editing = .edit(routine)
          } label: {
            Image(systemName: "pencil").frame(width: 26, height: 26)
          }
          .help("Edit")
          Button {
            stageDelete(routine)
          } label: {
            Image(systemName: "trash").frame(width: 26, height: 26)
          }
          .help("Delete")
          .accessibilityLabel("Delete \(routine.name)")
          Menu {
            Button("Advanced settings…") { advancedRoutineID = routine.id }
          } label: {
            Image(systemName: "ellipsis").frame(width: 26, height: 26)
          }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(palette.paper.opacity(0.8))
      }
    }
    .padding(16)
    .automationCard(palette)
    .opacity(routine.enabled ? 1 : 0.72)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { editing = .edit(routine) }
  }

  @ViewBuilder func agentBadge(_ target: RoutineTarget, size: CGFloat = 36) -> some View {
    switch target {
    case .spawnProfile(let id):
      if let entry = services.botRoster().first(where: { $0.profile.id == id }) {
        BotAvatarView(
          presentation: BotAvatarPresentation(
            id: entry.profile.id, name: entry.profile.name, appearance: entry.appearance,
            photoURL: services.botPhotoURL(entry.appearance?.photoRelativePath),
            state: entry.avatarState),
          size: size, showsStateBadge: false)
      } else {
        providerBadge(nil, size: size)
      }
    case .spawnProvider(let raw):
      providerBadge(AgentProvider.allCases.first { $0.rawValue == raw }, size: size)
    case .existingAgent:
      providerBadge(nil, size: size)
    }
  }

  private func providerBadge(_ provider: AgentProvider?, size: CGFloat) -> some View {
    AgentProviderLogo(provider: provider, size: size * 0.44, color: palette.paper.opacity(0.85))
      .frame(width: size, height: size)
      .background(palette.paper.opacity(0.08), in: Circle())
  }

  // MARK: Actions

  func setEnabled(_ routine: Routine, _ on: Bool) {
    var copy = routine
    copy.enabled = on
    Task {
      do { _ = try await services.saveRoutine(copy) } catch {
        status = OttoStatusToast(
          kind: .error, title: "Couldn’t update", detail: error.localizedDescription)
      }
    }
  }

  /// Binning is instant and undoable: the card hides, and only when the countdown ends is
  /// the automation (and its run history) actually deleted.
  func stageDelete(_ routine: Routine) {
    commitPendingDelete()
    pendingDelete = routine
    undo = OttoUndoToast(title: "Automation deleted", detail: "“\(routine.name)”")
  }

  private func commitPendingDelete() {
    guard let routine = pendingDelete else { return }
    pendingDelete = nil
    do { try services.deleteRoutine(id: routine.id) } catch {
      status = OttoStatusToast(
        kind: .error, title: "Couldn’t delete", detail: error.localizedDescription)
    }
  }

  func run(_ routine: Routine) {
    running.insert(routine.id)
    Task {
      do {
        let output = try await services.testRoutine(id: routine.id)
        status =
          output.fired
          ? OttoStatusToast(
            kind: .success, title: "Running", detail: "“\(routine.name)” started.")
          : output.reason == "overlap"
            ? OttoStatusToast(
              kind: .info, title: "Already running",
              detail: "“\(routine.name)” will report back when it finishes.")
            : OttoStatusToast(
              kind: .error, title: "Didn’t run", detail: output.reason ?? "Unknown reason.")
      } catch {
        status = OttoStatusToast(
          kind: .error, title: "Couldn’t run", detail: error.localizedDescription)
      }
      running.remove(routine.id)
    }
  }

  // MARK: Labels

  func agentName(_ target: RoutineTarget) -> String {
    switch target {
    case .spawnProfile(let id): services.agentProfiles.profile(id: id)?.name ?? "A bot"
    case .spawnProvider(let raw): raw
    case .existingAgent(let id):
      store.snapshot.canvases.flatMap(\.nodes).first { $0.id == id }?.displayName ?? "An agent"
    }
  }

  func accountName(_ routine: Routine) -> String? {
    guard let id = routine.accountID else { return nil }
    return services.providerAccounts.accounts.first { $0.id == id }?.name
  }

  nonisolated static func firstLine(of text: String) -> String {
    text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
  }

  static func outcomeLabel(_ outcome: RoutineRunOutcome) -> String {
    switch outcome {
    case .running: "running"
    case .completed: "done"
    case .failed: "failed"
    case .skipped: "skipped"
    case .noChange: "nothing new"
    }
  }

  /// When an automation runs, naming the step it follows when it is part of a flow.
  func triggerLabel(_ routine: Routine) -> String {
    guard let link = routine.runAfter else { return Self.scheduleLabel(routine) }
    let parent = routines.routine(id: link.routineID)?.name ?? "the previous step"
    return Self.chainLabel(parent: parent, when: link.when)
  }

  static func chainLabel(parent: String, when condition: RoutineChainCondition) -> String {
    switch condition {
    case .succeeded: "After “\(parent)” succeeds"
    case .failed: "If “\(parent)” fails"
    case .finished: "After “\(parent)” finishes"
    }
  }

  static func scheduleLabel(_ routine: Routine) -> String {
    if routine.runAfter != nil { return "After another automation" }
    switch routine.trigger {
    case .schedule(let cron?, _):
      if let parsed = AutomationSchedule(cron: cron) { return parsed.label }
      return "Custom schedule"
    case .schedule(nil, let seconds?):
      return seconds % 3600 == 0 ? "Every \(seconds / 3600)h" : "Every \(max(1, seconds / 60)) min"
    case .schedule: return "On a schedule"
    case .webhook: return "When a webhook arrives"
    case .agentEvent: return "When an agent event happens"
    case .slackMessage: return "On a Slack message"
    case .discordMessage: return "On a Discord message"
    case .gitEvent: return "On a git change"
    }
  }
}

// MARK: - Schedule

enum AutomationFrequency: String, CaseIterable, Identifiable {
  case daily, weekdays, weekly, hourly
  var id: String { rawValue }
  var title: String {
    switch self {
    case .daily: "Every day"
    case .weekdays: "Weekdays"
    case .weekly: "Once a week"
    case .hourly: "Every hour"
    }
  }
  func label(at time: DateComponents, weekday: Int = 2) -> String {
    let clock = String(format: "%02d:%02d", time.hour ?? 9, time.minute ?? 0)
    switch self {
    case .daily: return "Every day at \(clock)"
    case .weekdays: return "Weekdays at \(clock)"
    case .weekly:
      return "\(Calendar.current.weekdaySymbols[(weekday - 1 + 7) % 7])s at \(clock)"
    case .hourly: return "Every hour"
    }
  }
}

/// The friendly schedules the editor offers, round-tripped through a cron expression.
struct AutomationSchedule: Equatable {
  var frequency: AutomationFrequency
  var hour: Int
  var minute: Int
  /// Calendar weekday, 1 = Sunday.
  var weekday: Int

  init(frequency: AutomationFrequency, hour: Int, minute: Int, weekday: Int = 2) {
    self.frequency = frequency
    self.hour = hour
    self.minute = minute
    self.weekday = weekday
  }

  init?(cron: String) {
    let parts = cron.split(separator: " ").map(String.init)
    guard parts.count == 5, parts[2] == "*", parts[3] == "*" else { return nil }
    if parts[1] == "*", let minute = Int(parts[0]) {
      self.init(frequency: .hourly, hour: 0, minute: minute)
      return
    }
    guard let minute = Int(parts[0]), let hour = Int(parts[1]) else { return nil }
    switch parts[4] {
    case "*": self.init(frequency: .daily, hour: hour, minute: minute)
    case "1-5": self.init(frequency: .weekdays, hour: hour, minute: minute)
    default:
      guard let day = Int(parts[4]), (0...6).contains(day) else { return nil }
      self.init(frequency: .weekly, hour: hour, minute: minute, weekday: day + 1)
    }
  }

  var cron: String {
    switch frequency {
    case .daily: "\(minute) \(hour) * * *"
    case .weekdays: "\(minute) \(hour) * * 1-5"
    case .weekly: "\(minute) \(hour) * * \(weekday - 1)"
    case .hourly: "\(minute) * * * *"
    }
  }

  var label: String {
    frequency.label(at: DateComponents(hour: hour, minute: minute), weekday: weekday)
  }
}

struct AutomationTemplate: Identifiable, Equatable {
  var id: String { title }
  let title: String
  let symbol: String
  let task: String
  let frequency: AutomationFrequency
  let time: DateComponents
  /// Calendar weekday for weekly templates, 1 = Sunday.
  var weekday = 2

  static let all: [AutomationTemplate] = [
    AutomationTemplate(
      title: "Morning inbox triage", symbol: "tray.full",
      task:
        "Go through my inbox from the last day. List anything that needs a reply or a decision, with a one-line summary each. Don’t reply to anything.",
      frequency: .weekdays, time: DateComponents(hour: 8, minute: 0)),
    AutomationTemplate(
      title: "Weekly progress report", symbol: "chart.bar.doc.horizontal",
      task:
        "Summarise what changed this week across my projects: what shipped, what’s blocked, and what needs me next week.",
      frequency: .weekly, time: DateComponents(hour: 16, minute: 0), weekday: 6),
    AutomationTemplate(
      title: "Meeting prep", symbol: "calendar",
      task:
        "Look at tomorrow’s calendar. For each meeting, note who’s attending, what we last discussed and what I should decide.",
      frequency: .weekdays, time: DateComponents(hour: 17, minute: 30)),
  ]
}

// MARK: - Editor

/// The four questions: what, who, which account, when. Results go to the Home brief by default.
struct AutomationEditor: View {
  let services: ApplicationServices
  let target: AutomationsView.EditorTarget
  let onFinish: (Routine?) -> Void
  @Environment(\.ottoPalette) var palette

  enum Doer: Hashable {
    case bot(UUID)
    case provider(AgentProvider)
  }
  enum Destination: String, CaseIterable, Identifiable {
    case brief, card, botChat, none
    var id: String { rawValue }
  }

  @State private var name = ""
  @State private var task = ""
  @State private var doer: Doer = .provider(.claudeCode)
  @State private var accountID: UUID?
  @State private var schedule = AutomationSchedule(frequency: .weekdays, hour: 9, minute: 0)
  @State private var destination: Destination = .brief
  /// The card a "Home card" automation refreshes; nil makes a new card named after it.
  @State private var cardID: UUID?
  @State private var allowChanges = false
  /// Each answer waits on Home for approval before anything after it runs.
  @State private var reviewOnHome = false
  @State private var afterApproval = ""
  @State private var model: String?
  @State private var enabled = true
  /// Set for a step that runs after another automation instead of on a schedule.
  @State private var runAfter: RoutineChainLink?
  @State private var existing: Routine?
  /// The doer the form opened with, so loading it doesn't clear the saved model.
  @State private var loadedDoer: Doer?
  @State private var saving = false
  @State private var error: String?

  private var bots: [BotRosterEntry] { services.botRoster() }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(
          existing == nil
            ? (runAfter == nil ? "New automation" : "New step") : "Edit automation"
        )
        .font(.ottoDisplay(20).weight(.semibold))
        Text(
          runAfter == nil
            ? "Otto runs it at the time you pick and brings the result back to you."
            : "Otto runs it when \(parentName) finishes and hands it that step’s answer."
        )
        .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
      }
      .padding(22)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          step("1", "What should it do?") {
            TextField("Name (optional)", text: $name)
              .textFieldStyle(.roundedBorder)
            TextEditor(text: $task)
              .font(.ottoDisplay(13))
              .frame(minHeight: 96)
              .padding(6)
              .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
              .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(palette.paper.opacity(0.12))
              )
              .overlay(alignment: .topLeading) {
                if task.isEmpty {
                  Text("e.g. Every morning, check my inbox and list what needs a reply.")
                    .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
                    .padding(.horizontal, 11).padding(.vertical, 14)
                    .allowsHitTesting(false)
                }
              }
          }
          if runAfter != nil {
            AutomationVariableChips(steps: chainAncestors) { token in
              task =
                task.isEmpty || task.hasSuffix(" ") || task.hasSuffix("\n")
                ? task + token : task + " " + token
            }
          }
          step("2", "Who does it?") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
              ForEach(bots) { entry in
                doerOption(.bot(entry.profile.id)) {
                  BotAvatarView(
                    presentation: BotAvatarPresentation(
                      id: entry.profile.id, name: entry.profile.name,
                      appearance: entry.appearance,
                      photoURL: services.botPhotoURL(entry.appearance?.photoRelativePath),
                      state: entry.avatarState),
                    size: 26, showsStateBadge: false)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(entry.profile.name).font(.ottoDisplay(13).weight(.medium))
                    Text("Your bot").font(.ottoDisplay(10.5)).foregroundStyle(palette.muted)
                  }
                }
              }
              ForEach(AutomationHarnesses.all, id: \.self) { provider in
                doerOption(.provider(provider)) {
                  AgentProviderLogo(provider: provider, size: 14, color: palette.paper)
                    .frame(width: 26, height: 26)
                    .background(palette.paper.opacity(0.08), in: Circle())
                  VStack(alignment: .leading, spacing: 1) {
                    Text(provider.rawValue).font(.ottoDisplay(13).weight(.medium))
                    Text("A fresh agent").font(.ottoDisplay(10.5)).foregroundStyle(palette.muted)
                  }
                }
              }
            }
          }
          if case .provider(let provider) = doer {
            step("3", "Which model?") {
              AutomationModelPicker(provider: provider, accountID: accountID, model: $model)
              Text("Leave it on the default, or pick one, for example Opus 5.5 or GPT-6 Sol.")
                .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
            }
          }
          step("4", "Which AI account?") {
            RoutineAccountPicker(
              accounts: services.providerAccounts, accountID: $accountID,
              provider: doerProvider, botAccountName: doerBotAccountName, showsLabel: false
            )
            .frame(maxWidth: 320, alignment: .leading)
            Text("The subscription or key the agent uses, for example Work or Personal.")
              .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
          }
          if runAfter != nil {
            step("5", "When does it start?") {
              Picker("Starts", selection: chainConditionBinding) {
                Text("When it succeeds").tag(RoutineChainCondition.succeeded)
                Text("If it fails").tag(RoutineChainCondition.failed)
                Text("Either way").tag(RoutineChainCondition.finished)
              }
              .pickerStyle(.segmented)
              .frame(maxWidth: 420, alignment: .leading)
              Text(
                AutomationsView.chainLabel(
                  parent: parentName, when: runAfter?.when ?? .succeeded
                ).uppercased()
              )
              .font(.ottoMono(10, weight: .medium)).tracking(1.2)
              .foregroundStyle(palette.muted)
            }
          } else {
            step("5", "When?") {
              HStack(spacing: 12) {
                Picker("Frequency", selection: $schedule.frequency) {
                  ForEach(AutomationFrequency.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                if schedule.frequency == .weekly {
                  Picker("Day", selection: $schedule.weekday) {
                    ForEach(1...7, id: \.self) { day in
                      Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                    }
                  }
                  .labelsHidden().frame(width: 130)
                }
                if schedule.frequency != .hourly {
                  DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                }
              }
              Text(schedule.label).font(.ottoMono(10, weight: .medium)).tracking(1.2)
                .foregroundStyle(palette.muted)
            }
          }
          step("6", "Where should results go?") {
            Picker("Results", selection: $destination) {
              Text("My Home brief").tag(Destination.brief)
              Text("A Home card").tag(Destination.card)
              if case .bot = doer { Text("The bot’s chat").tag(Destination.botChat) }
              Text("Nowhere, just do it").tag(Destination.none)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460, alignment: .leading)
            if destination == .card {
              Picker("Card", selection: $cardID) {
                Text("A new card").tag(UUID?.none)
                ForEach(services.homeCards.allCards) { card in
                  Text(card.title).tag(Optional(card.id))
                }
              }
              .frame(maxWidth: 320, alignment: .leading)
              Text("Each run replaces what the card shows with fresh results.")
                .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
            }
            Toggle(
              "Allow it to make changes (it still asks before anything risky)", isOn: $allowChanges
            )
            .font(.ottoDisplay(12))
          }
          step("7", "Check with you first?") {
            Toggle("Ask me on Home to approve, comment or reject each result", isOn: $reviewOnHome)
              .font(.ottoDisplay(12))
              .accessibilityIdentifier("automations.editor.review")
            if reviewOnHome {
              TextField(
                "When I approve, do this (optional), e.g. Post it in #tips on Discord",
                text: $afterApproval, axis: .vertical
              )
              .textFieldStyle(.roundedBorder)
              .lineLimit(1...3)
              Text(
                afterApproval.trimmingCharacters(in: .whitespaces).isEmpty
                  ? "With nothing here there’s nothing to approve, so it shows as an update instead."
                  : "The same agent does this with the approved text. Posting or sending needs “Allow it to make changes” on."
              )
              .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
            }
          }
          if let error {
            Text(error).font(.ottoDisplay(12)).foregroundStyle(palette.red)
          }
        }
        .padding(22)
      }
      Divider()
      HStack {
        Toggle("On", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
        Spacer()
        Button("Cancel", role: .cancel) { onFinish(nil) }.keyboardShortcut(.cancelAction)
        Button(saving ? "Saving…" : (existing == nil ? "Create automation" : "Save")) { save() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(saving || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(16)
    }
    .frame(width: 620, height: 740)
    .background(palette.surface)
    .foregroundStyle(palette.paper)
    .onAppear {
      load()
      loadedDoer = doer
    }
    .onChange(of: doer) { _, newValue in
      if loadedDoer != newValue { model = nil }
      if case .provider = newValue, destination == .botChat { destination = .brief }
    }
    // The review card already shows the result, so it needn't land in the brief as well.
    .onChange(of: reviewOnHome) { _, on in
      if on, destination == .brief { destination = .none }
    }
  }

  private var parentName: String {
    runAfter.flatMap { services.routines.routine(id: $0.routineID)?.name }
      .map { "“\($0)”" } ?? "the previous step"
  }

  /// The automations this step comes after, nearest first.
  private var chainAncestors: [String] {
    var names: [String] = []
    var cursor = runAfter?.routineID
    var seen: Set<UUID> = []
    while let id = cursor, seen.insert(id).inserted, let parent = services.routines.routine(id: id)
    {
      names.append(parent.name)
      cursor = parent.runAfter?.routineID
    }
    return names
  }

  private var chainConditionBinding: Binding<RoutineChainCondition> {
    Binding(
      get: { runAfter?.when ?? .succeeded },
      set: { runAfter?.when = $0 })
  }

  private var doerBot: AgentProfile? {
    if case .bot(let id) = doer { return services.agentProfiles.profile(id: id) }
    return nil
  }

  private var doerProvider: AgentProvider? {
    if let doerBot { return doerBot.provider }
    if case .provider(let provider) = doer { return provider }
    return nil
  }

  private var doerBotAccountName: String? {
    doerBot.map { services.providerAccounts.account(id: $0.accountID)?.name ?? "This Mac’s login" }
  }

  private var timeBinding: Binding<Date> {
    Binding(
      get: {
        Calendar.current.date(
          from: DateComponents(hour: schedule.hour, minute: schedule.minute)) ?? .now
      },
      set: { date in
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        schedule.hour = parts.hour ?? 9
        schedule.minute = parts.minute ?? 0
      })
  }

  private func step<Content: View>(
    _ number: String, _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(number).font(.ottoMono(10, weight: .bold))
          .frame(width: 20, height: 20)
          .background(palette.signal.opacity(0.18), in: Circle())
          .foregroundStyle(palette.signal)
        Text(title).font(.ottoDisplay(14).weight(.semibold))
      }
      content()
    }
  }

  private func doerOption<Content: View>(_ option: Doer, @ViewBuilder content: () -> Content)
    -> some View
  {
    let selected = doer == option
    return Button {
      doer = option
    } label: {
      HStack(spacing: 10) {
        content()
        Spacer(minLength: 0)
        if selected {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.signal)
        }
      }
      .padding(10)
      .background(
        selected ? palette.signal.opacity(0.12) : palette.paper.opacity(0.04),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(selected ? palette.signal.opacity(0.6) : palette.paper.opacity(0.1))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func load() {
    switch target {
    case .new(let template):
      if let first = bots.first { doer = .bot(first.profile.id) }
      if let template {
        name = template.title
        task = template.task
        schedule = AutomationSchedule(
          frequency: template.frequency, hour: template.time.hour ?? 9,
          minute: template.time.minute ?? 0, weekday: template.weekday)
      }
    case .newStep(let parent):
      runAfter = RoutineChainLink(routineID: parent.id, when: .succeeded)
      destination = .none
      switch parent.target {
      case .spawnProfile(let id): doer = .bot(id)
      case .spawnProvider(let raw):
        doer = .provider(AgentProvider.allCases.first { $0.rawValue == raw } ?? .claudeCode)
      case .existingAgent: if let first = bots.first { doer = .bot(first.profile.id) }
      }
      accountID = parent.accountID
    case .edit(let routine):
      existing = routine
      runAfter = routine.runAfter
      model = routine.model
      name = routine.name
      task = routine.instruction
      enabled = routine.enabled
      accountID = routine.accountID
      allowChanges = routine.permissionMode == AgentPermissionMode.workspaceWrite.rawValue
      reviewOnHome = routine.needsReview
      afterApproval = routine.afterApproval ?? ""
      switch routine.target {
      case .spawnProfile(let id): doer = .bot(id)
      case .spawnProvider(let raw):
        doer = .provider(AgentProvider.allCases.first { $0.rawValue == raw } ?? .claudeCode)
      case .existingAgent: break
      }
      if case .schedule(let cron?, _) = routine.trigger, let parsed = AutomationSchedule(cron: cron)
      {
        schedule = parsed
      }
      switch routine.delivery {
      case .brief: destination = .brief
      case .homeCard(let id):
        destination = .card
        cardID = id
      case .botChannel, .origin: destination = .botChat
      default: destination = .none
      }
    }
  }

  private func save() {
    let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalName =
      trimmedName.isEmpty
      ? String(AutomationsView.firstLine(of: trimmedTask).prefix(48)) : trimmedName
    let routineTarget: RoutineTarget =
      switch doer {
      case .bot(let id): .spawnProfile(profileID: id)
      case .provider(let provider): .spawnProvider(provider: provider.rawValue)
      }
    var linkedCardID = cardID.flatMap { services.homeCards.card(id: $0)?.id }
    if destination == .card, linkedCardID == nil {
      do {
        linkedCardID = try services.homeCards.add(HomeCard(title: finalName, style: .list)).id
      } catch {
        self.error = error.localizedDescription
        return
      }
    }
    let delivery: RoutineDelivery =
      switch (destination, doer) {
      case (.brief, _): .brief(profileID: services.dailyBrief.selectedProfile.id)
      case (.card, _): .homeCard(cardID: linkedCardID ?? UUID())
      case (.botChat, .bot(let id)): .botChannel(profileID: id)
      default: .canvas
      }
    var routine =
      existing
      ?? Routine(
        name: finalName, instruction: trimmedTask,
        trigger: .schedule(cron: schedule.cron, intervalSeconds: nil), target: routineTarget)
    routine.name = finalName
    routine.instruction = trimmedTask
    routine.target = routineTarget
    if let runAfter {
      routine.chain(after: runAfter.routineID, when: runAfter.when)
    } else {
      routine.runAfter = nil
      routine.trigger = .schedule(cron: schedule.cron, intervalSeconds: nil)
    }
    routine.delivery = delivery
    routine.accountID = accountID
    if case .provider = doer { routine.model = model } else { routine.model = nil }
    routine.enabled = enabled
    routine.quietWhenUnchanged = destination == .brief
    routine.reviewOnHome = reviewOnHome ? true : nil
    let action = afterApproval.trimmingCharacters(in: .whitespacesAndNewlines)
    routine.afterApproval = reviewOnHome && !action.isEmpty ? action : nil
    routine.permissionMode =
      (allowChanges ? AgentPermissionMode.workspaceWrite : .readOnly).rawValue
    routine.timeZoneIdentifier = TimeZone.current.identifier
    saving = true
    Task {
      do {
        let saved = try await services.saveRoutine(routine)
        linkCard(saved, to: destination == .card ? linkedCardID : nil)
        onFinish(saved)
      } catch {
        self.error = error.localizedDescription
      }
      saving = false
    }
  }

  /// Points the chosen card at this automation and unlinks any card it used to refresh.
  private func linkCard(_ routine: Routine, to cardID: UUID?) {
    for card in services.homeCards.allCards
    where card.automationID == routine.id && card.id != cardID {
      _ = try? services.homeCards.update(id: card.id) { $0.automationID = nil }
    }
    if let cardID {
      _ = try? services.homeCards.update(id: cardID) { $0.automationID = routine.id }
    }
  }
}

/// "New automation" asks how much control you want: the simple four-question form, or the
/// advanced canvas for a flow of agents.
struct AutomationModeChooser: View {
  enum Mode { case simple, advanced }
  let onChoose: (Mode?) -> Void
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("New automation").font(.ottoDisplay(20).weight(.semibold))
        Text("Pick how much you want to set up. You can switch a simple one to a flow later.")
          .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
      }
      HStack(alignment: .top, spacing: 12) {
        option(
          .simple, symbol: "clock", title: "Simple",
          detail: "One agent, one task, on a schedule. Four quick questions.",
          tag: "Most people start here")
        option(
          .advanced, symbol: "point.3.connected.trianglepath.dotted", title: "Advanced",
          detail:
            "Build a flow on a canvas. Add AI agent nodes, pick each one’s harness and model, and chain them together.",
          tag: "Flows")
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onChoose(nil) }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(width: 600)
    .background(palette.surface)
    .foregroundStyle(palette.paper)
  }

  private func option(_ mode: Mode, symbol: String, title: String, detail: String, tag: String)
    -> some View
  {
    Button {
      onChoose(mode)
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 16))
          .foregroundStyle(palette.signal)
          .frame(width: 34, height: 34)
          .background(palette.signal.opacity(0.14), in: Circle())
        Text(title).font(.ottoDisplay(16).weight(.semibold))
        Text(detail).font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
          .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Text(tag.uppercased()).font(.ottoMicro).tracking(1.4).foregroundStyle(palette.muted)
      }
      .padding(16)
      .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
      .automationCard(palette)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("automations.mode.\(mode == .simple ? "simple" : "advanced")")
  }
}

/// Its parent redraws on every streamed token and passes fresh closures, so equality is by the
/// stores it shows; its own state and observed stores still update it as normal.
extension AutomationsView: @MainActor Equatable {
  static func == (lhs: AutomationsView, rhs: AutomationsView) -> Bool {
    lhs.store === rhs.store && lhs.services === rhs.services && lhs.routines === rhs.routines
      && lhs.initialFlowID == rhs.initialFlowID
  }
}

/// The label that marks an automation built as an advanced flow.
struct AdvancedTag: View {
  @Environment(\.ottoPalette) private var palette
  var body: some View {
    Text("ADVANCED").font(.ottoMono(9, weight: .semibold)).tracking(1.4)
      .foregroundStyle(palette.signal)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(palette.signal.opacity(0.12), in: Capsule())
  }
}

extension View {
  /// The Automations card surface: a quiet plate with a hairline border and a soft lift.
  fileprivate func automationCard(_ palette: OttoPalette) -> some View {
    background(
      palette.raised.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .ottoElevated(cornerRadius: 14)
  }
}
