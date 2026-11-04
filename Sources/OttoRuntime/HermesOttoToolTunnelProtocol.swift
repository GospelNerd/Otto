import Foundation

/// Wire contract used when a remote Hermes gateway cannot spawn Otto's local stdio MCP server.
/// Hermes carries an allowlisted request over its existing authenticated clarify channel; the
/// local bridge recognizes the marker and invokes Otto with the node's normal scoped token.
public enum HermesOttoToolTunnelProtocol {
  public static let marker = "__OTTO_TOOL_V1__"
  /// Emitted by sessions instructed before the rename; still accepted.
  public static let legacyMarker = "__MUSE_TOOL_V1__"

  public static let allowedTools: Set<String> = [
    "node.list",
    "browser.open", "browser.open_tab", "browser.get_selection",
    "browser.navigate", "browser.get_state", "browser.refresh", "browser.back",
    "browser.forward", "browser.inspect", "browser.click", "browser.type",
    "browser.scroll", "browser.screenshot",
    "terminal.run", "terminal.wait", "terminal.read_output", "terminal.stop_process",
    "skill.list", "skill.read",
  ]

  public struct Request: Sendable, Equatable {
    public let name: String
    public let argumentsJSON: Data

    public init(name: String, argumentsJSON: Data) {
      self.name = name
      self.argumentsJSON = argumentsJSON
    }
  }

  public enum ParseResult: Sendable, Equatable {
    case ordinaryClarification
    case request(Request)
    case rejected(String)
  }

  public static func parse(question: String) -> ParseResult {
    guard let prefix = [marker, legacyMarker].first(where: { question.hasPrefix($0) }) else {
      return .ordinaryClarification
    }
    let payload = String(question.dropFirst(prefix.count))
    do {
      guard let data = payload.data(using: .utf8),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let name = object["name"] as? String,
        allowedTools.contains(name)
      else {
        return .rejected("The requested Otto tool is malformed or not allowed.")
      }
      let arguments = object["arguments"] as? [String: Any] ?? [:]
      guard JSONSerialization.isValidJSONObject(arguments) else {
        return .rejected("The requested Otto tool arguments are invalid.")
      }
      return .request(
        Request(
          name: name,
          argumentsJSON: try JSONSerialization.data(
            withJSONObject: arguments, options: [.sortedKeys])
        ))
    } catch {
      return .rejected("The requested Otto tool payload is invalid JSON.")
    }
  }
}
