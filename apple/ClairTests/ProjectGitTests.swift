import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class ProjectGitTests: XCTestCase {
  func testStatusSeparatesStagedUnstagedAndUntrackedChanges() throws {
    let fixture = try GitFixture()
    let service = ProjectGitService(rootURL: fixture.root)

    try fixture.write("tracked.txt", contents: "working tree\n")
    try fixture.write("untracked.txt", contents: "new file\n")

    var snapshot = try service.status()
    XCTAssertTrue(snapshot.isRepository)
    XCTAssertEqual(snapshot.branch, "main")
    XCTAssertEqual(snapshot.stagedChanges, [])
    XCTAssertEqual(snapshot.unstagedChanges.map(\.path), ["tracked.txt"])
    XCTAssertEqual(snapshot.untrackedChanges.map(\.path), ["untracked.txt"])

    snapshot = try service.stage(path: "tracked.txt")
    XCTAssertEqual(snapshot.stagedChanges.map(\.path), ["tracked.txt"])
    XCTAssertEqual(snapshot.unstagedChanges, [])

    try fixture.write("tracked.txt", contents: "staged then working tree\n")
    snapshot = try service.status()
    XCTAssertEqual(snapshot.stagedChanges.map(\.path), ["tracked.txt"])
    XCTAssertEqual(snapshot.unstagedChanges.map(\.path), ["tracked.txt"])
    XCTAssertEqual(snapshot.untrackedChanges.map(\.path), ["untracked.txt"])
  }

  func testDiffStageUnstageAndCommitPreserveStagedBoundary() throws {
    let fixture = try GitFixture()
    let service = ProjectGitService(rootURL: fixture.root)

    try fixture.write("tracked.txt", contents: "changed\n")
    var snapshot = try service.status()
    let tracked = try XCTUnwrap(snapshot.changes.first { $0.path == "tracked.txt" })
    let workingTreeDiff = try service.diff(for: tracked, basis: .workingTree)
    XCTAssertTrue(workingTreeDiff.text.contains("-baseline"))
    XCTAssertTrue(workingTreeDiff.text.contains("+changed"))

    snapshot = try service.stage(path: tracked.path)
    let stagedChange = try XCTUnwrap(snapshot.stagedChanges.first)
    let stagedDiff = try service.diff(for: stagedChange, basis: .staged)
    XCTAssertTrue(stagedDiff.text.contains("+changed"))

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

    try fixture.remove("tracked.txt")
    var snapshot = try service.status()
    XCTAssertEqual(snapshot.changes.first?.kind, .deleted)
    try fixture.runGit(["restore", "tracked.txt"])
    snapshot = try service.status()
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

  init(createRepository: Bool = true) throws {
    container = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-project-git-\(UUID().uuidString)", isDirectory: true)
    root = container.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
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
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
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
