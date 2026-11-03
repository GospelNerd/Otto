import Dispatch
import Foundation
import OttoTools

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

public final class ControlServer: @unchecked Sendable {
  public let socketPath: String

  private let registry: ToolRegistry
  private let authenticator: ControlAuthenticator
  private let listener: Int32
  private let source: DispatchSourceRead
  private let stateLock = NSLock()
  private var stopped = false

  public init(
    socketPath: String,
    registry: ToolRegistry,
    authenticator: ControlAuthenticator
  ) throws {
    self.socketPath = socketPath
    self.registry = registry
    self.authenticator = authenticator
    let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directory.path, 0o700)
    unlink(socketPath)

    let listener = try UnixSocket.create()
    do {
      try UnixSocket.bind(listener, path: socketPath)
      guard systemListen(listener, SOMAXCONN) == 0 else { throw UnixSocket.socketError() }
      try UnixSocket.setNonBlocking(listener)
      chmod(socketPath, 0o600)
    } catch {
      systemClose(listener)
      throw error
    }
    self.listener = listener
    self.source = DispatchSource.makeReadSource(
      fileDescriptor: listener,
      queue: DispatchQueue(label: "io.openotto.control.accept", qos: .userInitiated)
    )
    self.source.setEventHandler { [weak self] in self?.acceptConnections() }
    self.source.setCancelHandler {}
    self.source.resume()
  }

  deinit {
    stop()
  }

  public func stop() {
    stateLock.withLock {
      guard !stopped else { return }
      stopped = true
      source.cancel()
      systemClose(listener)
      unlink(socketPath)
    }
  }

  private func acceptConnections() {
    while true {
      let client = systemAccept(listener)
      if client < 0 {
        if errno == EINTR { continue }
        return
      }
      do {
        try UnixSocket.setNonBlocking(client)
        try UnixSocket.setCloseOnExec(client)
      } catch {
        systemClose(client)
        continue
      }
      // Reading the request can wait up to the I/O timeout, so it gets its own thread.
      // Request handling then runs as a Task.
      UnixSocket.detachBlockingWork(name: "io.openotto.control.connection") { [weak self] in
        self?.readAndHandle(client)
      }
    }
  }

  private func readAndHandle(_ client: Int32) {
    let request: ControlRequest
    do {
      request = try UnixSocket.readMessage(ControlRequest.self, from: client)
    } catch {
      try? UnixSocket.writeMessage(
        ControlResponse(
          id: "unknown",
          error: ControlFailure(code: "invalid_request", message: error.localizedDescription)
        ),
        to: client
      )
      systemClose(client)
      return
    }
    Task { [weak self] in
      guard let self else {
        systemClose(client)
        return
      }
      await handle(request, client: client)
    }
  }

  private func handle(_ request: ControlRequest, client: Int32) async {
    defer { systemClose(client) }
    let response = await process(request)
    try? UnixSocket.writeMessage(response, to: client)
  }

  private func process(_ request: ControlRequest) async -> ControlResponse {
    guard let grant = await authenticator.resolve(request.token) else {
      return ControlResponse(
        id: request.id,
        error: ControlFailure(code: "unauthorized", message: "Invalid or expired control token")
      )
    }

    let context = ToolContext(
      actorID: grant.actorID, scopes: grant.scopes, confirmed: request.confirmed,
      source: grant.source, sourceNodeID: grant.sourceNodeID ?? request.sourceNodeID,
      sourceCanvasID: grant.sourceCanvasID ?? request.sourceCanvasID,
      targetCanvasID: grant.sourceCanvasID ?? request.targetCanvasID,
      interactionPrivileges: grant.interactionPrivileges)
    do {
      switch request.method {
      case .toolsList:
        return ControlResponse(
          id: request.id, result: try JSONValue.encode(await registry.definitions(for: context)))
      case .toolsCall:
        guard let name = request.toolName else {
          throw ControlProtocolError.invalidRequest("tools/call requires toolName")
        }
        let result = try await registry.call(
          name: name,
          input: request.arguments ?? .object([:]),
          context: context,
          requestID: request.id
        )
        return ControlResponse(id: request.id, result: result)
      }
    } catch {
      return ControlResponse(
        id: request.id,
        error: ControlFailure(code: "tool_error", message: error.localizedDescription)
      )
    }
  }
}
