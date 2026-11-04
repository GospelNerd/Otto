import Foundation
import Testing

@testable import OttoWorktrees

@Suite("Turn checkpoints")
struct TurnCheckpointsTests {
  @Test("A stalled snapshot is bounded, cleaned up, and does not block the next capture")
  func stalledSnapshotTimesOut() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.write("tracked.txt", "committed\n")
    try repo.commitAll("base")
    try repo.write("tracked.txt", "staged\n")
    try repo.git(["add", "tracked.txt"])
    try repo.write("tracked.txt", "unstaged\n")
    let indexBefore = try Data(contentsOf: URL(fileURLWithPath: repo.file(".git/index")))
    let headBefore = try repo.git(["rev-parse", "HEAD"])
    // Use exec so the deliberately uncooperative helper is the exact process being killed.
    // The marker and wrapper live outside the work tree and cannot enter a snapshot.
    let helper = URL(fileURLWithPath: repo.path).appendingPathExtension("helper")
    try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: helper) }
    let marker = helper.appendingPathComponent("stall")
    try Data().write(to: marker)
    let executable = helper.appendingPathComponent("git")
    try """
    #!/bin/sh
    if [ "$1" = add ] && [ -f '\(marker.path)' ]; then
      echo $$ > '\(helper.path)/pid'
      touch "$GIT_INDEX_FILE.lock"
      trap '' TERM
      exec /bin/sleep 30
    fi
    exec /usr/bin/git "$@"
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let checkpoints = TurnCheckpointStore(gitExecutable: executable, checkpointTimeout: 0.8)
    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: TurnCheckpointError.self) {
      try await checkpoints.captureCheckpoint(in: repo.path, agentID: UUID())
    }
    #expect(start.duration(to: clock.now) < .seconds(3))
    let pid = try #require(
      Int32(
        String(contentsOf: helper.appendingPathComponent("pid"), encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    // The killed child must have been reaped, rather than left running in the background.
    #expect(kill(pid, 0) == -1)
    #expect(try Data(contentsOf: URL(fileURLWithPath: repo.file(".git/index"))) == indexBefore)
    #expect(try repo.git(["rev-parse", "HEAD"]) == headBefore)
    #expect(try String(contentsOfFile: repo.file("tracked.txt"), encoding: .utf8) == "unstaged\n")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: repo.file(".git"))
        .allSatisfy { !$0.hasPrefix("otto-checkpoint-index-") })

    try FileManager.default.removeItem(at: marker)
    #expect(try await checkpoints.captureCheckpoint(in: repo.path, agentID: UUID()) != nil)
  }

  @Test("Git output larger than a pipe buffer cannot deadlock checkpoint capture")
  func drainsBothOutputStreams() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.commitAll("base")
    let executable = URL(fileURLWithPath: repo.path).appendingPathExtension("git")
    defer { try? FileManager.default.removeItem(at: executable) }
    try """
    #!/bin/sh
    if [ "$1" = add ]; then
      /usr/bin/head -c 131072 /dev/zero >&2
      /usr/bin/head -c 131072 /dev/zero
    fi
    exec /usr/bin/git "$@"
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let checkpoints = TurnCheckpointStore(gitExecutable: executable, checkpointTimeout: 2)
    #expect(try await checkpoints.captureCheckpoint(in: repo.path, agentID: UUID()) != nil)
  }

  @Test("A turn's edits, additions, and deletions are summarized between checkpoints")
  func summarizesTurn() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.write("existing.txt", "one\ntwo\nthree\n")
    try repo.commitAll("base")

    let store = TurnCheckpointStore()
    let agentID = UUID()
    let baseline = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))

    try repo.write("existing.txt", "one\nTWO\nthree\nfour\n")
    try repo.write("created.txt", "fresh\n")
    try FileManager.default.removeItem(atPath: repo.file("todo-delete.txt"))

    let completion = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    let summary = try await store.changeSummary(
      in: repo.path, from: baseline, to: completion)

    let byPath = Dictionary(uniqueKeysWithValues: summary.files.map { ($0.path, $0) })
    #expect(byPath.count == 3)
    #expect(byPath["created.txt"]?.additions == 1)
    #expect(byPath["created.txt"]?.deletions == 0)
    #expect(byPath["todo-delete.txt"]?.deletions == 1)
    #expect(byPath["existing.txt"]?.additions == 2)
    #expect(byPath["existing.txt"]?.deletions == 1)
    #expect(summary.totalAdditions == 3)
    #expect(summary.totalDeletions == 2)

    let fullDiff = try await store.unifiedDiff(
      in: repo.path, from: baseline, to: completion)
    #expect(fullDiff.contains("+TWO"))
    #expect(fullDiff.contains("+fresh"))
    let scoped = try await store.unifiedDiff(
      in: repo.path, from: baseline, to: completion, file: "created.txt")
    #expect(scoped.contains("+fresh"))
    #expect(!scoped.contains("TWO"))
  }

  @Test("Checkpoints never disturb the user's index, branch, or working tree")
  func leavesUserStateUntouched() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.write("tracked.txt", "committed\n")
    try repo.commitAll("base")
    // The user has a deliberately staged change and an unstaged one in flight.
    try repo.write("tracked.txt", "staged edit\n")
    try repo.git(["add", "tracked.txt"])
    try repo.write("unstaged.txt", "loose\n")
    let statusBefore = try repo.git(["status", "--porcelain=v1"])
    let headBefore = try repo.git(["rev-parse", "HEAD"])

    let store = TurnCheckpointStore()
    _ = try #require(try await store.captureCheckpoint(in: repo.path, agentID: UUID()))

    #expect(try repo.git(["status", "--porcelain=v1"]) == statusBefore)
    #expect(try repo.git(["rev-parse", "HEAD"]) == headBefore)
    #expect(try repo.git(["symbolic-ref", "HEAD"]).contains("refs/heads/"))
  }

  @Test("Binary files summarize without line counts")
  func binaryFiles() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.commitAll("base", allowEmpty: true)
    let store = TurnCheckpointStore()
    let agentID = UUID()
    let baseline = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))

    try Data([0, 1, 2, 0, 4]).write(to: URL(fileURLWithPath: repo.file("blob.bin")))
    let completion = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    let summary = try await store.changeSummary(
      in: repo.path, from: baseline, to: completion)

    #expect(summary.files.map(\.path) == ["blob.bin"])
    #expect(summary.files[0].additions == nil)
    #expect(summary.files[0].deletions == nil)
    #expect(summary.totalAdditions == 0)
  }

  @Test("Old checkpoints are pruned to the retention window")
  func prunesOldCheckpoints() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.commitAll("base", allowEmpty: true)
    let store = TurnCheckpointStore()
    let agentID = UUID()
    for turn in 0..<(TurnCheckpointStore.retainedCheckpointsPerAgent + 3) {
      try repo.write("churn.txt", "turn \(turn)\n")
      _ = try await store.captureCheckpoint(in: repo.path, agentID: agentID)
    }
    let refs = try repo.git([
      "for-each-ref", "--format=%(refname)", "refs/otto/checkpoints/\(agentID.uuidString)/",
    ])
    let count = refs.split(separator: "\n").count
    #expect(count == TurnCheckpointStore.retainedCheckpointsPerAgent)
  }

  @Test("Directories outside any repository yield no checkpoint")
  func nonRepositoryDirectories() async throws {
    let directory = NSTemporaryDirectory() + "otto-nonrepo-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let store = TurnCheckpointStore()
    #expect(try await store.captureCheckpoint(in: directory, agentID: UUID()) == nil)
  }

  @Test("Restore returns the workspace to the exact baseline without moving HEAD")
  func restoresBaseline() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.write("existing.txt", "before\n")
    try repo.commitAll("base")
    let head = try repo.git(["rev-parse", "HEAD"])
    let store = TurnCheckpointStore()
    let agentID = UUID()
    let baseline = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    try repo.write("existing.txt", "after\n")
    try repo.write("new.txt", "created\n")
    let completion = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    let summary = try await store.changeSummary(
      in: repo.path, from: baseline, to: completion)

    try await store.restoreBaseline(summary)

    #expect(try String(contentsOfFile: repo.file("existing.txt"), encoding: .utf8) == "before\n")
    #expect(!FileManager.default.fileExists(atPath: repo.file("new.txt")))
    #expect(try repo.git(["rev-parse", "HEAD"]) == head)
  }

  @Test("Restore refuses to overwrite changes made after the completed turn")
  func restoreFailsClosedOnLaterChanges() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.write("existing.txt", "before\n")
    try repo.commitAll("base")
    let store = TurnCheckpointStore()
    let agentID = UUID()
    let baseline = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    try repo.write("existing.txt", "after\n")
    let completion = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    let summary = try await store.changeSummary(
      in: repo.path, from: baseline, to: completion)
    try repo.write("later.txt", "do not lose\n")

    await #expect(throws: TurnCheckpointError.self) {
      try await store.restoreBaseline(summary)
    }
    #expect(try String(contentsOfFile: repo.file("existing.txt"), encoding: .utf8) == "after\n")
    #expect(try String(contentsOfFile: repo.file("later.txt"), encoding: .utf8) == "do not lose\n")
  }
}

private struct TemporaryRepo {
  let path: String

  init() throws {
    path = NSTemporaryDirectory() + "otto-turnrepo-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try git(["init", "--initial-branch=main"])
    try git(["config", "user.name", "Test"])
    try git(["config", "user.email", "test@localhost"])
    try write("todo-delete.txt", "doomed\n")
  }

  func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

  func cleanup() { try? FileManager.default.removeItem(atPath: path) }

  func write(_ name: String, _ content: String) throws {
    try content.write(toFile: file(name), atomically: true, encoding: .utf8)
  }

  func commitAll(_ message: String, allowEmpty: Bool = false) throws {
    try git(["add", "-A"])
    var arguments = ["commit", "-m", message]
    if allowEmpty { arguments.append("--allow-empty") }
    try git(arguments)
  }

  @discardableResult
  func git(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw TurnCheckpointError.git("git \(arguments.joined(separator: " ")) failed")
    }
    return String(decoding: output, as: UTF8.self)
  }
}
