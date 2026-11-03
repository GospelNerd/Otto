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

public struct ControlClient: Sendable {
  private static let requestQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "io.openotto.control.client"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 16
    return queue
  }()

  public let socketPath: String
  public let token: String
  public let sourceNodeID: UUID?
  public let sourceCanvasID: UUID?

  public init(
    socketPath: String,
    token: String,
    sourceNodeID: UUID? = nil,
    sourceCanvasID: UUID? = nil
  ) {
    self.socketPath = socketPath
    self.token = token
    self.sourceNodeID = sourceNodeID
    self.sourceCanvasID = sourceCanvasID
  }

  public func listTools() throws -> [ToolDefinition] {
    let response = try request(ControlRequest(method: .toolsList, token: token))
    guard let result = response.result else {
      throw ControlProtocolError.invalidRequest("tools/list returned no result")
    }
    return try result.decode([ToolDefinition].self)
  }

  public func listToolsAsync() async throws -> [ToolDefinition] {
    let response = try await requestAsync(ControlRequest(method: .toolsList, token: token))
    guard let result = response.result else {
      throw ControlProtocolError.invalidRequest("tools/list returned no result")
    }
    return try result.decode([ToolDefinition].self)
  }

  public func call(
    _ name: String,
    arguments: JSONValue = .object([:]),
    confirmed: Bool = false,
    requestID: String = UUID().uuidString,
    timeoutMilliseconds: Int32? = nil
  ) throws -> JSONValue {
    let response = try request(
      ControlRequest(
        id: requestID,
        method: .toolsCall,
        token: token,
        toolName: name,
        arguments: arguments,
        confirmed: confirmed,
        sourceNodeID: sourceNodeID,
        sourceCanvasID: sourceCanvasID
      ),
      timeoutMilliseconds: timeoutMilliseconds
    )
    guard let result = response.result else {
      throw ControlProtocolError.invalidRequest("tools/call returned no result")
    }
    return result
  }

  public func callAsync(
    _ name: String,
    arguments: JSONValue = .object([:]),
    confirmed: Bool = false,
    requestID: String = UUID().uuidString,
    timeoutMilliseconds: Int32? = nil
  ) async throws -> JSONValue {
    let response = try await requestAsync(
      ControlRequest(
        id: requestID,
        method: .toolsCall,
        token: token,
        toolName: name,
        arguments: arguments,
        confirmed: confirmed,
        sourceNodeID: sourceNodeID,
        sourceCanvasID: sourceCanvasID
      ),
      timeoutMilliseconds: timeoutMilliseconds
    )
    guard let result = response.result else {
      throw ControlProtocolError.invalidRequest("tools/call returned no result")
    }
    return result
  }

  private func request(
    _ request: ControlRequest,
    timeoutMilliseconds: Int32? = nil
  ) throws -> ControlResponse {
    let maximumAttempts = request.method == .toolsList ? 3 : 1
    var lastError: (any Error)?
    for _ in 0..<maximumAttempts {
      do {
        return try requestOnce(request, timeoutMilliseconds: timeoutMilliseconds)
      } catch {
        lastError = error
      }
    }
    throw lastError ?? ControlProtocolError.socket("Control request failed")
  }

  private func requestOnce(
    _ request: ControlRequest,
    timeoutMilliseconds: Int32? = nil
  ) throws -> ControlResponse {
    let descriptor = try UnixSocket.create()
    defer { systemClose(descriptor) }
    try UnixSocket.connect(descriptor, path: socketPath)
    try UnixSocket.setNonBlocking(descriptor)
    try UnixSocket.writeMessage(request, to: descriptor)
    let response = try UnixSocket.readMessage(
      ControlResponse.self,
      from: descriptor,
      timeoutMilliseconds: timeoutMilliseconds ?? UnixSocket.clientResponseTimeoutMilliseconds
    )
    if let failure = response.error { throw ControlProtocolError.remote(failure) }
    return response
  }

  private func requestAsync(
    _ request: ControlRequest,
    timeoutMilliseconds: Int32? = nil
  ) async throws -> ControlResponse {
    try await withCheckedThrowingContinuation { continuation in
      Self.requestQueue.addOperation {
        continuation.resume(
          with: Result { try self.request(request, timeoutMilliseconds: timeoutMilliseconds) })
      }
    }
  }
}
