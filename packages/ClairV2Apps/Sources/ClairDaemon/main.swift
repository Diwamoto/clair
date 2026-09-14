import ClairV2Agent
import ClairV2DaemonKit
import ClairV2Push
import ClairV2Transport
import ClairV2Workspace
import Darwin
import Dispatch
import Foundation

private struct ClairUnavailablePushRelay: ClairPushSending {
  func send(_ delivery: ClairPushDelivery) throws -> ClairPushDeliveryResult {
    ClairPushDeliveryResult(status: .unavailable)
  }
}

@main
struct ClairDaemonMain {
  static func main() {
    do {
      let configuration = try ClairDaemonConfiguration(paths: daemonPaths())
      let runtime = try makeRuntime(configuration: configuration)
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

  private static func makeRuntime(
    configuration: ClairDaemonConfiguration
  ) throws -> ClairDaemonRuntime {
    // The executable owns the same H10 composition root as the fixture suite.
    // Project discovery, provider credentials, and APNs are intentionally
    // injected/configured by later product surfaces; an empty catalog and
    // unavailable relay fail closed until those inputs are supplied.
    let workspace = try ClairV2WorkspaceRuntime(projects: [])
    let authority = try ClairPairingAuthority(
      hostID: try ClairHostID("clair-daemon"),
      endpoint: try ClairTransportEndpoint("wss://127.0.0.1/clair")
    )
    let agentRuntime = try ClairV2AgentRuntime(workspace: workspace, providers: [])
    let host = try ClairDaemonHost(
      workspace: workspace,
      authority: authority,
      agentRuntime: agentRuntime,
      pushRelay: ClairUnavailablePushRelay()
    )
    return ClairDaemonRuntime(configuration: configuration, host: host)
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
