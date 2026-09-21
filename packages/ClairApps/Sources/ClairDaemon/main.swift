import ClairAgent
import ClairDaemonKit
import ClairPush
import ClairShared
import ClairTransport
import ClairWorkspace
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
      // @Sendable: main() is MainActor-isolated, so a plain closure inherits that and traps (dispatch_assert_queue) when this global-queue source fires.
      interrupt.setEventHandler { @Sendable in termination.signal() }
      terminate.setEventHandler { @Sendable in termination.signal() }
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
    // Local host registration supplies the executable and project, never a
    // remote caller's shell command. No provider credentials are copied into
    // configuration or diagnostics. OpenCode can use its own protected config.
    let root = argument("--project-root")
    let executable = argument("--opencode-executable")
    guard (root == nil) == (executable == nil) else { throw ClairAgentError.invalidLaunchSpec }
    let projectID = try ProjectID("local-project")
    let projects =
      try root.map { [try ClairProjectRoot(id: projectID, rootURL: URL(fileURLWithPath: $0))] }
      ?? []
    let workspace = try ClairWorkspaceRuntime(projects: projects)
    let authority = try ClairPairingAuthority(
      hostID: try ClairHostID("clair-daemon"),
      endpoint: try ClairTransportEndpoint("wss://127.0.0.1/clair"),
      defaultVisibleScopes: root == nil ? [] : [try ResourceScope(projectID: projectID)]
    )
    var providers: [any ClairAgentProviderAdapter] = []
    if let executable {
      let inherited = ProcessInfo.processInfo.environment
      var environment = inherited.filter {
        ["HOME", "PATH", "LANG", "TMPDIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME"].contains($0.key)
      }
      environment["TERM"] = "xterm-256color"
      providers.append(
        try ClairOpenCodeProvider(
          executableURL: URL(fileURLWithPath: executable),
          version: ClairProviderVersion(argument("--opencode-version") ?? "unknown"),
          environment: environment, processFactory: ClairPTYAgentProcessFactory()
        ))
    }
    let agentRuntime = try ClairAgentRuntime(workspace: workspace, providers: providers)
    let host = try ClairDaemonHost(
      workspace: workspace,
      authority: authority,
      agentRuntime: agentRuntime,
      pushRelay: ClairUnavailablePushRelay()
    )
    return ClairDaemonRuntime(configuration: configuration, host: host)
  }

  private static func argument(_ name: String) -> String? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1),
      !arguments[index + 1].hasPrefix("--")
    else { return nil }
    return arguments[index + 1]
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
