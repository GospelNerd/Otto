import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

enum UnixSocket {
  static let messageLimit = 1_048_576
  static let ioTimeoutMilliseconds: Int32 = 10_000
  static let clientResponseTimeoutMilliseconds: Int32 = 10_000

  static func create() throws -> Int32 {
    #if os(Linux)
      #if canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
      #else
        let socketType = SOCK_STREAM
      #endif
      let descriptor = socket(AF_UNIX, socketType, 0)
    #else
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard descriptor >= 0 else { throw socketError() }
    // Linux has no SO_NOSIGPIPE; writes use send(MSG_NOSIGNAL) instead (see systemWrite).
    #if !os(Linux)
      var noSignal: Int32 = 1
      guard
        setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          &noSignal,
          socklen_t(MemoryLayout<Int32>.size)
        ) == 0
      else {
        let error = socketError()
        systemClose(descriptor)
        throw error
      }
    #endif
    do {
      try setCloseOnExec(descriptor)
    } catch {
      systemClose(descriptor)
      throw error
    }
    return descriptor
  }

  static func address(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count + 1 < capacity else {
      throw ControlProtocolError.socket("Unix socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      for (index, byte) in bytes.enumerated() {
        buffer[index] = byte
      }
    }
    return address
  }

  static func bind(_ descriptor: Int32, path: String) throws {
    var address = try address(for: path)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        systemBind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw socketError() }
  }

  static func connect(_ descriptor: Int32, path: String) throws {
    var address = try address(for: path)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        systemConnect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw socketError() }
  }

  static func setNonBlocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw socketError()
    }
  }

  static func setCloseOnExec(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFD)
    guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
      throw socketError()
    }
  }

  static func writeMessage<T: Encodable>(_ value: T, to descriptor: Int32) throws {
    var data = try JSONEncoder.control.encode(value)
    data.append(0x0a)
    try data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var remaining = buffer.count
      var offset = 0
      while remaining > 0 {
        let written = systemWrite(descriptor, base.advanced(by: offset), remaining)
        if written < 0 {
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK {
            try waitFor(descriptor, event: Int16(POLLOUT))
            continue
          }
          throw socketError()
        }
        remaining -= written
        offset += written
      }
    }
  }

  static func readMessage<T: Decodable>(
    _ type: T.Type,
    from descriptor: Int32,
    timeoutMilliseconds: Int32 = ioTimeoutMilliseconds
  ) throws -> T {
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 8_192)
    while data.count <= messageLimit {
      let count = systemRead(descriptor, &bytes, bytes.count)
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          try waitFor(
            descriptor,
            event: Int16(POLLIN),
            timeoutMilliseconds: timeoutMilliseconds
          )
          continue
        }
        throw socketError()
      }
      if count == 0 { break }
      data.append(contentsOf: bytes.prefix(count))
      if let newline = data.firstIndex(of: 0x0a) {
        data = data[..<newline]
        break
      }
    }
    guard data.count <= messageLimit else { throw ControlProtocolError.responseTooLarge }
    do {
      return try JSONDecoder.control.decode(type, from: data)
    } catch {
      throw ControlProtocolError.invalidRequest(error.localizedDescription)
    }
  }

  /// Runs blocking socket work on a thread of its own, off the shared worker pool.
  ///
  /// `poll()` waits can last up to the I/O timeout. Running them on OperationQueue,
  /// Dispatch, or the Swift concurrency pool takes a thread the server needs to answer.
  /// On Linux that pool is sized to about the CPU count and grows only about one thread per
  /// second, so a burst of waiting clients starves the server until requests time out.
  static func detachBlockingWork(
    name: String,
    _ work: @escaping @Sendable () -> Void
  ) {
    let thread = Thread(block: work)
    thread.name = name
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  static func socketError() -> ControlProtocolError {
    ControlProtocolError.socket(String(cString: strerror(errno)))
  }

  private static func waitFor(
    _ descriptor: Int32,
    event: Int16,
    timeoutMilliseconds: Int32 = ioTimeoutMilliseconds
  ) throws {
    var pollDescriptor = pollfd(fd: descriptor, events: event, revents: 0)
    while true {
      let result = poll(&pollDescriptor, 1, timeoutMilliseconds)
      if result > 0 { return }
      if result < 0, errno == EINTR { continue }
      if result == 0 {
        throw ControlProtocolError.socket("Unix socket I/O timed out")
      }
      throw socketError()
    }
  }
}

// Platform-neutral POSIX wrappers. Darwin keeps its module-qualified calls unchanged; Linux uses
// the Glibc/Musl globals. Mirrors the helpers in OttoRemote/RemoteSocketTransport.swift.
func systemClose(_ descriptor: Int32) {
  #if os(Linux)
    _ = close(descriptor)
  #else
    _ = Darwin.close(descriptor)
  #endif
}

func systemListen(_ descriptor: Int32, _ backlog: Int32) -> Int32 {
  #if os(Linux)
    listen(descriptor, backlog)
  #else
    Darwin.listen(descriptor, backlog)
  #endif
}

func systemAccept(_ descriptor: Int32) -> Int32 {
  #if os(Linux)
    accept(descriptor, nil, nil)
  #else
    Darwin.accept(descriptor, nil, nil)
  #endif
}

private func systemBind(
  _ descriptor: Int32,
  _ address: UnsafePointer<sockaddr>,
  _ length: socklen_t
) -> Int32 {
  #if os(Linux)
    bind(descriptor, address, length)
  #else
    Darwin.bind(descriptor, address, length)
  #endif
}

private func systemConnect(
  _ descriptor: Int32,
  _ address: UnsafePointer<sockaddr>,
  _ length: socklen_t
) -> Int32 {
  #if os(Linux)
    connect(descriptor, address, length)
  #else
    Darwin.connect(descriptor, address, length)
  #endif
}

private func systemWrite(
  _ descriptor: Int32,
  _ buffer: UnsafeRawPointer,
  _ count: Int
) -> Int {
  #if os(Linux)
    send(descriptor, buffer, count, Int32(MSG_NOSIGNAL))
  #else
    Darwin.write(descriptor, buffer, count)
  #endif
}

private func systemRead(
  _ descriptor: Int32,
  _ buffer: UnsafeMutableRawPointer,
  _ count: Int
) -> Int {
  #if os(Linux)
    read(descriptor, buffer, count)
  #else
    Darwin.read(descriptor, buffer, count)
  #endif
}

extension JSONEncoder {
  fileprivate static var control: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var control: JSONDecoder { JSONDecoder() }
}
