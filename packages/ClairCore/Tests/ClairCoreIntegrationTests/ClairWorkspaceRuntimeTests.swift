#if os(macOS)

  import Foundation
  import Testing
  import Darwin

  @testable import ClairShared
  @testable import ClairWorkspace

  @Test
  func workspaceCatalogUsesTypedProjectAndWorktreeIdentity() throws {
    let fixture = try WorkspaceFixture(gitRepository: true)
    defer { fixture.remove() }

    let worktreeURL = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-h02-worktree-\(UUID().uuidString)", isDirectory: true)
    try fixture.runGit(["worktree", "add", "--quiet", "-b", "h02-fixture", worktreeURL.path])
    defer {
      _ = try? fixture.runGit(["worktree", "remove", "--force", worktreeURL.path])
      try? FileManager.default.removeItem(at: worktreeURL)
    }

    let projectID = try ProjectID("project-h02-catalog")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairWorkspaceRuntime(projects: [project])
    let catalog = try runtime.catalog()

    #expect(catalog.projects.count == 1)
    #expect(catalog.projects[0].id == projectID)
    #expect(catalog.projects[0].state == .available)
    #expect(catalog.projects[0].repositoryRootURL == fixture.rootURL.standardizedFileURL)
    #expect(catalog.projects[0].worktrees.count == 2)
    #expect(catalog.projects[0].worktrees.allSatisfy { $0.projectID == projectID })
    #expect(catalog.projects[0].worktrees.contains { $0.isMain })
    #expect(
      catalog.projects[0].worktrees.contains {
        $0.rootURL.resolvingSymlinksInPath().path
          == fixture.rootURL.resolvingSymlinksInPath().path
      }
    )
    #expect(catalog.projects[0].worktrees.contains { $0.branch == "h02-fixture" })

    let worktree = try #require(
      catalog.projects[0].worktrees.first(where: { $0.rootURL == worktreeURL.standardizedFileURL })
    )
    let tree = try runtime.fileTree(projectID: projectID, worktreeID: worktree.id)
    #expect(tree.root == .root)

    let otherProjectID = try ProjectID("project-h02-other")
    let otherRootURL = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-h02-other-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: otherRootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: otherRootURL) }
    let otherProject = try ClairProjectRoot(id: otherProjectID, rootURL: otherRootURL)
    let otherRuntime = try ClairWorkspaceRuntime(projects: [otherProject])

    do {
      _ = try otherRuntime.fileTree(projectID: otherProjectID, worktreeID: worktree.id)
      Issue.record("A WorktreeID from another Project was unexpectedly accepted.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .worktreeNotFound(worktree.id))
    }
  }

  @Test
  func workspaceLaunchRootCapabilityRetainsCatalogDeviceInodeAndDescriptor() throws {
    let fixture = try WorkspaceFixture(gitRepository: false)
    defer { fixture.remove() }
    let projectID = try ProjectID("project-h02-capability")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairWorkspaceRuntime(projects: [project])
    let catalog = try runtime.catalog()
    let entry = try #require(catalog.projects.first)
    let device = try #require(entry.rootDevice)
    let inode = try #require(entry.rootInode)

    let capability = try runtime.launchRootCapability(
      from: catalog,
      projectID: projectID
    )
    #expect(capability.rootURL == fixture.rootURL.standardizedFileURL)
    #expect(capability.device == device)
    #expect(capability.inode == inode)

    let descriptor = try capability.duplicateDescriptor()
    defer { Darwin.close(descriptor) }
    var information = stat()
    #expect(Darwin.fstat(descriptor, &information) == 0)
    #expect(UInt64(information.st_dev) == device)
    #expect(UInt64(information.st_ino) == inode)
  }

  @Test
  func workspaceLaunchRootCapabilityRejectsCatalogOutsideRegisteredProjectScope() throws {
    let fixture = try WorkspaceFixture(gitRepository: false)
    defer { fixture.remove() }
    let projectID = try ProjectID("project-h04-arbitrary-catalog")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairWorkspaceRuntime(projects: [project])
    let arbitraryRoot = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-arbitrary-root-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: arbitraryRoot, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: arbitraryRoot) }

    let arbitraryCatalog = ClairWorkspaceCatalog(projects: [
      ClairProjectCatalogEntry(
        id: projectID,
        rootURL: arbitraryRoot,
        state: .available,
        rootDevice: 1,
        rootInode: 1
      )
    ])
    do {
      _ = try runtime.launchRootCapability(from: arbitraryCatalog, projectID: projectID)
      Issue.record("An arbitrary catalog root unexpectedly acquired a launch capability.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .rootIdentityChanged(arbitraryRoot.standardizedFileURL))
    }
  }

  @Test
  func workspaceLaunchRootCapabilityRejectsCatalogOutsideRegisteredWorktreeScope() throws {
    let fixture = try WorkspaceFixture(gitRepository: true)
    defer { fixture.remove() }
    let projectID = try ProjectID("project-h04-arbitrary-worktree-catalog")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairWorkspaceRuntime(projects: [project])
    let catalog = try runtime.catalog()
    let registeredProject = try #require(catalog.projects.first)
    let registeredWorktree = try #require(registeredProject.worktrees.first)
    let repositoryRoot = try #require(registeredProject.repositoryRootURL)
    let arbitraryRoot = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent(
        "clair-arbitrary-worktree-" + UUID().uuidString,
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: arbitraryRoot, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: arbitraryRoot) }

    let arbitraryWorktree = ClairWorktreeCatalogEntry(
      id: registeredWorktree.id,
      projectID: projectID,
      repositoryRootURL: repositoryRoot,
      rootURL: arbitraryRoot,
      rootDevice: 1,
      rootInode: 1,
      state: .available,
      isMain: registeredWorktree.isMain
    )
    let arbitraryProject = ClairProjectCatalogEntry(
      id: projectID,
      rootURL: registeredProject.rootURL,
      state: registeredProject.state,
      rootDevice: registeredProject.rootDevice,
      rootInode: registeredProject.rootInode,
      repositoryRootURL: repositoryRoot,
      worktrees: [arbitraryWorktree]
    )
    let arbitraryCatalog = ClairWorkspaceCatalog(projects: [arbitraryProject])
    do {
      _ = try runtime.launchRootCapability(
        from: arbitraryCatalog,
        projectID: projectID,
        worktreeID: registeredWorktree.id
      )
      Issue.record("An arbitrary catalog worktree unexpectedly acquired a launch capability.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .rootIdentityChanged(arbitraryRoot.standardizedFileURL))
    }
  }

  @Test
  func workspaceFileTreeAndTextReadAreBounded() throws {
    let fixture = try WorkspaceFixture(gitRepository: false)
    defer { fixture.remove() }
    try fixture.writeText("Sources/main.swift", "print(\"hello\")\n")
    try fixture.writeText("Sources/nested/deep.swift", "let deep = true\n")
    try fixture.writeText("large.txt", String(repeating: "x", count: 33))
    try fixture.writeData("binary.dat", Data([0, 1, 2, 3]))
    try fixture.writeData("invalid.dat", Data([0xff, 0xfe]))

    let projectID = try ProjectID("project-h02-files")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let limits = try ClairWorkspaceLimits(
      maximumFileReadBytes: 32,
      maximumTreeEntries: 4_096,
      maximumTreeDepth: 16,
      maximumChangedFiles: 32,
      maximumChangedOutputBytes: 4_096,
      maximumGitOutputBytes: 4_096
    )
    let runtime = try ClairWorkspaceRuntime(projects: [project], limits: limits)
    let options = try ClairFileTreeOptions(maximumDepth: 4, maximumEntries: 2)

    let tree = try runtime.fileTree(projectID: projectID, options: options)
    #expect(tree.entries.count <= 2)
    #expect(tree.isTruncated)
    #expect(tree.entries.allSatisfy { $0.path.rawValue != "." })

    let read = try runtime.readFile(
      projectID: projectID,
      path: try ClairWorkspacePath("Sources/main.swift")
    )
    #expect(read.content == "print(\"hello\")\n")
    #expect(read.byteCount == 15)
    #expect(read.byteCount <= read.maximumBytes)

    let largePath = try ClairWorkspacePath("large.txt")
    do {
      _ = try runtime.readFile(projectID: projectID, path: largePath)
      Issue.record("The text read API unexpectedly loaded a file above its byte bound.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .fileTooLarge(path: largePath, size: 33, maximumBytes: 32))
    }

    let binaryPath = try ClairWorkspacePath("binary.dat")
    do {
      _ = try runtime.readFile(projectID: projectID, path: binaryPath)
      Issue.record("The text read API unexpectedly returned a binary file.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .binaryFile(binaryPath))
    }

    let invalidPath = try ClairWorkspacePath("invalid.dat")
    do {
      _ = try runtime.readFile(projectID: projectID, path: invalidPath)
      Issue.record("The text read API unexpectedly accepted invalid UTF-8.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .invalidEncoding(invalidPath))
    }
  }

  @Test
  func workspacePathRejectsAbsoluteAndEscapingValues() throws {
    do {
      _ = try ClairWorkspacePath("../outside")
      Issue.record("A parent traversal path was unexpectedly accepted.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .pathEscapesRoot)
    }

    do {
      _ = try ClairWorkspacePath("nested/../../outside")
      Issue.record("A nested parent traversal path was unexpectedly accepted.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .pathEscapesRoot)
    }

    do {
      _ = try ClairWorkspacePath("/outside")
      Issue.record("An absolute path was unexpectedly accepted.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .pathEscapesRoot)
    }

    do {
      _ = try ClairWorkspacePath("directory\\file")
      Issue.record("A platform-ambiguous path was unexpectedly accepted.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .invalidPath)
    }
  }

  @Test
  func workspaceRejectsSymlinkTraversalAndReportsSymlinkRoots() throws {
    let fixture = try WorkspaceFixture(gitRepository: false)
    defer { fixture.remove() }
    let outsideURL = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-h02-outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: outsideURL) }
    try Data("outside\n".utf8).write(to: outsideURL.appendingPathComponent("secret.txt"))
    try FileManager.default.createSymbolicLink(
      at: fixture.rootURL.appendingPathComponent("link.txt"),
      withDestinationURL: outsideURL.appendingPathComponent("secret.txt")
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.rootURL.appendingPathComponent("link-directory", isDirectory: true),
      withDestinationURL: outsideURL
    )

    let projectID = try ProjectID("project-h02-symlink")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairWorkspaceRuntime(projects: [project])
    let tree = try runtime.fileTree(projectID: projectID)
    #expect(tree.entries.contains { $0.path.rawValue == "link.txt" && $0.kind == .symlink })
    #expect(tree.entries.contains { $0.path.rawValue == "link-directory" && $0.kind == .symlink })
    #expect(!tree.entries.contains { $0.path.rawValue.hasPrefix("link-directory/") })

    let linkPath = try ClairWorkspacePath("link.txt")
    do {
      _ = try runtime.readFile(projectID: projectID, path: linkPath)
      Issue.record("The text read API unexpectedly followed a symlink.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .pathIsSymlink(linkPath))
    }

    let symlinkRootURL = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-h02-root-link-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: symlinkRootURL,
      withDestinationURL: fixture.rootURL
    )
    defer { try? FileManager.default.removeItem(at: symlinkRootURL) }
    let linkedProjectID = try ProjectID("project-h02-linked-root")
    let linkedProject = try ClairProjectRoot(id: linkedProjectID, rootURL: symlinkRootURL)
    let linkedRuntime = try ClairWorkspaceRuntime(projects: [linkedProject])
    let linkedCatalog = try linkedRuntime.catalog()
    #expect(linkedCatalog.projects[0].state == .symlink)
    do {
      _ = try linkedRuntime.fileTree(projectID: linkedProjectID)
      Issue.record("A symlink Project root was unexpectedly accepted.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .projectRootUnavailable(linkedProjectID, .symlink))
    }
  }

  @Test
  func workspaceReportsPermissionAndMissingRoots() throws {
    let fixture = try WorkspaceFixture(gitRepository: false)
    defer { fixture.remove() }
    try fixture.writeText("private.txt", "secret\n")
    let privateURL = fixture.rootURL.appendingPathComponent("private.txt")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000],
      ofItemAtPath: privateURL.path
    )
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: privateURL.path
      )
    }

    let projectID = try ProjectID("project-h02-permissions")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairWorkspaceRuntime(projects: [project])
    let path = try ClairWorkspacePath("private.txt")
    do {
      _ = try runtime.readFile(projectID: projectID, path: path)
      Issue.record("A permission-denied file was unexpectedly readable.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .pathPermissionDenied(path))
    }

    let missingRootURL = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-h02-missing-\(UUID().uuidString)", isDirectory: true)
    let missingID = try ProjectID("project-h02-missing")
    let missingProject = try ClairProjectRoot(id: missingID, rootURL: missingRootURL)
    let missingRuntime = try ClairWorkspaceRuntime(projects: [missingProject])
    let missingCatalog = try missingRuntime.catalog()
    #expect(missingCatalog.projects[0].state == .missing)
    do {
      _ = try missingRuntime.fileTree(projectID: missingID)
      Issue.record("A missing Project root was unexpectedly readable.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .projectRootUnavailable(missingID, .missing))
    }
  }

  @Test
  func changedFileSummaryReportsGitChangesWithBoundedOutput() throws {
    let fixture = try WorkspaceFixture(gitRepository: true)
    defer { fixture.remove() }
    try fixture.writeText("tracked.txt", "changed\n")
    try fixture.writeText("untracked-a.txt", "a\n")
    try fixture.writeText("untracked-b.txt", "b\n")

    let projectID = try ProjectID("project-h02-changes")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let normalRuntime = try ClairWorkspaceRuntime(projects: [project])
    let normalSummary = try normalRuntime.changedFileSummary(projectID: projectID)
    #expect(
      normalSummary.files.contains { $0.path.rawValue == "tracked.txt" && $0.kind == .modified })
    #expect(
      normalSummary.files.contains {
        $0.path.rawValue == "untracked-a.txt" && $0.kind == .untracked
      })
    #expect(normalSummary.files.allSatisfy { !$0.path.rawValue.contains("..") })
    #expect(!normalSummary.isTruncated)

    try fixture.runGit(["mv", "tracked.txt", "renamed.txt"])
    let renamedSummary = try normalRuntime.changedFileSummary(projectID: projectID)
    let renamed = try #require(
      renamedSummary.files.first(where: { $0.path.rawValue == "renamed.txt" })
    )
    #expect(renamed.kind == .renamed)
    #expect(renamed.originalPath?.rawValue == "tracked.txt")

    let boundedLimits = try ClairWorkspaceLimits(
      maximumFileReadBytes: 1_024,
      maximumTreeEntries: 256,
      maximumTreeDepth: 4,
      maximumChangedFiles: 1,
      maximumChangedOutputBytes: 32,
      maximumGitOutputBytes: 1_024
    )
    let boundedRuntime = try ClairWorkspaceRuntime(
      projects: [project],
      limits: boundedLimits
    )
    let boundedSummary = try boundedRuntime.changedFiles(projectID: projectID)
    #expect(boundedSummary.files.count <= 1)
    #expect(boundedSummary.outputBytes <= boundedSummary.maximumOutputBytes)
    #expect(boundedSummary.maximumFiles == 1)
    #expect(boundedSummary.isTruncated)
  }

  @Test
  func changedFileSummaryRejectsNonRepositories() throws {
    let fixture = try WorkspaceFixture(gitRepository: false)
    defer { fixture.remove() }
    let projectID = try ProjectID("project-h02-no-git")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairWorkspaceRuntime(projects: [project])

    do {
      _ = try runtime.changedFileSummary(projectID: projectID)
      Issue.record("A non-repository Project unexpectedly returned a Git summary.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .repositoryNotFound(projectID))
    }
  }

  @Test
  func gitDiffReportsTextBinaryRenameAndHunkMetadata() throws {
    let fixture = try WorkspaceFixture(gitRepository: true)
    defer { fixture.remove() }
    try fixture.writeText("tracked.txt", "one\nchanged\n")
    try fixture.writeText("untracked.txt", "new line\n")
    try fixture.writeData("binary.dat", Data([0, 1, 2, 3]))

    let projectID = try ProjectID("project-h07-diff")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairWorkspaceRuntime(projects: [project])
    let trackedPath = try ClairWorkspacePath("tracked.txt")
    let trackedDiff = try runtime.gitDiff(projectID: projectID, path: trackedPath)
    #expect(trackedDiff.kind == .text)
    #expect(trackedDiff.text?.contains("+changed") == true)
    let trackedHunk = try #require(trackedDiff.hunks.first)
    #expect(trackedHunk.oldStart == 1)
    #expect(trackedHunk.newStart == 1)
    #expect(trackedHunk.newCount == 2)

    let untrackedDiff = try runtime.gitDiff(
      projectID: projectID,
      path: try ClairWorkspacePath("untracked.txt")
    )
    #expect(untrackedDiff.kind == .text)
    #expect(untrackedDiff.text?.contains("+new line") == true)
    #expect(!untrackedDiff.hunks.isEmpty)

    let binaryDiff = try runtime.gitDiff(
      projectID: projectID,
      path: try ClairWorkspacePath("binary.dat")
    )
    #expect(binaryDiff.kind == .binary)
    #expect(binaryDiff.text == nil)
    #expect(binaryDiff.hunks.isEmpty)

    try fixture.runGit(["mv", "tracked.txt", "renamed.txt"])
    let renameDiff = try runtime.gitDiff(
      projectID: projectID,
      path: try ClairWorkspacePath("renamed.txt")
    )
    #expect(renameDiff.originalPath?.rawValue == "tracked.txt")
    #expect(renameDiff.path.rawValue == "renamed.txt")
  }

  @Test
  func gitDiffSupportsStagedChangesAndBoundedLargeOutput() throws {
    let fixture = try WorkspaceFixture(gitRepository: true)
    defer { fixture.remove() }
    try fixture.writeText("tracked.txt", "staged\n")
    try fixture.runGit(["add", "tracked.txt"])

    let projectID = try ProjectID("project-h07-staged")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairWorkspaceRuntime(projects: [project])
    let path = try ClairWorkspacePath("tracked.txt")
    let staged = try runtime.gitDiff(
      projectID: projectID,
      path: path,
      basis: .staged
    )
    #expect(staged.kind == .text)
    #expect(staged.text?.contains("+staged") == true)

    try fixture.writeText("tracked.txt", String(repeating: "large line\n", count: 80))
    let boundedLimits = try ClairWorkspaceLimits(
      maximumFileReadBytes: 1_024,
      maximumTreeEntries: 256,
      maximumTreeDepth: 4,
      maximumChangedFiles: 32,
      maximumChangedOutputBytes: 96,
      maximumGitOutputBytes: 1_024
    )
    let boundedRuntime = try ClairWorkspaceRuntime(
      projects: [project],
      limits: boundedLimits
    )
    let bounded = try boundedRuntime.gitDiff(projectID: projectID, path: path)
    #expect(bounded.isTruncated)
    #expect(bounded.outputBytes <= bounded.maximumOutputBytes)
  }

  @Test
  func gitDiffRejectsInvalidEncodingAndCatalogRootRace() throws {
    let fixture = try WorkspaceFixture(gitRepository: true)
    defer { fixture.remove() }
    try fixture.writeData("invalid.txt", Data([0xff, 0xfe, 0x0a]))

    let projectID = try ProjectID("project-h07-race")
    let project = try ClairProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairWorkspaceRuntime(projects: [project])
    do {
      _ = try runtime.gitDiff(
        projectID: projectID,
        path: try ClairWorkspacePath("invalid.txt")
      )
      Issue.record("Invalid UTF-8 diff output was unexpectedly returned.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .gitOutputInvalidEncoding(operation: "read working_tree diff"))
    }

    let catalog = try runtime.catalog()
    let movedURL = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-h07-moved-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.rootURL, to: movedURL)
    defer { try? FileManager.default.removeItem(at: movedURL) }
    try FileManager.default.createDirectory(at: fixture.rootURL, withIntermediateDirectories: false)
    do {
      _ = try runtime.gitStatus(projectID: projectID, catalog: catalog)
      Issue.record("A catalog root replaced during selection was unexpectedly accepted.")
    } catch let error as ClairWorkspaceError {
      #expect(error == .rootIdentityChanged(fixture.rootURL.standardizedFileURL))
    }
  }

  private final class WorkspaceFixture {
    let rootURL: URL

    init(gitRepository: Bool) throws {
      rootURL = URL(fileURLWithPath: "/private/tmp")
        .appendingPathComponent("clair-h02-fixture-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      if gitRepository {
        try runGit(["init", "--quiet"])
        try runGit(["config", "user.email", "clair-h02@example.invalid"])
        try runGit(["config", "user.name", "Clair H02"])
        try writeText("tracked.txt", "initial\n")
        try runGit(["add", "tracked.txt"])
        try runGit(["commit", "--quiet", "-m", "initial"])
      }
    }

    func writeText(_ relativePath: String, _ value: String) throws {
      try writeData(relativePath, Data(value.utf8))
    }

    func writeData(_ relativePath: String, _ data: Data) throws {
      let url = rootURL.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url)
    }

    @discardableResult
    func runGit(_ arguments: [String]) throws -> String {
      let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
      guard
        let path = candidates.first(where: {
          FileManager.default.isExecutableFile(atPath: $0)
        })
      else {
        throw FixtureError.commandFailed
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = arguments
      process.currentDirectoryURL = rootURL
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = Pipe()
      process.standardError = FileHandle.nullDevice
      try process.run()
      let output =
        (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw FixtureError.commandFailed
      }
      return String(data: output, encoding: .utf8) ?? ""
    }

    func remove() {
      try? FileManager.default.removeItem(at: rootURL)
    }
  }

  private enum FixtureError: Error {
    case commandFailed
  }

#endif
