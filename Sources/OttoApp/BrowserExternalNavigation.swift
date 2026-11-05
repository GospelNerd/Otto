import AppKit
import OttoModels

/// Hand app callbacks to Launch Services instead of trying to render them as websites.
/// Never record the URL: OAuth callbacks can contain one-time codes.
@MainActor
struct BrowserExternalNavigation {
  var application: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
  var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }

  func handOff(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
      !OttoNames.isAppURLScheme(scheme),
      !["http", "https", "about", "file", "data", "blob", "javascript", "webkit", "ftp"]
        .contains(scheme),
      application(url) != nil
    else { return false }
    return open(url)
  }

  /// WebKit can reject an HTTP-to-app redirect before asking the navigation delegate.
  /// Recover only that failure, using its destination; never replay an OAuth request.
  func handOffRedirectFailure(_ error: any Error) -> Bool {
    let error = error as NSError
    guard error.domain.isEmpty, error.code == 0,
      error.localizedDescription == "Redirection to URL with a scheme that is not HTTP(S)",
      let url = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
        ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(
          URL.init(string:))
    else { return false }
    return handOff(url)
  }
}
