import Foundation
import OttoModels

public actor HarnessSessionStore {
  public struct Limits: Equatable, Sendable {
    public var maximumMessages: Int
    public var maximumUTF8Bytes: Int

    /// A safety net only. HarnessCompactor sizes live history to the model's context window and
    /// folds older messages into a summary well before these limits.
    public init(maximumMessages: Int = 1_000, maximumUTF8Bytes: Int = 8 * 1_024 * 1_024) {
      self.maximumMessages = max(2, maximumMessages)
      self.maximumUTF8Bytes = max(1_024, maximumUTF8Bytes)
    }
  }

  public let rootURL: URL
  public let limits: Limits
  private let fileManager: FileManager

  public init(
    rootURL: URL = HarnessSessionStore.defaultRootURL(),
    limits: Limits = Limits(),
    fileManager: FileManager = .default
  ) {
    self.rootURL = rootURL
    self.limits = limits
    self.fileManager = fileManager
  }

  public static func defaultRootURL() -> URL {
    if let override = OttoEnvironment.value("HARNESS_SESSIONS_DIR"),
      !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    let applicationSupport =
      FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first ?? FileManager.default.homeDirectoryForCurrentUser
    return
      applicationSupport
      .appending(path: "Otto", directoryHint: .isDirectory)
      .appending(path: "Harness", directoryHint: .isDirectory)
      .appending(path: "Sessions", directoryHint: .isDirectory)
  }

  public func loadOrCreate(
    sessionID: String?, providerID: String, modelID: String
  ) throws -> HarnessSession {
    guard let sessionID else {
      return HarnessSession(providerID: providerID, modelID: modelID)
    }
    guard HarnessSession.isOttoID(sessionID) else { throw HarnessError.invalidSessionID }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL(for: sessionID))
    } catch {
      let readError = error as NSError
      // Bot channels may outlive an older provider session file. Starting a
      // fresh provider session is safer than permanently failing every new
      // prompt, and does not delete the existing Otto chat transcript.
      // Never do this for invalid JSON or permission failures: those are
      // different problems that must stay visible for recovery.
      if readError.domain == NSCocoaErrorDomain,
        readError.code == NSFileReadNoSuchFileError
      {
        return HarnessSession(providerID: providerID, modelID: modelID)
      }
      throw error
    }
    var session = try decoder().decode(HarnessSession.self, from: data)
    session.providerID = providerID
    session.modelID = modelID
    return session
  }

  public func save(_ session: HarnessSession) throws {
    guard HarnessSession.isOttoID(session.id) else { throw HarnessError.invalidSessionID }
    var bounded = session
    bounded.messages = boundedMessages(session.messages)
    let liveIDs = Set(bounded.messages.map(\.id))
    var archive = session.archivedMessages ?? []
    var archivedIDs = Set(archive.map(\.id))
    archive += session.messages.filter {
      !liveIDs.contains($0.id) && archivedIDs.insert($0.id).inserted
    }
    bounded.archivedMessages = archive.isEmpty ? nil : archive
    bounded.updatedAt = Date()
    try fileManager.createDirectory(
      at: rootURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let destination = fileURL(for: bounded.id)
    let data = try encoder().encode(bounded)
    try data.write(to: destination, options: .atomic)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  public func load(sessionID: String) throws -> HarnessSession {
    guard HarnessSession.isOttoID(sessionID) else { throw HarnessError.invalidSessionID }
    return try decoder().decode(
      HarnessSession.self, from: Data(contentsOf: fileURL(for: sessionID)))
  }

  private func fileURL(for sessionID: String) -> URL {
    rootURL.appending(path: "\(sessionID).json")
  }

  private func boundedMessages(_ messages: [HarnessMessage]) -> [HarnessMessage] {
    var result = Array(messages.suffix(limits.maximumMessages))
    var bytes = result.reduce(0) { $0 + $1.content.utf8.count }
    while result.count > 1, bytes > limits.maximumUTF8Bytes {
      bytes -= result.removeFirst().content.utf8.count
    }
    // Oversized messages stay in the archive, never silently cut in the durable transcript.
    if bytes > limits.maximumUTF8Bytes { return [] }
    return result
  }

  public func contextSummary(_ session: HarnessSession) -> String {
    let uncertain = (session.toolReceipts ?? []).filter {
      $0.state == "executing" || $0.state == "uncertain"
    }.map {
      "Uncertain tool: \($0.name), call \($0.callID). Verify its external result before repeating it."
    }
    if let compaction = session.compaction {
      return (uncertain + [
        "Summary of the earlier conversation (older messages were compacted to fit the model's context window):\n"
          + compaction.summary
      ]).joined(separator: "\n")
    }
    return String((uncertain + legacyArchiveLines(session)).joined(separator: "\n").prefix(8_000))
  }

  /// Sessions saved before compaction existed only kept a digest of their archive.
  public func legacyArchiveDigest(_ session: HarnessSession) -> String {
    String(legacyArchiveLines(session).joined(separator: "\n").prefix(8_000))
  }

  private func legacyArchiveLines(_ session: HarnessSession) -> [String] {
    let archive = session.archivedMessages ?? []
    let constraints = archive.filter { message in
      message.role == .user
        && ["must", "constraint", "never", "do not", "decision"].contains {
          message.content.localizedCaseInsensitiveContains($0)
        }
    }
    let candidates = constraints + Array(archive.suffix(6))
    var seen = Set<UUID>()
    return candidates.filter { seen.insert($0.id).inserted }.map {
      "\($0.role.rawValue): \(String($0.content.prefix(1_000)))"
    }
  }

  private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
