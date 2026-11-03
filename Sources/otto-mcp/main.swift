import Foundation
import OttoControl
import OttoMCP
import OttoModels

@main
struct OttoMCPCommand {
  private static let usage = """
    Usage: otto-mcp

    Runs the Otto Model Context Protocol bridge over standard input and output.
    Otto launches this helper with a scoped control socket and token.
    """

  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
      print(usage)
      return
    }
    guard arguments.isEmpty else {
      FileHandle.standardError.write(Data("\(usage)\n".utf8))
      Foundation.exit(64)
    }
    let environment = ProcessInfo.processInfo.environment
    guard let socket = OttoEnvironment.value("CONTROL_SOCKET", in: environment),
      let token = OttoEnvironment.value("CONTROL_TOKEN", in: environment)
    else {
      FileHandle.standardError.write(Data("Missing Otto control environment.\n".utf8))
      Foundation.exit(2)
    }

    let client = ControlClient(
      socketPath: socket,
      token: token,
      sourceNodeID: OttoEnvironment.value("NODE_ID", in: environment).flatMap(
        UUID.init(uuidString:)),
      sourceCanvasID: OttoEnvironment.value("CANVAS_ID", in: environment).flatMap(
        UUID.init(uuidString:))
    )
    let dispatcher = MCPRequestDispatcher(
      handle: { line, cancellation in
        MCPBridge(client: client, isCancelled: { cancellation.isCancelled }).handle(line: line)
      },
      write: { response in
        print(response)
        #if os(Linux)
          // Glibc declares `stdout` as a mutable global, which Swift 6 rejects in this
          // concurrent closure. fflush(nil) flushes every output stream, stdout included.
          fflush(nil)
        #else
          fflush(stdout)
        #endif
      }
    )
    while let line = readLine() {
      dispatcher.submit(line: line)
    }
    dispatcher.waitUntilFinished()
  }
}
