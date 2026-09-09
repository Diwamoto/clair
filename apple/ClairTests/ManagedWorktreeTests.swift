import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class ManagedWorktreeTests: XCTestCase {
  func testCreateListInspectAndRestartPreserveStableIdentity() throws {
    let fixture = try WorktreeFixture()
    let service = fixture.makeService()

    let first = try service.create(
      branch: "agent/first",
      baseRevision: "HEAD",
      targetName: "first"
    )
    let second = try service.create(
      branch: "agent/second",
      baseRevision: first.baseRevision,
      targetName: "second"
    )

    XCTAssertEqual(first.state, .available)
    XCTAssertEqual(first.currentBranch, "agent/first")
    XCTAssertEqual(second.state, .available)
    XCTAssertEqual(second.currentBranch, "agent/second")
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertNotEqual(first.rootURL, second.rootURL)
    XCTAssertFalse(first.rootURL.path.hasPrefix(fixture.root.path + "/"))
    XCTAssertFalse(second.rootURL.path.hasPrefix(fixture.root.path + "/"))

    let listed = try service.list()
    XCTAssertEqual(listed.map(\.id), [first.id, second.id])

    let restarted = fixture.makeService()
    let recovered = try XCTUnwrap(try restarted.list().first { $0.id == first.id })
    XCTAssertEqual(recovered.rootURL, first.rootURL)
    XCTAssertEqual(recovered.branch, first.branch)
    XCTAssertEqual(recovered.baseRevision, first.baseRevision)
    XCTAssertEqual(try restarted.inspect(second.id).id, second.id)
  }

  func testCreateRejectsBranchConflictTargetConflictAndInvalidBase() throws {
    let fixture = try WorktreeFixture()
    let service = fixture.makeService()
    _ = try service.create(
      branch: "agent/existing",
      baseRevision: "HEAD",
      targetName: "existing"
    )

    XCTAssertThrowsError(
      try service.create(
        branch: "agent/existing",
        baseRevision: "HEAD",
        targetName: "another"
      )
    ) { error in
      XCTAssertEqual(error as? ManagedWorktreeError, .branchAlreadyExists("agent/existing"))
    }
    XCTAssertThrowsError(
      try service.create(
        branch: "agent/another",
        baseRevision: "does-not-exist",
        targetName: "another"
      )
    ) { error in
      XCTAssertEqual(error as? ManagedWorktreeError, .invalidBaseRevision("does-not-exist"))
    }

    let target = fixture.managementRoot.appendingPathComponent("occupied", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try service.create(
        branch: "agent/occupied",
        baseRevision: "HEAD",
        targetName: "occupied"
      )
    ) { error in
      XCTAssertEqual(error as? ManagedWorktreeError, .targetExists(target.standardizedFileURL.path))
    }
  }

  func testCleanupRequiresCleanTargetNoActiveSessionAndExplicitConfirmation() throws {
    let fixture = try WorktreeFixture()
    let service = fixture.makeService()
    let worktree = try service.create(
      branch: "agent/cleanup",
      baseRevision: "HEAD",
      targetName: "cleanup"
    )

    let activeSessionID = UUID()
    let activePlan = try service.prepareCleanup(
      worktree.id,
      activeSessionIDs: [activeSessionID],
      expectedRootURL: worktree.rootURL
    )
    XCTAssertFalse(activePlan.canConfirm)
    XCTAssertTrue(activePlan.blockers.contains(.activeSession))
    XCTAssertThrowsError(
      try service.confirmCleanup(activePlan, activeSessionIDs: [activeSessionID])
    ) {
      XCTAssertEqual(
        $0 as? ManagedWorktreeError,
        .cleanupBlocked([.activeSession])
      )
    }

    try fixture.write("dirty.txt", in: worktree.rootURL)
    let dirtyPlan = try service.prepareCleanup(
      worktree.id,
      expectedRootURL: worktree.rootURL
    )
    XCTAssertFalse(dirtyPlan.canConfirm)
    XCTAssertTrue(dirtyPlan.blockers.contains(.dirtyWorkingTree))
    XCTAssertThrowsError(try service.confirmCleanup(dirtyPlan)) {
      XCTAssertEqual(
        $0 as? ManagedWorktreeError,
        .cleanupBlocked([.dirtyWorkingTree])
      )
    }

    let wrongTarget = fixture.container.appendingPathComponent("wrong-target", isDirectory: true)
    let wrongPlan = try service.prepareCleanup(
      worktree.id,
      expectedRootURL: wrongTarget
    )
    XCTAssertFalse(wrongPlan.canConfirm)
    XCTAssertTrue(wrongPlan.blockers.contains(.targetMismatch))
    XCTAssertThrowsError(try service.confirmCleanup(wrongPlan)) {
      XCTAssertEqual(
        $0 as? ManagedWorktreeError,
        .cleanupBlocked([.targetMismatch, .dirtyWorkingTree])
      )
    }

    try FileManager.default.removeItem(at: worktree.rootURL.appendingPathComponent("dirty.txt"))
    let stalePlan = try service.prepareCleanup(
      worktree.id,
      expectedRootURL: worktree.rootURL
    )
    XCTAssertTrue(stalePlan.canConfirm)
    try fixture.write("committed.txt", in: worktree.rootURL)
    _ = try fixture.runGit(["-C", worktree.rootURL.path, "add", "--", "committed.txt"])
    _ = try fixture.runGit(
      ["-C", worktree.rootURL.path, "commit", "--quiet", "-m", "advance worktree"]
    )
    XCTAssertThrowsError(try service.confirmCleanup(stalePlan)) {
      guard let error = $0 as? ManagedWorktreeError, case .targetMismatch = error else {
        return XCTFail("Expected a stale cleanup fingerprint rejection, got \($0).")
      }
    }

    let cleanPlan = try service.prepareCleanup(
      worktree.id,
      expectedRootURL: worktree.rootURL
    )
    XCTAssertTrue(cleanPlan.canConfirm)
    try service.confirmCleanup(cleanPlan)
    XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.rootURL.path))
    XCTAssertTrue(try service.list().isEmpty)
  }

  func testMissingWorktreeIsDiscoveredWithoutRetargeting() throws {
    let fixture = try WorktreeFixture()
    let service = fixture.makeService()
    let worktree = try service.create(
      branch: "agent/missing",
      baseRevision: "HEAD",
      targetName: "missing"
    )

    try fixture.runGit(["worktree", "remove", "--force", "--", worktree.rootURL.path])

    let restarted = fixture.makeService()
    let discovered = try XCTUnwrap(try restarted.list().first { $0.id == worktree.id })
    XCTAssertEqual(discovered.state, .missing)
    XCTAssertEqual(discovered.rootURL.path, worktree.rootURL.path)
    XCTAssertNil(discovered.gitStatus)
  }

  func testDetachedHeadIsNotLaunchableOrCleanable() throws {
    let fixture = try WorktreeFixture()
    let service = fixture.makeService()
    let worktree = try service.create(
      branch: "agent/detached",
      baseRevision: "HEAD",
      targetName: "detached"
    )

    _ = try fixture.runGit(["-C", worktree.rootURL.path, "switch", "--detach", "HEAD"])

    let inspected = try service.inspect(worktree.id)
    XCTAssertEqual(inspected.state, .detached)
    XCTAssertNil(inspected.currentBranch)
    let plan = try service.prepareCleanup(worktree.id, expectedRootURL: worktree.rootURL)
    XCTAssertFalse(plan.canConfirm)
    XCTAssertTrue(plan.blockers.contains(.detachedWorktree))
    XCTAssertThrowsError(try service.confirmCleanup(plan)) {
      XCTAssertEqual(
        $0 as? ManagedWorktreeError,
        .cleanupBlocked([.detachedWorktree])
      )
    }
  }

  func testCatalogCannotRetargetCleanupOutsideManagedRoot() throws {
    let fixture = try WorktreeFixture()
    let service = fixture.makeService()
    let outsideRoot = fixture.container.appendingPathComponent("outside", isDirectory: true)
    _ = try fixture.runGit(["worktree", "add", "-b", "agent/outside", outsideRoot.path, "HEAD"])
    let record = ManagedWorktreeRecord(
      id: UUID(),
      projectID: UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!,
      repositoryRootPath: fixture.root.path,
      rootPath: outsideRoot.path,
      branch: "agent/outside",
      baseRevision: "HEAD",
      createdAt: Date()
    )
    try fixture.store.save(
      ManagedWorktreeStoreSnapshot(
        schemaVersion: ManagedWorktreeStoreSnapshot.currentSchemaVersion,
        worktrees: [record]
      )
    )

    XCTAssertThrowsError(try service.list()) {
      XCTAssertEqual($0 as? ManagedWorktreeError, .invalidTarget(outsideRoot.path))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideRoot.path))
  }

  func testManagedTerminalRootAndWorktreeIdentityRoundTrip() throws {
    let fixture = try WorktreeFixture(createRepository: false)
    let projectID = UUID()
    let worktreeID = UUID()
    let managedRoot = fixture.container.appendingPathComponent("managed-root", isDirectory: true)
    try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
    let tab = ProjectPaneTab.terminal(
      title: "Agent",
      executionRootURL: managedRoot,
      worktreeID: worktreeID
    )
    let decodedTab = try JSONDecoder().decode(
      ProjectPaneTab.self,
      from: JSONEncoder().encode(tab)
    )

    XCTAssertEqual(decodedTab.executionRootURL, managedRoot.standardizedFileURL)
    XCTAssertEqual(decodedTab.worktreeID, worktreeID)

    let agentSession = AgentSession(
      profile: .codex,
      projectRoot: managedRoot,
      worktreeID: worktreeID
    )
    let decodedAgentSession = try JSONDecoder().decode(
      AgentSession.self,
      from: JSONEncoder().encode(agentSession)
    )
    XCTAssertEqual(decodedAgentSession, agentSession)

    let leaf = ProjectPaneLeaf(activeTabID: tab.id)

    let surface = ProjectSurfaceModel(
      projectID: projectID,
      rootURL: fixture.container,
      snapshot: ProjectSurfaceSnapshot(
        schemaVersion: ProjectSurfaceSnapshot.currentSchemaVersion,
        projectID: projectID,
        tabs: [tab],
        root: .leaf(leaf),
        focusedPaneID: leaf.id,
        maximizedPaneID: nil,
        selectedNodeID: nil,
        expandedNodeIDs: []
      )
    )

    XCTAssertEqual(
      surface.terminalSession(tabID: tab.id)?.projectRootURL, managedRoot.standardizedFileURL)
    XCTAssertEqual(surface.sessionIDsInUse(for: worktreeID), [tab.sessionID!])
  }

  func testDirectAndManagedAgentLaunchCommandsKeepRootsDistinct() {
    let coordinator = AgentWorkflowCoordinator(
      activityStore: AgentActivityStore(fileURL: nil),
      notifier: NoopAgentActivityNotifier(),
      startHookMonitoring: false
    )
    let projectID = UUID()
    let worktreeID = UUID()
    let projectRoot = URL(fileURLWithPath: "/tmp/clair project")
    let managedRoot = URL(fileURLWithPath: "/tmp/clair managed worktree")

    let directCommand = coordinator.launchCommand(
      profile: .codex,
      projectRoot: projectRoot,
      projectID: projectID,
      sessionID: UUID()
    )
    let managedCommand = coordinator.launchCommand(
      profile: .codex,
      projectRoot: managedRoot,
      projectID: projectID,
      sessionID: UUID(),
      worktreeID: worktreeID
    )

    XCTAssertFalse(directCommand.contains("CLAIR_WORKTREE_ID"))
    XCTAssertTrue(managedCommand.contains("CLAIR_WORKTREE_ID='\(worktreeID.uuidString)'"))
    XCTAssertTrue(directCommand.contains("cd -- '/tmp/clair project'"))
    XCTAssertTrue(managedCommand.contains("cd -- '/tmp/clair managed worktree'"))
  }

  func testAgentLaunchRejectsManagedRootIdentityMismatch() throws {
    let fixture = try WorktreeFixture(createRepository: false)
    let projectID = UUID()
    let projectRoot = fixture.container.appendingPathComponent("project", isDirectory: true)
    let managedRoot = fixture.container.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
    let worktree = ManagedWorktree(
      id: UUID(),
      projectID: projectID,
      repositoryRootURL: projectRoot,
      rootURL: managedRoot,
      branch: "agent/test",
      baseRevision: "HEAD",
      createdAt: Date(),
      state: .available,
      headRevision: nil,
      currentBranch: "agent/test",
      gitStatus: nil
    )
    let surface = ProjectSurfaceModel(
      projectID: projectID,
      rootURL: projectRoot
    )
    let coordinator = AgentWorkflowCoordinator(
      activityStore: AgentActivityStore(fileURL: nil),
      notifier: NoopAgentActivityNotifier(),
      startHookMonitoring: false
    )

    XCTAssertNil(
      coordinator.launch(
        profile: .codex,
        projectID: projectID,
        projectRoot: projectRoot,
        surface: surface,
        worktree: worktree
      )
    )
    XCTAssertTrue(coordinator.lastErrorMessage?.contains("no longer available") == true)
    XCTAssertTrue(surface.tabStore.isEmpty)
  }
}

@MainActor
private final class WorktreeFixture {
  let container: URL
  let root: URL
  let managementRoot: URL
  let store: ManagedWorktreeStore

  init(createRepository: Bool = true) throws {
    container = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-managed-worktree-\(UUID().uuidString)", isDirectory: true)
    root = container.appendingPathComponent("repo", isDirectory: true)
    managementRoot = container.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: managementRoot, withIntermediateDirectories: true)
    store = ManagedWorktreeStore(
      fileURL: container.appendingPathComponent("state/worktrees-v1.json")
    )

    guard createRepository else {
      return
    }

    try runGit(["init", "--quiet", "-b", "main"])
    try runGit(["config", "user.name", "Clair Test"])
    try runGit(["config", "user.email", "clair-test@example.invalid"])
    try write("tracked.txt", in: root, contents: "baseline\n")
    try runGit(["add", "."])
    try runGit(["commit", "--quiet", "-m", "baseline"])
  }

  func makeService() -> ProjectWorktreeService {
    ProjectWorktreeService(
      projectID: UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!,
      repositoryRootURL: root,
      managementRootURL: managementRoot,
      store: store
    )
  }

  func write(_ path: String, in directory: URL, contents: String = "change\n") throws {
    let fileURL = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: fileURL)
  }

  @discardableResult
  func runGit(
    _ arguments: [String],
    allowedExitStatuses: Set<Int32> = [0]
  ) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard allowedExitStatuses.contains(process.terminationStatus) else {
      throw WorktreeFixtureError.commandFailed(
        arguments: arguments,
        status: process.terminationStatus,
        message: String(decoding: data, as: UTF8.self)
      )
    }
    return String(decoding: data, as: UTF8.self)
  }

  deinit {
    try? FileManager.default.removeItem(at: container)
  }
}

private enum WorktreeFixtureError: Error {
  case commandFailed(arguments: [String], status: Int32, message: String)
}

private struct NoopAgentActivityNotifier: AgentActivityNotifier {
  func notify(activity: AgentActivity) {}
}
