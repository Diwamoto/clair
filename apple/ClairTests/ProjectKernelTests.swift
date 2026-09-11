import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class ProjectKernelTests: XCTestCase {
  func testOpensGitAndNonGitFoldersInOneWorkspace() throws {
    let fixture = try Fixture()
    let gitRoot = try fixture.makeDirectory(named: "git-project")
    try FileManager.default.createDirectory(
      at: gitRoot.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    let plainRoot = try fixture.makeDirectory(named: "plain-project")
    let workspace = fixture.makeWorkspace()

    let projects = [gitRoot, plainRoot].map { root in
      project(
        workspace.execute(.openProject(OpenProjectCommand(rootURL: root)))
      )
    }

    XCTAssertEqual(workspace.projects.count, 2)
    let projectIDs = projects.compactMap { $0?.id }
    XCTAssertEqual(Set(projectIDs).count, 2)
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

  func testHumanCommandInvocationSwitchesProjectAndRecordsExecution() throws {
    let fixture = try Fixture()
    let firstRoot = try fixture.makeDirectory(named: "command-first")
    let secondRoot = try fixture.makeDirectory(named: "command-second")
    let workspace = fixture.makeWorkspace()
    let first = try XCTUnwrap(
      project(workspace.execute(.openProject(OpenProjectCommand(rootURL: firstRoot))))
    )
    let second = try XCTUnwrap(
      project(workspace.execute(.openProject(OpenProjectCommand(rootURL: secondRoot))))
    )
    XCTAssertEqual(workspace.activeProjectID, second.id)

    let suiteName = "clair-command-surface-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let surface = CommandSurfaceModel(
      workspace: workspace,
      shortcutStore: CommandShortcutStore(defaults: defaults)
    )

    let result = surface.invoke(commandID: .switchProject, source: .commandWindow)
    guard case .success(.none) = result else {
      return XCTFail("Expected switch command to succeed, got \(result)")
    }
    XCTAssertEqual(surface.lastExecution?.commandID, .switchProject)
    XCTAssertEqual(surface.lastExecution?.source, .commandWindow)
    XCTAssertEqual(surface.lastExecution?.outcome.isSuccess, true)
    XCTAssertEqual(workspace.activeProjectID, first.id)

  }

  func testHumanCommandSurfacePreservesUnavailableReasonAndDisplaysError() throws {
    let fixture = try Fixture()
    let workspace = fixture.makeWorkspace()
    let surface = CommandSurfaceModel(workspace: workspace)
    let missingID = UUID()
    let command = ClairCommand.switchProject(
      SwitchProjectCommand(projectID: missingID)
    )

    let preflight = workspace.preflight(command)
    XCTAssertEqual(preflight.risk, .read)
    XCTAssertEqual(
      preflight.availability.reason,
      "Cannot switch a Project that is not open."
    )
    let result = surface.dispatch(command, source: .commandWindow)

    guard case .failure(.unavailable(let commandID, let reason)) = result else {
      return XCTFail("Expected an unavailable command error, got \(result)")
    }
    XCTAssertEqual(commandID, .switchProject)
    XCTAssertEqual(reason, preflight.availability.reason)
    XCTAssertEqual(
      surface.lastExecution?.outcome,
      .failure(
        "Command project.switch is unavailable: Cannot switch a Project that is not open."
      )
    )
    let match = try XCTUnwrap(surface.matches(for: "project.switch").first)
    XCTAssertFalse(match.availability.isAvailable)
    XCTAssertEqual(match.availability.reason, reason)
  }

  func testConfigurableShortcutRejectsInvalidAndConflictingMappings() throws {
    let fixture = try Fixture()
    let workspace = fixture.makeWorkspace()
    let suiteName = "clair-command-shortcuts-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let surface = CommandSurfaceModel(
      workspace: workspace,
      shortcutStore: CommandShortcutStore(defaults: defaults)
    )
    let originalRefreshShortcut = surface.shortcuts[.gitRefresh]

    let invalid = surface.setShortcut(
      CommandShortcut(key: " ", modifiers: [.command]),
      for: .gitRefresh
    )
    guard case .failure(.invalidKey) = invalid else {
      return XCTFail("Expected an invalid shortcut key error, got \(invalid)")
    }
    XCTAssertEqual(surface.shortcuts[.gitRefresh], originalRefreshShortcut)

    let openShortcut = try XCTUnwrap(surface.shortcuts[.openProject])
    let conflict = surface.setShortcut(openShortcut, for: .gitRefresh)
    guard
      case .failure(
        .conflict(
          existing: .openProject,
          requested: .gitRefresh,
          shortcut: openShortcut
        )
      ) = conflict
    else {
      return XCTFail("Expected a conflicting shortcut error, got \(conflict)")
    }
    XCTAssertEqual(surface.shortcuts[.gitRefresh], originalRefreshShortcut)

    let reserved = surface.setShortcut(
      CommandShortcut(key: "s", modifiers: [.command]),
      for: .gitRefresh
    )
    guard case .failure(.reserved(CommandShortcut(key: "s", modifiers: [.command]))) = reserved
    else {
      return XCTFail("Expected a reserved shortcut error, got \(reserved)")
    }
    XCTAssertEqual(surface.shortcuts[.gitRefresh], originalRefreshShortcut)

    let configured = CommandShortcut(key: "x", modifiers: [.command, .option])
    let configuredResult = surface.setShortcut(configured, for: .gitRefresh)
    guard case .success = configuredResult else {
      return XCTFail("Expected a valid shortcut assignment, got \(configuredResult)")
    }
    XCTAssertEqual(surface.shortcuts[.gitRefresh], configured)
    XCTAssertEqual(
      try XCTUnwrap(surface.matches(for: "git.refresh").first).shortcut,
      configured
    )
    XCTAssertEqual(
      CommandShortcutStore(defaults: defaults).load()[.gitRefresh],
      configured
    )

    let clearedResult = surface.setShortcut(nil, for: .gitRefresh)
    guard case .success = clearedResult else {
      return XCTFail("Expected clearing a shortcut to succeed, got \(clearedResult)")
    }
    XCTAssertNil(surface.shortcuts[.gitRefresh])
  }

  func testFileTreeLoadsNestedFoldersAndOpensFixtureEditorTab() async throws {
    let fixture = try Fixture()
    let root = try fixture.makeDirectory(named: "tree-project")
    let sources = root.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let file = sources.appendingPathComponent("main.swift")
    try Data("print(\"hello\")\n".utf8).write(to: file)
    let workspace = fixture.makeWorkspace()

    _ = workspace.execute(.openProject(OpenProjectCommand(rootURL: root)))
    let surface = try XCTUnwrap(workspace.activeSurface)
    let rootNode = try XCTUnwrap(surface.fileTree.root)
    let sourcesNode = try XCTUnwrap(surface.fileTree.node(withID: sources.path))

    XCTAssertEqual(surface.fileTree.availability, .available)
    XCTAssertEqual(rootNode.name, root.lastPathComponent)
    XCTAssertNil(sourcesNode.children)
    XCTAssertFalse(surface.isExpanded(sources.path))

    surface.toggleExpansion(for: sources.path)
    await waitForFileTree(surface) { snapshot in
      !snapshot.isLoading && snapshot.node(withID: file.path) != nil
    }
    let loadedSourcesNode = try XCTUnwrap(surface.fileTree.node(withID: sources.path))
    XCTAssertEqual(loadedSourcesNode.children?.map(\.name), ["main.swift"])
    XCTAssertTrue(surface.isExpanded(sources.path))
    surface.select(nodeID: file.path)

    XCTAssertEqual(surface.selectedNodeID, file.path)
    XCTAssertEqual(surface.activeTab?.id, file.path)
    XCTAssertEqual(surface.activeTab?.title, "main.swift")
    XCTAssertEqual(surface.activeTab?.content, "print(\"hello\")\n")
  }

  func testRestoredExpandedDirectoriesFinishLoadingAfterSurfaceCreation() async throws {
    let fixture = try Fixture()
    let root = try fixture.makeDirectory(named: "restored-tree-project")
    let sources = root.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let file = sources.appendingPathComponent("main.swift")
    try Data("print(\"restored\")\n".utf8).write(to: file)

    let projectID = UUID()
    var workspaceSnapshot = ProjectSurfaceSnapshot.empty(for: projectID)
    workspaceSnapshot.expandedNodeIDs = [sources.path]
    let surface = ProjectSurfaceModel(
      projectID: projectID,
      rootURL: root,
      snapshot: workspaceSnapshot
    )

    await waitForFileTree(surface) { snapshot in
      !snapshot.isLoading && snapshot.node(withID: file.path) != nil
    }

    XCTAssertTrue(surface.isExpanded(sources.path))
    XCTAssertEqual(
      surface.fileTree.node(withID: sources.path)?.children?.map(\.name),
      ["main.swift"]
    )
  }

  func testFileTreeWatcherRefreshesExternalCreateRenameAndDelete() async throws {
    let fixture = try Fixture()
    let root = try fixture.makeDirectory(named: "watched-project")
    let workspace = fixture.makeWorkspace()

    _ = workspace.execute(.openProject(OpenProjectCommand(rootURL: root)))
    let surface = try XCTUnwrap(workspace.activeSurface)
    let nested = root.appendingPathComponent("Nested", isDirectory: true)
    let created = nested.appendingPathComponent("created.txt")
    let renamed = nested.appendingPathComponent("renamed.txt")

    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    await waitForFileTree(surface) { snapshot in
      snapshot.node(withID: nested.path) != nil
    }

    surface.toggleExpansion(for: nested.path)
    await waitForFileTree(surface) { snapshot in
      !snapshot.isLoading && snapshot.node(withID: nested.path)?.children != nil
    }

    try Data("created".utf8).write(to: created)
    await waitForFileTree(surface) { snapshot in
      snapshot.node(withID: created.path) != nil
    }

    try FileManager.default.moveItem(at: created, to: renamed)
    await waitForFileTree(surface) { snapshot in
      snapshot.node(withID: created.path) == nil
        && snapshot.node(withID: renamed.path) != nil
    }

    try FileManager.default.removeItem(at: renamed)
    await waitForFileTree(surface) { snapshot in
      snapshot.node(withID: renamed.path) == nil
    }
  }

  func testFileTreeShowsMissingRootAndRecoversWhenRootReturns() async throws {
    let fixture = try Fixture()
    let root = try fixture.makeDirectory(named: "recoverable-project")
    let workspace = fixture.makeWorkspace()

    _ = workspace.execute(.openProject(OpenProjectCommand(rootURL: root)))
    let surface = try XCTUnwrap(workspace.activeSurface)
    try FileManager.default.removeItem(at: root)

    await waitForFileTree(surface) { snapshot in
      snapshot.availability == .missing
    }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let restoredFile = root.appendingPathComponent("restored.txt")
    try Data("restored".utf8).write(to: restoredFile)
    await waitForFileTree(surface) { snapshot in
      snapshot.availability == .available
        && snapshot.node(withID: restoredFile.path) != nil
    }
  }

  func testPaneLayoutSupportsNestedSplitsTabMoveCloseMaximizeAndEqualize() throws {
    let fixture = try Fixture()
    let root = try fixture.makeDirectory(named: "pane-layout-project")
    let file = root.appendingPathComponent("main.txt")
    try Data("pane layout".utf8).write(to: file)
    let workspace = fixture.makeWorkspace()

    _ = workspace.execute(.openProject(OpenProjectCommand(rootURL: root)))
    let surface = try XCTUnwrap(workspace.activeSurface)
    surface.select(nodeID: file.path)
    let originalPaneID = surface.focusedPaneID

    surface.splitFocusedPane(orientation: .horizontal)
    let rightPaneID = surface.focusedPaneID
    XCTAssertEqual(surface.paneIDs.count, 2)
    XCTAssertNotEqual(originalPaneID, rightPaneID)

    surface.openDiff(in: rightPaneID)
    surface.splitFocusedPane(orientation: .vertical)
    let lowerPaneID = surface.focusedPaneID
    XCTAssertEqual(surface.paneIDs.count, 3)
    XCTAssertTrue(surface.tabs(in: rightPaneID).contains { $0.kind == .diff })

    surface.openDiff(in: lowerPaneID)
    let movedTabID = try XCTUnwrap(surface.activeTab(in: lowerPaneID)?.id)
    surface.moveActiveTab(to: originalPaneID)
    XCTAssertFalse(surface.tabs(in: lowerPaneID).contains { $0.id == movedTabID })
    XCTAssertTrue(surface.tabs(in: originalPaneID).contains { $0.id == movedTabID })
    XCTAssertEqual(surface.focusedPaneID, originalPaneID)

    surface.toggleMaximizeFocusedPane()
    XCTAssertEqual(surface.maximizedPaneID, originalPaneID)
    surface.equalizeSplits()
    XCTAssertTrue(splitRatios(in: surface.layout).allSatisfy { $0 == 0.5 })

    surface.showTerminal(in: originalPaneID)
    let terminalTabID = try XCTUnwrap(
      surface.tabs(in: originalPaneID).first(where: { $0.kind == .terminal })?.id
    )
    XCTAssertNotNil(surface.terminalSession(tabID: terminalTabID))

    let encoded = try JSONEncoder().encode(surface.workspaceSnapshot)
    let encodedText = String(decoding: encoded, as: UTF8.self)
    XCTAssertFalse(encodedText.contains("transcript"))

    surface.endTerminal()
    surface.closePane(id: lowerPaneID)
    XCTAssertEqual(surface.paneIDs.count, 2)
    XCTAssertTrue(surface.tabStore.contains { $0.id == movedTabID })
    XCTAssertTrue(surface.workspaceSnapshot.validated(for: surface.projectID) != nil)
  }

  func testProjectLayoutsSelectionAndActivityStayIsolatedAcrossSwitchAndRestart() throws {
    let fixture = try Fixture()
    let roots = try ["first", "second"].map { name -> (URL, URL) in
      let root = try fixture.makeDirectory(named: "pane-\(name)")
      let file = root.appendingPathComponent("\(name).txt")
      try Data(name.utf8).write(to: file)
      return (root, file)
    }
    let workspace = fixture.makeWorkspace()
    var projects: [(project: Project, file: URL, snapshot: ProjectSurfaceSnapshot)] = []

    for (index, pair) in roots.enumerated() {
      let project = try XCTUnwrap(
        project(workspace.execute(.openProject(OpenProjectCommand(rootURL: pair.0))))
      )
      let surface = try XCTUnwrap(workspace.activeSurface)
      surface.select(nodeID: pair.1.path)
      surface.workspaceActivity = index == 0 ? .search : .activity
      if index == 0 {
        surface.splitFocusedPane(orientation: .horizontal)
        surface.openDiff(in: surface.focusedPaneID)
      } else {
        surface.openDiff()
      }
      projects.append((project, pair.1, surface.workspaceSnapshot))
    }

    for expected in projects {
      _ = workspace.execute(.switchProject(SwitchProjectCommand(projectID: expected.project.id)))
      let surface = try XCTUnwrap(workspace.activeSurface)
      XCTAssertEqual(surface.selectedNodeID, expected.file.path)
      XCTAssertEqual(surface.workspaceSnapshot, expected.snapshot)
      let other = projects.first { $0.project.id != expected.project.id }!
      XCTAssertNil(surface.fileTree.node(withID: other.file.path))
    }

    let restored = fixture.makeWorkspace()
    XCTAssertEqual(restored.activeProjectID, projects.last?.project.id)

    for expected in projects {
      _ = restored.execute(
        .switchProject(SwitchProjectCommand(projectID: expected.project.id))
      )
      let surface = try XCTUnwrap(restored.activeSurface)
      XCTAssertEqual(surface.workspaceSnapshot, expected.snapshot)
      XCTAssertEqual(surface.selectedNodeID, expected.file.path)
      XCTAssertEqual(surface.workspaceActivity.rawValue, expected.snapshot.workspaceActivity)
      XCTAssertTrue(
        surface.editorTabs.allSatisfy { $0.projectID == expected.project.id }
      )
      XCTAssertTrue(
        surface.editorTabs.allSatisfy {
          $0.url.standardizedFileURL.path == expected.file.standardizedFileURL.path
        }
      )
    }
  }

  func testCorruptOrMissingWorkspaceSnapshotFallsBackWithoutReplacingCorruptData() throws {
    let fixture = try Fixture()
    let root = try fixture.makeDirectory(named: "recoverable-pane-project")
    let workspace = fixture.makeWorkspace()
    let project = try XCTUnwrap(
      project(workspace.execute(.openProject(OpenProjectCommand(rootURL: root))))
    )
    let surface = try XCTUnwrap(workspace.activeSurface)
    surface.splitFocusedPane(orientation: .horizontal)
    let workspaceURL = try XCTUnwrap(fixture.store.workspaceFileURL)
    let corruptData = Data("{not-json".utf8)
    try corruptData.write(to: workspaceURL)

    let recovered = fixture.makeWorkspace()
    XCTAssertTrue(recovered.projects.contains { $0.id == project.id })
    XCTAssertTrue(recovered.lastErrorMessage?.contains("workspace store is malformed") == true)
    let recoveredSurface = try XCTUnwrap(recovered.activeSurface)
    XCTAssertEqual(recoveredSurface.paneIDs.count, 1)
    XCTAssertEqual(try Data(contentsOf: workspaceURL), corruptData)

    try FileManager.default.removeItem(at: workspaceURL)
    let missing = fixture.makeWorkspace()
    XCTAssertNil(missing.lastErrorMessage)
    XCTAssertEqual(try XCTUnwrap(missing.activeSurface).paneIDs.count, 1)
  }

  func testNavigationOpensSearchResultsAndAppliesReplacementToDirtyBuffers() throws {
    let fixture = try Fixture()
    let root = try fixture.makeDirectory(named: "navigation-project")
    let nested = root.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let firstFile = nested.appendingPathComponent("first.txt")
    let secondFile = root.appendingPathComponent("second.txt")
    try Data("old first\n".utf8).write(to: firstFile)
    try Data("old second\n".utf8).write(to: secondFile)
    let surface = ProjectSurfaceModel(
      projectID: UUID(),
      rootURL: root
    )

    let quickOpen = surface.quickOpenItems(matching: "first")
    XCTAssertEqual(quickOpen.map(\.relativePath), ["Sources/first.txt"])
    surface.openQuickOpenItem(try XCTUnwrap(quickOpen.first))
    XCTAssertEqual(surface.activeTab?.url.path, firstFile.path)

    surface.search(query: "old")
    XCTAssertEqual(surface.searchResults.count, 2)
    let result = try XCTUnwrap(surface.searchResults.first { $0.filePath == firstFile.path })
    surface.openSearchMatch(result)
    XCTAssertEqual(surface.selectedNodeID, firstFile.path)
    XCTAssertEqual(surface.activeTab?.id, firstFile.path)

    surface.previewReplacement(query: "old", replacement: "new")
    let preview = try XCTUnwrap(surface.replacementPreview)
    XCTAssertEqual(preview.matchCount, 2)
    surface.applyReplacement(preview)

    XCTAssertEqual(surface.editorDocument(tabID: firstFile.path)?.content, "new first\n")
    XCTAssertEqual(surface.editorDocument(tabID: secondFile.path)?.content, "new second\n")
    XCTAssertTrue(surface.editorDocument(tabID: firstFile.path)?.isDirty == true)
    XCTAssertEqual(try String(contentsOf: firstFile), "old first\n")
    XCTAssertEqual(try String(contentsOf: secondFile), "old second\n")
  }

  func testSearchResultsRefreshAfterExternalFileChange() async throws {
    let fixture = try Fixture()
    let root = try fixture.makeDirectory(named: "search-watch-project")
    let file = root.appendingPathComponent("watched.txt")
    try Data("before\n".utf8).write(to: file)
    let surface = ProjectSurfaceModel(
      projectID: UUID(),
      rootURL: root
    )

    surface.search(query: "after")
    XCTAssertTrue(surface.searchResults.isEmpty)
    try Data("after\n".utf8).write(to: file)

    await waitForSearch(surface) { results in
      results.count == 1 && results.first?.lineText == "after"
    }
    surface.search(query: "before")
    XCTAssertTrue(surface.searchResults.isEmpty)
    surface.search(query: "after")
    XCTAssertEqual(surface.searchResults.first?.relativePath, "watched.txt")
  }

  private func splitRatios(in node: ProjectPaneNode) -> [Double] {
    switch node {
    case .leaf:
      []
    case .split(_, _, let ratio, let first, let second):
      [ratio] + splitRatios(in: first) + splitRatios(in: second)
    }
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

  private func waitForFileTree(
    _ surface: ProjectSurfaceModel,
    timeout: TimeInterval = 3,
    matching predicate: (ProjectFileTreeSnapshot) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate(surface.fileTree) {
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for file tree refresh", file: file, line: line)
  }

  private func waitForSearch(
    _ surface: ProjectSurfaceModel,
    timeout: TimeInterval = 3,
    matching predicate: ([ProjectSearchMatch]) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate(surface.searchResults) {
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for search refresh", file: file, line: line)
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
