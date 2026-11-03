import Foundation
import OttoControl
import OttoTools
import Testing

private struct GreetingInput: Codable, Sendable { let name: String }
private struct GreetingOutput: Codable, Sendable, Equatable { let message: String }
private struct EmptyInput: Codable, Sendable {}

private struct GreetingTool: OttoTool {
  static let definition = ToolDefinition(
    name: "test.greet",
    description: "Produces a deterministic greeting.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  func call(_ input: GreetingInput, context: ToolContext) async throws -> GreetingOutput {
    GreetingOutput(message: "Hello, \(input.name)")
  }
}

private struct ContextOutput: Codable, Sendable, Equatable {
  let sourceNodeID: UUID?
  let sourceCanvasID: UUID?
  let targetCanvasID: UUID?
}

private struct ContextTool: OttoTool {
  static let definition = ToolDefinition(
    name: "test.context",
    description: "Returns authenticated invocation provenance.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  func call(_ input: EmptyInput, context: ToolContext) async throws -> ContextOutput {
    ContextOutput(
      sourceNodeID: context.sourceNodeID,
      sourceCanvasID: context.sourceCanvasID,
      targetCanvasID: context.targetCanvasID
    )
  }
}

@Suite("Authenticated Unix control socket")
struct ControlServerTests {
  @Test("Client lists and calls the shared registry over a user-private socket")
  func endToEndCall() async throws {
    let fixture = try await ControlFixture()
    defer {
      fixture.server.stop()
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    let definitions = try await fixture.client.listToolsAsync()
    #expect(definitions == [GreetingTool.definition])

    let result = try await fixture.client.callAsync(
      "test.greet",
      arguments: .object(["name": .string("Otto")]),
      requestID: "socket-e2e"
    )
    #expect(try result.decode(GreetingOutput.self) == GreetingOutput(message: "Hello, Otto"))
    #expect(await fixture.registry.auditLog().map(\.requestID) == ["socket-e2e"])

    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test("Invalid tokens cannot list or invoke tools")
  func deniesInvalidToken() async throws {
    let fixture = try await ControlFixture()
    defer {
      fixture.server.stop()
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    let attacker = ControlClient(socketPath: fixture.server.socketPath, token: "not-a-token")

    await #expect(throws: (any Error).self) {
      try await attacker.listToolsAsync()
    }
    #expect(await fixture.registry.auditLog().isEmpty)
  }

  @Test("Actor teardown revokes every issued grant")
  func actorRevocation() async {
    let authenticator = ControlAuthenticator()
    let first = await authenticator.issue(actorID: "node-1", scopes: [.canvasRead])
    let second = await authenticator.issue(actorID: "node-1", scopes: [.agentRead])
    let unrelated = await authenticator.issue(actorID: "node-2", scopes: [.canvasRead])

    #expect(await authenticator.revokeAll(actorID: "node-1") == 2)
    #expect(await authenticator.resolve(first) == nil)
    #expect(await authenticator.resolve(second) == nil)
    #expect(await authenticator.resolve(unrelated) != nil)
  }

  @Test("Agent grants bind provenance and canvas targeting to the authenticated token")
  func boundAgentProvenance() async throws {
    let directory = URL(fileURLWithPath: "/tmp/otto-\(UUID().uuidString.prefix(12))")
    let registry = ToolRegistry()
    try await registry.register(ContextTool())
    let authenticator = ControlAuthenticator()
    let nodeID = UUID()
    let canvasID = UUID()
    let token = await authenticator.issue(
      actorID: "bound-agent",
      scopes: [.canvasRead],
      source: .agent,
      sourceNodeID: nodeID,
      sourceCanvasID: canvasID
    )
    let server = try ControlServer(
      socketPath: directory.appending(path: "control.sock").path,
      registry: registry,
      authenticator: authenticator
    )
    defer {
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    let client = ControlClient(
      socketPath: server.socketPath,
      token: token,
      sourceNodeID: UUID(),
      sourceCanvasID: UUID()
    )

    let output = try await client.callAsync("test.context").decode(ContextOutput.self)
    #expect(
      output
        == ContextOutput(
          sourceNodeID: nodeID,
          sourceCanvasID: canvasID,
          targetCanvasID: canvasID
        ))
  }

  @Test("Dev and production instances keep isolated per-process control planes")
  func devInstanceControlPlaneParity() async throws {
    // scripts/dev-app.sh installs "Otto Dev.app" (io.openotto.desktop.dev) beside production, so
    // two live app instances are a supported configuration. Each derives its own
    // /tmp/otto-<pid>-<uuid> socket and its own authenticator, which is the whole parity
    // claim: clients reach exactly the instance whose scoped environment they hold, and one
    // instance's grants are worthless against the other.
    let production = try await InstanceFixture(label: "production")
    let dev = try await InstanceFixture(label: "dev")
    defer {
      production.tearDown()
      dev.tearDown()
    }
    #expect(production.server.socketPath != dev.server.socketPath)

    let fromProduction = try await production.client.callAsync("test.instance")
      .decode(InstanceOutput.self)
    let fromDev = try await dev.client.callAsync("test.instance").decode(InstanceOutput.self)
    #expect(fromProduction == InstanceOutput(instance: "production"))
    #expect(fromDev == InstanceOutput(instance: "dev"))

    // A production grant presented to the dev instance must be rejected, and the dev audit
    // log must show only the dev instance's own traffic.
    let crossed = ControlClient(socketPath: dev.server.socketPath, token: production.token)
    await #expect(throws: (any Error).self) {
      try await crossed.callAsync("test.instance")
    }
    #expect(await dev.registry.auditLog().count == 1)
  }

  @Test("ottoctl reaches the instance named in its scoped environment")
  func ottoctlReachesScopedInstance() async throws {
    // The same discovery contract otto-mcp uses: OTTO_CONTROL_SOCKET/OTTO_CONTROL_TOKEN
    // injected per spawned process. Running the real product against a dev-simulated
    // instance proves an installed Otto Dev.app serves its own CLI, not production's.
    let dev = try await InstanceFixture(label: "dev")
    defer { dev.tearDown() }

    let process = Process()
    process.executableURL = try builtExecutableURL(named: "ottoctl")
    process.arguments = ["call", "test.instance"]
    process.environment = [
      "OTTO_CONTROL_SOCKET": dev.server.socketPath,
      "OTTO_CONTROL_TOKEN": dev.token,
    ]
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    process.waitUntilExit()

    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0)
    #expect(output.contains("\"instance\" : \"dev\""), "unexpected ottoctl output: \(output)")
  }

  @Test("Listener drains a concurrent client backlog without stranded connections")
  func concurrentBacklog() async throws {
    let fixture = try await ControlFixture()
    defer {
      fixture.server.stop()
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    let client = fixture.client
    let counts = try await withThrowingTaskGroup(of: Int.self, returning: [Int].self) { group in
      for _ in 0..<100 {
        group.addTask { try await client.listToolsAsync().count }
      }
      var values: [Int] = []
      for try await value in group { values.append(value) }
      return values
    }
    #expect(counts.count == 100)
    #expect(counts.allSatisfy { $0 == 1 })
  }

  @Test("A request burst wider than the shared worker pool completes promptly")
  func burstDoesNotStarveServer() async throws {
    // Regression test for thread starvation. Blocking socket waits used to run on capped
    // OperationQueues. Linux libdispatch sizes its worker pool to about the CPU count and adds
    // roughly one thread per second when they block, so a burst of waiting clients left the
    // server with no thread to answer them. Each call has a short deadline, so starvation shows
    // up as a timeout instead of a slow pass.
    let fixture = try await ControlFixture()
    defer {
      fixture.server.stop()
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    let client = fixture.client
    let burst = max(48, ProcessInfo.processInfo.activeProcessorCount * 4)
    let clock = ContinuousClock()
    let start = clock.now
    let messages = try await withThrowingTaskGroup(of: String.self, returning: [String].self) {
      group in
      for index in 0..<burst {
        group.addTask {
          try await client.callAsync(
            "test.greet",
            arguments: .object(["name": .string("burst-\(index)")]),
            timeoutMilliseconds: 3_000
          ).decode(GreetingOutput.self).message
        }
      }
      var values: [String] = []
      for try await value in group { values.append(value) }
      return values
    }
    #expect(messages.count == burst)
    #expect(Set(messages).count == burst)
    #expect(clock.now - start < .seconds(5))
  }
}

private struct InstanceOutput: Codable, Sendable, Equatable { let instance: String }

/// Names the control-plane instance that served the call, so routing between concurrently
/// running app instances is observable.
private struct InstanceTool: OttoTool {
  static let definition = ToolDefinition(
    name: "test.instance",
    description: "Returns the identity of the serving instance.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  let label: String

  func call(_ input: EmptyInput, context: ToolContext) async throws -> InstanceOutput {
    InstanceOutput(instance: label)
  }
}

/// One simulated app instance: the same per-process socket derivation the app performs in
/// ApplicationServices, with its own registry and authenticator.
private struct InstanceFixture {
  let directory: URL
  let registry: ToolRegistry
  let server: ControlServer
  let client: ControlClient
  let token: String

  init(label: String) async throws {
    directory = URL(
      fileURLWithPath: "/tmp/otto-\(getpid())-\(UUID().uuidString.prefix(6))")
    registry = ToolRegistry()
    try await registry.register(InstanceTool(label: label))
    let authenticator = ControlAuthenticator()
    token = await authenticator.issue(actorID: "instance-\(label)", scopes: [.canvasRead])
    server = try ControlServer(
      socketPath: directory.appending(path: "control.sock").path,
      registry: registry,
      authenticator: authenticator
    )
    client = ControlClient(socketPath: server.socketPath, token: token)
  }

  func tearDown() {
    server.stop()
    try? FileManager.default.removeItem(at: directory)
  }
}

private func builtExecutableURL(named name: String) throws -> URL {
  #if canImport(Darwin)
    let bundleOrigins =
      Bundle.allBundles.compactMap(\.executableURL)
      + Bundle.allFrameworks.compactMap(\.executableURL)
  #else
    // Bundle.allBundles can crash in swift-corelibs-foundation when tests run in parallel
    // (seen with Swift 6.2.4); the running test binary is enough to find the build directory.
    let bundleOrigins = [URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()]
  #endif
  let origins =
    bundleOrigins
    + CommandLine.arguments
    .filter { $0.hasPrefix("/") }
    .map { URL(fileURLWithPath: $0) }
  for origin in origins {
    var directory = origin.standardizedFileURL.deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = directory.appending(path: name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
      directory.deleteLastPathComponent()
    }
  }
  throw CocoaError(.fileNoSuchFile)
}

private struct ControlFixture {
  let directory: URL
  let registry: ToolRegistry
  let server: ControlServer
  let client: ControlClient

  init() async throws {
    directory = URL(fileURLWithPath: "/tmp/otto-\(UUID().uuidString.prefix(12))")
    registry = ToolRegistry()
    try await registry.register(GreetingTool())
    let authenticator = ControlAuthenticator()
    let token = await authenticator.issue(actorID: "integration-test", scopes: [.canvasRead])
    let socketPath = directory.appending(path: "control.sock").path
    server = try ControlServer(
      socketPath: socketPath,
      registry: registry,
      authenticator: authenticator
    )
    client = ControlClient(socketPath: socketPath, token: token)
  }
}
