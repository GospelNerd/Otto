import Foundation
import OttoRuntime
import OttoTools

/// One finished `agent-desktop` call: its exit status and the JSON envelope it printed.
public struct DesktopCommandResult: Sendable, Equatable {
  public var exitCode: Int32
  public var envelope: JSONValue?
  public var standardError: String

  public init(exitCode: Int32, envelope: JSONValue?, standardError: String = "") {
    self.exitCode = exitCode
    self.envelope = envelope
    self.standardError = standardError
  }
}

public enum DesktopControlError: Error, LocalizedError, Equatable, Sendable {
  case notInstalled
  case launchFailed(String)
  case timedOut(String)
  case unreadableOutput(String)

  public var errorDescription: String? {
    switch self {
    case .notInstalled:
      "Desktop control is not set up: the agent-desktop CLI is not installed. Ask the person to "
        + "open Otto's Settings, choose Desktop control and click Install (or run "
        + "`\(AgentDesktopLocator.installCommand)`), then try again."
    case .launchFailed(let detail): "Otto could not start agent-desktop: \(detail)"
    case .timedOut(let command): "agent-desktop \(command) did not finish in time"
    case .unreadableOutput(let detail):
      "agent-desktop returned something Otto could not read: \(detail)"
    }
  }
}

/// Runs `agent-desktop` commands. The tools talk to this so tests can hand them a fake.
public protocol DesktopCommandRunning: Sendable {
  /// Where the CLI is, or nil when it is not installed.
  func executablePath() async -> String?
  func run(_ arguments: [String], timeout: Duration) async throws -> DesktopCommandResult
}

/// The real runner: one process per call, as upstream recommends, with a minimal environment
/// and Otto's own state root so refmaps and traces never land in a synced workspace folder.
public struct AgentDesktopRunner: DesktopCommandRunning {
  private let homeDirectory: String
  private let environmentOverrides: [String: String]

  public init(
    homeDirectory: String = NSHomeDirectory(), environmentOverrides: [String: String] = [:]
  ) {
    self.homeDirectory = homeDirectory
    self.environmentOverrides = environmentOverrides
  }

  public func executablePath() async -> String? {
    AgentDesktopLocator.executablePath(homeDirectory: homeDirectory)
  }

  public func run(_ arguments: [String], timeout: Duration) async throws -> DesktopCommandResult {
    guard let executable = AgentDesktopLocator.executablePath(homeDirectory: homeDirectory) else {
      throw DesktopControlError.notInstalled
    }
    let stateRoot = AgentDesktopLocator.stateRoot()
    try? FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var environment = [
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "HOME": homeDirectory,
      "AGENT_DESKTOP_HOME": stateRoot.path,
      "NO_COLOR": "1",
    ]
    environment.merge(environmentOverrides) { _, override in override }
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    do {
      try process.run()
    } catch {
      throw DesktopControlError.launchFailed(error.localizedDescription)
    }

    let timedOut = TimeoutFlag()
    let watchdog = Task {
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled, process.isRunning else { return }
      timedOut.set()
      process.terminate()
      try? await Task.sleep(for: .milliseconds(500))
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    // Drain both pipes before waiting: a large snapshot fills the pipe buffer long before exit.
    async let outputData = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
      .value
    async let errorData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
      .value
    let (stdout, stderr) = await (outputData, errorData)
    while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    watchdog.cancel()
    let command = arguments.first ?? ""
    if timedOut.value { throw DesktopControlError.timedOut(command) }

    let errorText = String(decoding: stderr, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let envelope = try? JSONDecoder().decode(JSONValue.self, from: stdout)
    if envelope == nil, process.terminationStatus != 0 {
      let detail = errorText.isEmpty ? "exit status \(process.terminationStatus)" : errorText
      throw DesktopControlError.unreadableOutput(String(detail.suffix(400)))
    }
    return DesktopCommandResult(
      exitCode: process.terminationStatus, envelope: envelope, standardError: errorText)
  }
}

private final class TimeoutFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flagged = false
  func set() {
    lock.lock()
    flagged = true
    lock.unlock()
  }
  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return flagged
  }
}

/// What `agent-desktop status` reports, reduced to what Otto and the person need.
public struct DesktopControlStatus: Codable, Sendable, Equatable {
  public enum Permission: String, Codable, Sendable {
    case granted, denied, unknown
  }

  public var installed: Bool
  public var executable: String?
  public var version: String?
  public var accessibility: Permission
  public var screenRecording: Permission
  /// What stands between the person and a working setup, in one sentence; nil when ready.
  public var setup: String?

  public var isReady: Bool { installed && accessibility == .granted }

  public init(
    installed: Bool, executable: String? = nil, version: String? = nil,
    accessibility: Permission = .unknown, screenRecording: Permission = .unknown,
    setup: String? = nil
  ) {
    self.installed = installed
    self.executable = executable
    self.version = version
    self.accessibility = accessibility
    self.screenRecording = screenRecording
    self.setup = setup
  }

  public static let notInstalled = DesktopControlStatus(
    installed: false,
    setup:
      "Install the agent-desktop CLI: open Otto's Settings, choose Desktop control and click "
      + "Install, or run `\(AgentDesktopLocator.installCommand)`.")

  /// Reads the `status` envelope. A missing permission block means the CLI could not tell.
  public static func parse(_ envelope: JSONValue?, executable: String?) -> DesktopControlStatus {
    let data = envelope?["data"]
    func permission(_ key: String) -> Permission {
      switch data?["permissions"]?[key]?["state"]?.stringValue {
      case "granted": .granted
      case "denied": .denied
      default: .unknown
      }
    }
    let accessibility = permission("accessibility")
    var setup: String?
    if accessibility != .granted {
      setup =
        "Otto needs macOS Accessibility permission before bots can see or operate apps. The "
        + "person grants it once: Otto's Settings, Desktop control, Grant access."
    }
    return DesktopControlStatus(
      installed: true, executable: executable, version: data?["version"]?.stringValue,
      accessibility: accessibility, screenRecording: permission("screen_recording"), setup: setup)
  }
}

extension DesktopCommandRunning {
  public func status() async -> DesktopControlStatus {
    guard let executable = await executablePath() else { return .notInstalled }
    guard let result = try? await run(["status"], timeout: .seconds(15)) else {
      return DesktopControlStatus(
        installed: true, executable: executable,
        setup: "agent-desktop is installed but `agent-desktop status` failed; run it in a "
          + "terminal to see why.")
    }
    return DesktopControlStatus.parse(result.envelope, executable: executable)
  }
}
