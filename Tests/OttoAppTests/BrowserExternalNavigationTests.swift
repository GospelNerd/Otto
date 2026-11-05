import AppKit
import Testing

@testable import OttoApp

@Suite("Browser app callbacks") @MainActor
struct BrowserExternalNavigationTests {
  @Test func onlyRegisteredAppSchemesAreHandedOff() {
    var opened: [URL] = []
    let handler = BrowserExternalNavigation(
      application: { _ in URL(fileURLWithPath: "/Applications/Fixture.app") },
      open: {
        opened.append($0)
        return true
      })
    for raw in [
      "https://example.com", "http://localhost", "otto://start", "muse://start",
      "file:///etc/hosts", "javascript:alert(1)", "data:text/plain,hello", "about:blank",
      "blob:https://example.com/id", "ftp://example.com",
    ] {
      #expect(!handler.handOff(URL(string: raw)!))
    }
    #expect(opened.isEmpty)
    let callback = URL(string: "fixture-app://oauth/complete")!
    #expect(handler.handOff(callback))
    #expect(opened == [callback])
    let missing = BrowserExternalNavigation(
      application: { _ in nil },
      open: { _ in
        Issue.record("Unregistered app must not launch")
        return true
      })
    #expect(!missing.handOff(callback))
    let refused = BrowserExternalNavigation(
      application: { _ in URL(fileURLWithPath: "/Applications/Fixture.app") }, open: { _ in false })
    #expect(!refused.handOff(callback))
  }

  @Test func recoversOnlyTheSpecificRedirectFailure() {
    var opened: [URL] = []
    let handler = BrowserExternalNavigation(
      application: { _ in URL(fileURLWithPath: "/Applications/Fixture.app") },
      open: {
        opened.append($0)
        return true
      })
    let callback = URL(string: "fixture-app://oauth/complete")!
    let description = "Redirection to URL with a scheme that is not HTTP(S)"
    for key in [NSURLErrorFailingURLErrorKey, NSURLErrorFailingURLStringErrorKey] {
      let value: Any = key == NSURLErrorFailingURLErrorKey ? callback : callback.absoluteString
      #expect(
        handler.handOffRedirectFailure(
          NSError(
            domain: "", code: 0,
            userInfo: [NSLocalizedDescriptionKey: description, key: value])))
    }
    #expect(opened == [callback, callback])
    #expect(
      !handler.handOffRedirectFailure(
        NSError(
          domain: NSURLErrorDomain, code: -1009,
          userInfo: [NSURLErrorFailingURLErrorKey: callback])))
    #expect(
      !handler.handOffRedirectFailure(
        NSError(
          domain: "", code: 0,
          userInfo: [NSLocalizedDescriptionKey: description])))
    #expect(
      !handler.handOffRedirectFailure(
        NSError(
          domain: "", code: 0,
          userInfo: [
            NSLocalizedDescriptionKey: description,
            NSURLErrorFailingURLStringErrorKey: "https://example.com",
          ])))
    #expect(opened.count == 2)
  }
}
