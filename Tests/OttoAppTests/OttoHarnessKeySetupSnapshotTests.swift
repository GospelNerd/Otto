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

/// Opt-in renders of the New session menu and the "No API key added" sheet, for design review.
/// Set OTTO_HARNESS_SNAPSHOT_DIR to a folder to write PNGs there.
@Suite("Otto Harness key setup snapshots")
struct OttoHarnessKeySetupSnapshotTests {
  @Test @MainActor func renderMenuAndSheet() throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_HARNESS_SNAPSHOT_DIR"] else {
      return
    }
    try FileManager.default.createDirectory(
      atPath: output, withIntermediateDirectories: true)
    let workspace = FileManager.default.temporaryDirectory.appending(path: "harness-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let canvas = CanvasStore()
    let agent = try #require(
      canvas.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    canvas.dispatch(.renameNode(id: agent, name: "Research session"))
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let voice = VoiceController(
      registry: ToolRegistry(), store: canvas, services: services,
      workspacePath: workspace.path, secrets: InMemorySecretStore())

    for themeID in ["nightspire", "field-notes"] {
      canvas.dispatch(.setTheme(themeID))
      let theme = OttoThemeCatalog.theme(id: themeID)
      let view = ZStack {
        ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
        ChatWorkspaceView(
          store: canvas, services: services, voice: voice,
          navigation: .constant(
            ChatSurfaceNavigationState(
              selectedAgentID: agent, selectedSessionID: agent,
              sessionCanvasID: canvas.activeCanvas.id)),
          launchAgent: {}, showingSessionCreator: true)
      }
      .environmentObject(services.messageQueue)
      .environment(\.ottoPalette, OttoPalette(theme: theme))
      try render(
        view, size: CGSize(width: 1280, height: 820),
        to: "\(output)/new-session-menu-\(themeID).png", light: theme.isLightAppearance)
    }

    let theme = OttoThemeCatalog.theme(id: "nightspire")
    let sheet = OttoHarnessKeySetupSheet(
      services: services, secrets: InMemorySecretStore(), cancel: {}, ready: {}
    )
    .environment(\.ottoPalette, OttoPalette(theme: theme))
    try render(sheet, size: CGSize(width: 625, height: 700), to: "\(output)/no-api-key-sheet.png")
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
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }
}
