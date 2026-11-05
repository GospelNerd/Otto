import AppKit
import WebKit

/// Own the child WebKit views for window.open, including the opener supplied by WebKit.
@MainActor
final class BrowserPopupWindows: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
  var externalNavigation = BrowserExternalNavigation()
  private(set) var windows: [ObjectIdentifier: NSWindowController] = [:]

  /// Ordinary pages belong in tabs, even when opened by JavaScript. Clicked links always
  /// do, including "Log in" links to a login page (heyreach.io); only script-opened
  /// embedded and authentication windows retain WebKit's opener configuration.
  nonisolated static func tabURL(
    navigationType: WKNavigationType, url: URL?, isMainFrame: Bool = true
  ) -> URL? {
    guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    if navigationType == .linkActivated { return url }
    guard isMainFrame, !isAuthenticationURL(url) else { return nil }
    return url
  }

  nonisolated static func isAuthenticationURL(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    let path = url.path.lowercased()
    return host == "accounts.google.com" || host == "appleid.apple.com"
      || path.contains("oauth") || path.contains("authorize")
      || path.contains("signin") || path.contains("login")
  }

  /// Match account navigation within the current Google product, never app-launcher links.
  nonisolated static func switchesAccount(from source: URL?, to destination: URL) -> Bool {
    guard let source, source.scheme == "https", destination.scheme == "https",
      let host = source.host?.lowercased(),
      ["mail.google.com", "calendar.google.com"].contains(host)
    else { return false }
    if destination.host?.lowercased() == host {
      let prefix = host == "mail.google.com" ? "/mail/u/" : "/calendar/u/"
      let path = destination.path
      return path.hasPrefix(prefix)
        && !(path.dropFirst(prefix.count).split(separator: "/").first?.isEmpty ?? true)
    }
    if destination.host?.lowercased() == "accounts.google.com",
      destination.path.lowercased() == "/accountchooser",
      let value = URLComponents(url: destination, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "continue" })?.value,
      let continuation = URL(string: value)
    {
      return switchesAccount(from: source, to: continuation)
    }
    return false
  }

  func webView(
    _ opener: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard navigationAction.targetFrame == nil else { return nil }
    if let url = navigationAction.request.url, externalNavigation.handOff(url) { return nil }
    // Replacing this configuration or navigating the parent would break window.opener.
    let popup = WKWebView(frame: .zero, configuration: configuration)
    BrowserSignInDiagnostics.configure(popup)
    BrowserPasswordBridge.register(popup)
    popup.uiDelegate = self
    popup.navigationDelegate = self
    BrowserSignInDiagnostics.record("popup.created")
    let width = windowFeatures.width?.doubleValue ?? 520
    let height = windowFeatures.height?.doubleValue ?? 680
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: max(width, 360), height: max(height, 480)),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "Sign in"
    window.contentView = popup
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.center()
    let controller = NSWindowController(window: window)
    windows[ObjectIdentifier(popup)] = controller
    controller.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
    return popup
  }
  func webView(
    _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
  ) {
    BrowserFilePicker.present(parameters, for: webView, completionHandler: completionHandler)
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    if navigationAction.targetFrame?.isMainFrame != false,
      let url = navigationAction.request.url, externalNavigation.handOff(url)
    {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webViewDidClose(_ webView: WKWebView) {
    BrowserSignInDiagnostics.record("popup.scriptClosed")
    guard let controller = windows.removeValue(forKey: ObjectIdentifier(webView)) else { return }
    controller.close()
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    BrowserSignInDiagnostics.record("popup.navigationFinished")
  }
  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
  ) {
    if externalNavigation.handOffRedirectFailure(error) { return }
    BrowserSignInDiagnostics.record("popup.navigationFailed", code: (error as NSError).code)
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    if externalNavigation.handOffRedirectFailure(error) { return }
    BrowserSignInDiagnostics.record(
      "popup.provisionalNavigationFailed", code: (error as NSError).code)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    BrowserSignInDiagnostics.record("popup.processTerminated")
  }
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    windows = windows.filter { $0.value.window !== window }
  }
  func closeAll() {
    let controllers = Array(windows.values)
    windows.removeAll()
    for controller in controllers {
      controller.window?.delegate = nil
      controller.close()
    }
  }
}

/// WKWebView on macOS shows no file chooser unless the UI delegate presents one, so an
/// `<input type="file">` (LinkedIn's media upload, Gmail attachments) silently does nothing.
@MainActor
enum BrowserFilePicker {
  static func present(
    _ parameters: WKOpenPanelParameters, for webView: WKWebView,
    completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
  ) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.resolvesAliases = true
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      completionHandler(response == .OK ? panel.urls : nil)
    }
    if let window = webView.window {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      panel.begin(completionHandler: finish)
    }
  }
}
