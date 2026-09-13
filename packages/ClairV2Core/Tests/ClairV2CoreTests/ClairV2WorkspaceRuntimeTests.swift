#if os(macOS)

  import Foundation
  import Testing

  @testable import ClairV2Shared
  @testable import ClairV2Workspace

  @Test
  func workspaceCatalogUsesTypedProjectAndWorktreeIdentity() throws {
    let fixture = try WorkspaceFixture(gitRepository: true)
    defer { fixture.remove() }

    let worktreeURL = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-v2-h02-worktree-\(UUID().uuidString)", isDirectory: true)
    try fixture.runGit(["worktree", "add", "--quiet", "-b", "h02-fixture", worktreeURL.path])
    defer {
      _ = try? fixture.runGit(["worktree", "remove", "--force", worktreeURL.path])
      try? FileManager.default.removeItem(at: worktreeURL)
    }

    let projectID = try ProjectID("project-h02-catalog")
    let project = try ClairV2ProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairV2WorkspaceRuntime(projects: [project])
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
      .appendingPathComponent("clair-v2-h02-other-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: otherRootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: otherRootURL) }
    let otherProject = try ClairV2ProjectRoot(id: otherProjectID, rootURL: otherRootURL)
    let otherRuntime = try ClairV2WorkspaceRuntime(projects: [otherProject])

    do {
      _ = try otherRuntime.fileTree(projectID: otherProjectID, worktreeID: worktree.id)
      Issue.record("A WorktreeID from another Project was unexpectedly accepted.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .worktreeNotFound(worktree.id))
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
    let project = try ClairV2ProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let limits = try ClairV2WorkspaceLimits(
      maximumFileReadBytes: 32,
      maximumTreeEntries: 4_096,
      maximumTreeDepth: 16,
      maximumChangedFiles: 32,
      maximumChangedOutputBytes: 4_096,
      maximumGitOutputBytes: 4_096
    )
    let runtime = try ClairV2WorkspaceRuntime(projects: [project], limits: limits)
    let options = try ClairV2FileTreeOptions(maximumDepth: 4, maximumEntries: 2)

    let tree = try runtime.fileTree(projectID: projectID, options: options)
    #expect(tree.entries.count <= 2)
    #expect(tree.isTruncated)
    #expect(tree.entries.allSatisfy { $0.path.rawValue != "." })

    let read = try runtime.readFile(
      projectID: projectID,
      path: try ClairV2WorkspacePath("Sources/main.swift")
    )
    #expect(read.content == "print(\"hello\")\n")
    #expect(read.byteCount == 15)
    #expect(read.byteCount <= read.maximumBytes)

    let largePath = try ClairV2WorkspacePath("large.txt")
    do {
      _ = try runtime.readFile(projectID: projectID, path: largePath)
      Issue.record("The text read API unexpectedly loaded a file above its byte bound.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .fileTooLarge(path: largePath, size: 33, maximumBytes: 32))
    }

    let binaryPath = try ClairV2WorkspacePath("binary.dat")
    do {
      _ = try runtime.readFile(projectID: projectID, path: binaryPath)
      Issue.record("The text read API unexpectedly returned a binary file.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .binaryFile(binaryPath))
    }

    let invalidPath = try ClairV2WorkspacePath("invalid.dat")
    do {
      _ = try runtime.readFile(projectID: projectID, path: invalidPath)
      Issue.record("The text read API unexpectedly accepted invalid UTF-8.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .invalidEncoding(invalidPath))
    }
  }

  @Test
  func workspacePathRejectsAbsoluteAndEscapingValues() throws {
    do {
      _ = try ClairV2WorkspacePath("../outside")
      Issue.record("A parent traversal path was unexpectedly accepted.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .pathEscapesRoot)
    }

    do {
      _ = try ClairV2WorkspacePath("nested/../../outside")
      Issue.record("A nested parent traversal path was unexpectedly accepted.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .pathEscapesRoot)
    }

    do {
      _ = try ClairV2WorkspacePath("/outside")
      Issue.record("An absolute path was unexpectedly accepted.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .pathEscapesRoot)
    }

    do {
      _ = try ClairV2WorkspacePath("directory\\file")
      Issue.record("A platform-ambiguous path was unexpectedly accepted.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .invalidPath)
    }
  }

  @Test
  func workspaceRejectsSymlinkTraversalAndReportsSymlinkRoots() throws {
    let fixture = try WorkspaceFixture(gitRepository: false)
    defer { fixture.remove() }
    let outsideURL = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-v2-h02-outside-\(UUID().uuidString)", isDirectory: true)
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
    let project = try ClairV2ProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairV2WorkspaceRuntime(projects: [project])
    let tree = try runtime.fileTree(projectID: projectID)
    #expect(tree.entries.contains { $0.path.rawValue == "link.txt" && $0.kind == .symlink })
    #expect(tree.entries.contains { $0.path.rawValue == "link-directory" && $0.kind == .symlink })
    #expect(!tree.entries.contains { $0.path.rawValue.hasPrefix("link-directory/") })

    let linkPath = try ClairV2WorkspacePath("link.txt")
    do {
      _ = try runtime.readFile(projectID: projectID, path: linkPath)
      Issue.record("The text read API unexpectedly followed a symlink.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .pathIsSymlink(linkPath))
    }

    let symlinkRootURL = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-v2-h02-root-link-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: symlinkRootURL,
      withDestinationURL: fixture.rootURL
    )
    defer { try? FileManager.default.removeItem(at: symlinkRootURL) }
    let linkedProjectID = try ProjectID("project-h02-linked-root")
    let linkedProject = try ClairV2ProjectRoot(id: linkedProjectID, rootURL: symlinkRootURL)
    let linkedRuntime = try ClairV2WorkspaceRuntime(projects: [linkedProject])
    let linkedCatalog = try linkedRuntime.catalog()
    #expect(linkedCatalog.projects[0].state == .symlink)
    do {
      _ = try linkedRuntime.fileTree(projectID: linkedProjectID)
      Issue.record("A symlink Project root was unexpectedly accepted.")
    } catch let error as ClairV2WorkspaceError {
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
    let project = try ClairV2ProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairV2WorkspaceRuntime(projects: [project])
    let path = try ClairV2WorkspacePath("private.txt")
    do {
      _ = try runtime.readFile(projectID: projectID, path: path)
      Issue.record("A permission-denied file was unexpectedly readable.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .pathPermissionDenied(path))
    }

    let missingRootURL = fixture.rootURL.deletingLastPathComponent()
      .appendingPathComponent("clair-v2-h02-missing-\(UUID().uuidString)", isDirectory: true)
    let missingID = try ProjectID("project-h02-missing")
    let missingProject = try ClairV2ProjectRoot(id: missingID, rootURL: missingRootURL)
    let missingRuntime = try ClairV2WorkspaceRuntime(projects: [missingProject])
    let missingCatalog = try missingRuntime.catalog()
    #expect(missingCatalog.projects[0].state == .missing)
    do {
      _ = try missingRuntime.fileTree(projectID: missingID)
      Issue.record("A missing Project root was unexpectedly readable.")
    } catch let error as ClairV2WorkspaceError {
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
    let project = try ClairV2ProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let normalRuntime = try ClairV2WorkspaceRuntime(projects: [project])
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

    let boundedLimits = try ClairV2WorkspaceLimits(
      maximumFileReadBytes: 1_024,
      maximumTreeEntries: 256,
      maximumTreeDepth: 4,
      maximumChangedFiles: 1,
      maximumChangedOutputBytes: 32,
      maximumGitOutputBytes: 1_024
    )
    let boundedRuntime = try ClairV2WorkspaceRuntime(
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
    let project = try ClairV2ProjectRoot(id: projectID, rootURL: fixture.rootURL)
    let runtime = try ClairV2WorkspaceRuntime(projects: [project])

    do {
      _ = try runtime.changedFileSummary(projectID: projectID)
      Issue.record("A non-repository Project unexpectedly returned a Git summary.")
    } catch let error as ClairV2WorkspaceError {
      #expect(error == .repositoryNotFound(projectID))
    }
  }

  private final class WorkspaceFixture {
    let rootURL: URL

    init(gitRepository: Bool) throws {
      rootURL = URL(fileURLWithPath: "/private/tmp")
        .appendingPathComponent("clair-v2-h02-fixture-\(UUID().uuidString)", isDirectory: true)
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
