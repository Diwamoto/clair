import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class ProjectGitTests: XCTestCase {
  func testDiffStageUnstageAndCommitPreserveStagedBoundary() throws {
    let fixture = try GitFixture()
    let service = ProjectGitService(rootURL: fixture.root)

    try fixture.write("tracked.txt", contents: "changed\n")
    try fixture.write("untracked.txt", contents: "untracked\n")
    var snapshot = try service.status()
    XCTAssertEqual(snapshot.stagedChanges, [])
    XCTAssertEqual(snapshot.unstagedChanges.map(\.path), ["tracked.txt"])
    XCTAssertEqual(snapshot.untrackedChanges.map(\.path), ["untracked.txt"])
    let tracked = try XCTUnwrap(snapshot.changes.first { $0.path == "tracked.txt" })
    let workingTreeDiff = try service.diff(for: tracked, basis: .workingTree)
    XCTAssertTrue(workingTreeDiff.text.contains("-baseline"))
    XCTAssertTrue(workingTreeDiff.text.contains("+changed"))

    snapshot = try service.stage(path: tracked.path)
    let stagedChange = try XCTUnwrap(snapshot.stagedChanges.first)
    let stagedDiff = try service.diff(for: stagedChange, basis: .staged)
    XCTAssertTrue(stagedDiff.text.contains("+changed"))

    try fixture.write("tracked.txt", contents: "later working tree\n")
    snapshot = try service.status()
    XCTAssertEqual(snapshot.stagedChanges.map(\.path), ["tracked.txt"])
    XCTAssertEqual(snapshot.unstagedChanges.map(\.path), ["tracked.txt"])
    XCTAssertEqual(snapshot.untrackedChanges.map(\.path), ["untracked.txt"])
    XCTAssertTrue(try service.diff(for: tracked, basis: .staged).text.contains("+changed"))
    XCTAssertTrue(
      try service.diff(for: tracked, basis: .workingTree).text.contains("+later working tree"))
    snapshot = try service.unstage(path: tracked.path)
    XCTAssertEqual(snapshot.stagedChanges, [])
    XCTAssertEqual(snapshot.unstagedChanges.map(\.path), ["tracked.txt"])

    snapshot = try service.stage(path: tracked.path)
    snapshot = try service.commit(message: "Update tracked file")
    XCTAssertFalse(snapshot.changes.contains { $0.path == tracked.path })
    XCTAssertTrue(try fixture.log().contains("Update tracked file"))
  }

  func testUntrackedDiffAndRenameDeleteStatusesAreSafe() throws {
    let fixture = try GitFixture()
    let service = ProjectGitService(rootURL: fixture.root)

    try fixture.write("untracked.txt", contents: "new\n")
    var snapshot = try service.status()
    let untracked = try XCTUnwrap(snapshot.untrackedChanges.first)
    let untrackedDiff = try service.diff(for: untracked, basis: .workingTree)
    XCTAssertTrue(untrackedDiff.text.contains("+new"))

    try fixture.runGit(["mv", "tracked.txt", "renamed.txt"])
    try fixture.remove("delete-me.txt")
    snapshot = try service.status()
    XCTAssertEqual(snapshot.changes.first { $0.path == "renamed.txt" }?.kind, .renamed)
    XCTAssertEqual(snapshot.changes.first { $0.path == "renamed.txt" }?.originalPath, "tracked.txt")
    XCTAssertEqual(snapshot.changes.first { $0.path == "delete-me.txt" }?.kind, .deleted)
  }

  func testCommitMessageAndBranchSwitchErrorsAreTypedAndSafe() throws {
    let fixture = try GitFixture()
    let service = ProjectGitService(rootURL: fixture.root)

    XCTAssertThrowsError(try service.commit(message: "  ")) { error in
      XCTAssertEqual(error as? ProjectGitError, .invalidCommitMessage)
    }
    XCTAssertThrowsError(try service.stage(path: "../outside")) { error in
      XCTAssertEqual(error as? ProjectGitError, .invalidPath("../outside"))
    }

    try fixture.runGit(["branch", "feature"])
    try fixture.write("tracked.txt", contents: "dirty\n")
    XCTAssertThrowsError(try service.switchBranch("feature")) { error in
      XCTAssertEqual(error as? ProjectGitError, .dirtyWorkingTree)
    }

    try fixture.runGit(["restore", "tracked.txt"])
    var snapshot = try service.status()
    XCTAssertTrue(snapshot.changes.isEmpty)

    snapshot = try service.switchBranch("feature")
    XCTAssertEqual(snapshot.branch, "feature")
    XCTAssertThrowsError(try service.switchBranch("does-not-exist")) { error in
      guard case .commandFailed(let operation, _, _) = error as? ProjectGitError else {
        return XCTFail("Expected a typed Git command failure, got \(error)")
      }
      XCTAssertEqual(operation, "switch branch")
    }
    XCTAssertEqual(try service.status().branch, "feature")
  }

  func testWorkspaceGitCommandsAndExternalIndexRefreshStayProjectScoped() async throws {
    let fixture = try GitFixture()
    let store = ProjectStore(
      fileURL: fixture.container.appendingPathComponent("state/projects-v1.json")
    )
    let workspace = ProjectWorkspaceModel(store: store)
    let project = try XCTUnwrap(
      project(
        workspace.execute(
          .openProject(OpenProjectCommand(rootURL: fixture.root))
        )
      )
    )
    let surface = try XCTUnwrap(workspace.activeSurface)

    try fixture.write("tracked.txt", contents: "external change\n")
    await waitForGitStatus(surface) { status in
      status.unstagedChanges.contains { $0.path == "tracked.txt" }
    }

    try fixture.runGit(["add", "tracked.txt"])
    await waitForGitStatus(surface) { status in
      status.stagedChanges.contains { $0.path == "tracked.txt" }
        && !status.unstagedChanges.contains { $0.path == "tracked.txt" }
    }

    let stageResult = workspace.execute(
      .gitStage(
        GitStageCommand(projectID: project.id, relativePath: "untracked.txt")
      )
    )
    guard case .failure(.git(.changeNotFound("untracked.txt"))) = stageResult else {
      return XCTFail("Expected a typed stale-change error, got \(stageResult)")
    }

    let unstageResult = workspace.execute(
      .gitUnstage(
        GitUnstageCommand(projectID: project.id, relativePath: "tracked.txt")
      )
    )
    guard case .success(.gitStatus(let afterUnstage)) = unstageResult else {
      return XCTFail("Expected a Git status result, got \(unstageResult)")
    }
    XCTAssertEqual(afterUnstage.unstagedChanges.map(\.path), ["tracked.txt"])
  }

  func testNonGitProjectReportsAvailabilityWithoutThrowing() throws {
    let fixture = try GitFixture(createRepository: false)
    let snapshot = try ProjectGitService(rootURL: fixture.root).status()
    XCTAssertEqual(snapshot, .notRepository)
  }

  func testGraphReadsCommitParentsRefsAndMetadataWithoutChangingWorkingTree() throws {
    let fixture = try GitFixture()
    let service = ProjectGitService(rootURL: fixture.root)

    try fixture.runGit(["branch", "feature"])
    try fixture.write("main.txt", contents: "main branch\n")
    let mainHead = try fixture.commit(in: fixture.root, message: "main change")

    try fixture.runGit(["switch", "feature"])
    try fixture.write("feature.txt", contents: "feature branch\n")
    let featureHead = try fixture.commit(in: fixture.root, message: "feature change")

    try fixture.runGit(["switch", "main"])
    try fixture.runGit(["merge", "--no-ff", "--no-edit", "feature"])
    let mergeHead = try fixture.headRevision(in: fixture.root)
    try fixture.runGit(
      ["tag", "-a", "v-feature", "-m", "feature release", featureHead]
    )
    try fixture.runGit(["tag", "v-main", mainHead])
    try fixture.runGit(["update-ref", "refs/remotes/origin/main", mainHead])
    try fixture.write("dirty.txt", contents: "not committed\n")

    let before = try service.status()
    let graph = try service.graph()
    let after = try service.status()

    XCTAssertTrue(graph.isRepository)
    XCTAssertEqual(graph.branch, "main")
    XCTAssertEqual(graph.headRevision, mergeHead)
    XCTAssertEqual(graph.commits.count, 4)
    XCTAssertFalse(graph.isTruncated)
    XCTAssertEqual(before, after)

    let refsByName = Dictionary(uniqueKeysWithValues: graph.refs.map { ($0.name, $0) })
    XCTAssertEqual(refsByName["main"]?.kind, .localBranch)
    XCTAssertTrue(refsByName["main"]?.isCurrent == true)
    XCTAssertEqual(refsByName["feature"]?.kind, .localBranch)
    XCTAssertEqual(refsByName["origin/main"]?.kind, .remoteBranch)
    XCTAssertEqual(refsByName["v-feature"]?.kind, .tag)
    XCTAssertEqual(refsByName["v-main"]?.kind, .tag)
    XCTAssertEqual(refsByName["v-main"]?.targetRevision, mainHead)
    XCTAssertEqual(graph.branches.map(\.name), ["feature", "main", "origin/main"])

    let mergeCommit = try XCTUnwrap(graph.commits.first { $0.revision == mergeHead })
    XCTAssertEqual(mergeCommit.parentRevisions, [mainHead, featureHead])
    XCTAssertTrue(mergeCommit.subject.contains("feature"))
    XCTAssertEqual(mergeCommit.refs.map(\.name), ["main"])
    XCTAssertEqual(mergeCommit.author, "Clair Test")
    XCTAssertNotNil(ISO8601DateFormatter().date(from: mergeCommit.authoredAt))

    let featureCommit = try XCTUnwrap(
      graph.commits.first { $0.revision == featureHead }
    )
    XCTAssertEqual(
      Set(featureCommit.refs.map(\.name)),
      Set(["feature", "v-feature"])
    )
    XCTAssertTrue(
      graph.commits.allSatisfy { commit in
        commit.parentRevisions.allSatisfy { parent in
          graph.commits.contains { $0.revision == parent }
        }
      }
    )
  }

  func testGraphLimitIsBoundedAndNonGitProjectIsSafe() throws {
    let fixture = try GitFixture()
    let service = ProjectGitService(rootURL: fixture.root)

    for index in 1...3 {
      try fixture.write("file-\(index).txt", contents: "\(index)\n")
      _ = try fixture.commit(in: fixture.root, message: "change \(index)")
    }

    let graph = try service.graph(limit: 2)
    XCTAssertEqual(graph.commits.count, 2)
    XCTAssertTrue(graph.isTruncated)

    let lowerBoundaryGraph = try service.graph(limit: 1)
    XCTAssertEqual(lowerBoundaryGraph.commits.count, 1)
    XCTAssertTrue(lowerBoundaryGraph.isTruncated)

    let exactBoundaryGraph = try service.graph(limit: 4)
    XCTAssertEqual(exactBoundaryGraph.commits.count, 4)
    XCTAssertFalse(exactBoundaryGraph.isTruncated)

    XCTAssertThrowsError(try service.graph(limit: 0)) { error in
      XCTAssertEqual(error as? ProjectGitError, .invalidGraphLimit(0))
    }
    XCTAssertThrowsError(
      try service.graph(limit: ProjectGitService.maximumGraphLimit + 1)
    ) { error in
      XCTAssertEqual(
        error as? ProjectGitError,
        .invalidGraphLimit(ProjectGitService.maximumGraphLimit + 1)
      )
    }

    let nonGitFixture = try GitFixture(createRepository: false)
    let nonGitGraph = try ProjectGitService(rootURL: nonGitFixture.root).graph()
    XCTAssertEqual(nonGitGraph, .notRepository)

    let emptyGitFixture = try GitFixture(createRepository: false)
    try emptyGitFixture.runGit(["init", "--quiet", "-b", "main"])
    let emptyGraph = try ProjectGitService(rootURL: emptyGitFixture.root).graph()
    XCTAssertTrue(emptyGraph.isRepository)
    XCTAssertEqual(emptyGraph.branch, "main")
    XCTAssertNil(emptyGraph.headRevision)
    XCTAssertTrue(emptyGraph.refs.isEmpty)
    XCTAssertTrue(emptyGraph.commits.isEmpty)
  }

  func testGraphIncludesDetachedHeadWhenNoRefsReachIt() throws {
    let fixture = try GitFixture()
    let head = try fixture.headRevision(in: fixture.root)
    try fixture.runGit(["switch", "--detach", "--quiet", head])
    try fixture.runGit(["branch", "-D", "--quiet", "main"])

    let graph = try ProjectGitService(rootURL: fixture.root).graph(limit: 1)

    XCTAssertTrue(graph.isRepository)
    XCTAssertNil(graph.branch)
    XCTAssertEqual(graph.headRevision, head)
    XCTAssertTrue(graph.refs.isEmpty)
    XCTAssertEqual(graph.commits.map(\.revision), [head])
    XCTAssertFalse(graph.isTruncated)
  }

  func testBranchWideReviewSeparatesCommittedAndUncommittedChangesAndGatesAdoption() throws {
    let fixture = try GitFixture()
    var source = try fixture.makeManagedWorktree(
      branch: "agent/review",
      targetName: "review"
    )

    try fixture.write(
      "tracked.txt",
      in: source.rootURL,
      contents: "committed source change\n"
    )
    let committedRevision = try fixture.commit(
      in: source.rootURL,
      message: "committed source change"
    )
    try fixture.write(
      "untracked.txt",
      in: source.rootURL,
      contents: "uncommitted source change\n"
    )
    source = try fixture.makeWorktreeService().inspect(source.id)

    let service = ProjectBranchReviewService(
      source: source,
      targetRootURL: fixture.root
    )
    let snapshot = try service.review()

    XCTAssertEqual(snapshot.sourceWorktreeID, source.id)
    XCTAssertEqual(snapshot.sourceRootURL.path, source.rootURL.standardizedFileURL.path)
    XCTAssertEqual(snapshot.expectedSourceBranch, source.branch)
    XCTAssertEqual(snapshot.sourceBranch, source.branch)
    XCTAssertEqual(snapshot.baseRevision, source.baseRevision)
    XCTAssertEqual(snapshot.headRevision, committedRevision)
    XCTAssertEqual(snapshot.commits.map(\.revision), [committedRevision])
    XCTAssertEqual(snapshot.committedChanges.map(\.path), ["tracked.txt"])
    XCTAssertTrue(snapshot.committedDiff.contains("+committed source change"))
    XCTAssertFalse(snapshot.committedDiff.contains("+uncommitted source change"))
    XCTAssertEqual(snapshot.uncommittedChanges.map(\.path), ["untracked.txt"])
    XCTAssertEqual(snapshot.uncommittedChanges, snapshot.sourceStatus.changes)
    XCTAssertFalse(snapshot.isSourceClean)
    XCTAssertTrue(snapshot.isTargetClean)

    let dirtyPlan = try service.prepareAdoption()
    XCTAssertFalse(dirtyPlan.canAdopt)
    XCTAssertEqual(dirtyPlan.blockers, [.sourceDirty])
    XCTAssertThrowsError(try service.adopt(dirtyPlan)) { error in
      XCTAssertEqual(
        error as? ProjectBranchReviewError,
        .adoptionBlocked([.sourceDirty])
      )
    }

    _ = try fixture.commit(in: source.rootURL, message: "commit remaining source change")
    let cleanPlan = try service.prepareAdoption()
    XCTAssertTrue(cleanPlan.canAdopt)
    XCTAssertTrue(cleanPlan.blockers.isEmpty)

    try fixture.write("target-untracked.txt", contents: "target dirty\n")
    let targetDirtyPlan = try service.prepareAdoption()
    XCTAssertFalse(targetDirtyPlan.canAdopt)
    XCTAssertEqual(targetDirtyPlan.blockers, [.targetDirty])
    XCTAssertThrowsError(try service.adopt(targetDirtyPlan)) { error in
      XCTAssertEqual(
        error as? ProjectBranchReviewError,
        .adoptionBlocked([.targetDirty])
      )
    }
    try fixture.remove("target-untracked.txt")
  }

  func testCleanAdoptionCreatesTwoParentMergeCommitAndPreservesSourceAndTargetState() throws {
    let fixture = try GitFixture()
    var source = try fixture.makeManagedWorktree(
      branch: "agent/adopt",
      targetName: "adopt"
    )

    try fixture.write(
      "feature.txt",
      in: source.rootURL,
      contents: "feature branch\n"
    )
    let sourceHead = try fixture.commit(
      in: source.rootURL,
      message: "add feature"
    )
    source = try fixture.makeWorktreeService().inspect(source.id)

    let service = ProjectBranchReviewService(
      source: source,
      targetRootURL: fixture.root
    )
    let plan = try service.prepareAdoption()
    XCTAssertTrue(plan.canAdopt)
    XCTAssertEqual(plan.targetBranch, "main")
    XCTAssertEqual(plan.targetHeadRevision, try fixture.headRevision(in: fixture.root))

    let result = try service.adopt(plan)
    let mergeRevision: String
    guard case .adopted(let revision) = result else {
      return XCTFail("Expected a clean adoption result, got \(result)")
    }
    mergeRevision = revision

    XCTAssertEqual(mergeRevision, try fixture.headRevision(in: fixture.root))
    XCTAssertNotEqual(mergeRevision, sourceHead)
    let parentRevisions = try fixture.runGit(
      ["rev-list", "--parents", "-n", "1", "HEAD"]
    )
    .split(whereSeparator: \.isWhitespace)
    .map(String.init)
    XCTAssertEqual(parentRevisions.count, 3)
    XCTAssertEqual(Array(parentRevisions.dropFirst()), [plan.targetHeadRevision, sourceHead])

    let sourceStatus = try ProjectGitService(rootURL: source.rootURL).status()
    let targetStatus = try ProjectGitService(rootURL: fixture.root).status()
    XCTAssertEqual(sourceStatus.branch, source.branch)
    XCTAssertTrue(sourceStatus.changes.isEmpty)
    XCTAssertEqual(try fixture.headRevision(in: source.rootURL), sourceHead)
    XCTAssertEqual(targetStatus.branch, "main")
    XCTAssertTrue(targetStatus.changes.isEmpty)
    XCTAssertEqual(
      try String(contentsOf: fixture.root.appendingPathComponent("feature.txt")),
      "feature branch\n"
    )
  }

  func testDivergentAdoptionReturnsConflictAndLeavesTargetMergeInProgress() throws {
    let fixture = try GitFixture()
    var source = try fixture.makeManagedWorktree(
      branch: "agent/conflict",
      targetName: "conflict"
    )

    try fixture.write(
      "tracked.txt",
      in: source.rootURL,
      contents: "source conflict\n"
    )
    let sourceHead = try fixture.commit(
      in: source.rootURL,
      message: "source conflicting change"
    )
    source = try fixture.makeWorktreeService().inspect(source.id)

    try fixture.write("tracked.txt", contents: "target conflict\n")
    let targetHead = try fixture.commit(in: fixture.root, message: "target conflicting change")

    let service = ProjectBranchReviewService(
      source: source,
      targetRootURL: fixture.root
    )
    let plan = try service.prepareAdoption()
    XCTAssertTrue(plan.canAdopt)
    XCTAssertEqual(plan.targetHeadRevision, targetHead)

    defer {
      _ = try? fixture.runGit(["merge", "--abort"])
    }

    let result = try service.adopt(plan)
    guard case .conflict(let conflict) = result else {
      return XCTFail("Expected a conflict result, got \(result)")
    }
    XCTAssertEqual(conflict.sourceWorktreeID, source.id)
    XCTAssertEqual(conflict.sourceBranch, source.branch)
    XCTAssertEqual(conflict.targetBranch, "main")
    XCTAssertEqual(conflict.targetRootURL.path, fixture.root.standardizedFileURL.path)
    XCTAssertEqual(conflict.paths, ["tracked.txt"])
    XCTAssertFalse(conflict.commandMessage.isEmpty)
    XCTAssertEqual(try fixture.headRevision(in: fixture.root), targetHead)
    XCTAssertEqual(
      try fixture.runGit(["rev-parse", "--verify", "MERGE_HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines),
      sourceHead
    )

    let targetStatus = try ProjectGitService(rootURL: fixture.root).status()
    XCTAssertEqual(targetStatus.branch, "main")
    XCTAssertTrue(
      targetStatus.changes.contains {
        $0.path == "tracked.txt" && $0.kind == .conflicted
      }
    )
  }

  func testAdoptionRejectsStalePlanAfterSourceHeadAdvances() throws {
    let fixture = try GitFixture()
    var source = try fixture.makeManagedWorktree(
      branch: "agent/stale",
      targetName: "stale"
    )

    try fixture.write("first.txt", in: source.rootURL, contents: "first\n")
    let firstHead = try fixture.commit(in: source.rootURL, message: "first source change")
    source = try fixture.makeWorktreeService().inspect(source.id)

    let service = ProjectBranchReviewService(
      source: source,
      targetRootURL: fixture.root
    )
    let plan = try service.prepareAdoption()
    let targetHead = try fixture.headRevision(in: fixture.root)

    try fixture.write("second.txt", in: source.rootURL, contents: "second\n")
    let secondHead = try fixture.commit(in: source.rootURL, message: "second source change")
    XCTAssertNotEqual(firstHead, secondHead)

    XCTAssertThrowsError(try service.adopt(plan)) { error in
      XCTAssertEqual(error as? ProjectBranchReviewError, .stalePlan)
    }
    XCTAssertEqual(try fixture.headRevision(in: fixture.root), targetHead)
    XCTAssertTrue(try ProjectGitService(rootURL: fixture.root).status().changes.isEmpty)
    XCTAssertEqual(
      try fixture.runGit(["rev-list", "--parents", "-n", "1", "HEAD"])
        .split(whereSeparator: \.isWhitespace)
        .count,
      1
    )
  }

  private func project(
    _ result: Result<ClairCommandResult, CommandError>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Project? {
    guard case .success(.project(let project)) = result else {
      XCTFail("Expected a Project result, got \(result)", file: file, line: line)
      return nil
    }
    return project
  }

  private func waitForGitStatus(
    _ surface: ProjectSurfaceModel,
    timeout: TimeInterval = 3,
    matching predicate: (ProjectGitSnapshot) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let status = surface.gitStatus, predicate(status) {
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for Git status refresh", file: file, line: line)
  }
}

@MainActor
private final class GitFixture {
  let container: URL
  let root: URL
  let managementRoot: URL
  let worktreeStore: ManagedWorktreeStore
  let projectID: UUID

  init(createRepository: Bool = true) throws {
    container = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-project-git-\(UUID().uuidString)", isDirectory: true)
    root = container.appendingPathComponent("repo", isDirectory: true)
    managementRoot = container.appendingPathComponent("managed", isDirectory: true)
    worktreeStore = ManagedWorktreeStore(
      fileURL: container.appendingPathComponent("state/worktrees-v1.json")
    )
    projectID = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: managementRoot,
      withIntermediateDirectories: true
    )

    guard createRepository else {
      return
    }

    try runGit(["init", "--quiet", "-b", "main"])
    try runGit(["config", "user.name", "Clair Test"])
    try runGit(["config", "user.email", "clair-test@example.invalid"])
    try write("tracked.txt", contents: "baseline\n")
    try write("delete-me.txt", contents: "delete me\n")
    try runGit(["add", "."])
    try runGit(["commit", "--quiet", "-m", "baseline"])
  }

  func write(_ path: String, contents: String) throws {
    try write(path, in: root, contents: contents)
  }

  func write(_ path: String, in directory: URL, contents: String) throws {
    let url = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
  }

  func makeWorktreeService() -> ProjectWorktreeService {
    ProjectWorktreeService(
      projectID: projectID,
      repositoryRootURL: root,
      managementRootURL: managementRoot,
      store: worktreeStore
    )
  }

  func makeManagedWorktree(branch: String, targetName: String) throws -> ManagedWorktree {
    try makeWorktreeService().create(
      branch: branch,
      baseRevision: "HEAD",
      targetName: targetName
    )
  }

  func headRevision(in directory: URL) throws -> String {
    try runGit(["-C", directory.path, "rev-parse", "HEAD"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  func commit(in directory: URL, message: String) throws -> String {
    _ = try runGit(["-C", directory.path, "add", "--all"])
    _ = try runGit(["-C", directory.path, "commit", "--quiet", "-m", message])
    return try headRevision(in: directory)
  }

  func remove(_ path: String) throws {
    try FileManager.default.removeItem(at: root.appendingPathComponent(path))
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
      throw GitFixtureError.commandFailed(
        arguments: arguments,
        status: process.terminationStatus,
        message: String(decoding: data, as: UTF8.self)
      )
    }
    return String(decoding: data, as: UTF8.self)
  }

  func log() throws -> String {
    try runGit(["log", "-1", "--format=%s"])
  }

  deinit {
    try? FileManager.default.removeItem(at: container)
  }
}

private enum GitFixtureError: Error {
  case commandFailed(arguments: [String], status: Int32, message: String)
}
