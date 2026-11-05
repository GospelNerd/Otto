import Foundation

/// Where the `agent-desktop` CLI (vercel-labs/agent-desktop) lives on this Mac. It reads native
/// apps through the accessibility tree so bots can operate Mail, Notes, Finder and the rest
/// without screenshots. Otto spawns it from the app process, so the macOS Accessibility grant
/// belongs to Otto itself and covers every harness Otto runs.
public enum AgentDesktopLocator {
  /// Points Otto at a specific binary, for development builds or an unusual install.
  public static let environmentOverride = "OTTO_AGENT_DESKTOP"

  public static func executablePath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: String = NSHomeDirectory(),
    fileManager: FileManager = .default
  ) -> String? {
    if let override = environment[environmentOverride], !override.isEmpty,
      fileManager.isExecutableFile(atPath: override)
    {
      return override
    }
    return searchDirectories(homeDirectory: homeDirectory, fileManager: fileManager)
      .map { "\($0)/agent-desktop" }
      .first { fileManager.isExecutableFile(atPath: $0) }
  }

  public static var isInstalled: Bool { executablePath() != nil }

  /// Homebrew first, then the npm-style global installs. An agent shell inherits a richer PATH
  /// than the app, so the list is explicit rather than read from the environment.
  public static func searchDirectories(homeDirectory: String, fileManager: FileManager) -> [String] {
    var directories = [
      "/opt/homebrew/bin", "/usr/local/bin", "\(homeDirectory)/.local/bin",
      "\(homeDirectory)/.npm-global/bin", "\(homeDirectory)/.volta/bin",
      "\(homeDirectory)/.bun/bin",
    ]
    let nvmRoot = "\(homeDirectory)/.nvm/versions/node"
    let nvmVersions = ((try? fileManager.contentsOfDirectory(atPath: nvmRoot)) ?? [])
      .filter { $0.hasPrefix("v") }
      .sorted { lhs, rhs in
        rhs.dropFirst().split(separator: ".").compactMap { Int($0) }
          .lexicographicallyPrecedes(lhs.dropFirst().split(separator: ".").compactMap { Int($0) })
      }
    directories += nvmVersions.map { "\(nvmRoot)/\($0)/bin" }
    return directories
  }

  /// Snapshots, refmaps and traces hold private desktop content, so they stay in Application
  /// Support rather than in a workspace folder that may sync to iCloud.
  public static func stateRoot(fileManager: FileManager = .default) -> URL {
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return base.appending(path: "Otto/Desktop", directoryHint: .isDirectory)
  }

  /// The one-line install a person can run themselves.
  public static let installCommand = "brew install agent-desktop"
}
