import AppKit
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

struct RoutineManagerView: View {
  enum Style {
    case window
    case embedded
  }

  @Environment(\.ottoPalette) private var palette
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: CanvasStore
  @ObservedObject var services: ApplicationServices
  var style: Style
  var initialRoutineID: UUID?
  var prefillProfileID: UUID?
  var prefillNodeID: UUID?
  @ObservedObject private var routines: RoutineStore
  @State private var selectedID: UUID?
  @State private var draft: Routine?
  @State private var pendingDeletion: Routine?
  @State private var notice: String?
  @State private var webhookInstructions: RoutineInstructionsOutput?
  @State private var scheduleTime = Date()
  @State private var showsRawCron = false

  init(
    store: CanvasStore,
    services: ApplicationServices,
    style: Style = .window,
    initialRoutineID: UUID? = nil,
    prefillProfileID: UUID? = nil,
    prefillNodeID: UUID? = nil
  ) {
    self.store = store
    self.services = services
    self.style = style
    self.initialRoutineID = initialRoutineID
    self.prefillProfileID = prefillProfileID
    self.prefillNodeID = prefillNodeID
    self.routines = services.routines
  }

  private var ownerIsLocked: Bool { prefillProfileID != nil || prefillNodeID != nil }

  private var visibleRoutines: [Routine] {
    routines.routines.filter(matchesOwner)
  }

  var body: some View {
    Group {
      if style == .window {
        windowBody
      } else {
        embeddedBody
      }
    }
    .background(palette.surface)
    .onAppear { applyLaunch() }
    .onChange(of: routines.routines) { _, _ in reconcile() }
    .onChange(of: initialRoutineID) { _, _ in applyLaunch() }
    .confirmationDialog(
      "Delete \(pendingDeletion?.name ?? "routine")?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      )
    ) {
      Button("Delete routine", role: .destructive) {
        if let value = pendingDeletion { delete(value) }
      }
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text("This removes its definition. Existing run history remains auditable.")
    }
  }

  private var windowBody: some View {
    VStack(spacing: 0) {
      header
      Divider()
      HSplitView {
        roster.frame(minWidth: 250, idealWidth: 280, maxWidth: 330)
        editor.frame(minWidth: 500, idealWidth: 590)
      }
    }
    .frame(minWidth: 820, minHeight: 590)
  }

  private var embeddedBody: some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        Button(action: { create(profileID: prefillProfileID, nodeID: prefillNodeID) }) {
          Label("New", systemImage: "plus")
            .font(.ottoMono(7, weight: .black))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(palette.cyan)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      Divider().overlay(palette.paper.opacity(0.08))
      if visibleRoutines.isEmpty, draft == nil {
        ContentUnavailableView {
          Label("No routines yet", systemImage: "clock.badge.plus")
        } description: {
          Text("Add a schedule, webhook, or agent-event job.")
        }
        .foregroundStyle(palette.paper)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        compactRoster
        Divider().overlay(palette.paper.opacity(0.08))
        editor
      }
    }
  }

  private var compactRoster: some View {
    ScrollView {
      OttoFluidHover(
        axis: .vertical,
        style: OttoFluidHoverStyle(fill: palette.paper.opacity(0.05), cornerRadius: 10)
      ) {
        LazyVStack(spacing: 4) {
          ForEach(visibleRoutines) { routine in
            rosterRow(routine)
              .ottoHoverItem(routine.id)
          }
        }
        .padding(8)
      }
    }
    .ottoScrollChrome(fade: 12)
    .frame(maxHeight: min(CGFloat(max(visibleRoutines.count, 1)) * 52, 168))
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("ROUTINES")
          .font(.ottoMono(10, weight: .black)).tracking(2).foregroundStyle(palette.signal)
        Text("Let agents act on a schedule or canvas event.")
          .font(.ottoDisplay(15)).foregroundStyle(palette.paper)
      }
      Spacer()
      Button("New routine", action: create)
      Button("Done") { dismiss() }
    }
    .padding(18)
  }

  private var roster: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("AUTOMATIONS · \(routines.routines.count)")
        .font(.ottoMono(8, weight: .black)).tracking(1.3).foregroundStyle(palette.muted)
        .padding(16)
      if routines.routines.isEmpty {
        ContentUnavailableView(
          "No routines", systemImage: "clock.badge.plus",
          description: Text("Create a typed schedule or agent-event trigger.")
        )
        .foregroundStyle(palette.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          OttoFluidHover(
            axis: .vertical,
            style: OttoFluidHoverStyle(fill: palette.paper.opacity(0.05), cornerRadius: 10)
          ) {
            LazyVStack(spacing: 6) {
              ForEach(routines.routines) { routine in
                rosterRow(routine)
                  .ottoHoverItem(routine.id)
              }
            }
            .padding(10)
          }
        }
        .ottoScrollChrome()
      }
    }
    .background(palette.ink.opacity(0.3))
  }

  private func rosterRow(_ routine: Routine) -> some View {
    Button {
      selectedID = routine.id
      draft = routine
    } label: {
      HStack {
        Circle().fill(routine.enabled ? palette.signal : palette.muted).frame(width: 8, height: 8)
        VStack(alignment: .leading) {
          Text(routine.name).font(.ottoDisplay(13).weight(.semibold))
          Text(routine.trigger.summary).font(.ottoMono(7.5)).foregroundStyle(palette.muted)
            .lineLimit(1)
        }
        Spacer()
        Text("R\(routine.revision)").font(.ottoMono(7))
      }
      .foregroundStyle(palette.paper)
      .padding(10)
      .background(
        selectedID == routine.id ? palette.raised : palette.raised.opacity(0.3),
        in: RoundedRectangle(cornerRadius: 10)
      )
      .animation(OttoMotion.tint, value: selectedID == routine.id)
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder private var editor: some View {
    if let current = draft {
      let routine = Binding(get: { draft ?? current }, set: { draft = $0 })
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Toggle("Active", isOn: routine.enabled)
              .toggleStyle(.ottoSwitch)
              .fixedSize()
            Spacer()
            Button("Test run") { test(routine.wrappedValue) }
            Button("Delete", role: .destructive) { pendingDeletion = routine.wrappedValue }
          }
          heading("INSTRUCTION", "What the agent should do each time")
          TextField("Routine name", text: routine.name).textFieldStyle(.roundedBorder)
          TextEditor(text: routine.instruction)
            .font(.ottoMono(10.5)).frame(minHeight: 120).padding(8)
            .background(palette.ink.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
          heading("WHEN TO RUN", "Typed schedules are the primary input")
          Picker("Trigger", selection: triggerKind(routine)) {
            Text("On a schedule").tag(0)
            Text("Agent event").tag(1)
            Text("Webhook").tag(2)
          }
          triggerEditor(routine)
          if !ownerIsLocked {
            heading("TARGET & DELIVERY", "Automated runs use a lower privilege tier")
            targetEditor(routine)
            Picker("Delivery", selection: deliveryKind(routine)) {
              Text("Canvas").tag(0)
              Text("Origin / bot thread").tag(1)
              Text("Document").tag(2)
              Text("Bot channel").tag(3)
              Text("Home brief").tag(4)
              if !services.homeCards.cards.isEmpty { Text("Home card").tag(5) }
            }
            if case .document(let path) = routine.wrappedValue.delivery {
              TextField(
                "Document path",
                text: Binding(
                  get: { path },
                  set: { routine.wrappedValue.delivery = .document(relativePath: $0) })
              )
              .textFieldStyle(.roundedBorder)
            }
            if case .brief = routine.wrappedValue.delivery {
              Picker("Home brief", selection: briefProfile(routine)) {
                ForEach(services.dailyBrief.profiles) { profile in
                  Text(profile.name).tag(profile.id)
                }
              }
            }
            if case .botChannel = routine.wrappedValue.delivery {
              Picker("Bot", selection: deliveryProfile(routine)) {
                ForEach(services.agentProfiles.activeProfiles) { profile in
                  Text(profile.name).tag(profile.id)
                }
              }
            }
          }
          Picker("Permission", selection: permissionMode(routine)) {
            Text("Read only").tag(AgentPermissionMode.readOnly.rawValue)
            Text("Workspace write").tag(AgentPermissionMode.workspaceWrite.rawValue)
            Text("Unrestricted (explicit)").tag(AgentPermissionMode.unrestricted.rawValue)
          }
          TextField("Tool allowlist (comma separated)", text: allowlist(routine))
            .textFieldStyle(.roundedBorder)
          Toggle("Suppress unchanged [SILENT] runs", isOn: routine.quietWhenUnchanged)
            .toggleStyle(.ottoSwitch)
          Picker("Overlap", selection: routine.concurrency) {
            Text("Skip while busy").tag(ConcurrencyPolicy.skip)
            Text("Queue latest").tag(ConcurrencyPolicy.queueLatest)
          }
          if let notice {
            Text(notice).font(.ottoMono(9)).foregroundStyle(palette.signal)
          }
          HStack {
            Spacer()
            Button("Save changes") { Task { await save(routine.wrappedValue) } }
              .keyboardShortcut(.defaultAction)
          }
          heading("RECENT RUNS", "Local append-only history")
          ForEach(routines.recentRuns(routineID: current.id, limit: 10)) { run in
            HStack {
              Text(run.outcome.rawValue.uppercased()).font(.ottoMono(8, weight: .bold))
              if run.retryOfRunID != nil { Text("RETRY").font(.ottoMono(8, weight: .bold)) }
              Text(run.firedAt.formatted())
              Spacer()
              Text(run.error ?? "").lineLimit(1)
            }
            .font(.ottoMono(8)).foregroundStyle(palette.muted)
          }
        }
        .padding(style == .embedded ? 14 : 22)
      }
    } else {
      ContentUnavailableView("Select a routine", systemImage: "clock.arrow.circlepath")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private func triggerEditor(_ routine: Binding<Routine>) -> some View {
    if case .schedule = routine.wrappedValue.trigger {
      Picker("Schedule", selection: schedulePreset(routine)) {
        Text("Every day at 09:00").tag("daily")
        Text("Weekdays at 09:00").tag("weekdays")
        Text("Weekends at 09:00").tag("weekends")
        Text("Every N hours").tag("interval")
        Text("Custom cron…").tag("custom")
      }
      if schedulePreset(routine).wrappedValue == "interval" {
        Stepper(
          "Every \(intervalHours(routine).wrappedValue) hour\(intervalHours(routine).wrappedValue == 1 ? "" : "s")",
          value: intervalHours(routine), in: 1...720
        )
      } else if schedulePreset(routine).wrappedValue == "custom" || showsRawCron {
        TextField("Cron expression", text: rawCron(routine)).textFieldStyle(.roundedBorder)
      } else {
        DatePicker("Time", selection: $scheduleTime, displayedComponents: .hourAndMinute)
          .onChange(of: scheduleTime) { _, value in updateScheduleTime(routine, date: value) }
        Button("Use custom cron") { showsRawCron = true }
          .buttonStyle(.link)
      }
    } else if case .webhook(let slug, _) = routine.wrappedValue.trigger {
      TextField(
        "Webhook slug",
        text: Binding(
          get: { slug }, set: { routine.wrappedValue.trigger = .webhook(slug: $0, filter: nil) })
      )
      .textFieldStyle(.roundedBorder)
      Text("Use routine.instructions to reveal the signing secret once and get tunnel commands.")
        .font(.ottoMono(8)).foregroundStyle(palette.muted)
      Text("Local URL: http://127.0.0.1:8787/hooks/\(slug)")
        .font(.ottoMono(8)).textSelection(.enabled)
      if let offline = services.hookListenerOfflineSince, routine.wrappedValue.enabled {
        Text("Listener offline since \(offline.formatted())")
          .font(.ottoMono(8, weight: .bold)).foregroundStyle(.red)
      }
      Button("Reveal secret & copy setup instructions") {
        loadWebhookInstructions(routine.wrappedValue)
      }
      if let instructions = webhookInstructions {
        if let secret = instructions.oneTimeSecret {
          Text("ONE-TIME SECRET: \(secret)").font(.ottoMono(8)).textSelection(.enabled)
        }
        Text(instructions.text).font(.ottoMono(8)).textSelection(.enabled)
      }
    } else {
      Picker("Event", selection: eventType(routine)) {
        Text("Agent completed").tag("agent.run_completed")
        Text("Agent failed").tag("agent.run_failed")
      }
    }
  }

  private func targetEditor(_ routine: Binding<Routine>) -> some View {
    VStack(alignment: .leading) {
      Picker("Target type", selection: targetKind(routine)) {
        Text("Existing agent").tag(0)
        Text("Saved profile").tag(1)
        Text("Provider").tag(2)
      }
      switch routine.wrappedValue.target {
      case .existingAgent:
        Picker("Agent", selection: targetNode(routine)) {
          ForEach(store.activeCanvas.nodes.filter { $0.kind == .agent }) { node in
            Text(node.displayName).tag(node.id)
          }
        }
      case .spawnProfile:
        Picker("Profile", selection: targetProfile(routine)) {
          ForEach(services.agentProfiles.activeProfiles) { profile in
            Text(profile.name).tag(profile.id)
          }
        }
      case .spawnProvider:
        Picker("Provider", selection: targetProvider(routine)) {
          ForEach(AgentProvider.allCases, id: \.self) { provider in
            Text(provider.rawValue).tag(provider.rawValue)
          }
        }
      }
      switch routine.wrappedValue.target {
      case .existingAgent:
        // A running agent keeps the account it was started with.
        EmptyView()
      case .spawnProfile(let id):
        let bot = services.agentProfiles.profile(id: id)
        RoutineAccountPicker(
          accounts: services.providerAccounts, accountID: routine.accountID,
          provider: bot?.provider,
          botAccountName: bot.map {
            services.providerAccounts.account(id: $0.accountID)?.name ?? "This Mac’s login"
          })
      case .spawnProvider(let provider):
        RoutineAccountPicker(
          accounts: services.providerAccounts, accountID: routine.accountID,
          provider: AgentProvider(rawValue: provider), botAccountName: nil)
      }
    }
  }

  private func heading(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading) {
      Text(title).font(.ottoMono(8, weight: .black)).tracking(1.2).foregroundStyle(palette.signal)
      Text(detail).font(.ottoMono(8)).foregroundStyle(palette.muted)
    }
  }

  private func triggerKind(_ routine: Binding<Routine>) -> Binding<Int> {
    Binding(
      get: {
        if case .schedule = routine.wrappedValue.trigger { return 0 }
        if case .agentEvent = routine.wrappedValue.trigger { return 1 }
        return 2
      },
      set: {
        if $0 == 0 {
          routine.wrappedValue.trigger = .schedule(cron: "0 9 * * *", intervalSeconds: nil)
        } else if $0 == 1 {
          routine.wrappedValue.trigger = .agentEvent(types: ["agent.run_completed"], nodeID: nil)
        } else {
          routine.wrappedValue.trigger = .webhook(
            slug: "incoming-\(routine.wrappedValue.id.uuidString.prefix(8).lowercased())",
            filter: nil)
        }
      })
  }

  private func intervalHours(_ routine: Binding<Routine>) -> Binding<Int> {
    Binding(
      get: {
        guard case .schedule(_, let seconds) = routine.wrappedValue.trigger else { return 1 }
        return max(1, (seconds ?? 3_600) / 3_600)
      },
      set: { routine.wrappedValue.trigger = .schedule(cron: nil, intervalSeconds: $0 * 3_600) })
  }

  private func schedulePreset(_ routine: Binding<Routine>) -> Binding<String> {
    Binding(
      get: {
        guard case .schedule(let cron, let interval) = routine.wrappedValue.trigger else {
          return "daily"
        }
        if interval != nil { return "interval" }
        return ["0 9 * * *": "daily", "0 9 * * 1-5": "weekdays", "0 9 * * 0,6": "weekends"][
          cron ?? ""] ?? "custom"
      },
      set: {
        let values = ["daily": "0 9 * * *", "weekdays": "0 9 * * 1-5", "weekends": "0 9 * * 0,6"]
        routine.wrappedValue.trigger =
          $0 == "interval"
          ? .schedule(cron: nil, intervalSeconds: 3_600)
          : .schedule(cron: values[$0] ?? "0 9 * * *", intervalSeconds: nil)
      })
  }

  private func rawCron(_ routine: Binding<Routine>) -> Binding<String> {
    Binding(
      get: {
        if case .schedule(let cron, _) = routine.wrappedValue.trigger { return cron ?? "" }
        return ""
      }, set: { routine.wrappedValue.trigger = .schedule(cron: $0, intervalSeconds: nil) })
  }

  private func updateScheduleTime(_ routine: Binding<Routine>, date: Date) {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    let suffix: String
    switch schedulePreset(routine).wrappedValue {
    case "weekdays": suffix = "1-5"
    case "weekends": suffix = "0,6"
    default: suffix = "*"
    }
    routine.wrappedValue.trigger = .schedule(
      cron: "\(parts.minute ?? 0) \(parts.hour ?? 9) * * \(suffix)", intervalSeconds: nil)
  }

  private func eventType(_ routine: Binding<Routine>) -> Binding<String> {
    Binding(
      get: {
        if case .agentEvent(let types, _) = routine.wrappedValue.trigger {
          return types.first ?? "agent.run_completed"
        }
        return "agent.run_completed"
      }, set: { routine.wrappedValue.trigger = .agentEvent(types: [$0], nodeID: nil) })
  }

  private func targetNode(_ routine: Binding<Routine>) -> Binding<UUID> {
    Binding(
      get: {
        if case .existingAgent(let id) = routine.wrappedValue.target { return id }
        return store.activeCanvas.nodes.first(where: { $0.kind == .agent })?.id ?? UUID()
      }, set: { routine.wrappedValue.target = .existingAgent(nodeID: $0) })
  }

  private func targetKind(_ routine: Binding<Routine>) -> Binding<Int> {
    Binding(
      get: {
        switch routine.wrappedValue.target {
        case .existingAgent: 0
        case .spawnProfile: 1
        case .spawnProvider: 2
        }
      },
      set: { kind in
        if kind == 0, let node = store.activeCanvas.nodes.first(where: { $0.kind == .agent }) {
          routine.wrappedValue.target = .existingAgent(nodeID: node.id)
        } else if kind == 1, let profile = services.agentProfiles.activeProfiles.first {
          routine.wrappedValue.target = .spawnProfile(profileID: profile.id)
        } else if kind == 2 {
          routine.wrappedValue.target = .spawnProvider(provider: AgentProvider.codex.rawValue)
        }
      })
  }

  private func targetProfile(_ routine: Binding<Routine>) -> Binding<UUID> {
    Binding(
      get: {
        if case .spawnProfile(let id) = routine.wrappedValue.target { return id }
        return services.agentProfiles.activeProfiles.first?.id ?? UUID()
      }, set: { routine.wrappedValue.target = .spawnProfile(profileID: $0) })
  }

  private func targetProvider(_ routine: Binding<Routine>) -> Binding<String> {
    Binding(
      get: {
        if case .spawnProvider(let provider) = routine.wrappedValue.target { return provider }
        return AgentProvider.codex.rawValue
      }, set: { routine.wrappedValue.target = .spawnProvider(provider: $0) })
  }

  private func permissionMode(_ routine: Binding<Routine>) -> Binding<String> {
    Binding(
      get: { routine.wrappedValue.permissionMode ?? AgentPermissionMode.readOnly.rawValue },
      set: { routine.wrappedValue.permissionMode = $0 })
  }

  private func loadWebhookInstructions(_ routine: Routine) {
    Task {
      do {
        let saved = try await services.saveRoutine(routine)
        let output = try await services.routineInstructions(id: saved.id)
        webhookInstructions = output
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.text, forType: .string)
        notice = "Setup instructions copied. The secret is shown only this time."
      } catch { notice = error.localizedDescription }
    }
  }

  private func deliveryKind(_ routine: Binding<Routine>) -> Binding<Int> {
    Binding(
      get: {
        switch routine.wrappedValue.delivery {
        case .canvas: 0
        case .origin: 1
        case .document: 2
        case .botChannel: 3
        case .brief: 4
        case .homeCard: 5
        }
      },
      set: {
        switch $0 {
        case 1: routine.wrappedValue.delivery = .origin
        case 2: routine.wrappedValue.delivery = .document(relativePath: "Routine Reports.md")
        case 3:
          let profileID: UUID
          if case .spawnProfile(let id) = routine.wrappedValue.target {
            profileID = id
          } else {
            profileID = services.agentProfiles.activeProfiles.first?.id ?? UUID()
          }
          routine.wrappedValue.delivery = .botChannel(profileID: profileID)
        case 4:
          routine.wrappedValue.delivery = .brief(profileID: services.dailyBrief.selectedProfile.id)
        case 5:
          if case .homeCard = routine.wrappedValue.delivery { return }
          if let card = services.homeCards.cards.first {
            routine.wrappedValue.delivery = .homeCard(cardID: card.id)
          }
        default:
          routine.wrappedValue.delivery = .canvas
        }
      })
  }

  private func allowlist(_ routine: Binding<Routine>) -> Binding<String> {
    Binding(
      get: { routine.wrappedValue.toolAllowlist?.joined(separator: ", ") ?? "" },
      set: {
        routine.wrappedValue.toolAllowlist = $0.split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      })
  }

  private func deliveryProfile(_ routine: Binding<Routine>) -> Binding<UUID> {
    Binding(
      get: {
        if case .botChannel(let id) = routine.wrappedValue.delivery { return id }
        return services.agentProfiles.activeProfiles.first?.id ?? UUID()
      },
      set: { routine.wrappedValue.delivery = .botChannel(profileID: $0) }
    )
  }

  private func briefProfile(_ routine: Binding<Routine>) -> Binding<UUID> {
    Binding(
      get: {
        if case .brief(let id?) = routine.wrappedValue.delivery { return id }
        return services.dailyBrief.selectedProfile.id
      },
      set: { routine.wrappedValue.delivery = .brief(profileID: $0) }
    )
  }

  private func create() {
    create(profileID: nil, nodeID: nil)
  }

  private func matchesOwner(_ routine: Routine) -> Bool {
    if let prefillProfileID {
      if case .spawnProfile(let id) = routine.target, id == prefillProfileID { return true }
      if case .botChannel(let id) = routine.delivery, id == prefillProfileID { return true }
      if case .existingAgent(let nodeID) = routine.target {
        return store.snapshot.canvases
          .flatMap(\.nodes)
          .first { $0.id == nodeID }?.agentDefinition?.profileID == prefillProfileID
      }
      return false
    }
    if let prefillNodeID {
      if case .existingAgent(let id) = routine.target { return id == prefillNodeID }
      return false
    }
    return true
  }

  private func applyLaunch() {
    if let id = initialRoutineID, let value = routines.routine(id: id), matchesOwner(value) {
      selectedID = id
      draft = value
      return
    }
    selectInitial()
  }

  private func create(profileID: UUID?, nodeID: UUID?) {
    let target: RoutineTarget
    let delivery: RoutineDelivery
    if let profileID {
      target = .spawnProfile(profileID: profileID)
      delivery = .botChannel(profileID: profileID)
    } else if let nodeID {
      target = .existingAgent(nodeID: nodeID)
      delivery = .origin
    } else if let profile = services.agentProfiles.activeProfiles.first {
      target = .spawnProfile(profileID: profile.id)
      delivery = .botChannel(profileID: profile.id)
    } else if let node = store.activeCanvas.nodes.first(where: { $0.kind == .agent }) {
      target = .existingAgent(nodeID: node.id)
      delivery = .canvas
    } else {
      notice = "Hire a bot or create an agent first."
      return
    }
    Task {
      await save(
        Routine(
          name: "New routine",
          instruction: "Describe what to do.",
          trigger: .schedule(cron: "0 9 * * *", intervalSeconds: nil),
          target: target,
          permissionMode: AgentPermissionMode.readOnly.rawValue,
          delivery: delivery
        ))
    }
  }

  @MainActor private func save(_ value: Routine) async {
    do {
      let saved = try await services.saveRoutine(value)
      selectedID = saved.id
      draft = saved
      notice = "Saved."
    } catch { notice = error.localizedDescription }
  }

  private func test(_ value: Routine) {
    Task {
      do {
        let saved = try await services.saveRoutine(value)
        selectedID = saved.id
        draft = saved
        _ = try await services.testRoutine(id: saved.id, payload: "Test run from Routine Manager")
        notice = "Test run started."
      } catch { notice = error.localizedDescription }
    }
  }

  private func delete(_ value: Routine) {
    try? services.deleteRoutine(id: value.id)
    draft = nil
    selectedID = nil
    pendingDeletion = nil
    selectInitial()
  }

  private func selectInitial() {
    if let first = visibleRoutines.first {
      selectedID = first.id
      draft = first
    } else {
      selectedID = nil
      draft = nil
    }
  }

  private func reconcile() {
    if let id = selectedID, let value = routines.routine(id: id), matchesOwner(value) {
      draft = value
    } else {
      selectInitial()
    }
  }
}
