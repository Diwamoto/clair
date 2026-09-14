import Foundation
import Testing

@testable import ClairV2Agent
@testable import ClairV2Shared
@testable import ClairV2Workspace

#if os(macOS)
  import Darwin
#endif

@Test
func h04StartsOpenCodeWithTypedIdentityAndValidatedProjectCwd() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }

  let factory = H04ProcessFactory()
  let provider = try fixtureProvider(factory: factory)
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: "h04-project"),
    provider: provider
  )
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-start")

  let running = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: sessionID
  )

  #expect(running.lifecycle == .running)
  #expect(running.identity.provider.providerID == .openCode)
  #expect(running.identity.provider.version.rawValue == "1.0.0")
  #expect(running.identity.projectID == projectID)
  #expect(running.identity.worktreeID == nil)
  #expect(running.identity.sessionID == sessionID)
  #expect(running.workingDirectoryURL == fixture.rootURL.standardizedFileURL)
  #expect(factory.specs.count == 1)
  #expect(factory.specs[0].workingDirectoryURL == fixture.rootURL.standardizedFileURL)
  #expect(factory.specs[0].environment["CLAIR_PROJECT_ID"] == projectID.rawValue)
  #expect(factory.specs[0].environment["CLAIR_SESSION_ID"] == sessionID.rawValue)

  let stopped = try await runtime.stop(sessionID: sessionID)
  #expect(stopped.lifecycle == .stopped)
  #expect(stopped.processID == nil)
  #expect(stopped.exit?.reason == .stopped)
  #expect(factory.processes[0].terminateCount == 1)
}

@Test
func h04DoesNotPublishRunningForAnImmediateProcessExit() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let immediateExit = ClairV2AgentProcessExit(status: 0)
  let factory = H04ProcessFactory(startExit: immediateExit)
  let provider = try fixtureProvider(factory: factory)
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: "h04-project"),
    provider: provider
  )
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-immediate-exit")

  let exited = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: sessionID
  )

  #expect(exited.lifecycle == .exited)
  #expect(exited.processID == nil)
  #expect(exited.exit?.reason == .normal)
  #expect(exited.failure == nil)
  #expect(try await runtime.session(sessionID: sessionID).lifecycle == .exited)
}

@Test
func h04UsesTheExactValidatedWorktreeRootAndRejectsAdapterCwdRedirect() async throws {
  let fixture = try H04WorkspaceFixture(gitRepository: true)
  defer { fixture.remove() }
  let projectID = try ProjectID("h04-worktree-project")
  let workspace = try fixture.workspace(projectID: projectID.rawValue)
  let catalog = try workspace.catalog()
  let worktree = try #require(catalog.projects[0].worktrees.first)
  let factory = H04ProcessFactory()
  let provider = try fixtureProvider(factory: factory)
  let runtime = try ClairV2AgentRuntime(workspace: workspace, provider: provider)
  let sessionID = try SessionID("h04-session-worktree")

  let running = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID, worktreeID: worktree.id),
    sessionID: sessionID
  )
  #expect(running.lifecycle == .running)
  #expect(running.identity.worktreeID == worktree.id)
  #expect(running.workingDirectoryURL == worktree.rootURL.standardizedFileURL)
  #expect(factory.specs[0].environment["CLAIR_WORKTREE_ID"] == worktree.id.rawValue)
  _ = try await runtime.stop(sessionID: sessionID)

  let redirectFactory = H04ProcessFactory()
  let redirectProvider = try fixtureProvider(
    factory: redirectFactory,
    cwdOverride: fixture.rootURL.deletingLastPathComponent()
  )
  let redirectRuntime = try ClairV2AgentRuntime(
    workspace: workspace,
    provider: redirectProvider
  )
  let redirectSessionID = try SessionID("h04-session-cwd-redirect")
  do {
    _ = try await redirectRuntime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID, worktreeID: worktree.id),
      sessionID: redirectSessionID
    )
    Issue.record("The adapter unexpectedly redirected the provider cwd.")
  } catch let error as ClairV2AgentError {
    guard case .workingDirectoryMismatch = error else {
      Issue.record("Unexpected H04 cwd error: \(error).")
      return
    }
  }
  #expect(redirectFactory.specs.isEmpty)
  #expect(try await redirectRuntime.session(sessionID: redirectSessionID).lifecycle == .failed)
}

@Test
func h04MapsUnavailableWorkspaceRootsBeforeCreatingAProcess() async throws {
  let root = URL(fileURLWithPath: "/private/tmp")
    .appendingPathComponent("clair-v2-h04-missing-\(UUID().uuidString)", isDirectory: true)
  let projectID = try ProjectID("h04-missing-project")
  let workspace = try ClairV2WorkspaceRuntime(
    projects: [try ClairV2ProjectRoot(id: projectID, rootURL: root)]
  )
  let factory = H04ProcessFactory()
  let provider = try fixtureProvider(factory: factory)
  let runtime = try ClairV2AgentRuntime(workspace: workspace, provider: provider)

  do {
    _ = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: try SessionID("h04-session-missing-root")
    )
    Issue.record("The missing workspace root unexpectedly launched a process.")
  } catch let error as ClairV2AgentError {
    guard case .workspace(.projectRootUnavailable(let actualID, .missing)) = error else {
      Issue.record("Unexpected unavailable-root error: \(error).")
      return
    }
    #expect(actualID == projectID)
  }
  #expect(factory.specs.isEmpty)
}

@Test
func h04RejectsDuplicateAndStaleLifecycleRequestsWithoutReplacingLiveProcess() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let factory = H04ProcessFactory()
  let provider = try fixtureProvider(factory: factory)
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-duplicate")
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: provider
  )
  _ = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: sessionID
  )

  do {
    _ = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: sessionID
    )
    Issue.record("The duplicate session unexpectedly launched.")
  } catch let error as ClairV2AgentError {
    #expect(error == .duplicateLaunch(sessionID))
  }
  do {
    _ = try await runtime.resume(sessionID: sessionID)
    Issue.record("The live session unexpectedly resumed twice.")
  } catch let error as ClairV2AgentError {
    #expect(error == .duplicateLaunch(sessionID))
  }
  #expect(factory.processes.count == 1)

  _ = try await runtime.stop(sessionID: sessionID)
  let stoppedAgain = try await runtime.stop(sessionID: sessionID)
  #expect(stoppedAgain.lifecycle == .stopped)
  let resumed = try await runtime.resume(sessionID: sessionID)
  #expect(resumed.lifecycle == .running)
  #expect(resumed.identity.sessionID == sessionID)
  #expect(resumed.processGeneration != stoppedAgain.processGeneration)
  #expect(factory.processes.count == 2)

  factory.processes[0].emit(
    ClairV2AgentProcessExit(status: 99, wasRequestedByClair: false)
  )
  try await H04TestSupport.yieldToActor()
  let stillRunning = try await runtime.session(sessionID: sessionID)
  #expect(stillRunning.lifecycle == .running)
  #expect(stillRunning.processID == factory.processes[1].processID)

  do {
    _ = try await runtime.resume(sessionID: try SessionID("h04-unknown-session"))
    Issue.record("An unknown session unexpectedly resumed.")
  } catch let error as ClairV2AgentError {
    #expect(error == .staleSession(try SessionID("h04-unknown-session")))
  }
  _ = try await runtime.stop(sessionID: sessionID)
}

@Test
func h04SerializesConcurrentStartsAndStops() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let factory = H04ProcessFactory(autoTerminateOnRequest: false, terminationDelay: 50_000_000)
  let provider = try fixtureProvider(factory: factory)
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-concurrent")
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: provider,
    limits: try ClairV2AgentLaunchLimits(terminationGracePeriod: 0.2)
  )

  let startResults = await withTaskGroup(of: Result<ClairV2AgentSessionSnapshot, Error>.self) {
    group in
    for _ in 0..<8 {
      group.addTask {
        do {
          return .success(
            try await runtime.start(
              providerID: .openCode,
              target: ClairV2AgentTarget(projectID: projectID),
              sessionID: sessionID
            )
          )
        } catch {
          return .failure(error)
        }
      }
    }
    var results: [Result<ClairV2AgentSessionSnapshot, Error>] = []
    for await result in group {
      results.append(result)
    }
    return results
  }
  #expect(startResults.compactMap { try? $0.get() }.count == 1)
  #expect(factory.processes.count == 1)

  let firstStop = Task {
    try await runtime.stop(sessionID: sessionID)
  }
  try await Task.sleep(nanoseconds: 1_000_000)
  do {
    _ = try await runtime.stop(sessionID: sessionID)
    Issue.record("Concurrent stop unexpectedly bypassed the stopping state.")
  } catch let error as ClairV2AgentError {
    #expect(error == .lifecycleConflict(sessionID, state: .stopping))
  }
  _ = try await firstStop.value
  #expect(factory.processes[0].forceTerminateCount == 1)
  #expect(try await runtime.session(sessionID: sessionID).lifecycle == .stopped)
}

@Test
func h04RestartReservesTheSessionBeforeTerminationAwaits() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let factory = H04ProcessFactory(
    autoTerminateOnRequest: true,
    terminationDelay: 100_000_000
  )
  let provider = try fixtureProvider(factory: factory)
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-restart-race")
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: provider,
    limits: try ClairV2AgentLaunchLimits(terminationGracePeriod: 0.5)
  )
  let first = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: sessionID
  )

  let restartTask = Task {
    try await runtime.restart(sessionID: sessionID)
  }
  for _ in 0..<100 {
    if factory.processes[0].terminateCount == 1 { break }
    await Task.yield()
    try await Task.sleep(nanoseconds: 1_000_000)
  }
  #expect(factory.processes[0].terminateCount == 1)
  do {
    _ = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: sessionID
    )
    Issue.record("A concurrent start unexpectedly created a second process.")
  } catch let error as ClairV2AgentError {
    #expect(error == .duplicateLaunch(sessionID))
  }

  let restarted = try await restartTask.value
  #expect(restarted.lifecycle == .running)
  #expect(restarted.processGeneration != first.processGeneration)
  #expect(factory.processes.count == 2)
  _ = try await runtime.stop(sessionID: sessionID)
}

@Test
func h04RetainsCleanupPendingHandleUntilAForceRetrySucceeds() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let factory = H04ProcessFactory(
    terminationFailures: 1,
    forceTerminationFailures: 1
  )
  let provider = try fixtureProvider(factory: factory)
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-cleanup-pending")
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: provider
  )
  let running = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: sessionID
  )

  do {
    _ = try await runtime.stop(sessionID: sessionID)
    Issue.record("A termination failure unexpectedly discarded the process handle.")
  } catch let error as ClairV2AgentError {
    #expect(error == .processTerminationFailed)
  }
  let pending = try await runtime.session(sessionID: sessionID)
  #expect(pending.lifecycle == .cleanupPending)
  #expect(pending.failure == .cleanupPending)
  #expect(pending.processID == running.processID)
  #expect(factory.processes[0].terminateCount == 1)
  #expect(factory.processes[0].forceTerminateCount == 1)

  let stopped = try await runtime.stop(sessionID: sessionID)
  #expect(stopped.lifecycle == .stopped)
  #expect(stopped.processID == nil)
  #expect(stopped.failure == .forcedTermination)
  #expect(factory.processes[0].forceTerminateCount == 2)
}

@Test
func h04DoesNotPublishCompletedExitBeforeCallbackCleanupSucceeds() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let factory = H04ProcessFactory(forceTerminationFailures: 1)
  let provider = try fixtureProvider(factory: factory)
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-callback-cleanup")
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: provider
  )
  let running = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: sessionID
  )

  factory.processes[0].emit(
    ClairV2AgentProcessExit(status: 0),
    cleanupPending: true
  )
  try await H04TestSupport.yieldToActor()

  let pending = try await runtime.session(sessionID: sessionID)
  #expect(pending.lifecycle == .cleanupPending)
  #expect(pending.failure == .cleanupPending)
  #expect(pending.exit == nil)
  #expect(pending.processID == running.processID)

  let completed = try await runtime.retryCleanup(sessionID: sessionID)
  #expect(completed.lifecycle == .exited)
  #expect(completed.failure == nil)
  #expect(completed.exit?.reason == .normal)
  #expect(completed.processID == nil)
}

@Test
func h04ShutdownFencesNewLifecycleOperationsUntilCleanupCompletes() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let factory = H04ProcessFactory(
    autoTerminateOnRequest: true,
    terminationDelay: 250_000_000
  )
  let provider = try fixtureProvider(factory: factory, version: "1.0.0")
  let upgradedProvider = try fixtureProvider(factory: H04ProcessFactory(), version: "2.0.0")
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-shutdown-fence")
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: provider,
    limits: try ClairV2AgentLaunchLimits(terminationGracePeriod: 1)
  )
  _ = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: sessionID
  )

  let shutdownTask = Task {
    await runtime.shutdown()
  }
  for _ in 0..<100 {
    if factory.processes[0].terminateCount == 1 { break }
    await Task.yield()
    try await Task.sleep(nanoseconds: 1_000_000)
  }
  #expect(factory.processes[0].terminateCount == 1)

  do {
    _ = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: try SessionID("h04-session-during-shutdown")
    )
    Issue.record("A start unexpectedly passed the shutdown fence.")
  } catch let error as ClairV2AgentError {
    #expect(error == .shutdownInProgress)
  }
  do {
    _ = try await runtime.resume(sessionID: sessionID)
    Issue.record("A resume unexpectedly passed the shutdown fence.")
  } catch let error as ClairV2AgentError {
    #expect(error == .shutdownInProgress)
  }
  do {
    _ = try await runtime.restart(sessionID: sessionID)
    Issue.record("A restart unexpectedly passed the shutdown fence.")
  } catch let error as ClairV2AgentError {
    #expect(error == .shutdownInProgress)
  }
  do {
    _ = try await runtime.upgrade(sessionID: sessionID, to: upgradedProvider)
    Issue.record("An upgrade unexpectedly passed the shutdown fence.")
  } catch let error as ClairV2AgentError {
    #expect(error == .shutdownInProgress)
  }
  do {
    _ = try await runtime.stop(sessionID: sessionID)
    Issue.record("A concurrent stop unexpectedly bypassed the stopping state.")
  } catch let error as ClairV2AgentError {
    #expect(error == .lifecycleConflict(sessionID, state: .stopping))
  }

  await shutdownTask.value
  let stopped = try await runtime.session(sessionID: sessionID)
  #expect(stopped.lifecycle == .stopped)
  #expect(stopped.processID == nil)
  #expect(factory.processes.count == 1)
}

@Test
func h04ReportsProviderUpgradeWithoutReplacingTheRecordedSession() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let firstFactory = H04ProcessFactory()
  let firstProvider = try fixtureProvider(factory: firstFactory, version: "1.0.0")
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-upgrade")
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: firstProvider
  )
  _ = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: sessionID
  )

  let upgradedFactory = H04ProcessFactory()
  let upgradedProvider = try fixtureProvider(factory: upgradedFactory, version: "2.0.0")
  try await runtime.installProvider(upgradedProvider)

  do {
    _ = try await runtime.restart(sessionID: sessionID)
    Issue.record("The provider upgrade unexpectedly replaced a session implicitly.")
  } catch let error as ClairV2AgentError {
    guard case .providerUpgradeRequired(let actualSessionID, let recorded, let requested) = error
    else {
      Issue.record("Unexpected provider upgrade error: \(error).")
      return
    }
    #expect(actualSessionID == sessionID)
    #expect(recorded.version.rawValue == "1.0.0")
    #expect(requested.version.rawValue == "2.0.0")
  }
  #expect(firstFactory.processes.count == 1)
  #expect(upgradedFactory.processes.isEmpty)
  #expect(try await runtime.session(sessionID: sessionID).lifecycle == .running)

  let upgraded = try await runtime.upgrade(
    sessionID: sessionID,
    to: upgradedProvider
  )
  #expect(upgraded.lifecycle == .running)
  #expect(upgraded.identity.provider.version.rawValue == "2.0.0")
  #expect(upgraded.identity.sessionID == sessionID)
  #expect(upgradedFactory.processes.count == 1)
  _ = try await runtime.stop(sessionID: sessionID)
}

@Test
func h04MapsProviderFactoryFailureWithoutRetainingAProcessHandle() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-factory-failure")
  let factory = H04ProcessFactory(creationError: H04FixtureError.factoryFailed)
  let provider = try fixtureProvider(factory: factory)
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: provider
  )

  do {
    _ = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: sessionID
    )
    Issue.record("The provider factory unexpectedly created a process.")
  } catch let error as ClairV2AgentError {
    #expect(error == .processCreationFailed)
  }
  let failed = try await runtime.session(sessionID: sessionID)
  #expect(failed.lifecycle == .failed)
  #expect(failed.processID == nil)
  #expect(factory.processes.isEmpty)
}

@Test
func h04RetainsTypedNormalAbnormalAndSignalExitResults() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let factory = H04ProcessFactory()
  let provider = try fixtureProvider(factory: factory)
  let projectID = try ProjectID("h04-project")
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: provider
  )

  let normalID = try SessionID("h04-session-normal-exit")
  _ = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: normalID
  )
  factory.processes[0].emit(ClairV2AgentProcessExit(status: 0))
  try await H04TestSupport.yieldToActor()
  let normal = try await runtime.session(sessionID: normalID)
  #expect(normal.lifecycle == .exited)
  #expect(normal.exit?.reason == .normal)
  #expect(normal.exit?.status == 0)
  #expect(normal.exit?.signal == nil)

  let abnormalID = try SessionID("h04-session-abnormal-exit")
  _ = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: abnormalID
  )
  factory.processes[1].emit(ClairV2AgentProcessExit(status: 23))
  try await H04TestSupport.yieldToActor()
  let abnormal = try await runtime.session(sessionID: abnormalID)
  #expect(abnormal.lifecycle == .failed)
  #expect(abnormal.failure == .abnormalExit)
  #expect(abnormal.exit?.reason == .abnormal)
  #expect(abnormal.exit?.status == 23)

  let signalID = try SessionID("h04-session-signal-exit")
  _ = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: signalID
  )
  factory.processes[2].emit(ClairV2AgentProcessExit(signal: 9))
  try await H04TestSupport.yieldToActor()
  let signaled = try await runtime.session(sessionID: signalID)
  #expect(signaled.lifecycle == .failed)
  #expect(signaled.failure == .signaledExit)
  #expect(signaled.exit?.reason == .signal)
  #expect(signaled.exit?.signal == 9)
}

@Test
func h04BoundsLaunchMetadataAndKeepsCredentialsOutOfDescriptionsAndSnapshots() async throws {
  let limits = try ClairV2AgentLaunchLimits(
    maximumArguments: 1,
    maximumArgumentBytes: 4,
    maximumArgumentTotalBytes: 4,
    maximumEnvironmentEntries: 1,
    maximumEnvironmentKeyBytes: 4,
    maximumEnvironmentValueBytes: 4,
    maximumEnvironmentTotalBytes: 8,
    maximumOutputBytes: 8,
    terminationGracePeriod: 0
  )
  let cwd = URL(fileURLWithPath: "/private/tmp")
  do {
    _ = try ClairV2AgentLaunchSpec(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["12345"],
      environment: [:],
      workingDirectoryURL: cwd,
      limits: limits
    )
    Issue.record("An oversized argument unexpectedly passed the launch bound.")
  } catch let error as ClairV2AgentError {
    #expect(error == .invalidLaunchSpec)
  }
  do {
    _ = try ClairV2AgentLaunchSpec(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: [],
      environment: ["KEY": "12345"],
      workingDirectoryURL: cwd,
      limits: limits
    )
    Issue.record("An oversized environment value unexpectedly passed the launch bound.")
  } catch let error as ClairV2AgentError {
    #expect(error == .invalidEnvironment)
  }

  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let factory = H04ProcessFactory()
  let provider = try fixtureProvider(
    factory: factory,
    credentials: ["OPENCODE_API_KEY": "super-secret-fixture-value"]
  )
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-secret")
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: provider
  )
  let running = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: sessionID
  )
  #expect(!String(describing: factory.specs[0]).contains("super-secret-fixture-value"))
  #expect(!String(describing: running).contains("super-secret-fixture-value"))
  let encoded = try JSONEncoder().encode(running)
  #expect(!String(decoding: encoded, as: UTF8.self).contains("super-secret-fixture-value"))
  #expect(!String(describing: provider).contains("super-secret-fixture-value"))
  _ = try await runtime.stop(sessionID: sessionID)
}

@Test
func h04BoundsRawOutputAtTheRuntimeSeam() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let limits = try ClairV2AgentLaunchLimits(
    maximumArguments: 64,
    maximumArgumentBytes: 8 * 1024,
    maximumArgumentTotalBytes: 32 * 1024,
    maximumEnvironmentEntries: 64,
    maximumEnvironmentKeyBytes: 256,
    maximumEnvironmentValueBytes: 8 * 1024,
    maximumEnvironmentTotalBytes: 64 * 1024,
    maximumOutputBytes: 8,
    terminationGracePeriod: 0
  )
  let factory = H04ProcessFactory(
    rawOutput: ClairV2AgentRawOutput(
      stdout: Data(repeating: 0x6F, count: 9),
      stderr: Data(repeating: 0x65, count: 9)
    )
  )
  let provider = try fixtureProvider(factory: factory, outputLimit: 8)
  let projectID = try ProjectID("h04-project")
  let sessionID = try SessionID("h04-session-output-bound")
  let runtime = try ClairV2AgentRuntime(
    workspace: fixture.workspace(projectID: projectID.rawValue),
    provider: provider,
    limits: limits
  )

  _ = try await runtime.start(
    providerID: .openCode,
    target: ClairV2AgentTarget(projectID: projectID),
    sessionID: sessionID
  )
  let liveOutput = try await runtime.rawOutput(for: sessionID)
  #expect(liveOutput.stdout.count + liveOutput.stderr.count <= limits.maximumOutputBytes)
  #expect(liveOutput.isTruncated)
  let stopped = try await runtime.stop(sessionID: sessionID)
  #expect(stopped.outputWasTruncated)
}

@Test
func h04RuntimeRevalidatesAdversarialAdapterSpecs() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let projectID = try ProjectID("h04-project")
  let cwd = fixture.rootURL.standardizedFileURL
  let restrictiveLimits = try ClairV2AgentLaunchLimits(
    maximumArguments: 1,
    maximumArgumentBytes: 8,
    maximumArgumentTotalBytes: 8,
    maximumEnvironmentEntries: 1,
    maximumEnvironmentKeyBytes: 256,
    maximumEnvironmentValueBytes: 8 * 1024,
    maximumEnvironmentTotalBytes: 64 * 1024,
    maximumOutputBytes: 8,
    terminationGracePeriod: 0
  )
  let oversizedArguments = try ClairV2AgentLaunchSpec(
    executableURL: URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "while :; do :; done"],
    environment: [:],
    workingDirectoryURL: cwd,
    limits: .standard
  )
  let oversizedEnvironment = try ClairV2AgentLaunchSpec(
    executableURL: URL(fileURLWithPath: "/bin/sh"),
    arguments: [],
    environment: ["KEY": "one", "OTHER": "two"],
    workingDirectoryURL: cwd,
    limits: .standard
  )
  let oversizedOutput = try ClairV2AgentLaunchSpec(
    executableURL: URL(fileURLWithPath: "/bin/sh"),
    arguments: [],
    environment: [:],
    workingDirectoryURL: cwd,
    outputPolicy: .bounded(maximumBytes: 64),
    limits: .standard
  )
  let cases: [(String, ClairV2AgentLaunchSpec, ClairV2AgentError)] = [
    ("argv", oversizedArguments, .invalidLaunchSpec),
    ("environment", oversizedEnvironment, .invalidEnvironment),
    ("output", oversizedOutput, .invalidLaunchSpec),
  ]

  for (suffix, spec, expectedError) in cases {
    let factory = H04ProcessFactory()
    let provider = H04AdversarialProvider(
      spec: spec,
      factory: H04ProcessFactoryAdapter(factory: factory)
    )
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider,
      limits: restrictiveLimits
    )
    let sessionID = try SessionID("h04-session-adversarial-\(suffix)")
    do {
      _ = try await runtime.start(
        providerID: .openCode,
        target: ClairV2AgentTarget(projectID: projectID),
        sessionID: sessionID
      )
      Issue.record("The adversarial \(suffix) launch spec unexpectedly spawned.")
    } catch let error as ClairV2AgentError {
      #expect(error == expectedError)
    }
    #expect(factory.specs.isEmpty)
    #expect(try await runtime.session(sessionID: sessionID).lifecycle == .failed)
  }
}

@Test
func h04MapsMissingAndNonExecutableOpenCodeBinariesToTypedErrors() async throws {
  let fixture = try H04WorkspaceFixture()
  defer { fixture.remove() }
  let projectID = try ProjectID("h04-project")
  let workspace = try fixture.workspace(projectID: projectID.rawValue)
  let missingURL = fixture.rootURL.appendingPathComponent("missing-opencode")
  let missingProvider = try ClairV2OpenCodeProvider(
    executableURL: missingURL,
    version: try ClairV2ProviderVersion("1.0.0"),
    processFactory: H04ProcessFactoryAdapter(factory: H04ProcessFactory())
  )
  let missingRuntime = try ClairV2AgentRuntime(workspace: workspace, provider: missingProvider)
  do {
    _ = try await missingRuntime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: try SessionID("h04-session-missing-executable")
    )
    Issue.record("The missing OpenCode executable unexpectedly launched.")
  } catch let error as ClairV2AgentError {
    #expect(error == .missingExecutable(missingURL.standardizedFileURL))
  }

  let nonExecutableURL = fixture.rootURL.appendingPathComponent("non-executable-opencode")
  try Data("fixture".utf8).write(to: nonExecutableURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: 0o600)],
    ofItemAtPath: nonExecutableURL.path
  )
  let nonExecutableProvider = try ClairV2OpenCodeProvider(
    executableURL: nonExecutableURL,
    version: try ClairV2ProviderVersion("1.0.0"),
    processFactory: H04ProcessFactoryAdapter(factory: H04ProcessFactory())
  )
  let nonExecutableRuntime = try ClairV2AgentRuntime(
    workspace: workspace,
    provider: nonExecutableProvider
  )
  do {
    _ = try await nonExecutableRuntime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: try SessionID("h04-session-non-executable")
    )
    Issue.record("The non-executable OpenCode file unexpectedly launched.")
  } catch let error as ClairV2AgentError {
    #expect(error == .executableNotExecutable(nonExecutableURL.standardizedFileURL))
  }
}

#if os(macOS)

  @Test
  func h04RepeatedRealTrueExitsAreResolvedBeforeStartReturns() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let projectID = try ProjectID("h04-real-true-project")
    let trueExecutable = try #require(
      ["/bin/true", "/usr/bin/true"].first {
        FileManager.default.isExecutableFile(atPath: $0)
      }
    )
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: trueExecutable),
      version: try ClairV2ProviderVersion("fixture"),
      outputPolicy: .discard,
      processFactory: ClairV2SystemAgentProcessFactory()
    )
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider
    )

    for index in 0..<32 {
      let sessionID = try SessionID("h04-real-true-\(index)")
      let result = try await runtime.start(
        providerID: .openCode,
        target: ClairV2AgentTarget(projectID: projectID),
        sessionID: sessionID
      )
      if result.lifecycle == .running {
        _ = try? await runtime.stop(sessionID: sessionID)
      }
      #expect(result.lifecycle == .exited)
      #expect(result.processID == nil)
      #expect(result.exit?.reason == .normal)
      #expect(result.failure == nil)
    }
  }

  @Test
  func h04ProviderDoesNotInheritRuntimeOwnedWorkingDirectoryDescriptor() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let reportURL = fixture.rootURL.appendingPathComponent("child-fds.txt")
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("fixture"),
      arguments: [
        "-c",
        """
        status=0
        for fd in /dev/fd/*; do
          target=$(/usr/bin/readlink "$fd" 2>/dev/null || true)
          case "$target" in
            "$H04_WORKSPACE_ROOT"|"$H04_WORKSPACE_ROOT"/*) status=1 ;;
          esac
        done
        printf '%s' "$status" > "$H04_FD_REPORT"
        exit "$status"
        """,
      ],
      environment: [
        "H04_FD_REPORT": reportURL.path,
        "H04_WORKSPACE_ROOT": fixture.rootURL.path,
      ],
      outputPolicy: .discard,
      processFactory: ClairV2SystemAgentProcessFactory()
    )
    let projectID = try ProjectID("h04-fd-project")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider
    )

    var result = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: try SessionID("h04-fd-session")
    )
    for _ in 0..<200 where result.lifecycle == .running {
      try await Task.sleep(nanoseconds: 10_000_000)
      result = try await runtime.session(sessionID: try SessionID("h04-fd-session"))
    }

    #expect(result.lifecycle == .exited)
    #expect(result.exit?.reason == .normal)
    #expect(String(decoding: try Data(contentsOf: reportURL), as: UTF8.self) == "0")
  }

  @Test
  func h04RecoversFromWaitIDFailureAndNeverKillsOrReapsTheGroupTwice() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let instrumentation = H04ProcessLifecycleInstrumentation()
    let capture = H04ProcessCapture()
    let factory = ClairV2SystemAgentProcessFactory(
      processGroupClaimFailures: 0,
      waitIDFailures: 1,
      onProcessGroupKill: { groupID, keeperID in
        instrumentation.recordGroupKill(groupID: groupID, keeperID: keeperID)
      },
      onLeaderReap: { processID in
        instrumentation.recordLeaderReap(processID: processID)
      },
      onGroupKeeperReap: { processID in
        instrumentation.recordKeeperReap(processID: processID)
      }
    )
    let trueExecutable = try #require(
      ["/bin/true", "/usr/bin/true"].first {
        FileManager.default.isExecutableFile(atPath: $0)
      }
    )
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: trueExecutable),
      version: try ClairV2ProviderVersion("fixture"),
      outputPolicy: .discard,
      processFactory: H04CapturingProcessFactory(base: factory, capture: capture)
    )
    let projectID = try ProjectID("h04-waitid-project")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider
    )

    var result = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: try SessionID("h04-waitid-session")
    )
    let process = try #require(capture.process)
    for _ in 0..<200 where result.lifecycle == .running {
      try await Task.sleep(nanoseconds: 10_000_000)
      result = try await runtime.session(sessionID: try SessionID("h04-waitid-session"))
    }
    if result.lifecycle == .running {
      _ = try? await runtime.stop(sessionID: try SessionID("h04-waitid-session"))
      result = try await runtime.session(sessionID: try SessionID("h04-waitid-session"))
    }
    #expect(result.lifecycle == .exited)
    #expect(result.exit?.reason == .normal)
    #expect(result.processID == nil)
    #expect(!process.isRunning)
    #expect(!process.hasPendingCleanup)

    let beforeRetry = instrumentation.snapshot()
    _ = try await process.forceTerminate()
    let afterRetry = instrumentation.snapshot()
    #expect(afterRetry == beforeRetry)
    #expect(beforeRetry.groupKillCount == 1)
    #expect(beforeRetry.leaderReapCount == 1)
    #expect(beforeRetry.keeperReapCount == 1)
    #expect(beforeRetry.groupID == beforeRetry.keeperID)
    #expect(beforeRetry.events == [.groupKill, .leaderReap, .keeperReap])
  }

  @Test
  func h04LongLivedWaitIDFailureDoesNotBlockStartAndStopCompletesThroughRetry() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let waitIDFailure = H04CompletionLatch()
    let startCompletion = H04CompletionLatch()
    let capture = H04ProcessCapture()
    let factory = ClairV2SystemAgentProcessFactory(
      processGroupClaimFailures: 0,
      waitIDFailures: 1,
      onWaitIDFailure: { waitIDFailure.signal() }
    )
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("fixture"),
      arguments: ["-c", "sleep 60"],
      outputPolicy: .discard,
      processFactory: H04CapturingProcessFactory(base: factory, capture: capture)
    )
    let projectID = try ProjectID("h04-waitid-long-lived-project")
    let sessionID = try SessionID("h04-waitid-long-lived-session")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider,
      limits: try ClairV2AgentLaunchLimits(terminationGracePeriod: 0.1)
    )

    let startTask = Task {
      defer { startCompletion.signal() }
      return try await runtime.start(
        providerID: .openCode,
        target: ClairV2AgentTarget(projectID: projectID),
        sessionID: sessionID
      )
    }
    #expect(waitIDFailure.wait(timeout: 2))
    let startReturned = startCompletion.wait(timeout: 1)
    if !startReturned, let process = capture.process {
      // Keep this regression test bounded even if the pre-repair behavior is
      // reintroduced: the safe external cleanup path wakes the blocked reap.
      _ = try? await process.forceTerminate()
    }
    let running = try await startTask.value
    #expect(startReturned)
    #expect(running.lifecycle == .running)
    #expect(running.processID ?? 0 > 0)
    let process = try #require(capture.process)
    #expect(process.hasPendingCleanup)

    let stopped = try await runtime.stop(sessionID: sessionID)
    #expect(stopped.lifecycle == .stopped)
    #expect(stopped.processID == nil)
    #expect(!process.isRunning)
    #expect(!process.hasPendingCleanup)
  }

  @Test
  func h04ClosedStandardInputStillStartsKeeperAndReleasesAllOwnedResources() async throws {
    let markerURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-h04-closed-stdin-" + UUID().uuidString)
    let scratchURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-h04-closed-stdin-scratch-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: markerURL) }
    defer { try? FileManager.default.removeItem(at: scratchURL) }
    let packageURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: scratchURL,
      withIntermediateDirectories: true
    )
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/bin/sh")
    probe.arguments = [
      "-c",
      "exec 0<&-; exec /usr/bin/env swift test --package-path \"$1\" "
        + "--scratch-path \"$2\" --filter h04ClosedStandardInputProbe --no-parallel",
      "clair-h04-closed-stdin",
      packageURL.path,
      scratchURL.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["CLAIR_H04_CLOSED_STDIN_PROBE"] = "1"
    environment["CLAIR_H04_CLOSED_STDIN_MARKER"] = markerURL.path
    probe.environment = environment
    probe.standardOutput = FileHandle.standardOutput
    probe.standardError = FileHandle.standardError
    try probe.run()
    probe.waitUntilExit()
    #expect(probe.terminationStatus == 0)
    #expect(FileManager.default.fileExists(atPath: markerURL.path))
  }

  @Test
  func h04ClosedStandardInputProbe() async throws {
    guard ProcessInfo.processInfo.environment["CLAIR_H04_CLOSED_STDIN_PROBE"] == "1" else {
      return
    }
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let lifecycle = H04ProcessLifecycleInstrumentation()
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("fixture"),
      arguments: ["-c", "sleep 60"],
      outputPolicy: .discard,
      processFactory: ClairV2SystemAgentProcessFactory(
        processGroupClaimFailures: 0,
        onGroupKeeperReap: { processID in
          lifecycle.recordKeeperReap(processID: processID)
        }
      )
    )
    let projectID = try ProjectID("h04-closed-stdin-project")
    let sessionID = try SessionID("h04-closed-stdin-session")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider,
      limits: try ClairV2AgentLaunchLimits(terminationGracePeriod: 0.1)
    )

    let running = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: sessionID
    )
    #expect(running.lifecycle == .running)
    let stopped = try await runtime.stop(sessionID: sessionID)
    #expect(stopped.lifecycle == .stopped)
    #expect(stopped.processID == nil)
    #expect(lifecycle.snapshot().keeperReapCount == 1)
    if let markerPath = ProcessInfo.processInfo.environment["CLAIR_H04_CLOSED_STDIN_MARKER"] {
      try Data("passed".utf8).write(to: URL(fileURLWithPath: markerPath))
    }
  }

  @Test
  func h04InvalidTerminationCallbackRetainsHandleUntilRealCleanupCompletes() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let childPIDURL = fixture.rootURL.appendingPathComponent("invalid-callback-child.pid")
    let callback = H04TerminationCallbackCapture()
    let capture = H04ProcessCapture()
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("fixture"),
      arguments: [
        "-c",
        "sleep 60 & child=$!; printf '%s' \"$child\" > \"$H04_CHILD_PID_FILE\"; wait \"$child\"",
      ],
      environment: ["H04_CHILD_PID_FILE": childPIDURL.path],
      outputPolicy: .discard,
      processFactory: H04InvalidTerminationCallbackFactory(
        base: ClairV2SystemAgentProcessFactory(),
        callback: callback,
        capture: capture
      )
    )
    let projectID = try ProjectID("h04-invalid-callback-project")
    let sessionID = try SessionID("h04-invalid-callback-session")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider,
      limits: try ClairV2AgentLaunchLimits(terminationGracePeriod: 0.1)
    )

    let running = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: sessionID
    )
    #expect(running.lifecycle == .running)
    var childPIDValue: Int32?
    for _ in 0..<200 {
      if let data = try? Data(contentsOf: childPIDURL),
        let value = Int32(String(decoding: data, as: UTF8.self)),
        value > 0
      {
        childPIDValue = value
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let childPID = try #require(childPIDValue)
    #expect(Darwin.kill(childPID, 0) == 0)

    callback.emit(ClairV2AgentProcessExit(status: 0, signal: SIGKILL))
    let process = try #require(capture.process)
    var failed: ClairV2AgentSessionSnapshot?
    for _ in 0..<300 {
      let snapshot = try await runtime.session(sessionID: sessionID)
      if snapshot.lifecycle == .failed, snapshot.processID == nil {
        failed = snapshot
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let final = try #require(failed)
    #expect(final.failure == .abnormalExit)
    #expect(!process.isRunning)
    #expect(!process.hasPendingCleanup)
    var childGone = false
    for _ in 0..<200 {
      if Darwin.kill(childPID, 0) == -1, errno == ESRCH {
        childGone = true
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(childGone)
  }

  @Test
  func h04CleansProcessGroupBeforeReapingLeader() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let childPIDURL = fixture.rootURL.appendingPathComponent("pre-reap-child.pid")
    let reapBarrier = H04LeaderReapBarrier()
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("fixture"),
      arguments: [
        "-c",
        "sleep 60 & child=$!; printf '%s' \"$child\" > \"$H04_CHILD_PID_FILE\"; exit 0",
      ],
      environment: ["H04_CHILD_PID_FILE": childPIDURL.path],
      outputPolicy: .discard,
      processFactory: ClairV2SystemAgentProcessFactory(
        processGroupClaimFailures: 0,
        onBeforeLeaderReap: { processID in
          reapBarrier.beforeReap(processID)
        }
      )
    )
    let projectID = try ProjectID("h04-pre-reap-project")
    let sessionID = try SessionID("h04-pre-reap-session")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider
    )

    let startTask = Task {
      try await runtime.start(
        providerID: .openCode,
        target: ClairV2AgentTarget(projectID: projectID),
        sessionID: sessionID
      )
    }
    defer { reapBarrier.release() }
    let leaderPID = try #require(reapBarrier.waitForLeader())

    var childPIDValue: Int32?
    for _ in 0..<200 {
      if let data = try? Data(contentsOf: childPIDURL),
        let value = Int32(String(decoding: data, as: UTF8.self)),
        value > 0
      {
        childPIDValue = value
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let childPID = try #require(childPIDValue)

    var leaderIsStillWaitable = false
    for _ in 0..<200 {
      var info = siginfo_t()
      let waitResult = Darwin.waitid(
        P_PID,
        id_t(leaderPID),
        &info,
        WEXITED | WNOHANG | WNOWAIT
      )
      if waitResult == 0, info.si_pid == leaderPID {
        leaderIsStillWaitable = true
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(leaderIsStillWaitable)

    var childGone = false
    for _ in 0..<200 {
      if Darwin.kill(childPID, 0) == -1, errno == ESRCH {
        childGone = true
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(childGone)

    reapBarrier.release()
    let exited = try await startTask.value
    #expect(exited.lifecycle == .exited)
    #expect(exited.exit?.reason == .normal)
    #expect(exited.processID == nil)
  }

  @Test
  func h04SystemProcessFixtureStopsAndReleasesARealChild() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let childPIDURL = fixture.rootURL.appendingPathComponent("child.pid")
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("fixture"),
      arguments: [
        "-c",
        "sleep 0.1; sleep 60 & child=$!; printf '%s' \"$child\" > \"$H04_CHILD_PID_FILE\"; wait \"$child\"",
      ],
      environment: ["H04_CHILD_PID_FILE": childPIDURL.path],
      processFactory: ClairV2SystemAgentProcessFactory()
    )
    let projectID = try ProjectID("h04-project")
    let sessionID = try SessionID("h04-session-real-process")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider,
      limits: try ClairV2AgentLaunchLimits(terminationGracePeriod: 0.2)
    )
    let running = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: sessionID
    )
    #expect(running.processID ?? 0 > 0)
    var childPIDValue: Int32?
    for _ in 0..<200 {
      if let data = try? Data(contentsOf: childPIDURL),
        let value = Int32(String(decoding: data, as: UTF8.self)),
        value > 0
      {
        childPIDValue = value
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let childPID = try #require(childPIDValue)
    #expect(Darwin.kill(childPID, 0) == 0)
    let stopped = try await runtime.stop(sessionID: sessionID)
    #expect(stopped.lifecycle == .stopped)
    #expect(stopped.processID == nil)
    #expect(stopped.exit?.reason == .stopped || stopped.exit?.reason == .forced)

    var childGone = false
    for _ in 0..<200 {
      if Darwin.kill(childPID, 0) == -1, errno == ESRCH {
        childGone = true
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(childGone)
  }

  @Test
  func h04ProcessGroupClaimFailureRetainsRealDescendantCleanupState() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let childPIDURL = fixture.rootURL.appendingPathComponent("claim-failure-child.pid")
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("fixture"),
      arguments: [
        "-c",
        "sleep 60 & child=$!; printf '%s' \"$child\" > \"$H04_CHILD_PID_FILE\"; wait \"$child\"",
      ],
      environment: ["H04_CHILD_PID_FILE": childPIDURL.path],
      processFactory: ClairV2SystemAgentProcessFactory(
        processGroupClaimFailures: 1,
        processGroupClaimFailureDelay: 0.2
      )
    )
    let projectID = try ProjectID("h04-project")
    let sessionID = try SessionID("h04-session-claim-failure")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider,
      limits: try ClairV2AgentLaunchLimits(terminationGracePeriod: 0.2)
    )

    do {
      _ = try await runtime.start(
        providerID: .openCode,
        target: ClairV2AgentTarget(projectID: projectID),
        sessionID: sessionID
      )
      Issue.record("The injected process-group claim failure unexpectedly succeeded.")
    } catch let error as ClairV2AgentError {
      #expect(error == .processGroupUnavailable)
    }

    var childPIDValue: Int32?
    for _ in 0..<200 {
      if let data = try? Data(contentsOf: childPIDURL),
        let value = Int32(String(decoding: data, as: UTF8.self)),
        value > 0
      {
        childPIDValue = value
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let childPID = try #require(childPIDValue)
    var childGone = false
    for _ in 0..<200 {
      if Darwin.kill(childPID, 0) == -1, errno == ESRCH {
        childGone = true
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(childGone)

    let failed = try await runtime.session(sessionID: sessionID)
    #expect(failed.lifecycle == .failed)
    #expect(failed.processID == nil)
  }

  @Test
  func h04LateProcessGroupClaimCannotReassertPendingCleanupAfterExit() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("fixture"),
      arguments: ["-c", "exit 0"],
      outputPolicy: .discard,
      processFactory: ClairV2SystemAgentProcessFactory(
        processGroupClaimFailures: 1,
        processGroupClaimFailureDelay: 0.2
      )
    )
    let projectID = try ProjectID("h04-project")
    let sessionID = try SessionID("h04-session-claim-exit-race")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider
    )

    do {
      _ = try await runtime.start(
        providerID: .openCode,
        target: ClairV2AgentTarget(projectID: projectID),
        sessionID: sessionID
      )
      Issue.record("The injected process-group claim failure unexpectedly succeeded.")
    } catch let error as ClairV2AgentError {
      #expect(error == .processGroupUnavailable)
    }

    let failed = try await runtime.session(sessionID: sessionID)
    #expect(failed.lifecycle == .failed)
    #expect(failed.failure == .launchFailed)
    #expect(failed.processID == nil)
  }

  @Test
  func h04CatalogSnapshotRejectsSamePathRootReplacementBeforeCapabilityOpen() throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let projectID = try ProjectID("h04-catalog-replacement-project")
    let workspace = try fixture.workspace(projectID: projectID.rawValue)
    let catalog = try workspace.catalog()
    let project = try #require(catalog.projects.first)
    #expect(project.rootDevice != nil)
    #expect(project.rootInode != nil)

    let replacement = H04CWDReplacement(rootURL: fixture.rootURL)
    defer { replacement.restore() }
    try replacement.replaceWithReplacementDirectory()

    do {
      _ = try workspace.launchRootCapability(from: catalog, projectID: projectID)
      Issue.record("A same-path root replacement unexpectedly acquired the old catalog capability.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .rootIdentityChanged(fixture.rootURL.standardizedFileURL))
    }
  }

  @Test
  func h04StaleCleanupFailureCannotReassertPendingAfterConcurrentForceCleanup() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let cleanupFailure = H04CleanupFailureLatch()
    let capture = H04ProcessCapture()
    let factory = ClairV2SystemAgentProcessFactory(
      processGroupClaimFailures: 0,
      cleanupFailures: 1,
      cleanupFailureDelay: 0.5,
      onCleanupFailure: { cleanupFailure.signal() }
    )
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("fixture"),
      arguments: ["-c", "sleep 0.5; exit 0"],
      outputPolicy: .discard,
      processFactory: H04CapturingProcessFactory(base: factory, capture: capture)
    )
    let projectID = try ProjectID("h04-cleanup-race-project")
    let sessionID = try SessionID("h04-cleanup-race")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider
    )

    let running = try await runtime.start(
      providerID: .openCode,
      target: ClairV2AgentTarget(projectID: projectID),
      sessionID: sessionID
    )
    #expect(running.lifecycle == .running)

    for _ in 0..<1_000 where !cleanupFailure.isSignaled {
      await Task.yield()
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(cleanupFailure.isSignaled)
    let process = try #require(capture.process)
    let stopped = try await runtime.stop(sessionID: sessionID)
    #expect(stopped.lifecycle == .exited)
    #expect(stopped.exit?.reason == .normal)
    #expect(stopped.processID == nil)
    #expect(!process.hasPendingCleanup)
    let exited = try await runtime.session(sessionID: sessionID)
    #expect(exited.failure == nil)
    #expect(exited.exit?.reason == .normal)
    #expect(exited.processID == nil)
    #expect(!process.hasPendingCleanup)
  }

  @Test
  func h04FailsClosedWhenValidatedCwdIsReplacedBeforeSpawn() async throws {
    let fixture = try H04WorkspaceFixture()
    defer { fixture.remove() }
    let markerURL = fixture.rootURL.appendingPathComponent("launched")
    let replacement = H04CWDReplacement(rootURL: fixture.rootURL)
    defer { replacement.restore() }

    let baseProvider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("fixture"),
      arguments: ["-c", "printf launched > \"$H04_CWD_MARKER\""],
      environment: ["H04_CWD_MARKER": markerURL.path],
      outputPolicy: .discard,
      processFactory: ClairV2SystemAgentProcessFactory()
    )
    let provider = H04CWDReplacementProvider(
      base: baseProvider,
      replacement: replacement
    )
    let projectID = try ProjectID("h04-project")
    let sessionID = try SessionID("h04-session-cwd-replacement")
    let runtime = try ClairV2AgentRuntime(
      workspace: fixture.workspace(projectID: projectID.rawValue),
      provider: provider
    )

    do {
      _ = try await runtime.start(
        providerID: .openCode,
        target: ClairV2AgentTarget(projectID: projectID),
        sessionID: sessionID
      )
      Issue.record("The replaced working directory unexpectedly launched.")
    } catch let error as ClairV2AgentError {
      #expect(error == .workingDirectoryChanged(fixture.rootURL.standardizedFileURL))
    }
    #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    let failed = try await runtime.session(sessionID: sessionID)
    #expect(failed.lifecycle == .failed)
    #expect(failed.processID == nil)
  }

#endif

private func fixtureProvider(
  factory: H04ProcessFactory,
  version: String = "1.0.0",
  cwdOverride: URL? = nil,
  credentials: [String: String] = [:],
  outputLimit: Int = 128
) throws -> H04Provider {
  let base = try ClairV2OpenCodeProvider(
    executableURL: URL(fileURLWithPath: "/bin/sh"),
    version: try ClairV2ProviderVersion(version),
    arguments: ["-c", "while :; do sleep 60; done"],
    outputPolicy: .bounded(maximumBytes: outputLimit),
    credentials: H04Credentials(values: credentials),
    processFactory: H04ProcessFactoryAdapter(factory: factory)
  )
  return H04Provider(base: base, cwdOverride: cwdOverride)
}

private struct H04Provider: ClairV2AgentProviderAdapter {
  let base: ClairV2OpenCodeProvider
  let cwdOverride: URL?

  var identity: ClairV2ProviderIdentity { base.identity }

  func makeLaunchSpec(
    for session: ClairV2AgentSessionIdentity,
    workingDirectoryURL: URL,
    limits: ClairV2AgentLaunchLimits
  ) throws -> ClairV2AgentLaunchSpec {
    let spec = try base.makeLaunchSpec(
      for: session,
      workingDirectoryURL: workingDirectoryURL,
      limits: limits
    )
    guard let cwdOverride else { return spec }
    return try ClairV2AgentLaunchSpec(
      executableURL: spec.executableURL,
      arguments: spec.arguments,
      environment: spec.environment,
      workingDirectoryURL: cwdOverride,
      outputPolicy: spec.outputPolicy,
      limits: limits
    )
  }

  func makeProcess(
    spec: ClairV2AgentLaunchSpec,
    onTermination: @escaping ClairV2AgentTerminationHandler
  ) throws -> any ClairV2AgentProcess {
    try base.makeProcess(spec: spec, onTermination: onTermination)
  }
}

#if os(macOS)

  private struct H04CWDReplacementProvider: ClairV2AgentProviderAdapter {
    let base: ClairV2OpenCodeProvider
    let replacement: H04CWDReplacement

    var identity: ClairV2ProviderIdentity { base.identity }

    func makeLaunchSpec(
      for session: ClairV2AgentSessionIdentity,
      workingDirectoryURL: URL,
      limits: ClairV2AgentLaunchLimits
    ) throws -> ClairV2AgentLaunchSpec {
      let spec = try base.makeLaunchSpec(
        for: session,
        workingDirectoryURL: workingDirectoryURL,
        limits: limits
      )
      try replacement.replaceWithReplacementDirectory()
      return spec
    }

    func makeProcess(
      spec: ClairV2AgentLaunchSpec,
      onTermination: @escaping ClairV2AgentTerminationHandler
    ) throws -> any ClairV2AgentProcess {
      return try base.makeProcess(spec: spec, onTermination: onTermination)
    }
  }

  private struct H04CapturingProcessFactory: ClairV2AgentProcessFactory {
    let base: ClairV2SystemAgentProcessFactory
    let capture: H04ProcessCapture

    func makeProcess(
      spec: ClairV2AgentLaunchSpec,
      onTermination: @escaping ClairV2AgentTerminationHandler
    ) throws -> any ClairV2AgentProcess {
      let process = try base.makeProcess(spec: spec, onTermination: onTermination)
      capture.set(process)
      return process
    }
  }

  private struct H04InvalidTerminationCallbackFactory: ClairV2AgentProcessFactory {
    let base: ClairV2SystemAgentProcessFactory
    let callback: H04TerminationCallbackCapture
    let capture: H04ProcessCapture

    func makeProcess(
      spec: ClairV2AgentLaunchSpec,
      onTermination: @escaping ClairV2AgentTerminationHandler
    ) throws -> any ClairV2AgentProcess {
      // Suppress the real callback so the test can inject an invalid callback
      // while the provider and its descendant are still live.
      let process = try base.makeProcess(
        spec: spec,
        onTermination: { _ in }
      )
      callback.set(onTermination)
      capture.set(process)
      return process
    }
  }

  private final class H04CompletionLatch: @unchecked Sendable {
    private let signalValue = DispatchSemaphore(value: 0)

    func signal() {
      signalValue.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
      signalValue.wait(timeout: .now() + timeout) == .success
    }
  }

  private final class H04TerminationCallbackCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackValue: ClairV2AgentTerminationHandler?

    func set(_ callback: @escaping ClairV2AgentTerminationHandler) {
      lock.lock()
      callbackValue = callback
      lock.unlock()
    }

    func emit(_ processExit: ClairV2AgentProcessExit) {
      lock.lock()
      let callback = callbackValue
      lock.unlock()
      callback?(processExit)
    }
  }

  private final class H04CleanupFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var signaledValue = false

    var isSignaled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return signaledValue
    }

    func signal() {
      lock.lock()
      signaledValue = true
      lock.unlock()
    }
  }

  private final class H04LeaderReapBarrier: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var processIDValue: Int32?

    func beforeReap(_ processID: Int32) {
      lock.lock()
      processIDValue = processID
      lock.unlock()
      entered.signal()
      _ = releaseSignal.wait(timeout: .now() + 5)
    }

    func waitForLeader() -> Int32? {
      guard entered.wait(timeout: .now() + 2) == .success else { return nil }
      lock.lock()
      defer { lock.unlock() }
      return processIDValue
    }

    func release() {
      releaseSignal.signal()
    }
  }

  private final class H04ProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var processValue: (any ClairV2AgentProcess)?

    var process: (any ClairV2AgentProcess)? {
      lock.lock()
      defer { lock.unlock() }
      return processValue
    }

    func set(_ process: any ClairV2AgentProcess) {
      lock.lock()
      processValue = process
      lock.unlock()
    }
  }

  private enum H04ProcessLifecycleEvent: Equatable {
    case groupKill
    case leaderReap
    case keeperReap
  }

  private struct H04ProcessLifecycleSnapshot: Equatable {
    let groupKillCount: Int
    let leaderReapCount: Int
    let keeperReapCount: Int
    let groupID: Int32?
    let keeperID: Int32?
    let events: [H04ProcessLifecycleEvent]
  }

  private final class H04ProcessLifecycleInstrumentation: @unchecked Sendable {
    private let lock = NSLock()
    private var groupKillCountValue = 0
    private var leaderReapCountValue = 0
    private var keeperReapCountValue = 0
    private var groupIDValue: Int32?
    private var keeperIDValue: Int32?
    private var eventsValue: [H04ProcessLifecycleEvent] = []

    func recordGroupKill(groupID: Int32, keeperID: Int32) {
      lock.lock()
      groupKillCountValue += 1
      groupIDValue = groupID
      keeperIDValue = keeperID
      eventsValue.append(.groupKill)
      lock.unlock()
    }

    func recordLeaderReap(processID: Int32) {
      lock.lock()
      leaderReapCountValue += 1
      eventsValue.append(.leaderReap)
      lock.unlock()
    }

    func recordKeeperReap(processID: Int32) {
      lock.lock()
      keeperReapCountValue += 1
      eventsValue.append(.keeperReap)
      lock.unlock()
    }

    func snapshot() -> H04ProcessLifecycleSnapshot {
      lock.lock()
      defer { lock.unlock() }
      return H04ProcessLifecycleSnapshot(
        groupKillCount: groupKillCountValue,
        leaderReapCount: leaderReapCountValue,
        keeperReapCount: keeperReapCountValue,
        groupID: groupIDValue,
        keeperID: keeperIDValue,
        events: eventsValue
      )
    }
  }

#endif

private struct H04AdversarialProvider: ClairV2AgentProviderAdapter {
  let spec: ClairV2AgentLaunchSpec
  let factory: H04ProcessFactoryAdapter
  let identity: ClairV2ProviderIdentity

  init(spec: ClairV2AgentLaunchSpec, factory: H04ProcessFactoryAdapter) {
    self.spec = spec
    self.factory = factory
    self.identity = ClairV2ProviderIdentity(
      providerID: .openCode,
      version: try! ClairV2ProviderVersion("adversarial")
    )
  }

  func makeLaunchSpec(
    for session: ClairV2AgentSessionIdentity,
    workingDirectoryURL: URL,
    limits: ClairV2AgentLaunchLimits
  ) throws -> ClairV2AgentLaunchSpec {
    spec
  }

  func makeProcess(
    spec: ClairV2AgentLaunchSpec,
    onTermination: @escaping ClairV2AgentTerminationHandler
  ) throws -> any ClairV2AgentProcess {
    try factory.makeProcess(spec: spec, onTermination: onTermination)
  }
}

private struct H04Credentials: ClairV2AgentCredentialSource {
  let values: [String: String]

  func environment(for providerID: ClairV2ProviderID) throws -> [String: String] {
    values
  }
}

private struct H04ProcessFactoryAdapter: ClairV2AgentProcessFactory {
  let factory: H04ProcessFactory

  func makeProcess(
    spec: ClairV2AgentLaunchSpec,
    onTermination: @escaping ClairV2AgentTerminationHandler
  ) throws -> any ClairV2AgentProcess {
    try factory.makeProcess(
      spec: spec,
      onTermination: onTermination
    )
  }
}

private final class H04ProcessFactory: @unchecked Sendable {
  let autoTerminateOnRequest: Bool
  let terminationDelay: UInt64
  let creationError: Error?
  let rawOutput: ClairV2AgentRawOutput
  let terminationFailures: Int
  let forceTerminationFailures: Int
  let startExit: ClairV2AgentProcessExit?
  private let lock = NSLock()
  private(set) var specs: [ClairV2AgentLaunchSpec] = []
  private(set) var processes: [H04FakeProcess] = []

  init(
    autoTerminateOnRequest: Bool = true,
    terminationDelay: UInt64 = 0,
    creationError: Error? = nil,
    rawOutput: ClairV2AgentRawOutput = ClairV2AgentRawOutput(),
    terminationFailures: Int = 0,
    forceTerminationFailures: Int = 0,
    startExit: ClairV2AgentProcessExit? = nil
  ) {
    self.autoTerminateOnRequest = autoTerminateOnRequest
    self.terminationDelay = terminationDelay
    self.creationError = creationError
    self.rawOutput = rawOutput
    self.terminationFailures = terminationFailures
    self.forceTerminationFailures = forceTerminationFailures
    self.startExit = startExit
  }

  func makeProcess(
    spec: ClairV2AgentLaunchSpec,
    onTermination: @escaping ClairV2AgentTerminationHandler
  ) throws -> H04FakeProcess {
    if let creationError {
      throw creationError
    }
    let process = H04FakeProcess(
      processID: Int32(10_000 + processCount),
      autoTerminateOnRequest: autoTerminateOnRequest,
      terminationDelay: terminationDelay,
      rawOutput: rawOutput,
      terminationFailures: terminationFailures,
      forceTerminationFailures: forceTerminationFailures,
      startExit: startExit,
      onTermination: onTermination
    )
    lock.lock()
    specs.append(spec)
    processes.append(process)
    lock.unlock()
    return process
  }

  private var processCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return processes.count
  }
}

private final class H04FakeProcess: ClairV2AgentProcess, @unchecked Sendable {
  let processID: Int32
  private let autoTerminateOnRequest: Bool
  private let terminationDelay: UInt64
  private let output: ClairV2AgentRawOutput
  private let startExit: ClairV2AgentProcessExit?
  private let onTermination: ClairV2AgentTerminationHandler
  private let lock = NSLock()
  private var started = false
  private var running = false
  private var pendingCleanup = false
  private var completedExit: ClairV2AgentProcessExit?
  private var terminationFailuresRemaining: Int
  private var forceTerminationFailuresRemaining: Int
  private(set) var terminateCount = 0
  private(set) var forceTerminateCount = 0

  init(
    processID: Int32,
    autoTerminateOnRequest: Bool,
    terminationDelay: UInt64,
    rawOutput: ClairV2AgentRawOutput,
    terminationFailures: Int,
    forceTerminationFailures: Int,
    startExit: ClairV2AgentProcessExit?,
    onTermination: @escaping ClairV2AgentTerminationHandler
  ) {
    self.processID = processID
    self.autoTerminateOnRequest = autoTerminateOnRequest
    self.terminationDelay = terminationDelay
    self.output = rawOutput
    self.startExit = startExit
    self.terminationFailuresRemaining = terminationFailures
    self.forceTerminationFailuresRemaining = forceTerminationFailures
    self.onTermination = onTermination
  }

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  var hasPendingCleanup: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pendingCleanup
  }

  func start() throws -> ClairV2AgentProcessStartOutcome {
    lock.lock()
    guard !started else {
      lock.unlock()
      throw ClairV2AgentError.processAlreadyStarted
    }
    started = true
    running = true
    let startExit = self.startExit
    lock.unlock()
    if let startExit {
      emit(startExit)
      return .terminated(startExit)
    }
    return .running
  }

  func send(signal: ClairV2AgentSignal) async throws {
    guard isRunning else { throw ClairV2AgentError.processNotRunning }
    if signal == .terminate {
      emit(
        ClairV2AgentProcessExit(
          signal: signal.rawValue,
          wasRequestedByClair: true
        )
      )
    }
  }

  func terminate(gracePeriod: TimeInterval) async throws -> ClairV2AgentProcessExit {
    let shouldFinish = markTerminate()
    if let completed = shouldFinish.completed {
      return completed
    }
    if shouldFinish.shouldFail {
      throw ClairV2AgentError.processTerminationFailed
    }
    if shouldFinish.autoTerminate {
      if terminationDelay > 0 {
        try? await Task.sleep(nanoseconds: terminationDelay)
      }
      emit(
        ClairV2AgentProcessExit(
          status: 0,
          wasRequestedByClair: true
        )
      )
    } else {
      try? await Task.sleep(
        nanoseconds: max(terminationDelay, UInt64(max(0, gracePeriod) * 1_000_000_000))
      )
      return try await forceTerminate()
    }
    return await waitForExit()
  }

  func forceTerminate() async throws -> ClairV2AgentProcessExit {
    let state = markForceTermination()
    let completed = state.completed
    let wasStarted = state.wasStarted
    if state.shouldFail {
      throw ClairV2AgentError.processTerminationFailed
    }
    if let completed {
      if state.pendingCleanup {
        clearPendingCleanup()
      }
      return completed
    }
    guard wasStarted else {
      return ClairV2AgentProcessExit(
        wasRequestedByClair: true,
        wasForceTerminated: true,
        didLaunch: false
      )
    }
    emit(
      ClairV2AgentProcessExit(
        signal: 9,
        wasRequestedByClair: true,
        wasForceTerminated: true
      )
    )
    return await waitForExit()
  }

  func rawOutput() async -> ClairV2AgentRawOutput {
    output
  }

  func emit(_ exit: ClairV2AgentProcessExit, cleanupPending: Bool = false) {
    lock.lock()
    guard completedExit == nil else {
      lock.unlock()
      return
    }
    completedExit = exit
    running = false
    pendingCleanup = cleanupPending
    lock.unlock()
    onTermination(exit)
  }

  private func markTerminate() -> (
    completed: ClairV2AgentProcessExit?,
    autoTerminate: Bool,
    shouldFail: Bool
  ) {
    lock.lock()
    terminateCount += 1
    let completed = completedExit
    let shouldFail = terminationFailuresRemaining > 0
    if shouldFail {
      terminationFailuresRemaining -= 1
    }
    lock.unlock()
    return (completed, autoTerminateOnRequest, shouldFail)
  }

  private func markForceTermination() -> (
    completed: ClairV2AgentProcessExit?,
    wasStarted: Bool,
    pendingCleanup: Bool,
    shouldFail: Bool
  ) {
    lock.lock()
    forceTerminateCount += 1
    let completed = completedExit
    let wasStarted = started
    let pendingCleanup = self.pendingCleanup
    let shouldFail = forceTerminationFailuresRemaining > 0
    if shouldFail {
      forceTerminationFailuresRemaining -= 1
    }
    lock.unlock()
    return (completed, wasStarted, pendingCleanup, shouldFail)
  }

  private func waitForExit() async -> ClairV2AgentProcessExit {
    while true {
      let completed = currentExit()
      if let completed { return completed }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  private func currentExit() -> ClairV2AgentProcessExit? {
    lock.lock()
    defer { lock.unlock() }
    return completedExit
  }

  private func clearPendingCleanup() {
    lock.lock()
    pendingCleanup = false
    lock.unlock()
  }
}

private enum H04TestSupport {
  static func yieldToActor() async throws {
    for _ in 0..<3 {
      await Task.yield()
      try await Task.sleep(nanoseconds: 1_000_000)
    }
  }
}

#if os(macOS)

  private final class H04CWDReplacement: @unchecked Sendable {
    let rootURL: URL
    private let displacedURL: URL
    private let lock = NSLock()
    private var replaced = false

    init(rootURL: URL) {
      self.rootURL = rootURL
      self.displacedURL = rootURL.deletingLastPathComponent()
        .appendingPathComponent(
          "clair-v2-h04-cwd-displaced-" + UUID().uuidString,
          isDirectory: true
        )
    }

    func replaceWithReplacementDirectory() throws {
      lock.lock()
      defer { lock.unlock() }
      guard !replaced else { return }
      try FileManager.default.moveItem(at: rootURL, to: displacedURL)
      do {
        try FileManager.default.createDirectory(
          at: rootURL,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
        replaced = true
      } catch {
        try? FileManager.default.moveItem(at: displacedURL, to: rootURL)
        throw error
      }
    }

    func restore() {
      lock.lock()
      defer { lock.unlock() }
      guard replaced else { return }
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.moveItem(at: displacedURL, to: rootURL)
      replaced = false
    }
  }

#endif

private final class H04WorkspaceFixture {
  let rootURL: URL
  private let isGitRepository: Bool

  init(gitRepository: Bool = false) throws {
    self.isGitRepository = gitRepository
    rootURL = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("clair-v2-h04-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    if gitRepository {
      try runGit(["init", "--quiet"])
      try runGit(["config", "user.email", "clair-h04@example.invalid"])
      try runGit(["config", "user.name", "Clair H04"])
      try Data("initial\n".utf8).write(to: rootURL.appendingPathComponent("tracked.txt"))
      try runGit(["add", "tracked.txt"])
      try runGit(["commit", "--quiet", "-m", "initial"])
    }
  }

  func workspace(projectID: String) throws -> ClairV2WorkspaceRuntime {
    let id = try ProjectID(projectID)
    return try ClairV2WorkspaceRuntime(
      projects: [try ClairV2ProjectRoot(id: id, rootURL: rootURL)]
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  @discardableResult
  private func runGit(_ arguments: [String]) throws -> String {
    let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
    guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
      throw H04FixtureError.commandUnavailable
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = rootURL
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let output =
      (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    guard process.terminationStatus == 0 else {
      throw H04FixtureError.commandFailed
    }
    return String(decoding: output, as: UTF8.self)
  }
}

private enum H04FixtureError: Error {
  case commandUnavailable
  case commandFailed
  case factoryFailed
}
