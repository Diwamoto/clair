import ClairV2DaemonKit
import Darwin
import Dispatch
import Foundation

@main
struct ClairDaemonMain {
  static func main() {
    do {
      let runtime = try ClairDaemonRuntime(
        configuration: ClairDaemonConfiguration(paths: daemonPaths())
      )
      signal(SIGINT, SIG_IGN)
      signal(SIGTERM, SIG_IGN)
      let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
      let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
      let termination = DispatchSemaphore(value: 0)
      interrupt.setEventHandler { termination.signal() }
      terminate.setEventHandler { termination.signal() }
      interrupt.resume()
      terminate.resume()
      try runtime.start()
      withExtendedLifetime(interrupt) {
        withExtendedLifetime(terminate) {
          while runtime.state != .stopped {
            if termination.wait(timeout: .now() + 0.25) == .success {
              try? runtime.stop()
            }
          }
        }
      }
      interrupt.cancel()
      terminate.cancel()
    } catch {
      let message = "ClairDaemon failed to start: \(error.localizedDescription)\n"
      FileHandle.standardError.write(Data(message.utf8))
      exit(EXIT_FAILURE)
    }
  }

  private static func daemonPaths() -> ClairDaemonPaths {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let directoryIndex = arguments.firstIndex(of: "--directory"),
      arguments.indices.contains(directoryIndex + 1)
    else {
      return .default
    }
    return ClairDaemonPaths(directoryURL: URL(fileURLWithPath: arguments[directoryIndex + 1]))
  }
}
