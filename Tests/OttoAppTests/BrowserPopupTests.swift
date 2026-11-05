import AppKit
import Foundation
import OttoBrowser
import Testing
import WebKit

@testable import OttoApp

@Suite("Browser popup handoff", .serialized) @MainActor
struct BrowserPopupTests {
  @Test func httpRedirectHandsOffAppCallbackWithoutPageError() async throws {
    _ = NSApplication.shared
    let server = try PopupFixtureServer()
    defer { server.stop() }
    let destination = URL(string: "otto-test-callback://oauth/complete")!
    var opened: [URL] = []
    var pageErrors: [String] = []
    var loading: Bool?
    let coordinator = BrowserWebView.Coordinator(
      nodeID: UUID(), tabID: UUID(), runtime: BrowserRuntime(),
      requestedURL: server.url.absoluteString, requestedRevision: 0,
      report: {
        loading = $0.isLoading
        if let error = $0.errorMessage { pageErrors.append(error) }
      })
    coordinator.isActive = true
    coordinator.externalNavigation = BrowserExternalNavigation(
      application: { _ in URL(fileURLWithPath: "/Applications/Fixture.app") },
      open: {
        opened.append($0)
        return true
      })
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
    view.navigationDelegate = coordinator
    view.load(URLRequest(url: server.url.appendingPathComponent("redirect")))
    for _ in 0..<200 {
      if !opened.isEmpty || !pageErrors.isEmpty { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(opened == [destination])
    #expect(pageErrors.isEmpty)
    #expect(loading == false)
  }

  @Test func iframePopupReturnsMessageBeforeClosing() async throws {
    _ = NSApplication.shared
    let server = try PopupFixtureServer()
    defer { server.stop() }
    let popups = BrowserPopupWindows()
    defer { popups.closeAll() }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    // Only the disposable fixture enables script-opened windows without a real mouse gesture.
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    let opener = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
    opener.uiDelegate = popups
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = opener
    window.orderFront(nil)
    defer { window.close() }
    opener.load(URLRequest(url: server.url))
    for _ in 0..<200 {
      if (try? await opener.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    _ = try await opener.evaluateJavaScript(
      "document.querySelector('iframe').contentWindow.postMessage('open', '*')")
    for _ in 0..<300 {
      if (try? await opener.evaluateJavaScript("window.returned === true")) as? Bool == true {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    let returned = try await opener.evaluateJavaScript("window.returned === true") as? Bool
    #expect(returned == true)
    #expect(popups.windows.isEmpty)
  }

  @Test func ordinaryLinksAndScriptWindowsOpenAsTabs() {
    let account = URL(string: "https://mail.google.com/mail/u/1/")!
    #expect(BrowserPopupWindows.tabURL(navigationType: .linkActivated, url: account) == account)
    #expect(BrowserPopupWindows.tabURL(navigationType: .other, url: account) == account)
    #expect(
      BrowserPopupWindows.tabURL(
        navigationType: .linkActivated, url: URL(string: "mailto:a@example.com")) == nil)
    #expect(BrowserPopupWindows.tabURL(navigationType: .linkActivated, url: nil) == nil)
    let login = URL(string: "https://app.heyreach.io/account/login")!
    #expect(BrowserPopupWindows.tabURL(navigationType: .linkActivated, url: login) == login)
    #expect(
      BrowserPopupWindows.tabURL(navigationType: .linkActivated, url: login, isMainFrame: false)
        == login)
  }
  @Test func scriptOpenedConfiguratorReachesTheTabOwnerWithoutAWindow() async throws {
    _ = NSApplication.shared
    let server = try PopupFixtureServer()
    defer { server.stop() }
    let coordinator = BrowserWebView.Coordinator(
      nodeID: UUID(), tabID: UUID(), runtime: BrowserRuntime(),
      requestedURL: server.url.absoluteString, requestedRevision: 0, report: { _ in })
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    let opener = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
    opener.uiDelegate = coordinator
    opener.navigationDelegate = coordinator
    let window = NSWindow(
      contentRect: opener.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = opener
    defer {
      window.close()
      coordinator.closePopupWindows()
    }
    let received = TabRequestBox()
    let observer = NotificationCenter.default.addObserver(
      forName: BrowserLinkTabRequest.name, object: nil, queue: .main
    ) { notification in
      let nodeID = notification.userInfo?["nodeID"] as? UUID
      let url = notification.userInfo?["url"] as? String
      MainActor.assumeIsolated {
        received.nodeID = nodeID
        received.url = url
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    opener.load(URLRequest(url: server.url))
    for _ in 0..<200 {
      if (try? await opener.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    _ = try await opener.evaluateJavaScript("window.open('/configurator', '_blank'); undefined")
    for _ in 0..<200 {
      if received.url != nil { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(received.nodeID == coordinator.nodeID)
    #expect(
      received.url == server.url.appendingPathComponent("configurator").absoluteString)
    #expect(coordinator.popupWindows.windows.isEmpty)
    opener.load(URLRequest(url: URL(string: "muse://start")!))
    try await Task.sleep(for: .milliseconds(100))
    #expect(
      opener.url == server.url || opener.url?.absoluteString == server.url.absoluteString + "/")
    #expect(opener.backForwardList.backList.allSatisfy { BrowserHistoryNavigation.isPage($0.url) })
  }

  @Test func authenticationAndEmbeddedPopupsKeepTheirOpener() {
    let oauth = URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=fixture")!
    #expect(BrowserPopupWindows.tabURL(navigationType: .other, url: oauth) == nil)
    #expect(
      BrowserPopupWindows.tabURL(
        navigationType: .other, url: URL(string: "https://example.com/provider"),
        isMainFrame: false) == nil)
    let configurator = URL(string: "https://configure.zodiac-nautic.com/")!
    #expect(BrowserPopupWindows.tabURL(navigationType: .other, url: configurator) == configurator)
  }

  @Test func accountSwitchesStayWithinTheCurrentGoogleProduct() {
    let mail = URL(string: "https://mail.google.com/mail/u/0/#inbox")!
    let calendar = URL(string: "https://calendar.google.com/calendar/u/0/r")!
    for (source, target) in [
      (mail, "https://mail.google.com/mail/u/1/"),
      (calendar, "https://calendar.google.com/calendar/u/2/r"),
      (
        mail,
        "https://accounts.google.com/AccountChooser?continue=https%3A%2F%2Fmail.google.com%2Fmail%2Fu%2F1%2F"
      ),
    ] {
      #expect(BrowserPopupWindows.switchesAccount(from: source, to: URL(string: target)!))
    }
    for target in [
      "https://calendar.google.com/calendar/u/1/r", "https://mail.google.com.evil.test/mail/u/1/",
      "https://accounts.google.com/o/oauth2/auth", "https://mail.google.com/mail/",
      "https://accounts.google.com/AccountChooser?continue=https%3A%2F%2Fevil.test%2F",
    ] {
      #expect(!BrowserPopupWindows.switchesAccount(from: mail, to: URL(string: target)!))
    }
  }

  @Test func internalPagesAreExcludedFromHistory() {
    for raw in ["muse://start", "muse:start", "otto://start", "otto:start", "about:blank"] {
      #expect(!BrowserHistoryNavigation.isPage(URL(string: raw)!))
    }
    #expect(BrowserHistoryNavigation.isPage(URL(string: "https://example.com")!))
  }

}

private final class PopupFixtureServer {
  let process = Process()
  let url: URL
  init() throws {
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-u", "-c",
      #"""
      from http.server import HTTPServer,BaseHTTPRequestHandler
      class H(BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_GET(self):
          p=self.server.server_port
          if self.path=='/redirect':
            self.send_response(302);self.send_header('Location','otto-test-callback://oauth/complete');self.end_headers();return
          self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers()
          if self.path=='/frame':
            body=f'''<script>addEventListener('message',e=>{{if(e.data==='open')window.open('/provider','signin');if(e.data==='done')parent.postMessage('done','http://127.0.0.1:{p}')}});parent.postMessage('ready','http://127.0.0.1:{p}')</script>'''
          elif self.path=='/provider':
            body="<script>window.opener.postMessage('done',location.origin);window.close()</script>"
          else:
            body=f'''<iframe src="http://localhost:{p}/frame"></iframe><script>window.returned=false;addEventListener('message',e=>{{if(e.origin!=='http://localhost:{p}')return;if(e.data==='ready')window.fixtureReady=true;if(e.data==='done')window.returned=true}})</script>'''
          self.wfile.write(body.encode())
      s=HTTPServer(('127.0.0.1',0),H);print(s.server_port,flush=True);s.serve_forever()
      """#,
    ]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: "http://127.0.0.1:" + port), Int(port) != nil else {
      process.terminate()
      throw CocoaError(.fileReadUnknown)
    }
    self.url = url
  }
  func stop() {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
}

@MainActor private final class TabRequestBox {
  var nodeID: UUID?
  var url: String?
}
