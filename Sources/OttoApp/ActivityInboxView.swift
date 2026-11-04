import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

/// Turns today's bot activity into one line per bot or automation. The newest finished, failed
/// or cancelled item speaks for its source; the count says how many runs it stands for. Items
/// that are still working or waiting on a person are left out: they belong in "Needs you".
struct ActivityInboxDigest {
  struct Row: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String?
    let state: BotActivityState
    let updatedAt: Date
    let count: Int
    let deepLink: BotActivityDeepLink
  }

  struct Digest: Equatable {
    var rows: [Row]
    /// Sessions the store marked failed only because Otto restarted under them. One quiet
    /// line stands for all of them; the raw stream still lists each.
    var interruptedCount: Int
  }

  /// The title `BotActivityStore` gives a run that was still working when Otto restarted.
  static let restartInterruptionTitle = "Work interrupted when Otto restarted"

  static func isRestartInterruption(_ item: BotActivityItem) -> Bool {
    item.state == .failed && item.title == restartInterruptionTitle
  }

  static func digest(
    from items: [BotActivityItem], now: Date, calendar: Calendar = .current
  ) -> Digest {
    let dayStart = calendar.startOfDay(for: now)
    let finished = items.filter { item in
      item.updatedAt >= dayStart && isFinished(item.state)
    }
    let interrupted = finished.filter(isRestartInterruption)
    var bySource: [String: [BotActivityItem]] = [:]
    for item in finished where !isRestartInterruption(item) {
      bySource[sourceKey(item.deepLink), default: []].append(item)
    }
    let rows = bySource.map { key, group in
      let latest = group.max { $0.updatedAt < $1.updatedAt } ?? group[0]
      return Row(
        id: key, title: latest.title, detail: latest.detail, state: latest.state,
        updatedAt: latest.updatedAt, count: group.count, deepLink: latest.deepLink)
    }
    .sorted { lhs, rhs in
      // Failures first so the eye lands on them, then newest first.
      if (lhs.state == .failed) != (rhs.state == .failed) { return lhs.state == .failed }
      return lhs.updatedAt > rhs.updatedAt
    }
    return Digest(rows: rows, interruptedCount: interrupted.count)
  }

  static func rows(
    from items: [BotActivityItem], now: Date, calendar: Calendar = .current
  ) -> [Row] {
    digest(from: items, now: now, calendar: calendar).rows
  }

  static func isFinished(_ state: BotActivityState) -> Bool {
    switch state {
    case .completed, .failed, .cancelled: true
    case .working, .needsUser: false
    }
  }

  static func sourceKey(_ link: BotActivityDeepLink) -> String {
    switch link {
    case .bot(let profileID, _): "bot:\(profileID.uuidString)"
    case .team(let channelID): "team:\(channelID.uuidString)"
    case .agent(let nodeID): "agent:\(nodeID.uuidString)"
    case .routine(let routineID, _): "routine:\(routineID.uuidString)"
    case .effect(let effectID): "effect:\(effectID.uuidString)"
    case .memory(let recordID, _): "memory:\(recordID)"
    }
  }
}

/// Everything that is waiting on the person, gathered once so the inbox, the sidebar badge and
/// Home can all agree on the same number.
struct ActivityNeedsYou {
  /// Reviews waiting for approval, a comment, or an Allow/Deny on their action.
  let reviews: [HomeReview]
  /// Live agents waiting for permission or an answer.
  let attention: [AgentAttentionItem]
  /// Agents the watchdog flags as stalled or looping, minus the ones above.
  let stuck: [AgentWatchdogFinding]
  /// Saved decisions that survive a restart, minus the ones the live runtime already shows.
  let saved: [BotActivityItem]

  @MainActor init(
    services: ApplicationServices, activity: BotActivityStore, reviews: HomeReviewStore
  ) {
    let attention = services.attentionItems.filter {
      $0.state == .waitingPermission || $0.state == .waitingUser
    }
    self.attention = attention
    self.reviews = reviews.onHome.filter(\.needsPerson)
    self.stuck = services.watchdogFindings.values
      .filter { finding in
        finding.kind != .waitingOnPerson && !attention.contains { $0.nodeID == finding.agentID }
      }
      .sorted { $0.since < $1.since }
    self.saved = activity.needsUser.filter { item in
      if case .agent(let nodeID) = item.deepLink {
        return !attention.contains { $0.nodeID == nodeID }
      }
      return true
    }
  }

  var count: Int { reviews.count + attention.count + stuck.count + saved.count }
}

/// The Activity place as an inbox: what needs a person first, acted on in place, then what
/// happened today, one line per bot. The raw stream is a toggle away, and search stays.
struct ActivityInboxView: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var activity: BotActivityStore
  @ObservedObject var reviews: HomeReviewStore
  /// nil when the session no longer exists.
  let agentName: (UUID) -> String?
  let openAgent: (UUID) -> Void
  let openDeepLink: (BotActivityDeepLink) -> Void
  @Environment(\.ottoPalette) private var palette
  @State private var query = ""
  @State private var results: [BotSearchResult] = []
  @State private var showingEverything = false
  @State private var status: OttoStatusToast?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(EdgeInsets(top: 26, leading: 32, bottom: 18, trailing: 32))
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if searching {
            searchResults
          } else {
            inbox
          }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
      }
    }
    .foregroundStyle(palette.paper)
    .background(palette.workspaceSurface)
    .ottoStatusToast($status)
    .onChange(of: query) { _, text in
      Task { results = await services.searchWorkspace(text) }
    }
    .accessibilityIdentifier("activity.inbox")
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Activity").font(.ottoDisplay(24).weight(.semibold))
        Text("What needs you first, then what happened.")
          .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
      }
      Spacer()
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").font(.system(size: 11))
          .foregroundStyle(palette.muted)
        TextField("Search bots, runs, results and memory", text: $query)
          .textFieldStyle(.plain)
          .font(.ottoDisplay(12.5))
      }
      .padding(.horizontal, 12)
      .frame(width: 300, height: 36)
      .background(palette.ink.opacity(0.48), in: RoundedRectangle(cornerRadius: 9))
      .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.paper.opacity(0.08)))
    }
  }

  private var searching: Bool {
    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: Needs you

  private var needs: ActivityNeedsYou {
    ActivityNeedsYou(services: services, activity: activity, reviews: reviews)
  }
  private var attention: [AgentAttentionItem] { needs.attention }
  private var stuckAgents: [AgentWatchdogFinding] { needs.stuck }
  private var recordedAttention: [BotActivityItem] { needs.saved }
  private var reviewsNeedingPerson: [HomeReview] { needs.reviews }
  private var needsYouCount: Int { needs.count }

  @ViewBuilder private var inbox: some View {
    sectionLabel("Needs you", count: needsYouCount, tint: palette.signal)
    if needsYouCount == 0 {
      allClear
    }
    ForEach(reviewsNeedingPerson) { review in
      Group {
        if review.isActing {
          HomeReviewActionCard(
            review: review, services: services, openAgent: openAgent, accentEdge: false)
        } else {
          HomeReviewCard(
            review: review, services: services, openAgent: openAgent,
            report: { status = $0 }, accentEdge: false)
        }
      }
      .padding(.bottom, 8)
    }
    ForEach(attention) { item in
      attentionCard(item)
    }
    ForEach(stuckAgents) { finding in
      stuckCard(finding)
    }
    ForEach(recordedAttention) { item in
      savedCard(item)
    }
    happenedHeader
      .padding(.top, 18)
      .padding(.bottom, 4)
    if showingEverything {
      if activity.items.isEmpty {
        quietLine("Nothing has happened yet.")
      }
      ForEach(activity.items) { item in
        rawRow(item)
      }
    } else {
      let digest = ActivityInboxDigest.digest(from: activity.items, now: .now)
      if digest.rows.isEmpty && digest.interruptedCount == 0 {
        quietLine("Nothing finished today.")
      }
      ForEach(digest.rows) { row in
        digestRow(row)
      }
      if digest.interruptedCount > 0 {
        quietLine(
          digest.interruptedCount == 1
            ? "1 session was interrupted when Otto restarted. It's under Show everything."
            : "\(digest.interruptedCount) sessions were interrupted when Otto restarted. "
              + "They're under Show everything.")
      }
      quietLine("Everything else is here when you search for it.")
    }
  }

  private var allClear: some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark.circle").font(.system(size: 15, weight: .light))
        .foregroundStyle(palette.signal)
      Text("Nothing needs you.").font(.ottoDisplay(13))
      Text("When an agent needs a decision, it will find you here.")
        .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 4)
    .accessibilityIdentifier("activity.allClear")
  }

  private func attentionCard(_ item: AgentAttentionItem) -> some View {
    let permission = item.state == .waitingPermission
    return card(
      kind: permission ? "Allow" : "Answer", tint: palette.cyan,
      title: permission
        ? "\(agentName(item.nodeID) ?? "An agent") is asking to do something"
        : "\(agentName(item.nodeID) ?? "An agent") has a question",
      caption: attentionReason(item), time: item.createdAt
    ) {
      Button {
        openAgent(item.nodeID)
      } label: {
        Label(permission ? "Review in chat" : "Reply in chat", systemImage: "bubble.left")
      }
      .buttonStyle(.bordered)
    }
    .accessibilityIdentifier("activity.needsYou.agent")
  }

  private func attentionReason(_ item: AgentAttentionItem) -> String {
    guard let finding = services.watchdogFindings[item.nodeID], finding.kind == .waitingOnPerson
    else { return item.reason }
    return "\(finding.reason). \(item.reason)"
  }

  private func stuckCard(_ finding: AgentWatchdogFinding) -> some View {
    card(
      kind: finding.kind == .looping ? "Looping" : "Stuck", tint: palette.amber,
      title: "\(agentName(finding.agentID) ?? "An agent"): \(finding.reason.lowercased())",
      caption: finding.kind == .looping
        ? "Calling the same tool with the same arguments over and over."
        : "Working, but nothing has changed since "
          + finding.since.formatted(date: .omitted, time: .shortened) + ".",
      time: finding.since
    ) {
      Button {
        openAgent(finding.agentID)
      } label: {
        Label("Open chat", systemImage: "bubble.left")
      }
      .buttonStyle(.bordered)
      Button(role: .destructive) {
        let id = finding.agentID
        Task { try? await services.stop(agentID: id) }
      } label: {
        Label("Stop it", systemImage: "stop.fill")
      }
      .buttonStyle(.bordered)
    }
    .accessibilityIdentifier("activity.needsYou.stuck")
  }

  private func savedCard(_ item: BotActivityItem) -> some View {
    card(
      kind: "Decide", tint: palette.signal, title: item.title,
      caption: item.detail ?? "A saved decision is waiting for you.", time: item.updatedAt
    ) {
      Button {
        openDeepLink(item.deepLink)
      } label: {
        Label("Open", systemImage: "arrow.right")
      }
      .buttonStyle(.bordered)
    }
    .accessibilityIdentifier("activity.needsYou.saved")
  }

  private func card<Actions: View>(
    kind: String, tint: Color, title: String, caption: String, time: Date?,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    HStack(alignment: .top, spacing: 16) {
      Text(kind.uppercased())
        .font(.ottoMono(8, weight: .bold)).tracking(1.2)
        .foregroundStyle(tint)
        .frame(width: 60, alignment: .leading)
        .padding(.top, 4)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(title).font(.ottoDisplay(14).weight(.semibold)).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          if let time {
            Text(time, style: .relative).font(.ottoMono(8.5)).foregroundStyle(palette.muted)
          }
        }
        Text(caption).font(.ottoDisplay(12)).foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) { actions() }
          .controlSize(.small)
          .padding(.top, 8)
      }
    }
    .padding(EdgeInsets(top: 16, leading: 20, bottom: 14, trailing: 20))
    .frame(maxWidth: .infinity, alignment: .leading)
    .ottoGlass(cornerRadius: 12)
    .padding(.bottom, 8)
  }

  // MARK: What happened

  private var happenedHeader: some View {
    HStack(spacing: 10) {
      Text("WHAT HAPPENED · TODAY").font(.ottoMono(8.5, weight: .bold)).tracking(1.2)
        .foregroundStyle(palette.muted)
      Rectangle().fill(palette.paper.opacity(0.07)).frame(height: 1)
      Button(showingEverything ? "Show less" : "Show everything") {
        showingEverything.toggle()
      }
      .buttonStyle(.plain)
      .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
      .padding(.horizontal, 10).padding(.vertical, 3)
      .overlay(Capsule().strokeBorder(palette.paper.opacity(0.1)))
      .accessibilityIdentifier("activity.showEverything")
    }
  }

  private func digestRow(_ row: ActivityInboxDigest.Row) -> some View {
    let failed = row.state == .failed
    return Button {
      openDeepLink(row.deepLink)
    } label: {
      HStack(spacing: 12) {
        Circle().fill(dot(row.state)).frame(width: 8, height: 8)
        Text(sourceName(row.deepLink) ?? row.title)
          .font(.ottoDisplay(12.5).weight(.semibold)).lineLimit(1)
          .frame(width: 220, alignment: .leading)
        Text(summary(row)).font(.ottoDisplay(12.5)).foregroundStyle(palette.muted).lineLimit(1)
        Spacer(minLength: 12)
        Text(row.count > 1 && !failed ? "Show \(row.count)" : "Open")
          .font(.ottoDisplay(12).weight(.semibold)).foregroundStyle(palette.cyan)
      }
      .padding(.horizontal, 14)
      .frame(height: 42)
      .background {
        if failed {
          RoundedRectangle(cornerRadius: 8).fill(palette.red.opacity(0.09))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.red.opacity(0.2)))
        }
      }
      .overlay(alignment: .bottom) {
        if !failed { Rectangle().fill(palette.paper.opacity(0.07)).frame(height: 1) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("activity.row")
  }

  private func summary(_ row: ActivityInboxDigest.Row) -> String {
    let time = row.updatedAt.formatted(date: .omitted, time: .shortened)
    let lead: String =
      switch row.state {
      case .failed: "Stopped"
      case .cancelled: "Cancelled"
      case .completed:
        row.count > 1 ? "\(row.count) runs finished, last \(time)" : "Finished \(time)"
      case .working, .needsUser: time
      }
    // When the row is named after its agent, the event title still has something to say.
    let event = sourceName(row.deepLink) == nil ? nil : row.title
    let tail = [event, row.detail].compactMap { $0 }.filter { !$0.isEmpty }
    return ([lead] + tail).joined(separator: " · ")
  }

  /// The agent behind a link, so a row reads "Coda" rather than "Work completed".
  private func sourceName(_ link: BotActivityDeepLink) -> String? {
    if case .agent(let nodeID) = link { return agentName(nodeID) ?? "Closed session" }
    return nil
  }

  private func rawRow(_ item: BotActivityItem) -> some View {
    Button {
      openDeepLink(item.deepLink)
    } label: {
      HStack(spacing: 12) {
        Circle().fill(dot(item.state)).frame(width: 8, height: 8)
        Text(sourceName(item.deepLink) ?? item.title)
          .font(.ottoDisplay(12.5).weight(.semibold)).lineLimit(1)
          .frame(width: 220, alignment: .leading)
        Text(
          [sourceName(item.deepLink) == nil ? nil : item.title, item.detail]
            .compactMap { $0 }.joined(separator: " · ")
        )
        .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted).lineLimit(1)
        Spacer(minLength: 12)
        Text(item.updatedAt, style: .relative).font(.ottoMono(8.5)).foregroundStyle(palette.muted)
      }
      .padding(.horizontal, 14)
      .frame(height: 38)
      .overlay(alignment: .bottom) {
        Rectangle().fill(palette.paper.opacity(0.07)).frame(height: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func dot(_ state: BotActivityState) -> Color {
    switch state {
    case .completed: palette.signal
    case .failed: palette.red
    case .needsUser: palette.cyan
    case .working: palette.amber
    case .cancelled: palette.muted
    }
  }

  // MARK: Shared bits

  private func sectionLabel(_ text: String, count: Int, tint: Color) -> some View {
    HStack(spacing: 10) {
      Text(text.uppercased()).font(.ottoMono(8.5, weight: .bold)).tracking(1.2)
        .foregroundStyle(palette.muted)
      if count > 0 {
        Text("\(count)").font(.ottoMono(8.5, weight: .bold)).foregroundStyle(tint)
      }
      Rectangle().fill(palette.paper.opacity(0.07)).frame(height: 1)
    }
    .padding(.bottom, 10)
  }

  private func quietLine(_ text: String) -> some View {
    Text(text).font(.ottoDisplay(11.5)).foregroundStyle(palette.muted)
      .padding(.horizontal, 14).padding(.vertical, 8)
  }

  @ViewBuilder private var searchResults: some View {
    if results.isEmpty {
      ContentUnavailableView.search(text: query).foregroundStyle(palette.muted)
    }
    ForEach(results) { result in
      Button {
        openDeepLink(result.deepLink)
      } label: {
        HStack(alignment: .top, spacing: 12) {
          Text(result.kind.rawValue.uppercased())
            .font(.ottoMono(8, weight: .bold)).tracking(1.2).foregroundStyle(palette.cyan)
            .frame(width: 60, alignment: .leading).padding(.top, 3)
          VStack(alignment: .leading, spacing: 3) {
            Text(result.title).font(.ottoDisplay(13).weight(.semibold))
            Text(result.excerpt).font(.ottoDisplay(11.5)).foregroundStyle(palette.muted)
              .lineLimit(2)
          }
          Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) {
          Rectangle().fill(palette.paper.opacity(0.07)).frame(height: 1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }
}
