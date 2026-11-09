import AppKit
import ApplicationServices
import OttoApplicationTools
import OttoRuntime
import SwiftUI

/// Whether desktop control works from this app process, answered without launching anything.
/// Otto spawns agent-desktop itself, so macOS attributes the Accessibility grant to Otto, and
/// `AXIsProcessTrusted` is the same answer the CLI gets.
enum DesktopControlReadiness {
  static var isInstalled: Bool { AgentDesktopLocator.isInstalled }
  static var hasAccessibility: Bool { AXIsProcessTrusted() }
  static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
  static var isReady: Bool { isInstalled && hasAccessibility }
}

@MainActor
final class DesktopControlSetupModel: ObservableObject {
  @Published var installed = DesktopControlReadiness.isInstalled
  @Published var executable: String?
  @Published var version: String?
  @Published var accessibility = DesktopControlReadiness.hasAccessibility
  @Published var screenRecording = DesktopControlReadiness.hasScreenRecording
  @Published var busy: String?
  @Published var message: String?

  private let runner = AgentDesktopRunner()

  var brewPath: String? {
    ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }

  func refresh() async {
    installed = DesktopControlReadiness.isInstalled
    accessibility = DesktopControlReadiness.hasAccessibility
    screenRecording = DesktopControlReadiness.hasScreenRecording
    executable = AgentDesktopLocator.executablePath()
    guard installed else {
      version = nil
      return
    }
    let status = await runner.status()
    version = status.version
  }

  func install() async {
    guard let brew = brewPath else {
      message =
        "Homebrew is not installed. Run `\(AgentDesktopLocator.installCommand)` in Terminal once Homebrew is set up, or install from github.com/vercel-labs/agent-desktop."
      return
    }
    busy = "Installing agent-desktop with Homebrew…"
    message = nil
    let failure = await Self.run(
      executable: brew, arguments: ["install", "agent-desktop"], timeout: .seconds(600))
    busy = nil
    if let failure {
      message = "Homebrew could not install agent-desktop: \(failure)"
    } else {
      message = "Installed. Now grant Otto access to your apps."
    }
    await refresh()
  }

  /// Opens System Settings with agent-desktop's own guide, which shows which app to add.
  func grantAccess() async {
    busy = "Opening System Settings…"
    message = nil
    do {
      let result = try await runner.run(["permissions", "--guide"], timeout: .seconds(20))
      let guide = result.envelope?["data"]?["guide"]?.stringValue
      message =
        guide == "not_needed"
        ? "Access is already granted."
        : "Follow the guide in System Settings, then come back here. Otto is the app to add."
    } catch {
      message =
        "Could not start the guide: \(error.localizedDescription). Open System Settings › Privacy & Security › Accessibility and add Otto."
      Self.openPrivacyPane("Privacy_Accessibility")
    }
    busy = nil
    await refresh()
  }

  func requestScreenRecording() async {
    if !CGRequestScreenCaptureAccess() {
      Self.openPrivacyPane("Privacy_ScreenCapture")
    }
    await refresh()
  }

  private static func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
      NSWorkspace.shared.open(url)
    }
  }

  /// Runs a setup command and returns why it failed, or nil when it succeeded.
  private static func run(executable: String, arguments: [String], timeout: Duration) async
    -> String?
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = [
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "HOME": NSHomeDirectory(), "HOMEBREW_NO_AUTO_UPDATE": "1", "NONINTERACTIVE": "1",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    do { try process.run() } catch { return error.localizedDescription }
    let watchdog = Task {
      try? await Task.sleep(for: timeout)
      if !Task.isCancelled, process.isRunning { process.terminate() }
    }
    let stderr = await Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
    while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
    watchdog.cancel()
    guard process.terminationStatus == 0 else {
      let text = String(decoding: stderr, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? "exit status \(process.terminationStatus)" : String(text.suffix(300))
    }
    return nil
  }
}

struct DesktopControlSettingsView: View {
  @StateObject private var model = DesktopControlSetupModel()

  var body: some View {
    Form {
      Section {
        HStack(alignment: .top, spacing: 14) {
          Image(systemName: "macwindow.on.rectangle")
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(.secondary)
            .frame(width: 64)
          VStack(alignment: .leading, spacing: 3) {
            Text("Let bots use your Mac's apps").font(.headline)
            Text(
              "Bots read an app's buttons and fields through macOS accessibility and act on them in the background: Mail, Notes, Finder, Slack, System Settings, the menu bar. No screenshots, no stolen cursor. Anything that needs a real click, real keystrokes or a picture of your screen shows you an Allow / Deny card first."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.vertical, 4)
      }

      Section("Setup") {
        statusRow(
          title: "agent-desktop command",
          detail: model.installed
            ? "Installed" + (model.version.map { " · \($0)" } ?? "")
            : "Not installed",
          ok: model.installed
        ) {
          if !model.installed {
            Button("Install") { Task { await model.install() } }
          }
        }
        statusRow(
          title: "Accessibility",
          detail: model.accessibility
            ? "Otto can see and operate your apps"
            : "Otto needs permission to see and operate your apps",
          ok: model.accessibility
        ) {
          if !model.accessibility {
            Button("Grant access") { Task { await model.grantAccess() } }
              .disabled(!model.installed)
          }
        }
        statusRow(
          title: "Screen Recording",
          detail: model.screenRecording
            ? "Bots may take screenshots when you allow one"
            : "Only needed for screenshots; bots work without it",
          ok: model.screenRecording
        ) {
          if !model.screenRecording {
            Button("Allow") { Task { await model.requestScreenRecording() } }
          }
        }
        HStack {
          Button("Check again") { Task { await model.refresh() } }
          if let busy = model.busy {
            ProgressView().controlSize(.small)
            Text(busy).font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
        }
        if let message = model.message {
          Text(message).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        if !model.installed, model.brewPath == nil {
          LabeledContent("Install by hand") {
            Text(AgentDesktopLocator.installCommand)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
          }
        }
      }
      .disabled(model.busy != nil)

      Section("How it works") {
        Text(
          "Ask a bot in plain words: “Archive every recruiter thread in Mail from this week” or “Turn my Monday note into a checklist”. It reads the app, acts on named elements, and reads again to check. The app stays where it is and your cursor stays yours."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          "Snapshots of your apps can contain private content. They stay on this Mac, under Otto's own folder in Application Support, and never in a synced workspace."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if let executable = model.executable {
          LabeledContent("Command") {
            Text(executable).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
        }
      }
    }
    .formStyle(.grouped)
    .task { await model.refresh() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in Task { await model.refresh() } }
  }

  @ViewBuilder
  private func statusRow<Action: View>(
    title: String, detail: String, ok: Bool, @ViewBuilder action: () -> Action
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: ok ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(ok ? .green : .secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
      action()
    }
  }
}
