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

private final class ClairBlockingResult<T>: @unchecked Sendable {
  var value: Result<T, Error>?
}

@main
struct ClairDaemonMain {
  static func main() {
    do {
      let configuration = try ClairDaemonConfiguration(paths: daemonPaths())
      let remotePort = argument("--remote-port").flatMap(UInt16.init) ?? 0
      let (runtime, host, pairingStore) = try makeRuntime(configuration: configuration, remotePort: remotePort)
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
      let remote = remotePort == 0 ? nil : startRemoteListener(host: host, store: pairingStore, port: remotePort)
      withExtendedLifetime(interrupt) {
        withExtendedLifetime(terminate) {
          while runtime.state != .stopped {
            if termination.wait(timeout: .now() + 0.25) == .success {
              try? runtime.stop()
            }
          }
        }
      }
      if let remote { _ = try? blocking { await remote.stop() } }
      interrupt.cancel()
      terminate.cancel()
    } catch {
      let message = "ClairDaemon failed to start: \(error.localizedDescription)\n"
      FileHandle.standardError.write(Data(message.utf8))
      exit(EXIT_FAILURE)
    }
  }

  /// N11: the remote client listener (loopback TLS, ADR-0016). A failure here is reported and
  /// the daemon keeps serving the local GUI; remote devices simply cannot connect.
  private static func startRemoteListener(
    host: ClairDaemonHost, store: ClairDaemonPairingStore, port: UInt16
  ) -> ClairRemoteListener? {
    guard #available(macOS 15, *) else {
      FileHandle.standardError.write(Data("ClairDaemon: remote listener needs macOS 15\n".utf8))
      return nil
    }
    do {
      let hostKey = try store.loadOrCreateHostKey().0
      let listener = ClairRemoteListener(
        host: host, identity: try ClairRemoteTLSIdentity.make(hostKey: hostKey), port: port,
        onGrantsChanged: { grants in
          do { try store.save(hostKey: hostKey, grants: grants) } catch {
            FileHandle.standardError.write(Data("ClairDaemon: cannot save device grants: \(error)\n".utf8))
            throw error
          }
        })
      _ = try blocking { try await listener.start() }
      return listener
    } catch {
      FileHandle.standardError.write(Data("ClairDaemon: remote listener unavailable: \(error)\n".utf8))
      return nil
    }
  }

  private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    let result = ClairBlockingResult<T>()
    Task.detached {
      do { result.value = .success(try await body()) } catch { result.value = .failure(error) }
      done.signal()
    }
    done.wait()
    return try result.value!.get()
  }

  private static func makeRuntime(
    configuration: ClairDaemonConfiguration, remotePort: UInt16
  ) throws -> (ClairDaemonRuntime, ClairDaemonHost, ClairDaemonPairingStore) {
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
    let pairingStore = ClairDaemonPairingStore(paths: configuration.paths)
    let persistedPairing = try pairingStore.loadOrCreateHostKey()
    let authority = try ClairPairingAuthority(
      hostID: try ClairHostID("clair-daemon"),
      // What a pairing link points at. A private-route client dials its own tailnet name
      // for the same passthrough port; the pin, not the endpoint, identifies the host.
      endpoint: try ClairTransportEndpoint("tls://127.0.0.1:\(remotePort == 0 ? 47_611 : remotePort)"),
      hostKey: persistedPairing.0,
      defaultVisibleScopes: root == nil ? [] : [try ResourceScope(projectID: projectID)],
      persistedGrants: persistedPairing.1
    )
    try pairingStore.save(hostKey: persistedPairing.0, grants: persistedPairing.1)
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
    return (ClairDaemonRuntime(configuration: configuration, host: host), host, pairingStore)
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
