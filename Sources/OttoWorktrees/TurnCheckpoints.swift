import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// One file's change between two turn checkpoints, from `git diff --numstat`.
public struct TurnFileChange: Codable, Sendable, Equatable, Identifiable {
  public var path: String
  /// Line counts are nil for binary files, which numstat reports as `-`.
  public var additions: Int?
  public var deletions: Int?

  public var id: String { path }

  public init(path: String, additions: Int?, deletions: Int?) {
    self.path = path
    self.additions = additions
    self.deletions = deletions
  }
}

/// What one agent turn changed on disk: the diff between the checkpoint captured when the
/// prompt was sent and the one captured when the run completed.
public struct TurnChangeSummary: Codable, Sendable, Equatable {
  /// Repository work-tree directory both refs live in; diffs must run here.
  public var directory: String
  public var baselineRef: String
  public var completionRef: String
  public var files: [TurnFileChange]

  public var totalAdditions: Int { files.compactMap(\.additions).reduce(0, +) }
  public var totalDeletions: Int { files.compactMap(\.deletions).reduce(0, +) }
  public var isEmpty: Bool { files.isEmpty }

  public init(
    directory: String, baselineRef: String, completionRef: String, files: [TurnFileChange]
  ) {
    self.directory = directory
    self.baselineRef = baselineRef
    self.completionRef = completionRef
    self.files = files
  }
}

public enum TurnCheckpointError: Error, LocalizedError, Equatable {
  case git(String)
  case dirtyWorkspace([String])

  public var errorDescription: String? {
    switch self {
    case .git(let message): "Turn checkpoint git operation failed: \(message)"
    case .dirtyWorkspace(let paths):
      "The workspace changed after this turn (\(paths.prefix(5).joined(separator: ", "))). Review or commit those changes before reverting."
    }
  }
}

/// Captures shadow snapshots of an agent's working tree as hidden git refs so each turn can be
/// diffed and reviewed, without ever touching the user's index, HEAD, or branches.
///
/// The mechanism (borrowed from T3 Code's checkpointing): build a commit through a temporary
/// `GIT_INDEX_FILE` — `read-tree HEAD`, `add -A`, `write-tree`, `commit-tree` — then point a
/// ref under `refs/otto/checkpoints/<agent>/` at it. Untracked files are included, ignored
/// files are not, and the user's own staged state is never observed or modified.
///
/// Checkpoints captured before the rename live under `refs/muse/checkpoints/`. They are never
/// rewritten: saved summaries keep their full ref names, and pruning counts both namespaces.
public actor TurnCheckpointStore {
  public static let refNamespace = "refs/otto/checkpoints"
  public static let legacyRefNamespace = "refs/muse/checkpoints"

  /// Checkpoints kept per agent; older refs are deleted on capture so repositories never
  /// accumulate unbounded hidden history.
  public static let retainedCheckpointsPerAgent = 8

  private static let diffByteLimit = 512 * 1024

  private let gitExecutable: URL
  private let checkpointTimeout: TimeInterval
  private var checkpointDeadline: DispatchTime?

  public init() {
    gitExecutable = URL(fileURLWithPath: "/usr/bin/git")
    checkpointTimeout = 2
  }

  // A real subprocess can be stalled deterministically in regression tests.
  init(gitExecutable: URL, checkpointTimeout: TimeInterval) {
    self.gitExecutable = gitExecutable
    self.checkpointTimeout = checkpointTimeout
  }

  /// Captures the working tree at `directory` and returns the checkpoint ref name, or nil when
  /// the directory is not inside a git work tree (no repository means no diff to offer — the
  /// caller should degrade by not showing a summary, not by erroring).
  public func captureCheckpoint(in directory: String, agentID: UUID) throws -> String? {
    // One budget for the whole optional snapshot, including repository probes and pruning.
    // The caller already degrades to no change summary when capture throws.
    checkpointDeadline = .now() + checkpointTimeout
    defer { checkpointDeadline = nil }
    guard isInsideWorkTree(directory) else { return nil }
    let commonDirectory = try gitCommonDirectory(of: directory)
    let temporaryIndex = (commonDirectory as NSString)
      .appendingPathComponent("otto-checkpoint-index-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(atPath: temporaryIndex)
      try? FileManager.default.removeItem(atPath: temporaryIndex + ".lock")
    }

    var environment = ProcessInfo.processInfo.environment
    environment["GIT_INDEX_FILE"] = temporaryIndex
    environment["GIT_AUTHOR_NAME"] = "Otto"
    environment["GIT_AUTHOR_EMAIL"] = "otto@localhost"
    environment["GIT_COMMITTER_NAME"] = "Otto"
    environment["GIT_COMMITTER_EMAIL"] = "otto@localhost"

    if headExists(directory) {
      _ = try runGit(["read-tree", "HEAD"], at: directory, environment: environment)
    }
    _ = try runGit(["add", "-A", "--", "."], at: directory, environment: environment)
    let tree = try runGit(["write-tree"], at: directory, environment: environment)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tree.isEmpty else { throw TurnCheckpointError.git("write-tree returned no tree") }
    let commit = try runGit(
      ["commit-tree", tree, "-m", "otto turn checkpoint"],
      at: directory, environment: environment
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !commit.isEmpty else { throw TurnCheckpointError.git("commit-tree returned no commit") }

    // Millisecond timestamp prefix keeps refs lexically ordered by age for pruning.
    let stamp = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
    let ref = "\(Self.refNamespace)/\(agentID.uuidString)/\(stamp)-\(UUID().uuidString.prefix(8))"
    _ = try runGit(["update-ref", ref, commit], at: directory)
    try pruneCheckpoints(in: directory, agentID: agentID)
    return ref
  }

  /// Per-file additions and deletions between two checkpoints.
  public func changeSummary(
    in directory: String, from baselineRef: String, to completionRef: String
  ) throws -> TurnChangeSummary {
    let numstat = try runGit(
      ["diff", "--no-ext-diff", "--numstat", baselineRef, completionRef], at: directory)
    let files = numstat.split(separator: "\n").compactMap { line -> TurnFileChange? in
      let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard fields.count == 3 else { return nil }
      return TurnFileChange(
        path: String(fields[2]),
        additions: Int(fields[0]),
        deletions: Int(fields[1])
      )
    }
    return TurnChangeSummary(
      directory: directory,
      baselineRef: baselineRef,
      completionRef: completionRef,
      files: files
    )
  }

  /// Unified diff between two checkpoints, optionally scoped to one file, bounded so a huge
  /// turn cannot balloon the review surface.
  public func unifiedDiff(
    in directory: String, from baselineRef: String, to completionRef: String, file: String? = nil
  ) throws -> String {
    var arguments = ["diff", "--no-ext-diff", baselineRef, completionRef]
    if let file {
      arguments.append(contentsOf: ["--", file])
    }
    let diff = try runGit(arguments, at: directory)
    return String(diff.prefix(Self.diffByteLimit))
  }

  /// Restores the exact working-tree snapshot captured before a turn, without moving HEAD or the
  /// current branch. The operation fails closed when the workspace no longer matches the turn's
  /// completion checkpoint, preventing a revert from overwriting later user or agent work.
  public func restoreBaseline(_ summary: TurnChangeSummary) throws {
    let current = try captureEphemeralTree(in: summary.directory)
    let expected = try runGit(
      ["rev-parse", "\(summary.completionRef)^{tree}"], at: summary.directory
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard current.tree == expected else {
      let changed = try runGit(
        ["diff", "--name-only", summary.completionRef, current.commit], at: summary.directory
      ).split(separator: "\n").map(String.init)
      throw TurnCheckpointError.dirtyWorkspace(changed)
    }

    let baselineTree = try runGit(
      ["rev-parse", "\(summary.baselineRef)^{tree}"], at: summary.directory
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let trackedAtCompletion = try runGit(
      ["ls-tree", "-r", "--name-only", summary.completionRef], at: summary.directory
    ).split(separator: "\n").map(String.init)
    let trackedAtBaseline = Set(
      try runGit(["ls-tree", "-r", "--name-only", summary.baselineRef], at: summary.directory)
        .split(separator: "\n").map(String.init))
    _ = try runGit(["read-tree", "--reset", "-u", baselineTree], at: summary.directory)
    for path in trackedAtCompletion where !trackedAtBaseline.contains(path) {
      try? FileManager.default.removeItem(
        atPath: (summary.directory as NSString).appendingPathComponent(path))
    }
  }

  /// Creates a throwaway commit for comparison only. It uses the same private-index mechanism as
  /// normal checkpoints and never changes refs, HEAD, the user's index, or working files.
  private func captureEphemeralTree(in directory: String) throws -> (tree: String, commit: String) {
    let commonDirectory = try gitCommonDirectory(of: directory)
    let temporaryIndex = (commonDirectory as NSString)
      .appendingPathComponent("otto-revert-index-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(atPath: temporaryIndex) }
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_INDEX_FILE"] = temporaryIndex
    environment["GIT_AUTHOR_NAME"] = "Otto"
    environment["GIT_AUTHOR_EMAIL"] = "otto@localhost"
    environment["GIT_COMMITTER_NAME"] = "Otto"
    environment["GIT_COMMITTER_EMAIL"] = "otto@localhost"
    if headExists(directory) {
      _ = try runGit(["read-tree", "HEAD"], at: directory, environment: environment)
    }
    _ = try runGit(["add", "-A", "--", "."], at: directory, environment: environment)
    let tree = try runGit(["write-tree"], at: directory, environment: environment)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let commit = try runGit(
      ["commit-tree", tree, "-m", "otto revert guard"],
      at: directory, environment: environment
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return (tree, commit)
  }

  /// Deletes this agent's oldest checkpoint refs beyond the retention window.
  public func pruneCheckpoints(
    in directory: String, agentID: UUID,
    keeping: Int = TurnCheckpointStore.retainedCheckpointsPerAgent
  ) throws {
    let prefixes = [Self.refNamespace, Self.legacyRefNamespace].map {
      "\($0)/\(agentID.uuidString)/"
    }
    // Ordered by the timestamp leaf so legacy and current refs age out together.
    let refs = try runGit(["for-each-ref", "--format=%(refname)"] + prefixes, at: directory)
      .split(separator: "\n")
      .map(String.init)
      .sorted {
        ($0.split(separator: "/").last ?? "", $0) < ($1.split(separator: "/").last ?? "", $1)
      }
    guard refs.count > keeping else { return }
    for ref in refs.prefix(refs.count - keeping) {
      _ = try runGit(["update-ref", "-d", ref], at: directory)
    }
  }

  private func isInsideWorkTree(_ directory: String) -> Bool {
    (try? runGit(["rev-parse", "--is-inside-work-tree"], at: directory))?
      .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
  }

  private func headExists(_ directory: String) -> Bool {
    (try? runGit(["rev-parse", "--verify", "--quiet", "HEAD"], at: directory)) != nil
  }

  private func gitCommonDirectory(of directory: String) throws -> String {
    let reported = try runGit(["rev-parse", "--git-common-dir"], at: directory)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if (reported as NSString).isAbsolutePath { return reported }
    return (directory as NSString).appendingPathComponent(reported)
  }

  @discardableResult
  private func runGit(
    _ arguments: [String], at directory: String, environment: [String: String]? = nil
  ) throws -> String {
    try Task.checkCancellation()
    let deadline = checkpointDeadline ?? (.now() + 10)
    guard DispatchTime.now() < deadline else {
      throw TurnCheckpointError.git("Snapshot time limit exceeded")
    }
    let process = Process()
    process.executableURL = gitExecutable
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    if let environment { process.environment = environment }

    // Pipes can deadlock if Git fills stderr while we are reading stdout. Files also let us
    // return on timeout without waiting for EOF from a stuck Git process or its children.
    let captureDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-checkpoint-output-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: captureDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: captureDirectory) }
    let outputURL = captureDirectory.appendingPathComponent("stdout")
    let errorsURL = captureDirectory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    FileManager.default.createFile(atPath: errorsURL.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: outputURL)
    let stderr = try FileHandle(forWritingTo: errorsURL)
    defer {
      try? stdout.close()
      try? stderr.close()
    }
    process.standardOutput = stdout
    process.standardError = stderr
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    // Foundation normally gives a child its own process group. Stop that group as well as
    // Git so a blocked clean filter cannot survive a timed-out snapshot.
    let pid = process.processIdentifier
    let ownsProcessGroup = getpgid(pid) == pid
    if exited.wait(timeout: deadline) == .timedOut {
      kill(ownsProcessGroup ? -pid : pid, SIGTERM)
      let stopped = exited.wait(timeout: .now() + 0.1) == .success
      if ownsProcessGroup {
        kill(-pid, SIGKILL)
      } else if !stopped, process.isRunning {
        kill(pid, SIGKILL)
      }
      if !stopped { _ = exited.wait(timeout: .now() + 0.1) }
      throw TurnCheckpointError.git("git \(arguments.first ?? ""): time limit exceeded")
    }
    guard process.terminationStatus == 0 else {
      let errors = try Data(contentsOf: errorsURL)
      throw TurnCheckpointError.git(
        "git \(arguments.joined(separator: " ")): "
          + String(decoding: errors.suffix(2_000), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
    return String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
  }
}
