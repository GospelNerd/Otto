import Foundation
import OSLog

/// Turns a speech engine's stderr into something a person can read. `sherpa-onnx-offline` prints
/// its entire recognizer configuration (hundreds of characters of `OfflineXxxModelConfig(...)`)
/// before it says what went wrong, so the line that matters is the last one. The full text still
/// goes to the system log for Console.
public enum TranscriptionDiagnostics {
  static let logger = Logger(subsystem: "io.openotto.desktop", category: "Transcription")

  /// The last meaningful line of `errorText`, at most `limit` characters. Configuration dumps,
  /// progress chatter and blank lines are dropped; a bare `Errors in config!` or `Failed to read`
  /// is prefixed with the line that explains it. Empty when nothing useful was printed.
  public static func summary(of errorText: String, limit: Int = 200) -> String {
    let lines = errorText.split(whereSeparator: \.isNewline)
      .map { shortenPaths(stripLogPrefix(String($0))).trimmingCharacters(in: .whitespaces) }
      .filter(isMeaningful)
    guard let last = lines.last else { return "" }
    var text = last
    if isGenericFailure(last), lines.count >= 2 {
      text = "\(lines[lines.count - 2]); \(last)"
    }
    guard text.count > limit else { return text }
    return String(text.prefix(max(0, limit - 1))) + "…"
  }

  /// Logs an engine failure in full so the whole stderr is in Console even though the person
  /// only sees `summary(of:)`.
  static func logFailure(engine: String, status: Int32, errorText: String) {
    logger.error(
      "\(engine, privacy: .public) exited with status \(status). stderr: \(errorText, privacy: .public)"
    )
  }

  private static let noise = [
    "Creating recognizer ...", "Started", "Done!", "----",
  ]
  private static let noisePrefixes = [
    "recognizer created in", "num threads:", "decoding method:", "max active paths:",
    "Elapsed seconds:", "Real time factor",
  ]

  private static func isMeaningful(_ line: String) -> Bool {
    guard !line.isEmpty, !noise.contains(line) else { return false }
    guard !noisePrefixes.contains(where: line.hasPrefix) else { return false }
    // The configuration dump, or the tail of it when stderr was cut mid-line.
    if line.contains("Config(") || line.contains("config=") { return false }
    if line.wholeMatch(of: #/[A-Za-z_]+=.*/#) != nil, line.contains(", ") { return false }
    return true
  }

  private static func isGenericFailure(_ line: String) -> Bool {
    line == "Errors in config!" || line.hasPrefix("Failed to read")
  }

  /// `SHERPA_ONNX_LOGE` prefixes every line with `path/file.cc:Function:123 `.
  private static func stripLogPrefix(_ line: String) -> String {
    line.replacing(#/^\S+\.(?:cc|cpp|c|h):\S*:\d+\s+/#, with: "")
  }

  /// A quoted absolute path, such as the temporary clip, is shown by its file name only.
  private static func shortenPaths(_ line: String) -> String {
    line.replacing(#/'\/[^']*\/([^'\/]+)'/#) { "'\($0.output.1)'" }
  }
}
