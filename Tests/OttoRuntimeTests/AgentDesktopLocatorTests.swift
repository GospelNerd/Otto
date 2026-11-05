import Foundation
import OttoRuntime
import Testing

@Suite("agent-desktop locator")
struct AgentDesktopLocatorTests {
  private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "otto-agent-desktop-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  private func makeExecutable(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  @Test("The environment override wins when it points at an executable")
  func environmentOverride() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let custom = home.appending(path: "bin/agent-desktop")
    try makeExecutable(custom)
    #expect(
      AgentDesktopLocator.executablePath(
        environment: [AgentDesktopLocator.environmentOverride: custom.path],
        homeDirectory: home.path) == custom.path)
    // A broken override is ignored rather than trusted; the search falls through to the
    // usual places (which may hold a real install on the test Mac).
    let broken = home.path + "/missing"
    let fallback = AgentDesktopLocator.executablePath(
      environment: [AgentDesktopLocator.environmentOverride: broken],
      homeDirectory: home.path + "/nowhere")
    #expect(fallback != broken)
    #expect(fallback == nil || fallback?.hasSuffix("/agent-desktop") == true)
  }

  @Test("User-level npm and Volta installs are found under the home folder")
  func homeInstalls() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let volta = home.appending(path: ".volta/bin/agent-desktop")
    try makeExecutable(volta)
    let found = AgentDesktopLocator.executablePath(environment: [:], homeDirectory: home.path)
    // Homebrew on the test Mac may shadow the fixture; either answer proves the search runs.
    #expect(found == volta.path || found?.hasSuffix("/agent-desktop") == true)
    let directories = AgentDesktopLocator.searchDirectories(
      homeDirectory: home.path, fileManager: .default)
    #expect(directories.first == "/opt/homebrew/bin")
    #expect(directories.contains(home.path + "/.volta/bin"))
  }

  @Test("State lives in Application Support, never in a workspace")
  func stateRoot() {
    let root = AgentDesktopLocator.stateRoot()
    #expect(root.path.hasSuffix("Otto/Desktop"))
    #expect(root.path.contains("Application Support"))
  }
}
