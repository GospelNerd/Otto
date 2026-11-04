import AppKit
import OttoCore
import OttoModels
import OttoSecurity
import OttoServices
import OttoTools
import OttoVoice
import SwiftUI
import Testing

@testable import OttoApp

/// Opt-in renders of the Skills place from this Mac's real skill folders, for design review.
/// Set OTTO_SKILLS_SNAPSHOT_DIR (and optionally OTTO_SKILLS_SNAPSHOT_THEME) to write PNGs.
@Suite("Skills snapshots")
struct SkillsSnapshotTests {
  @Test @MainActor func renderSkillsPlace() async throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_SKILLS_SNAPSHOT_DIR"] else {
      return
    }
    let themeID = ProcessInfo.processInfo.environment["OTTO_SKILLS_SNAPSHOT_THEME"] ?? "halcyon"
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    let workspace = FileManager.default.temporaryDirectory.appending(path: "skills-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let canvas = CanvasStore()
    canvas.dispatch(.setTheme(themeID))
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let voice = VoiceController(
      registry: ToolRegistry(), store: canvas, services: services,
      workspacePath: workspace.path, secrets: InMemorySecretStore())
    services.skills.refresh()
    for _ in 0..<300 where services.skills.entries.isEmpty {
      try await Task.sleep(for: .milliseconds(50))
    }
    let theme = OttoThemeCatalog.theme(id: themeID)
    let palette = OttoPalette(theme: theme)

    let place = ZStack {
      ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
      ChatWorkspaceView(
        store: canvas, services: services, voice: voice,
        navigation: .constant(ChatSurfaceNavigationState(destination: .skills)),
        launchAgent: {})
    }
    .environmentObject(services.messageQueue)
    .environment(\.ottoPalette, palette)
    try render(place, size: CGSize(width: 1440, height: 900), to: "\(output)/skills-\(themeID).png",
      light: theme.isLightAppearance)

    let used = services.skills.entries.first { $0.uses > 0 } ?? services.skills.entries.first
    let detail = ZStack {
      ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
      SkillsView(services: services, library: services.skills, selected: used?.name)
    }
    .environment(\.ottoPalette, palette)
    try render(detail, size: CGSize(width: 1280, height: 860),
      to: "\(output)/skills-detail-\(themeID).png", light: theme.isLightAppearance)
  }

  @MainActor private func render<V: View>(
    _ view: V, size: CGSize, to path: String, light: Bool = false
  ) throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }
}
