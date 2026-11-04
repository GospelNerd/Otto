import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

/// Advanced automations: a canvas where a flow is built from a trigger and AI agent nodes.
/// Each "+" adds an agent that runs after the one above it; the inspector sets its harness,
/// model, account, task and permissions. Nothing runs or is saved until "Save flow".
struct AutomationFlowBuilder: View {
  let services: ApplicationServices
  let initial: AutomationFlowDraft
  /// Called with the id of the automation that starts the saved flow, or nil on cancel.
  let onClose: (UUID?) -> Void
  @Environment(\.ottoPalette) private var palette
  @ObservedObject private var catalog = ProviderModelCatalogStore.shared

  @State private var draft = AutomationFlowDraft()
  @State private var selection: Selection = .trigger
  @State private var availability: [AgentProviderInfo] = []
  @State private var saving = false
  @State private var error: String?
  @State private var loaded = false

  enum Selection: Hashable {
    case trigger
    case step(UUID)
  }

  static let triggerAnchor = AutomationsView.triggerAnchorID

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Rectangle().fill(palette.paper.opacity(0.08)).frame(height: 1)
      HStack(spacing: 0) {
        canvas
        Rectangle().fill(palette.paper.opacity(0.08)).frame(width: 1)
        inspector
          .frame(width: 360)
          .background(palette.raised)
      }
    }
    .foregroundStyle(palette.paper)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      draft = initial
      selection = draft.steps.first.map { .step($0.id) } ?? .trigger
    }
    .task { availability = (try? await services.providerAvailability()) ?? [] }
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 12) {
      Button {
        onClose(nil)
      } label: {
        Label("Automations", systemImage: "chevron.left")
          .font(.ottoDisplay(12.5).weight(.medium))
      }
      .buttonStyle(.plain).foregroundStyle(palette.muted)
      .keyboardShortcut(.cancelAction)
      Rectangle().fill(palette.paper.opacity(0.12)).frame(width: 1, height: 18)
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .foregroundStyle(palette.signal)
      Text(draft.root?.displayName ?? "New flow")
        .font(.ottoDisplay(16).weight(.semibold)).lineLimit(1)
      Text(draft.existingIDs.isEmpty ? "ADVANCED · DRAFT" : "ADVANCED · EDITING")
        .font(.ottoMicro).tracking(1.6).foregroundStyle(palette.muted)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(palette.paper.opacity(0.06), in: Capsule())
      Spacer()
      if let error {
        Text(error).font(.ottoDisplay(12)).foregroundStyle(palette.red).lineLimit(1)
      }
      Text("\(draft.steps.count) agent\(draft.steps.count == 1 ? "" : "s")")
        .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
      Button("Cancel") { onClose(nil) }
        .buttonStyle(.bordered)
      Button(saving ? "Saving…" : "Save flow") { save() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(saving || draft.steps.isEmpty)
        .accessibilityIdentifier("automations.builder.save")
    }
    .padding(.horizontal, 22).padding(.vertical, 12)
  }

  // MARK: Canvas

  private var canvas: some View {
    GeometryReader { viewport in
      ScrollView([.horizontal, .vertical]) {
        VStack(spacing: 34) {
          triggerNode
            .anchorPreference(key: FlowAnchorKey.self, value: .bounds) {
              [Self.triggerAnchor: $0]
            }
          if let root = draft.root {
            branch(root)
          } else {
            addButton(label: "Add an AI agent") { add(after: nil) }
          }
        }
        .backgroundPreferenceValue(FlowAnchorKey.self) { anchors in
          GeometryReader { proxy in wires(anchors: anchors, proxy: proxy) }
        }
        .padding(40)
        .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .top)
      }
      .background(AutomationDotGrid())
      .background(palette.surface)
      .contentShape(Rectangle())
    }
  }

  private func branch(_ step: AutomationFlowDraft.Step) -> AnyView {
    let children = draft.children(of: step.id)
    return AnyView(
      VStack(spacing: 34) {
        VStack(spacing: 10) {
          agentNode(step)
          addButton(label: nil) { add(after: step.id) }
        }
        if !children.isEmpty {
          HStack(alignment: .top, spacing: 22) {
            ForEach(children) { child in branch(child) }
          }
        }
      })
  }

  private var triggerNode: some View {
    let selected = selection == .trigger
    return Button {
      selection = .trigger
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "clock")
          .font(.system(size: 12, weight: .medium))
          .frame(width: 30, height: 30)
          .background(palette.paper.opacity(0.07), in: Circle())
        VStack(alignment: .leading, spacing: 1) {
          Text("TRIGGER").font(.ottoMicro).tracking(1.6).foregroundStyle(palette.muted)
          Text(draft.schedule.label).font(.ottoDisplay(13).weight(.semibold))
        }
        if !draft.startsOn {
          Text("Off").font(.ottoDisplay(11)).foregroundStyle(palette.muted)
        }
      }
      .padding(.leading, 8).padding(.trailing, 18).padding(.vertical, 8)
      .background(palette.raised.opacity(0.95), in: Capsule())
      .overlay(
        Capsule().strokeBorder(
          selected ? palette.signal : palette.paper.opacity(0.1), lineWidth: selected ? 1.5 : 1)
      )
      .ottoElevated(cornerRadius: 24)
    }
    .buttonStyle(.plain)
  }

  private func agentNode(_ step: AutomationFlowDraft.Step) -> some View {
    let selected = selection == .step(step.id)
    let needsTask = step.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return Button {
      selection = .step(step.id)
    } label: {
      AutomationNodeCard(
        title: step.displayName, subtitle: doerTitle(step),
        logo: AnyView(nodeLogo(step.doer)),
        badge: .tag(step.allowChanges ? "CAN EDIT" : "READ ONLY"),
        task: needsTask ? "Add a task for this agent" : AutomationsView.firstLine(of: step.task),
        taskIsPlaceholder: needsTask,
        meta: [
          step.parentID == nil
            ? nil
            : (step.when == .succeeded
              ? "on success" : step.when == .failed ? "if it fails" : "either way"),
          step.reviewOnHome ? "asks you first" : nil,
        ].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
        trailing: destinationLabel(step.destination),
        childCount: draft.children(of: step.id).count, selected: selected)
    }
    .buttonStyle(.plain)
    .anchorPreference(key: FlowAnchorKey.self, value: .bounds) { [step.id: $0] }
    .contextMenu {
      Button("Add an agent after this") { add(after: step.id) }
      Button("Delete", role: .destructive) { remove(step.id) }
        .disabled(step.parentID == nil && !draft.children(of: step.id).isEmpty)
    }
    .accessibilityLabel("\(step.displayName), AI agent")
  }

  private func addButton(label: String?, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
          .foregroundStyle(palette.onSignal)
          .frame(width: 20, height: 20)
          .background(palette.signal, in: Circle())
        if let label {
          Text(label).font(.ottoDisplay(12.5).weight(.semibold)).foregroundStyle(palette.signal)
        }
      }
      .padding(.leading, 4).padding(.trailing, label == nil ? 4 : 12).padding(.vertical, 4)
      .background(palette.raised, in: Capsule())
      .overlay(Capsule().strokeBorder(palette.signal.opacity(0.5)))
    }
    .buttonStyle(.plain)
    .help("Add an AI agent that runs after this")
    .accessibilityLabel(label ?? "Add an agent after this")
  }

  private func wires(anchors: [UUID: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(draft.steps) { step in
        let parentKey = step.parentID ?? Self.triggerAnchor
        if let fromAnchor = anchors[parentKey], let toAnchor = anchors[step.id] {
          let from = proxy[fromAnchor]
          let to = proxy[toAnchor]
          AutomationWire(
            from: from, to: to, live: false,
            failedBranch: step.parentID != nil && step.when == .failed)
          if step.parentID != nil, step.when != .succeeded {
            Text(step.when == .failed ? "IF IT FAILS" : "EITHER WAY")
              .font(.ottoMono(8.5, weight: .medium)).tracking(1.2)
              .foregroundStyle(step.when == .failed ? palette.red : palette.muted)
              .padding(.horizontal, 7).padding(.vertical, 2)
              .background(palette.surface, in: Capsule())
              .overlay(Capsule().strokeBorder(palette.paper.opacity(0.14)))
              .fixedSize()
              .position(x: to.midX, y: to.minY - 14)
          }
        }
      }
    }
    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
  }

  // MARK: Inspector

  @ViewBuilder private var inspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        switch selection {
        case .trigger: triggerInspector
        case .step(let id):
          if let index = draft.steps.firstIndex(where: { $0.id == id }) {
            stepInspector($draft.steps[index])
          } else {
            triggerInspector
          }
        }
      }
      .padding(22)
      .frame(width: 360, alignment: .leading)
    }
    .scrollIndicators(.never)
  }

  private var triggerInspector: some View {
    VStack(alignment: .leading, spacing: 18) {
      header("TRIGGER", "When should this flow start?")
      field("Repeats") {
        Picker("Frequency", selection: $draft.schedule.frequency) {
          ForEach(AutomationFrequency.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
      }
      if draft.schedule.frequency == .weekly {
        field("Day") {
          Picker("Day", selection: $draft.schedule.weekday) {
            ForEach(1...7, id: \.self) { day in
              Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
            }
          }
          .labelsHidden()
        }
      }
      if draft.schedule.frequency != .hourly {
        field("Time") {
          DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
            .labelsHidden()
        }
      }
      Toggle("Turn the flow on when I save", isOn: $draft.startsOn)
        .font(.ottoDisplay(12.5))
      Text("Every agent after the first runs when the one above it finishes, and gets its answer.")
        .font(.ottoDisplay(11.5)).foregroundStyle(palette.muted)
      if draft.root == nil {
        Button("Add the first AI agent") { add(after: nil) }
          .buttonStyle(.borderedProminent)
      }
    }
  }

  private func stepInspector(_ step: Binding<AutomationFlowDraft.Step>) -> some View {
    let parentName = step.wrappedValue.parentID.flatMap { id in
      draft.steps.first { $0.id == id }?.displayName
    }
    return VStack(alignment: .leading, spacing: 18) {
      header(
        step.wrappedValue.parentID == nil ? "FIRST AI AGENT" : "AI AGENT",
        step.wrappedValue.displayName)
      field(step.wrappedValue.parentID == nil ? "Name (also names the flow)" : "Name") {
        TextField("e.g. Inbox triage", text: step.name).textFieldStyle(.roundedBorder)
      }
      field("Harness") { harnessGrid(step) }
      if case .provider(let provider) = step.wrappedValue.doer {
        field("Model") {
          AutomationModelPicker(
            provider: provider, accountID: step.wrappedValue.accountID, model: step.model)
        }
      }
      field("Account") {
        RoutineAccountPicker(
          accounts: services.providerAccounts, accountID: step.accountID,
          provider: provider(of: step.wrappedValue.doer),
          botAccountName: botAccountName(step.wrappedValue.doer), showsLabel: false)
      }
      field("Task") {
        TextEditor(text: step.task)
          .font(.ottoDisplay(13))
          .frame(minHeight: 110)
          .padding(6)
          .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.paper.opacity(0.12)))
          .overlay(alignment: .topLeading) {
            if step.wrappedValue.task.isEmpty {
              Text(
                parentName == nil
                  ? "What should this agent do?"
                  : "What should it do with \(parentName ?? "the previous step")’s answer?"
              )
              .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
              .padding(.horizontal, 11).padding(.vertical, 14)
              .allowsHitTesting(false)
            }
          }
      }
      AutomationVariableChips(steps: ancestorNames(of: step.wrappedValue)) { token in
        let task = step.wrappedValue.task
        step.wrappedValue.task =
          task.isEmpty || task.hasSuffix(" ") || task.hasSuffix("\n")
          ? task + token : task + " " + token
      }
      if let parentName {
        field("Starts") {
          Picker("Starts", selection: step.when) {
            Text("Succeeds").tag(RoutineChainCondition.succeeded)
            Text("Fails").tag(RoutineChainCondition.failed)
            Text("Either way").tag(RoutineChainCondition.finished)
          }
          .pickerStyle(.segmented).labelsHidden()
          Text(
            AutomationsView.chainLabel(parent: parentName, when: step.wrappedValue.when)
          )
          .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
        }
      }
      field("Permissions") {
        Picker("Permissions", selection: step.allowChanges) {
          Text("Read only").tag(false)
          Text("Can make changes").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden()
      }
      field("Check with you first?") {
        Toggle("Ask me on Home to approve each answer", isOn: step.reviewOnHome)
          .font(.ottoDisplay(12))
          .accessibilityIdentifier("automations.builder.review")
        if step.wrappedValue.reviewOnHome {
          TextField(
            "When I approve, do this (optional)", text: step.afterApproval, axis: .vertical
          )
          .textFieldStyle(.roundedBorder)
          .lineLimit(1...3)
          Text(
            draft.children(of: step.wrappedValue.id).isEmpty
              ? "Add what to do when you approve, or it shows as an update instead."
              : "The agents after this wait until you approve it on Home."
          )
          .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
        }
      }
      field("Results go to") {
        Picker("Results", selection: step.destination) {
          Text(
            draft.children(of: step.wrappedValue.id).isEmpty
              ? "Nowhere, just do it" : "Only the next agent"
          )
          .tag(AutomationEditor.Destination.none)
          Text("My Home brief").tag(AutomationEditor.Destination.brief)
          Text("A Home card").tag(AutomationEditor.Destination.card)
          if case .bot = step.wrappedValue.doer {
            Text("The bot’s chat").tag(AutomationEditor.Destination.botChat)
          }
        }
        .labelsHidden()
      }
      HStack {
        Button("Add an agent after this") { add(after: step.wrappedValue.id) }
          .buttonStyle(.bordered)
        Spacer()
        Button("Delete", role: .destructive) { remove(step.wrappedValue.id) }
          .buttonStyle(.bordered)
          .disabled(
            step.wrappedValue.parentID == nil
              && !draft.children(of: step.wrappedValue.id).isEmpty
          )
          .help(
            step.wrappedValue.parentID == nil
              && !draft.children(of: step.wrappedValue.id).isEmpty
              ? "Delete the agents after this one first" : "")
      }
      .padding(.top, 4)
    }
    .onAppear { loadModels(step.wrappedValue) }
    .onChange(of: step.wrappedValue.doer) { _, _ in
      step.wrappedValue.model = nil
      loadModels(step.wrappedValue)
    }
  }

  private func harnessGrid(_ step: Binding<AutomationFlowDraft.Step>) -> some View {
    let providers = AutomationHarnesses.all
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
      ForEach(providers, id: \.self) { provider in
        let installed =
          availability.isEmpty
          || availability.first { $0.provider == provider }?.installed == true
        harnessChip(selected: step.wrappedValue.doer == .provider(provider)) {
          AgentProviderLogo(provider: provider, size: 11, color: palette.paper)
          Text(provider.rawValue).font(.ottoDisplay(11.5).weight(.medium)).lineLimit(1)
          if !installed {
            Circle().fill(palette.amber).frame(width: 5, height: 5)
          }
        } action: {
          step.wrappedValue.doer = .provider(provider)
        }
        .help(installed ? "" : "\(provider.rawValue) isn’t set up on this Mac yet")
      }
      ForEach(services.botRoster()) { entry in
        harnessChip(selected: step.wrappedValue.doer == .bot(entry.profile.id)) {
          Image(systemName: "person.crop.circle").font(.system(size: 11))
          Text(entry.profile.name).font(.ottoDisplay(11.5).weight(.medium)).lineLimit(1)
        } action: {
          step.wrappedValue.doer = .bot(entry.profile.id)
          if step.wrappedValue.name.isEmpty { step.wrappedValue.name = entry.profile.name }
        }
      }
    }
  }

  private func harnessChip<Label: View>(
    selected: Bool, @ViewBuilder label: () -> Label, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) { label() }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          selected ? palette.signal.opacity(0.14) : palette.paper.opacity(0.04),
          in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? palette.signal.opacity(0.7) : palette.paper.opacity(0.1))
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func header(_ micro: String, _ title: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(micro).font(.ottoMicro).tracking(2).foregroundStyle(palette.muted)
      Text(title).font(.ottoDisplay(19).weight(.semibold)).lineLimit(2)
    }
  }

  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.ottoDisplay(12).weight(.medium)).foregroundStyle(palette.muted)
      content()
    }
  }

  private func tag(_ text: String) -> some View {
    Text(text).font(.ottoMono(9.5, weight: .medium)).foregroundStyle(palette.muted)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(palette.paper.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
      .lineLimit(1)
  }

  @ViewBuilder private func nodeLogo(_ doer: AutomationEditor.Doer) -> some View {
    if case .provider(let provider) = doer {
      AgentProviderLogo(provider: provider, size: 13, color: palette.paper.opacity(0.9))
    } else {
      doerBadge(doer, size: 22).clipShape(Circle())
    }
  }

  @ViewBuilder private func doerBadge(_ doer: AutomationEditor.Doer, size: CGFloat) -> some View {
    switch doer {
    case .bot(let id):
      if let entry = services.botRoster().first(where: { $0.profile.id == id }) {
        BotAvatarView(
          presentation: BotAvatarPresentation(
            id: entry.profile.id, name: entry.profile.name, appearance: entry.appearance,
            photoURL: services.botPhotoURL(entry.appearance?.photoRelativePath),
            state: entry.avatarState),
          size: size, showsStateBadge: false)
      } else {
        AgentProviderLogo(provider: nil, size: size * 0.44, color: palette.paper)
          .frame(width: size, height: size)
          .background(palette.paper.opacity(0.08), in: Circle())
      }
    case .provider(let provider):
      AgentProviderLogo(provider: provider, size: size * 0.44, color: palette.paper.opacity(0.85))
        .frame(width: size, height: size)
        .background(palette.paper.opacity(0.08), in: Circle())
    }
  }

  // MARK: Helpers

  private var timeBinding: Binding<Date> {
    Binding(
      get: {
        Calendar.current.date(
          from: DateComponents(hour: draft.schedule.hour, minute: draft.schedule.minute)) ?? .now
      },
      set: { date in
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        draft.schedule.hour = parts.hour ?? 9
        draft.schedule.minute = parts.minute ?? 0
      })
  }

  private func doerTitle(_ step: AutomationFlowDraft.Step) -> String {
    switch step.doer {
    case .bot(let id): "\(services.agentProfiles.profile(id: id)?.name ?? "Bot") · your bot"
    case .provider(let provider):
      AutomationModels.displayName(
        step.model, provider: provider, accountID: step.accountID, catalog: catalog)
        ?? provider.rawValue
    }
  }

  /// The agents before this one, nearest first, whose output it can use.
  private func ancestorNames(of step: AutomationFlowDraft.Step) -> [String] {
    var names: [String] = []
    var cursor = step.parentID
    var seen: Set<UUID> = []
    while let id = cursor, seen.insert(id).inserted,
      let parent = draft.steps.first(where: { $0.id == id })
    {
      names.append(parent.displayName)
      cursor = parent.parentID
    }
    return names
  }

  private func provider(of doer: AutomationEditor.Doer) -> AgentProvider? {
    switch doer {
    case .bot(let id): services.agentProfiles.profile(id: id)?.provider
    case .provider(let provider): provider
    }
  }

  private func botAccountName(_ doer: AutomationEditor.Doer) -> String? {
    guard case .bot(let id) = doer, let bot = services.agentProfiles.profile(id: id) else {
      return nil
    }
    return services.providerAccounts.account(id: bot.accountID)?.name ?? "This Mac’s login"
  }

  private func destinationLabel(_ destination: AutomationEditor.Destination) -> String? {
    switch destination {
    case .brief: "Home brief"
    case .card: "Home card"
    case .botChat: "Bot chat"
    case .none: nil
    }
  }

  private func loadModels(_ step: AutomationFlowDraft.Step) {
    if case .provider(let provider) = step.doer {
      catalog.load(provider, accountID: step.accountID)
    }
  }

  private func add(after parentID: UUID?) {
    let parent = parentID.flatMap { id in draft.steps.first { $0.id == id } }
    var step = AutomationFlowDraft.Step(parentID: parentID)
    if let parent {
      step.doer = parent.doer
      step.accountID = parent.accountID
    }
    draft.steps.append(step)
    selection = .step(step.id)
  }

  /// Removes an agent; the agents after it move up to run after whatever it ran after.
  private func remove(_ id: UUID) {
    guard let removed = draft.steps.first(where: { $0.id == id }) else { return }
    for index in draft.steps.indices where draft.steps[index].parentID == id {
      draft.steps[index].parentID = removed.parentID
    }
    draft.steps.removeAll { $0.id == id }
    selection = removed.parentID.map { .step($0) } ?? .trigger
  }

  private func save() {
    error = nil
    if let missing = draft.steps.first(where: {
      $0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) {
      selection = .step(missing.id)
      error = "Give “\(missing.displayName)” a task first."
      return
    }
    guard draft.steps.filter({ $0.parentID == nil }).count == 1 else {
      error = "A flow starts with one agent."
      return
    }
    saving = true
    Task {
      do {
        let rootID = try await draft.save(services: services)
        saving = false
        onClose(rootID)
      } catch {
        self.error = error.localizedDescription
        saving = false
      }
    }
  }
}

/// An advanced flow being built or edited. Steps are kept in memory until saved, then become
/// one automation each, chained with `runAfter`.
struct AutomationFlowDraft: Equatable {
  struct Step: Identifiable, Equatable {
    var id = UUID()
    var parentID: UUID?
    var when: RoutineChainCondition = .succeeded
    var name = ""
    var task = ""
    var doer: AutomationEditor.Doer = .provider(.claudeCode)
    var model: String?
    var accountID: UUID?
    var allowChanges = false
    /// Each answer waits on Home for approval before the agents after it run.
    var reviewOnHome = false
    var afterApproval = ""
    var destination: AutomationEditor.Destination = .none
    /// The card a Home-card step refreshes, when editing one that already has a card.
    var cardID: UUID?

    var displayName: String {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
      let task = AutomationsView.firstLine(of: self.task)
      return task.isEmpty ? "New agent" : String(task.prefix(40))
    }
  }

  var name = ""
  var schedule = AutomationSchedule(frequency: .weekdays, hour: 9, minute: 0)
  var startsOn = true
  var steps: [Step] = []
  /// Automations this draft was loaded from, so removed steps are deleted on save.
  var existingIDs: [UUID] = []
  var timeZoneIdentifier = TimeZone.current.identifier

  var root: Step? { steps.first { $0.parentID == nil } }

  func children(of id: UUID) -> [Step] { steps.filter { $0.parentID == id } }

  /// Parents before children, so each step's parent exists when it is saved.
  var savingOrder: [Step] {
    var ordered: [Step] = []
    var queue = steps.filter { $0.parentID == nil }
    while !queue.isEmpty {
      let next = queue.removeFirst()
      ordered.append(next)
      queue += children(of: next.id)
    }
    return ordered
  }

  /// Loads an existing flow, starting from the automation at its top.
  init(flowFrom root: Routine, in routines: [Routine]) {
    name = root.name
    if case .schedule(let cron?, _) = root.trigger, let parsed = AutomationSchedule(cron: cron) {
      schedule = parsed
    }
    startsOn = root.enabled
    timeZoneIdentifier = root.timeZoneIdentifier
    var queue = [root]
    var seen: Set<UUID> = []
    while !queue.isEmpty {
      let routine = queue.removeFirst()
      guard seen.insert(routine.id).inserted else { continue }
      steps.append(Step(routine: routine, isRoot: routine.id == root.id))
      queue += routines.filter { $0.runAfter?.routineID == routine.id }
    }
    existingIDs = steps.map(\.id)
  }

  init() {}

  @MainActor func save(services: ApplicationServices) async throws -> UUID {
    var rootID: UUID?
    for step in savingOrder {
      var routine =
        services.routines.routine(id: step.id)
        ?? Routine(
          id: step.id, name: step.displayName, instruction: step.task,
          trigger: .schedule(cron: schedule.cron, intervalSeconds: nil),
          target: .spawnProvider(provider: AgentProvider.claudeCode.rawValue))
      routine.name = step.displayName
      routine.instruction = step.task.trimmingCharacters(in: .whitespacesAndNewlines)
      switch step.doer {
      case .bot(let id): routine.target = .spawnProfile(profileID: id)
      case .provider(let provider): routine.target = .spawnProvider(provider: provider.rawValue)
      }
      routine.model = step.model
      routine.advanced = true
      routine.accountID = step.accountID
      routine.permissionMode =
        (step.allowChanges ? AgentPermissionMode.workspaceWrite : .readOnly).rawValue
      routine.timeZoneIdentifier = timeZoneIdentifier
      if let parentID = step.parentID {
        routine.chain(after: parentID, when: step.when)
        routine.enabled = true
      } else {
        routine.runAfter = nil
        routine.trigger = .schedule(cron: schedule.cron, intervalSeconds: nil)
        routine.enabled = startsOn
        rootID = step.id
      }
      var cardID = step.cardID
      if step.destination == .card, cardID == nil {
        cardID = try services.homeCards.add(HomeCard(title: step.displayName, style: .list)).id
      }
      routine.delivery =
        switch (step.destination, step.doer) {
        case (.brief, _): .brief(profileID: services.dailyBrief.selectedProfile.id)
        case (.card, _): .homeCard(cardID: cardID ?? UUID())
        case (.botChat, .bot(let id)): .botChannel(profileID: id)
        default: .canvas
        }
      routine.quietWhenUnchanged = step.destination == .brief
      routine.reviewOnHome = step.reviewOnHome ? true : nil
      let action = step.afterApproval.trimmingCharacters(in: .whitespacesAndNewlines)
      routine.afterApproval = step.reviewOnHome && !action.isEmpty ? action : nil
      let saved = try await services.saveRoutine(routine)
      if let cardID, step.destination == .card {
        _ = try? services.homeCards.update(id: cardID) { $0.automationID = saved.id }
      }
    }
    let kept = Set(steps.map(\.id))
    for id in existingIDs.reversed() where !kept.contains(id) {
      try services.deleteRoutine(id: id)
    }
    guard let rootID else { throw RoutineStoreError.invalid("A flow starts with one agent") }
    return rootID
  }
}

extension AutomationFlowDraft.Step {
  init(routine: Routine, isRoot: Bool) {
    id = routine.id
    parentID = isRoot ? nil : routine.runAfter?.routineID
    when = routine.runAfter?.when ?? .succeeded
    name = routine.name
    task = routine.instruction
    switch routine.target {
    case .spawnProfile(let id): doer = .bot(id)
    case .spawnProvider(let raw):
      doer = .provider(AgentProvider.allCases.first { $0.rawValue == raw } ?? .claudeCode)
    case .existingAgent: doer = .provider(.claudeCode)
    }
    model = routine.model
    accountID = routine.accountID
    allowChanges = routine.permissionMode == AgentPermissionMode.workspaceWrite.rawValue
    reviewOnHome = routine.needsReview
    afterApproval = routine.afterApproval ?? ""
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

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
