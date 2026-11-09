import OttoModels
import OttoServices
import SwiftUI

/// Every skill on this Mac in one place: Otto's own shared skills, plus the ones each harness
/// (Claude Code, Codex, Hermes…) already has, with where each lives and how often it is used.
struct SkillsView: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var library: SkillLibraryStore
  @Environment(\.ottoPalette) private var palette
  @State private var filter: SkillSource?
  @State private var query = ""
  @State private var selectedName: String?

  init(services: ApplicationServices, library: SkillLibraryStore, selected: String? = nil) {
    self.services = services
    self.library = library
    _selectedName = State(initialValue: selected)
  }
  @State private var creating = false
  @State private var error: String?

  private var visible: [SkillEntry] {
    library.entries.filter { entry in
      (filter == nil || entry.sources.contains(filter!))
        && (query.isEmpty || entry.name.localizedCaseInsensitiveContains(query)
          || entry.description.localizedCaseInsensitiveContains(query))
    }
  }

  private var selected: SkillEntry? {
    library.entries.first { $0.name == selectedName }
  }

  var body: some View {
    HStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          header
          sourceChips
          searchField
          if let error {
            Text(error).font(.ottoDisplay(12)).foregroundStyle(palette.red)
          }
          if library.entries.isEmpty, library.isScanning {
            ProgressView().controlSize(.small)
          } else if visible.isEmpty {
            Text(query.isEmpty ? "No skills here yet." : "No skills match “\(query)”.")
              .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
          } else {
            LazyVStack(spacing: 6) {
              ForEach(visible) { entry in row(entry) }
            }
          }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: 1000, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
      if let selected {
        detail(selected).frame(width: 420)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .foregroundStyle(palette.paper)
    .onAppear { library.refresh() }
    .sheet(isPresented: $creating) {
      NewSkillSheet { name, description, instructions in
        attempt {
          try library.create(name: name, description: description, instructions: instructions)
        }
      }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Skills").font(.ottoDisplay(26).weight(.semibold))
        Text(
          "Instructions your bots, teams and sessions load only when a task needs them. Otto skills work in every harness."
        )
        .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
      }
      Spacer()
      Button {
        creating = true
      } label: {
        Label("New skill", systemImage: "plus")
          .font(.ottoDisplay(12.5).weight(.semibold))
          .padding(.horizontal, 12).padding(.vertical, 6)
      }
      .buttonStyle(.ottoPrimary(cornerRadius: 8))
      .accessibilityIdentifier("skills.new")
    }
  }

  private var sourceChips: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        chip(nil, title: "All", count: library.entries.count)
        ForEach(SkillSource.allCases) { source in
          let count = library.entries.filter { $0.sources.contains(source) }.count
          if count > 0 || source == .otto {
            chip(source, title: label(source), count: count)
          }
        }
      }
    }
    .scrollIndicators(.hidden)
  }

  private func chip(_ source: SkillSource?, title: String, count: Int) -> some View {
    let active = filter == source
    return Button {
      filter = source
    } label: {
      HStack(spacing: 6) {
        Text(title).font(.ottoDisplay(12.5).weight(active ? .semibold : .regular))
        Text("\(count)").font(.ottoDisplay(11).monospacedDigit()).foregroundStyle(palette.muted)
      }
      .padding(.horizontal, 10).padding(.vertical, 5)
      .background(
        active ? palette.raised : palette.raised.opacity(0.6),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(palette.muted)
      TextField("Search skills", text: $query).textFieldStyle(.plain).font(.ottoDisplay(13))
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(
      palette.raised.opacity(0.8), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .frame(maxWidth: 360)
  }

  private func row(_ entry: SkillEntry) -> some View {
    let active = entry.name == selectedName
    return HStack(alignment: .top, spacing: 12) {
      Button {
        withAnimation(.easeOut(duration: 0.18)) {
          selectedName = active ? nil : entry.name
        }
      } label: {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: entry.isInOtto ? "sparkles" : "doc.text")
            .font(.system(size: 13))
            .foregroundStyle(entry.isInOtto ? palette.signal : palette.muted)
            .frame(width: 18).padding(.top, 2)
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.name).font(.ottoDisplay(14).weight(.semibold))
            if !entry.description.isEmpty {
              Text(entry.description).font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
                .lineLimit(2).multilineTextAlignment(.leading)
            }
            HStack(spacing: 5) {
              ForEach(entry.sources) { badge($0) }
            }
          }
          Spacer(minLength: 12)
          usageLabel(entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      shareSwitch(entry, compact: true).padding(.top, 1)
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(
      active ? palette.raised : palette.raised.opacity(0.8),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(palette.signal.opacity(active ? 0.6 : 0), lineWidth: 1))
  }

  /// One switch for "let every agent use this": on copies a harness's skill into Otto's library,
  /// off sends Otto's copy to the Trash. Skills written in Otto are always shared.
  @ViewBuilder private func shareSwitch(_ entry: SkillEntry, compact: Bool) -> some View {
    let ottoOnly = entry.isInOtto && !library.canStopSharing(entry)
    VStack(alignment: .trailing, spacing: 2) {
      Toggle(
        isOn: Binding(
          get: { entry.isInOtto },
          set: { on in
            attempt { on ? try library.addToOtto(entry) : try library.stopSharing(entry) }
          })
      ) {
        Text("All agents").font(.ottoDisplay(compact ? 11.5 : 12.5).weight(.medium))
      }
      .toggleStyle(.ottoSwitch)
      .disabled(ottoOnly)
      .help(
        ottoOnly
          ? "Written in Otto, so every agent can always use it."
          : entry.isInOtto
            ? "Every bot, team and session can use this. Turn off to keep it in \(harnessNames(entry)) only."
            : "Let every bot, team and session use this, in Codex, Claude Code, Otto Harness and the rest."
      )
      .accessibilityIdentifier("skills.share.\(entry.name)")
    }
    .fixedSize()
  }

  private func harnessNames(_ entry: SkillEntry) -> String {
    let names = entry.sources.filter { $0 != .otto }.map(\.title)
    return names.isEmpty ? "its harness" : ListFormatter.localizedString(byJoining: names)
  }

  /// Otto's own library is what every agent shares, so it is named for what it does.
  private func label(_ source: SkillSource) -> String {
    source == .otto ? "All agents" : source.title
  }

  private func badge(_ source: SkillSource) -> some View {
    Text(label(source))
      .font(.ottoDisplay(10.5).weight(.medium))
      .foregroundStyle(source == .otto ? palette.onSignal : palette.paper.opacity(0.8))
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(
        Capsule().fill(source == .otto ? palette.signal : palette.paper.opacity(0.08)))
  }

  @ViewBuilder private func usageLabel(_ entry: SkillEntry) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      if entry.uses > 0 {
        Text("Used \(entry.uses)×").font(.ottoDisplay(12).weight(.medium))
        if let last = entry.lastUsed {
          Text(last, format: .relative(presentation: .named))
            .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
        }
      } else {
        Text("Not used lately").font(.ottoDisplay(11.5)).foregroundStyle(palette.muted)
      }
    }
  }

  private func detail(_ entry: SkillEntry) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline) {
          Text(entry.name).font(.ottoDisplay(18).weight(.semibold))
          Spacer()
          Button {
            withAnimation(.easeOut(duration: 0.18)) { selectedName = nil }
          } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
          }
          .buttonStyle(.plain).foregroundStyle(palette.muted)
        }
        if !entry.description.isEmpty {
          Text(entry.description).font(.ottoDisplay(13)).foregroundStyle(palette.muted)
        }
        VStack(alignment: .leading, spacing: 6) {
          shareSwitch(entry, compact: false)
          Text(
            entry.isInOtto
              ? (library.canStopSharing(entry)
                ? "Every bot, team and session can use this, whichever harness it runs on. Otto keeps its own copy; the \(harnessNames(entry)) copy stays as it is."
                : "Written in Otto, so every bot, team and session can use it.")
              : "Only \(harnessNames(entry)) can use this today. Turn on All agents to let every bot, team and session use it too, in Codex, Claude Code, Otto Harness and the rest."
          )
          .font(.ottoDisplay(11.5)).foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)
        }
        if entry.isInOtto {
          audiencePicker(entry)
        }
        section("Found in") {
          ForEach(entry.locations, id: \.self) { location in
            VStack(alignment: .leading, spacing: 1) {
              Text(location.source == .otto ? "Otto library" : location.source.title)
                .font(.ottoDisplay(12).weight(.medium))
              Text(abbreviated(location.path)).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.muted).textSelection(.enabled).lineLimit(2)
            }
          }
        }
        section("Instructions") {
          Text(SkillParser.body(library.text(of: entry)))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(palette.paper.opacity(0.85))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(20)
    }
    .scrollIndicators(.hidden)
    .background(palette.paneSurface)
    .overlay(alignment: .leading) {
      Rectangle().fill(palette.paper.opacity(0.08)).frame(width: 1)
    }
  }

  private func audiencePicker(_ entry: SkillEntry) -> some View {
    let audience = library.audience(of: entry)
    let bots = services.agentProfileList
    return section("Available to") {
      Menu {
        Button("All bots, teams and sessions") { library.setAudience(.everyone, for: entry) }
        if !bots.isEmpty {
          Divider()
          ForEach(bots) { bot in
            Button(bot.name) { library.setAudience(.bots([bot.id]), for: entry) }
          }
        }
      } label: {
        Text(audienceTitle(audience, bots: bots)).font(.ottoDisplay(12.5))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
  }

  private func audienceTitle(_ audience: SkillAudience, bots: [AgentProfile]) -> String {
    switch audience {
    case .everyone: return "All bots, teams and sessions"
    case .bots(let ids):
      let names = bots.filter { ids.contains($0.id) }.map(\.name)
      return names.isEmpty ? "No bots" : names.joined(separator: ", ")
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased()).font(.ottoDisplay(10.5).weight(.semibold))
        .foregroundStyle(palette.muted).tracking(0.6)
      content()
    }
  }

  private func abbreviated(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  private func attempt(_ work: () throws -> Void) {
    do {
      try work()
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

private struct NewSkillSheet: View {
  let create: (String, String, String) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.ottoPalette) private var palette
  @State private var name = ""
  @State private var description = ""
  @State private var instructions = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New skill").font(.ottoDisplay(18).weight(.semibold))
      TextField("Name, e.g. weekly-linkedin-report", text: $name)
      TextField("When to use it, in one line", text: $description)
      Text("Instructions").font(.ottoDisplay(12)).foregroundStyle(palette.muted)
      TextEditor(text: $instructions)
        .font(.system(size: 12, design: .monospaced))
        .frame(minHeight: 180)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Create") {
          create(name, description, instructions)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 520)
  }
}
