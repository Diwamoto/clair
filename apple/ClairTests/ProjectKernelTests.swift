import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class ProjectKernelTests: XCTestCase {
  func testOpensGitNonGitAndTemporaryFoldersInOneWorkspace() throws {
    let fixture = try Fixture()
    let gitRoot = try fixture.makeDirectory(named: "git-project")
    try FileManager.default.createDirectory(
      at: gitRoot.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    let plainRoot = try fixture.makeDirectory(named: "plain-project")
    let temporaryRoot = try fixture.makeDirectory(named: "temporary-project")
    let workspace = fixture.makeWorkspace()

    let projects = [gitRoot, plainRoot, temporaryRoot].map { root in
      project(
        workspace.execute(.openProject(OpenProjectCommand(rootURL: root)))
      )
    }

    XCTAssertEqual(workspace.projects.count, 3)
    let projectIDs = projects.compactMap { $0?.id }
    XCTAssertEqual(Set(projectIDs).count, 3)
    XCTAssertTrue(workspace.projects.allSatisfy { $0.availability == .available })
    XCTAssertEqual(workspace.activeProjectID, projectIDs.last)
  }

  func testDuplicateCanonicalRootIsRejectedWithoutChangingState() throws {
    let fixture = try Fixture()
    let root = try fixture.makeDirectory(named: "duplicate-project")
    let workspace = fixture.makeWorkspace()
    let first = try XCTUnwrap(
      project(workspace.execute(.openProject(OpenProjectCommand(rootURL: root))))
    )
    let alternatePath =
      root
      .appendingPathComponent("nested", isDirectory: true)
      .appendingPathComponent("..", isDirectory: true)
    let symlinkPath = fixture.root.appendingPathComponent("duplicate-alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: root)

    let normalizedResult = workspace.execute(
      .openProject(OpenProjectCommand(rootURL: alternatePath))
    )
    let symlinkResult = workspace.execute(
      .openProject(OpenProjectCommand(rootURL: symlinkPath))
    )

    guard case .failure(.project(.duplicateRoot(let existingID))) = normalizedResult else {
      return XCTFail("Expected a duplicate root error, got \(normalizedResult)")
    }
    guard case .failure(.project(.duplicateRoot(let symlinkID))) = symlinkResult else {
      return XCTFail("Expected a symlink duplicate error, got \(symlinkResult)")
    }
    XCTAssertEqual(existingID, first.id)
    XCTAssertEqual(symlinkID, first.id)
    XCTAssertEqual(workspace.projects.map(\.id), [first.id])
    XCTAssertEqual(workspace.activeProjectID, first.id)
  }

  func testInvalidAndPermissionErrorsPreserveOtherProjects() throws {
    let fixture = try Fixture()
    let goodRoot = try fixture.makeDirectory(named: "good-project")
    let permissionRoot = try fixture.makeDirectory(named: "permission-project")
    let missingRoot = fixture.root.appendingPathComponent("missing-project", isDirectory: true)
    let fileRoot = fixture.root.appendingPathComponent("not-a-folder.txt")
    try Data("fixture".utf8).write(to: fileRoot)

    let checker = TestRootChecker(unreadablePath: permissionRoot.standardizedFileURL.path)
    let workspace = fixture.makeWorkspace(rootChecker: checker)
    let goodProject = try XCTUnwrap(
      project(workspace.execute(.openProject(OpenProjectCommand(rootURL: goodRoot))))
    )

    let missingResult = workspace.execute(
      .openProject(OpenProjectCommand(rootURL: missingRoot))
    )
    let fileResult = workspace.execute(
      .openProject(OpenProjectCommand(rootURL: fileRoot))
    )
    let permissionResult = workspace.execute(
      .openProject(OpenProjectCommand(rootURL: permissionRoot))
    )

    assertProjectError(missingResult, matching: .rootMissing(path: missingRoot.path))
    assertProjectError(fileResult, matching: .rootNotDirectory(path: fileRoot.path))
    assertProjectError(
      permissionResult,
      matching: .rootUnreadable(path: permissionRoot.standardizedFileURL.path)
    )
    XCTAssertEqual(workspace.projects.map(\.id), [goodProject.id])
    XCTAssertEqual(workspace.activeProjectID, goodProject.id)
  }

  func testMetadataCloseReopenAndStorePersistenceKeepStableProjectID() throws {
    let fixture = try Fixture()
    let firstRoot = try fixture.makeDirectory(named: "first-project")
    let secondRoot = try fixture.makeDirectory(named: "second-project")
    let workspace = fixture.makeWorkspace()
    let first = try XCTUnwrap(
      project(workspace.execute(.openProject(OpenProjectCommand(rootURL: firstRoot))))
    )
    let second = try XCTUnwrap(
      project(workspace.execute(.openProject(OpenProjectCommand(rootURL: secondRoot))))
    )

    _ = workspace.execute(
      .renameProject(
        RenameProjectCommand(projectID: first.id, name: "  Renamed Project  ")
      )
    )
    _ = workspace.execute(
      .setProjectColor(
        SetProjectColorCommand(projectID: first.id, color: .purple)
      )
    )
    _ = workspace.execute(
      .reorderProject(
        ReorderProjectCommand(projectID: first.id, targetIndex: 1)
      )
    )
    _ = workspace.execute(
      .closeProject(CloseProjectCommand(projectID: second.id))
    )

    XCTAssertEqual(workspace.projects.map(\.id), [first.id])
    XCTAssertEqual(workspace.projects.first?.name, "Renamed Project")
    XCTAssertEqual(workspace.projects.first?.color, .purple)

    let restored = fixture.makeWorkspace()
    XCTAssertEqual(restored.projects.map(\.id), [first.id])
    XCTAssertEqual(restored.projects.first?.name, "Renamed Project")
    XCTAssertEqual(restored.projects.first?.color, .purple)
    XCTAssertEqual(restored.activeProjectID, first.id)

    let reopened = try XCTUnwrap(
      project(restored.execute(.openProject(OpenProjectCommand(rootURL: secondRoot))))
    )
    XCTAssertEqual(reopened.id, second.id)

    let snapshot = try fixture.store.load()
    XCTAssertEqual(snapshot.schemaVersion, ProjectStoreSnapshot.currentSchemaVersion)
    XCTAssertEqual(snapshot.projects.count, 2)
  }

  func testCommandRegistryExposesTypedRiskAndAvailabilityPreflight() {
    let registry = CommandRegistry()
    let missingID = UUID()
    let unavailable = registry.preflight(
      .switchProject(SwitchProjectCommand(projectID: missingID)),
      state: ProjectCommandState(openProjectIDs: [], activeProjectID: nil)
    )
    XCTAssertFalse(unavailable.availability.isAvailable)
    XCTAssertNotNil(unavailable.availability.reason)
    XCTAssertEqual(unavailable.risk, .read)

    let open = registry.preflight(
      .openProject(OpenProjectCommand(rootURL: URL(fileURLWithPath: "/tmp"))),
      state: ProjectCommandState(openProjectIDs: [], activeProjectID: nil)
    )
    XCTAssertTrue(open.availability.isAvailable)
    XCTAssertEqual(open.commandID, .openProject)
    XCTAssertEqual(registry.descriptor(for: .openProject)?.aiAvailable, true)
    XCTAssertEqual(
      Set(registry.descriptors.map(\.id)),
      Set(ClairCommandID.allCases)
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

  private func assertProjectError(
    _ result: Result<ClairCommandResult, CommandError>,
    matching expected: ProjectError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .failure(.project(let actual)) = result else {
      return XCTFail("Expected ProjectError, got \(result)", file: file, line: line)
    }
    XCTAssertEqual(actual, expected, file: file, line: line)
  }
}

private final class Fixture {
  let root: URL
  let store: ProjectStore

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-project-kernel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    store = ProjectStore(
      fileURL: root.appendingPathComponent("state/projects-v1.json", isDirectory: false)
    )
  }

  func makeDirectory(named name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }

  @MainActor
  func makeWorkspace(
    rootChecker: any ProjectRootChecking = FileSystemProjectRootChecker()
  ) -> ProjectWorkspaceModel {
    ProjectWorkspaceModel(store: store, rootChecker: rootChecker)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct TestRootChecker: ProjectRootChecking {
  let unreadablePath: String
  private let fileSystemChecker = FileSystemProjectRootChecker()

  func canonicalURL(for rootURL: URL) -> URL {
    fileSystemChecker.canonicalURL(for: rootURL)
  }

  func validate(_ rootURL: URL) throws -> URL {
    let canonicalURL = canonicalURL(for: rootURL)
    if canonicalURL.path == unreadablePath {
      throw ProjectError.rootUnreadable(path: canonicalURL.path)
    }
    return try fileSystemChecker.validate(canonicalURL)
  }

  func availability(for rootURL: URL) -> ProjectAvailability {
    do {
      _ = try validate(rootURL)
      return .available
    } catch ProjectError.rootMissing {
      return .missing
    } catch ProjectError.rootNotDirectory {
      return .notDirectory
    } catch ProjectError.rootUnreadable {
      return .unreadable
    } catch {
      return .unreadable
    }
  }
}
