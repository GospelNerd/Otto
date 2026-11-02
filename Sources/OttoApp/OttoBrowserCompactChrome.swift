import AppKit
import OttoBrowser
import OttoModels
import SwiftUI

/// Where a browser is shown decides how much chrome it wears. The canvas node keeps its full
/// toolbar; inside Chat the page gets the room, with one row of chrome above it.
enum BrowserChromeStyle {
  /// The canvas node: toolbar, bookmarks, tab sidebar and agent rail.
  case canvas
  /// A work tab beside a conversation: one slim row, plus a way to move the page to Browser.
  case panel(openInBrowser: (() -> Void)?)
  /// Chat's Browser place: tabs across the top, the address inside the active tab.
  case place(aiVisible: Bool, toggleAI: () -> Void, askOtto: (String) -> Void)
}

/// Chat's Browser place: pinned sites, then tabs, with the active tab holding the address so
/// there is no second toolbar row. The look follows Chat's work-panel tabs.
struct OttoBrowserTabStrip: View {
  @Environment(\.ottoPalette) private var palette
  @FocusState private var addressFocused: Bool
  /// True while the open tabs are wider than the room the strip has for them, measured from
  /// the scroll view itself so the "all tabs" control appears exactly when tabs are hidden.
  @State private var tabsOverflow = false
  @Binding var address: String
  let addressFocusRequest: Int
  let session: BrowserSession
  let state: BrowserRuntimeState?
  let pinned: [BrowserBookmark]
  let aiVisible: Bool
  let navigate: (String) -> Void
  let selectTab: (UUID) -> Void
  let closeTab: (UUID) -> Void
  let newTab: () -> Void
  let submit: () -> Void
  let goBack: () -> Void
  let goForward: () -> Void
  let reloadOrStop: () -> Void
  let showImport: () -> Void
  let toggleAI: () -> Void
  var openInNewTab: (String) -> Void = { _ in }
  var pin: (BrowserTab) -> Void = { _ in }
  var unpin: (BrowserBookmark) -> Void = { _ in }

  var body: some View {
    HStack(spacing: 5) {
      HStack(spacing: 2) {
        CompactChromeButton(
          symbol: "chevron.left", help: "Back", disabled: state?.canGoBack != true,
          action: goBack)
        CompactChromeButton(
          symbol: "chevron.right", help: "Forward", disabled: state?.canGoForward != true,
          action: goForward)
        CompactChromeButton(
          symbol: state?.isLoading == true ? "xmark" : "arrow.clockwise",
          help: state?.isLoading == true ? "Stop loading" : "Reload", action: reloadOrStop)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(pinned) { bookmark in
            Button {
              navigate(bookmark.url)
            } label: {
              BrowserFavicon(url: bookmark.url, size: 14)
                .frame(width: 30, height: 30)
                .background(palette.paper.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("\(bookmark.title) — pinned site")
            .accessibilityLabel("\(bookmark.title), pinned site")
            .contextMenu {
              Button("Open") { navigate(bookmark.url) }
              Button("Open in New Tab") { openInNewTab(bookmark.url) }
              Divider()
              Button("Unpin") { unpin(bookmark) }
            }
          }
        }
      }
      .frame(maxWidth: pinned.isEmpty ? 0 : 210)
      .padding(.horizontal, pinned.isEmpty ? 0 : 4)

      if !pinned.isEmpty {
        // Separates pinned sites (shortcuts) from open tabs.
        Rectangle().fill(palette.paper.opacity(0.14)).frame(width: 1, height: 18)
      }

      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 5) {
            ForEach(session.tabs) { tab in
              Group {
                if tab.id == session.activeTabID {
                  activeTab(tab)
                } else {
                  StripTab(tab: tab, select: { selectTab(tab.id) }, close: { closeTab(tab.id) })
                }
              }
              .id(tab.id)
              .contextMenu {
                Button("Pin Site") { pin(tab) }
                  .disabled(
                    !tab.url.hasPrefix("http")
                      || pinned.contains { Self.sameSite($0.url, tab.url) })
                Divider()
                Button("Close Tab") { closeTab(tab.id) }
              }
            }
            Button(action: newTab) {
              Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(palette.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.ottoChrome)
            .foregroundStyle(palette.muted)
            .help("New tab (⌘T)")
            .accessibilityLabel("New tab")
          }
          .padding(.vertical, 2)
        }
        // The edge fade says "more this way"; the flag below adds the all-tabs menu.
        .ottoScrollChrome(axis: .horizontal, fade: 18, showsThumb: false)
        .onScrollGeometryChange(for: Bool.self) { geometry in
          Self.tabsOverflow(
            contentWidth: geometry.contentSize.width,
            containerWidth: geometry.containerSize.width)
        } action: { _, overflows in
          tabsOverflow = overflows
        }
        // A tab chosen anywhere (a click here, ⌘T, ⌃Tab, an agent, a link) is brought into
        // view; `task(id:)` also runs once on appearance, after the first layout.
        .task(id: session.activeTabID) {
          withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(session.activeTabID) }
        }
      }

      if tabsOverflow {
        BrowserAllTabsMenu(
          tabs: session.tabs, activeTabID: session.activeTabID, selectTab: selectTab,
          closeTab: closeTab)
      }

      Spacer(minLength: 4)
      if let tab = session.activeTab {
        let existing = pinned.first { Self.sameSite($0.url, tab.url) }
        Button {
          if let existing { unpin(existing) } else { pin(tab) }
        } label: {
          Image(systemName: existing == nil ? "pin" : "pin.fill")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.ottoChrome)
        .foregroundStyle(palette.paper.opacity(0.7))
        .disabled(!["http", "https"].contains(URL(string: tab.url)?.scheme ?? ""))
        .help(existing == nil ? "Pin site to shortcuts" : "Unpin site from shortcuts")
        .accessibilityLabel(existing == nil ? "Pin site to shortcuts" : "Unpin site from shortcuts")
      }
      BrowserPasswordsButton(tabID: session.activeTabID)

      Button(action: showImport) {
        Image(systemName: "square.and.arrow.down")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.ottoChrome)
      .foregroundStyle(palette.muted)
      .help("Import bookmarks from another browser")
      .accessibilityLabel("Import bookmarks")

      Button(action: toggleAI) {
        HStack(spacing: 5) {
          OttoMark(size: 17)
          Text(aiVisible ? "Hide Otto" : "Ask Otto").font(.ottoDisplay(12).weight(.semibold))
            .foregroundStyle(palette.paper)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(palette.paper.opacity(0.1)))
      }
      .buttonStyle(.plain)
      .keyboardShortcut("j", modifiers: .command)
      .help(aiVisible ? "Hide Otto (⌘J)" : "Ask Otto about this page (⌘J)")
    }
    .padding(.horizontal, 9)
    .frame(height: 44)
    .task(id: addressFocusRequest) {
      guard addressFocusRequest > 0 else { return }
      await Task.yield()
      addressFocused = true
      await Task.yield()
      NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }
  }

  /// Whether the tab row is wider than its viewport. Half a point of slack keeps the control
  /// from flickering on a strip that exactly fits.
  static func tabsOverflow(contentWidth: CGFloat, containerWidth: CGFloat) -> Bool {
    containerWidth > 0 && contentWidth > containerWidth + 0.5
  }

  static func sameSite(_ left: String, _ right: String) -> Bool {
    func host(_ url: String) -> String? {
      URL(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "")
    }
    guard let left = host(left) else { return false }
    return left == host(right)
  }

  private func activeTab(_ tab: BrowserTab) -> some View {
    HStack(spacing: 8) {
      BrowserFavicon(url: tab.url, size: 14)
      TextField(
        addressFocused ? "Search or enter address" : (tab.title.isEmpty ? "New Tab" : tab.title),
        text: $address
      )
      .textFieldStyle(.plain)
      .font(.ottoDisplay(12))
      .foregroundStyle(palette.paper)
      .focused($addressFocused)
      .onSubmit(submit)
      .accessibilityLabel("Address")
      if state?.isLoading == true {
        ProgressView().controlSize(.mini)
      }
      Button {
        closeTab(tab.id)
      } label: {
        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.ottoChrome(cornerRadius: 4))
      .foregroundStyle(palette.muted)
      .help("Close tab (⌘W)")
    }
    .padding(.leading, 10)
    .padding(.trailing, 6)
    .frame(width: 320, height: 30)
    .background(palette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(palette.paper.opacity(addressFocused ? 0.18 : 0.1))
    )
    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
  }
}

/// One row of the all-tabs menu: what the item says and whether it carries the checkmark.
struct BrowserAllTabsItem: Equatable, Identifiable {
  let id: UUID
  let title: String
  let isActive: Bool

  /// Every open tab in strip order, untitled ones named as the strip names them.
  static func items(tabs: [BrowserTab], activeTabID: UUID) -> [BrowserAllTabsItem] {
    tabs.map {
      BrowserAllTabsItem(
        id: $0.id, title: $0.title.isEmpty ? "New Tab" : $0.title, isActive: $0.id == activeTabID)
    }
  }
}

/// The compact control at the end of an overflowing strip: a chevron that lists every open
/// tab, ticks the active one, and switches to the tab you choose.
struct BrowserAllTabsMenu: View {
  @Environment(\.ottoPalette) private var palette
  let tabs: [BrowserTab]
  let activeTabID: UUID
  let selectTab: (UUID) -> Void
  let closeTab: (UUID) -> Void

  var body: some View {
    let items = BrowserAllTabsItem.items(tabs: tabs, activeTabID: activeTabID)
    Menu {
      ForEach(items) { item in
        Toggle(
          item.title,
          isOn: Binding(get: { item.isActive }, set: { _ in selectTab(item.id) }))
      }
      if let active = items.first(where: \.isActive) {
        Divider()
        Button("Close \u{201C}\(active.title)\u{201D}") { closeTab(active.id) }
      }
    } label: {
      // Styled like the Passwords key beside it: the popup rasterises its label as a template
      // image, so `tint` carries the colour and a SwiftUI background would not render.
      Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium))
        .frame(width: 24, height: 28)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .foregroundStyle(palette.muted)
    .tint(palette.muted)
    .fixedSize()
    .help("All tabs (\(tabs.count))")
    .accessibilityLabel("All tabs")
  }
}

private struct StripTab: View {
  @Environment(\.ottoPalette) private var palette
  let tab: BrowserTab
  let select: () -> Void
  let close: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 8) {
      BrowserFavicon(url: tab.url, size: 14)
      Text(tab.title.isEmpty ? "New Tab" : tab.title)
        .font(.ottoDisplay(12))
        .foregroundStyle(palette.muted)
        .lineLimit(1)
      Spacer(minLength: 0)
      Button(action: close) {
        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.ottoChrome(cornerRadius: 4))
      .foregroundStyle(palette.muted)
      .opacity(hovering ? 1 : 0)
      .accessibilityHidden(!hovering)
    }
    .padding(.leading, 10)
    .padding(.trailing, 6)
    .frame(width: 168, height: 30)
    .background(
      palette.ink.opacity(hovering ? 0.32 : 0.2),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .onHover { hovering = $0 }
    .help(tab.url)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(tab.title)
    .accessibilityAddTraits(.isButton)
  }
}

/// A browser work tab beside a conversation: back, forward, reload, the address, and a button
/// that moves the page to Chat's Browser place.
struct OttoBrowserCompactBar: View {
  @Environment(\.ottoPalette) private var palette
  @FocusState private var addressFocused: Bool
  @Binding var address: String
  let addressFocusRequest: Int
  let state: BrowserRuntimeState?
  let goBack: () -> Void
  let goForward: () -> Void
  let reloadOrStop: () -> Void
  let submit: () -> Void
  let openInBrowser: (() -> Void)?

  var body: some View {
    HStack(spacing: 4) {
      CompactChromeButton(
        symbol: "chevron.left", help: "Back", disabled: state?.canGoBack != true, action: goBack)
      CompactChromeButton(
        symbol: "chevron.right", help: "Forward", disabled: state?.canGoForward != true,
        action: goForward)
      CompactChromeButton(
        symbol: state?.isLoading == true ? "xmark" : "arrow.clockwise",
        help: state?.isLoading == true ? "Stop loading" : "Reload", action: reloadOrStop)

      HStack(spacing: 8) {
        BrowserFavicon(url: state?.url ?? address, size: 13)
        TextField("Search or enter address", text: $address)
          .textFieldStyle(.plain)
          .font(.ottoDisplay(12))
          .foregroundStyle(palette.paper)
          .focused($addressFocused)
          .onSubmit(submit)
          .accessibilityLabel("Address")
        if let phase = state?.agentControlPhase {
          HStack(spacing: 5) {
            Circle().fill(palette.signal).frame(width: 6, height: 6)
            Text(phase == .acting ? "Agent driving" : "Agent reading")
              .font(.ottoDisplay(10.5).weight(.medium))
          }
          .foregroundStyle(palette.signal)
          .transition(.opacity)
        } else if state?.isLoading == true {
          ProgressView().controlSize(.mini)
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 28)
      .background(palette.raised.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(palette.paper.opacity(addressFocused ? 0.16 : 0.08)))

      BrowserPasswordsButton(tabID: state?.activeTabID)
      if let openInBrowser {
        Button(action: openInBrowser) {
          Label("Open in Browser", systemImage: "arrow.up.forward.app")
            .font(.ottoDisplay(11.5).weight(.medium))
            .foregroundStyle(palette.paper)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Move this page to Browser, where you keep your own tabs")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .animation(.easeOut(duration: 0.16), value: state?.agentControlPhase)
    .task(id: addressFocusRequest) {
      guard addressFocusRequest > 0 else { return }
      await Task.yield()
      addressFocused = true
      await Task.yield()
      NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }
  }
}

private struct CompactChromeButton: View {
  @Environment(\.ottoPalette) private var palette
  let symbol: String
  let help: String
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.ottoChrome)
    .foregroundStyle(palette.paper.opacity(0.7))
    .disabled(disabled)
    .opacity(disabled ? 0.3 : 1)
    .help(help)
    .accessibilityLabel(help)
  }
}
