import AppKit
import OttoCore
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI
import UserNotifications

extension Notification.Name {
  static let ottoOpenCompletedConversation = Notification.Name("otto.openCompletedConversation")
}

/// One subscription to terminal run events; output and intermediate status updates never alert.
@MainActor
final class CompletionNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
  static let shared = CompletionNotifications()
  static let enabledKey = "otto.notifications.completion.enabled"
  static let botsKey = "otto.notifications.completion.bots"
  static let sessionsKey = "otto.notifications.completion.sessions"
  static let soundKey = "otto.notifications.completion.sound"
  @Published private(set) var permissionStatus = ""
  var visibleConversations: [UUID: UUID] = [:]
  private var tasks: [String: Task<Void, Never>] = [:]
  var onOpenConversation: ((UUID) -> Void)?
  private var completions = CompletionEventFilter()

  static func enabled(_ key: String, defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: key) == nil ? key != soundKey : defaults.bool(forKey: key)
  }

  func start(services: ApplicationServices, store: CanvasStore) {
    let key = services.defaultWorkspacePath
    guard tasks[key] == nil else { return }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let bus = services.supervisor.eventBus
    let stream = bus.stream(afterSequence: bus.latestSequence)
    tasks[key] = Task { [weak self, weak services] in
      for await event in stream {
        guard let self, let services, !Task.isCancelled else { return }
        await self.consume(event, services: services, store: store)
      }
    }
    services.watchdogAlertHandler = { [weak self, weak services] findings in
      guard let self, let services else { return }
      Task { await self.notifyWatchdog(findings, services: services, store: store) }
    }
    Task { await requestPermissionIfEnabled() }
  }

  func requestPermissionIfEnabled() async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if Self.enabled(Self.enabledKey), settings.authorizationStatus == .notDetermined {
      do { _ = try await center.requestAuthorization(options: [.alert, .sound]) } catch {
        permissionStatus = error.localizedDescription
        return
      }
    }
    await refreshPermission()
  }

  func refreshPermission() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: permissionStatus = "Notifications allowed by macOS."
    case .denied:
      permissionStatus = "Notifications are blocked in macOS. Enable them in System Settings."
    case .notDetermined: permissionStatus = "macOS permission has not been granted yet."
    @unknown default: permissionStatus = "Check notification permissions in System Settings."
    }
  }

  private func consume(_ event: OttoEvent, services: ApplicationServices, store: CanvasStore) async
  {
    guard event.type == .agentRunCompleted || event.type == .agentRunFailed,
      let nodeID = event.nodeID,
      let node = store.snapshot.canvases.lazy.flatMap(\.nodes).first(where: { $0.id == nodeID }),
      node.isStandaloneAgent, !services.office.boundSessionIDs.contains(nodeID)
    else { return }
    let key = "\(nodeID):\(event.runID ?? event.id)"
    guard completions.accept(event) else { return }
    let isBot = services.botRoster().contains { $0.nodeID == nodeID }
    guard Self.enabled(Self.enabledKey), Self.enabled(isBot ? Self.botsKey : Self.sessionsKey),
      !(NSApp.isActive && visibleConversations.values.contains(nodeID)),
      // Otto on screen says it himself; one announcement is enough.
      !OttoBuddyController.shared.replacesCompletionBanners(for: services)
    else { return }
    let content = UNMutableNotificationContent()
    let failed = event.type == .agentRunFailed
    content.title = "\(node.displayName) \(failed ? "needs attention" : "finished")"
    content.body =
      failed
      ? "Work could not finish. Open the conversation to review."
      : "Your work is ready. Open the conversation to view the result."
    content.threadIdentifier = nodeID.uuidString
    content.userInfo = ["nodeID": nodeID.uuidString]
    if Self.enabled(Self.soundKey) { content.sound = .default }
    do {
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: key, content: content, trigger: nil))
    } catch { permissionStatus = "Could not show notification: \(error.localizedDescription)" }
  }

  /// The watchdog already de-duplicates; each agent keeps a single banner that a repeat replaces.
  private func notifyWatchdog(
    _ findings: [AgentWatchdogFinding], services: ApplicationServices, store: CanvasStore
  ) async {
    guard Self.enabled(Self.enabledKey) else { return }
    for finding in findings {
      let nodeID = finding.agentID
      guard
        let node = store.snapshot.canvases.lazy.flatMap(\.nodes).first(where: { $0.id == nodeID }),
        !(NSApp.isActive && visibleConversations.values.contains(nodeID))
      else { continue }
      let isBot = services.botRoster().contains { $0.nodeID == nodeID }
      guard Self.enabled(isBot ? Self.botsKey : Self.sessionsKey) else { continue }
      let content = UNMutableNotificationContent()
      switch finding.kind {
      case .stalled: content.title = "\(node.displayName) looks stuck"
      case .looping: content.title = "\(node.displayName) may be going in circles"
      case .waitingOnPerson: content.title = "\(node.displayName) is still waiting for you"
      }
      content.body = "\(finding.reason). Open the conversation to check on it."
      content.threadIdentifier = nodeID.uuidString
      content.userInfo = ["nodeID": nodeID.uuidString]
      if Self.enabled(Self.soundKey) { content.sound = .default }
      do {
        try await UNUserNotificationCenter.current().add(
          UNNotificationRequest(identifier: "watchdog:\(nodeID)", content: content, trigger: nil))
      } catch { permissionStatus = "Could not show notification: \(error.localizedDescription)" }
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let raw = response.notification.request.content.userInfo["nodeID"] as? String,
      let nodeID = UUID(uuidString: raw)
    {
      Task { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        self.onOpenConversation?(nodeID)
      }
    }
    completionHandler()
  }
}

struct CompletionNotificationSettingsView: View {
  @ObservedObject private var notifications = CompletionNotifications.shared
  @AppStorage(CompletionNotifications.enabledKey) private var enabled = true
  @AppStorage(CompletionNotifications.botsKey) private var bots = true
  @AppStorage(CompletionNotifications.sessionsKey) private var sessions = true
  @AppStorage(CompletionNotifications.soundKey) private var sound = false

  var body: some View {
    Form {
      Section("Work completion") {
        Toggle("Notify when work finishes", isOn: $enabled)
        Toggle("Bots", isOn: $bots).disabled(!enabled)
        Toggle("Sessions", isOn: $sessions).disabled(!enabled)
        Toggle("Play a sound", isOn: $sound).disabled(!enabled)
        Text(
          "Shows a banner when work finishes or fails, unless you’re viewing that conversation. While Otto is on screen and speaking up, he tells you instead."
        )
        .font(.callout).foregroundStyle(.secondary)
      }
      Section("macOS permission") {
        Text(notifications.permissionStatus).foregroundStyle(.secondary)
        Button("Open Notification Settings") {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
          {
            NSWorkspace.shared.open(url)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 540, height: 380)
    .task { await notifications.refreshPermission() }
    .onChange(of: enabled) { _, _ in Task { await notifications.requestPermissionIfEnabled() } }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      Task { await notifications.refreshPermission() }
    }
  }
}

/// Bounded duplicate protection: a new turn on the same session must still notify.
struct CompletionEventFilter {
  private var seen: Set<String> = []
  private var order: [String] = []

  mutating func accept(_ event: OttoEvent) -> Bool {
    guard event.type == .agentRunCompleted || event.type == .agentRunFailed,
      let nodeID = event.nodeID
    else { return false }
    let key = "\(nodeID):\(event.runID ?? event.id)"
    guard seen.insert(key).inserted else { return false }
    order.append(key)
    if order.count > 2048 { seen.remove(order.removeFirst()) }
    return true
  }
}
