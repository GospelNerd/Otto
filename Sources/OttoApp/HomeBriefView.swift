import AppKit
import OttoModels
import SwiftUI

/// The daily brief as boxes: Your day across the top, then Top to-dos and New updates side by
/// side, each scrolling on its own. Sections without items are omitted rather than shown empty.
struct HomeBriefView: View {
  let brief: DailyBrief
  let now: Date
  /// To-dos and updates sit next to each other when Home is wide enough.
  var sideBySide = true
  @Binding var addingTodo: Bool
  let complete: (BriefItem) -> Void
  let dismiss: (BriefItem) -> Void
  let addTodo: (String) throws -> Void
  let perform: (BriefAction) -> Void
  let prep: (BriefItem) -> Void
  /// Hands an item to an agent to action: nil starts a new session, a bot ID asks that bot.
  var workOn: (BriefItem, UUID?) -> Void = { _, _ in }
  /// Bots offered in an item's menu.
  var bots: [(id: UUID, name: String)] = []

  @State private var newTodo = ""
  @State private var addError: String?
  @State private var selectedEventID: String?
  @State private var hoveredItemID: String?
  @FocusState private var todoFieldFocused: Bool

  @Environment(\.ottoPalette) private var palette
  private var muted: Color { palette.muted }
  private var accent: Color { palette.signal }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if !brief.events.isEmpty { day }
      let showsTodos = !brief.todos.isEmpty || addingTodo
      let showsUpdates = !brief.updates.isEmpty
      if showsTodos || showsUpdates {
        if sideBySide && showsTodos && showsUpdates {
          HStack(alignment: .top, spacing: 14) {
            todos.frame(maxHeight: .infinity, alignment: .top)
            updates.frame(maxHeight: .infinity, alignment: .top)
          }
          .fixedSize(horizontal: false, vertical: true)
        } else {
          if showsTodos { todos }
          if showsUpdates { updates }
        }
      }
      if brief.completedTodayCount > 0 {
        Text("\(brief.completedTodayCount) done today")
          .font(.ottoDisplay(10)).foregroundStyle(muted)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    // Card text defaults to the card palette, never the page's photo-dependent colour.
    .foregroundStyle(palette.paper)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Today’s brief")
  }

  // MARK: Boxes

  /// A titled card. Its list scrolls on its own once it is taller than `maxListHeight`, so a busy
  /// day never pushes the rest of Home out of reach.
  private func box<Header: View, Content: View, Footer: View>(
    _ title: String, count: Int?, @ViewBuilder header: () -> Header,
    @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: () -> Footer
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        label(title)
        if let count, count > 0 {
          Text("\(count)").font(.ottoMicro).foregroundStyle(muted)
        }
        Spacer()
        header()
      }
      ViewThatFits(in: .vertical) {
        list(content)
        // Legacy scroll bars would reserve a gutter and clip the right edge; the fade already
        // says there is more.
        ScrollView(.vertical) { list(content) }
          .scrollIndicators(.never)
          .mask(
            LinearGradient(
              stops: [
                .init(color: .white, location: 0), .init(color: .white, location: 0.88),
                .init(color: palette.paper.opacity(0.15), location: 1),
              ], startPoint: .top, endPoint: .bottom))
      }
      .frame(maxHeight: Self.maxListHeight, alignment: .top)
      footer()
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .ottoGlass(cornerRadius: 16)
  }

  private func list<Content: View>(_ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 18, content: content)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static let maxListHeight: CGFloat = 300

  private func label(_ title: String) -> some View {
    Text(title)
      .font(.ottoDisplay(15).weight(.semibold))
      .foregroundStyle(palette.paper.opacity(0.92))
      .accessibilityAddTraits(.isHeader)
  }

  private var todos: some View {
    box(
      "Top to-dos", count: brief.todos.count,
      header: {
        if !addingTodo {
          Button {
            addingTodo = true
          } label: {
            Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(muted)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Add a to-do")
          .help("Add a to-do")
        }
      },
      content: { ForEach(brief.todos) { item in todoRow(item) } },
      footer: {
        if addingTodo {
          HStack(spacing: 12) {
            Image(systemName: "circle").font(.system(size: 17, weight: .light))
              .foregroundStyle(muted)
            TextField("Add a to-do and press Return", text: $newTodo)
              .textFieldStyle(.plain)
              .font(.ottoDisplay(14))
              .focused($todoFieldFocused)
              .onSubmit(submitTodo)
              .onExitCommand { cancelAdd() }
              .accessibilityLabel("New to-do")
            Button("Cancel", action: cancelAdd).buttonStyle(.plain)
              .font(.ottoDisplay(10)).foregroundStyle(muted)
          }
          .onAppear { todoFieldFocused = true }
          if let addError {
            Text(addError).font(.ottoDisplay(11)).foregroundStyle(.orange)
          }
        } else if brief.todos.isEmpty {
          Text("Nothing open.").font(.ottoDisplay(12)).foregroundStyle(muted)
        }
      })
  }

  private func todoRow(_ item: BriefItem) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Button {
        withAnimation(.easeOut(duration: 0.2)) { complete(item) }
      } label: {
        Image(systemName: "circle")
          .font(.system(size: 17, weight: .light))
          .foregroundStyle(item.needsYou ? accent : muted)
          .frame(width: 20, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(item.origin == .otto ? "Clear \(item.title)" : "Mark \(item.title) done")
      .help(item.origin == .otto ? "Clear from today’s brief" : "Mark done")
      itemBody(item, trailingTag: deadline(item))
    }
  }

  private var day: some View {
    let selected = brief.events.first { $0.id == selectedEventID } ?? nextEvent
    return box(
      "Your day", count: brief.events.count, header: { EmptyView() },
      content: {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 22) {
            eventList(selected: selected).frame(width: 240)
            if let selected { eventDetail(selected) }
          }
          VStack(alignment: .leading, spacing: 16) {
            eventList(selected: selected)
            if let selected { eventDetail(selected) }
          }
        }
      }, footer: { EmptyView() })
  }

  private var nextEvent: BriefItem? {
    brief.events.first { ($0.endTime ?? $0.time ?? now) > now } ?? brief.events.first
  }

  private func eventList(selected: BriefItem?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(brief.events) { event in
        Button {
          selectedEventID = event.id
        } label: {
          HStack(spacing: 12) {
            Text(event.time.map(timeLabel) ?? "")
              .font(.ottoMono(10)).foregroundStyle(muted).frame(width: 46, alignment: .leading)
            Text(event.title).font(.ottoDisplay(12).weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 10).padding(.vertical, 8)
          .background(
            event.id == selected?.id ? palette.paper.opacity(0.07) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.title) at \(event.time.map(timeLabel) ?? "unknown time")")
        .accessibilityAddTraits(event.id == selected?.id ? .isSelected : [])
      }
    }
  }

  private func eventDetail(_ event: BriefItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(eventHeading(event)).font(.ottoDisplay(15).weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      if let reason = event.reason {
        Text(reason).font(.ottoDisplay(12)).foregroundStyle(muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !event.people.isEmpty {
        Label(event.people.joined(separator: ", "), systemImage: "person.2")
          .font(.ottoDisplay(11)).foregroundStyle(muted).lineLimit(2)
      }
      HStack(spacing: 14) {
        Button {
          prep(event)
        } label: {
          Label("Prep me", systemImage: "sparkles").font(.ottoDisplay(11).weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(accent.opacity(0.16), in: Capsule())
            .foregroundStyle(accent)
        }
        .buttonStyle(.plain)
        .help("Put a prep request in the composer")
        if let action = event.action { actionButton(action, title: "Open") }
        if let source = event.source {
          Text(source).font(.ottoDisplay(11)).foregroundStyle(muted)
        }
      }
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var updates: some View {
    box(
      "New updates", count: brief.updates.count, header: { EmptyView() },
      content: {
        ForEach(Array(brief.updates.enumerated()), id: \.element.id) { index, item in
          HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", index + 1))
              .font(.ottoMono(10)).foregroundStyle(muted.opacity(0.7))
              .frame(width: 20, alignment: .leading)
              .padding(.top, 3)
            itemBody(
              item,
              trailingTag: item.needsYou
                ? Text("NEEDS YOU").foregroundStyle(accent)
                : Text("FYI").foregroundStyle(muted.opacity(0.8)))
          }
        }
      }, footer: { EmptyView() })
  }

  // MARK: Item

  private func itemBody(_ item: BriefItem, trailingTag: Text?) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        let title = Text(item.title).font(.ottoDisplay(14).weight(.semibold))
          .foregroundStyle(palette.paper.opacity(0.94))
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        // Clicking an item gets it done: Otto's own items open where they live; anything
        // from your tools goes to an agent that works on it with you.
        Button {
          primaryAction(item)
        } label: {
          title
        }
        .buttonStyle(.plain)
        .help(opensInPlace(item) ? "Open" : "Work on this with an agent")
        Spacer(minLength: 8)
        Menu {
          if case .some(let action) = item.action, opensInPlace(item) {
            Button("Open") { perform(action) }
          }
          Button("Work on this in a new session") { workOn(item, nil) }
          if !bots.isEmpty {
            Section("Hand to a bot") {
              ForEach(bots, id: \.id) { bot in
                Button("Ask \(bot.name)") { workOn(item, bot.id) }
              }
            }
          }
          if case .openURL(let url) = item.action {
            Button("Open original") { perform(.openURL(url)) }
          }
          if case .stopAgent(let id) = item.secondaryAction {
            Button("Stop it") { perform(.stopAgent(id)) }
          }
          Divider()
          if item.kind == .todo {
            Button(item.origin == .otto ? "Clear" : "Mark done") { complete(item) }
          }
          Button("Not useful — remove") { dismiss(item) }
        } label: {
          Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(muted)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .opacity(hoveredItemID == item.id ? 1 : 0)
        .accessibilityLabel("Options for \(item.title)")
      }
      if let reason = item.reason {
        Text(reason).font(.ottoDisplay(12)).foregroundStyle(muted).lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      // Where it came from, who is involved and when, on one quiet line.
      HStack(spacing: 6) {
        if let source = item.source {
          Text(source.uppercased()).foregroundStyle(muted.opacity(0.9))
        }
        if !item.people.isEmpty {
          if item.source != nil { Text("·").foregroundStyle(muted.opacity(0.5)) }
          Text(item.people.joined(separator: ", ").uppercased()).foregroundStyle(muted.opacity(0.8))
        }
        Spacer(minLength: 8)
        if let trailingTag { trailingTag }
      }
      // Metadata as small tracked mono caps, so titles and reasons carry the weight.
      .font(.ottoMicro)
      .tracking(1.6)
      .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onHover { inside in
      if inside { hoveredItemID = item.id } else if hoveredItemID == item.id { hoveredItemID = nil }
    }
  }

  private func opensInPlace(_ item: BriefItem) -> Bool {
    switch item.action {
    case .openAgent, .openActivity, .openRoutine, .stopAgent: true
    case .openURL, nil: false
    }
  }

  private func primaryAction(_ item: BriefItem) {
    if case .some(let action) = item.action, opensInPlace(item) {
      perform(action)
    } else {
      workOn(item, nil)
    }
  }

  private func actionButton(_ action: BriefAction, title: String) -> some View {
    Button {
      perform(action)
    } label: {
      Label(title, systemImage: "arrow.up.right").font(.ottoDisplay(11)).foregroundStyle(muted)
    }
    .buttonStyle(.plain)
  }

  private func deadline(_ item: BriefItem) -> Text? {
    guard let time = item.time else { return nil }
    let calendar = Calendar.current
    let text =
      calendar.isDate(time, inSameDayAs: now)
      ? "Due \(timeLabel(time))"
      : "Due \(time.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
    return Text(text.uppercased()).foregroundStyle(time < now ? .orange : muted)
  }

  private func eventHeading(_ event: BriefItem) -> String {
    guard let start = event.time else { return event.title }
    let range = event.endTime.map { "\(timeLabel(start)) – \(timeLabel($0))" } ?? timeLabel(start)
    return "\(event.title) — \(range)"
  }

  private func timeLabel(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
  }

  private func submitTodo() {
    do {
      try addTodo(newTodo)
      newTodo = ""
      addError = nil
      todoFieldFocused = true
    } catch {
      addError = error.localizedDescription
    }
  }

  private func cancelAdd() {
    newTodo = ""
    addError = nil
    addingTodo = false
  }
}
