import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class ProjectNavigationTests: XCTestCase {
  func testQuickOpenFlattensFilesAndRanksFilenameMatches() throws {
    let fixture = try NavigationFixture()
    let sources = fixture.root.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let target = sources.appendingPathComponent("Target.swift")
    let other = fixture.root.appendingPathComponent("target-notes.txt")
    try Data("target".utf8).write(to: target)
    try Data("notes".utf8).write(to: other)

    let snapshot = ProjectFileTreeScanner.scanLoaded(
      rootURL: fixture.root,
      loadedDirectoryPaths: [fixture.root.path, sources.path]
    )
    let root = try XCTUnwrap(snapshot.root)
    let allItems = ProjectNavigation.quickOpenItems(
      from: root,
      rootURL: fixture.root,
      query: ""
    )
    XCTAssertEqual(allItems.map(\.relativePath), ["Sources/Target.swift", "target-notes.txt"])

    let matchingItems = ProjectNavigation.quickOpenItems(
      from: root,
      rootURL: fixture.root,
      query: "target"
    )
    XCTAssertEqual(matchingItems.first?.relativePath, "Sources/Target.swift")
    XCTAssertEqual(matchingItems.map(\.filePath), [target.path, other.path])
  }

  func testLoadedTreeIsLazyBoundedAndIgnoresGeneratedDirectories() throws {
    let fixture = try NavigationFixture()
    let sources = fixture.root.appendingPathComponent("Sources", isDirectory: true)
    let source = sources.appendingPathComponent("main.swift")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try Data("print(\"hello\")\n".utf8).write(to: source)
    try Data("readme\n".utf8).write(
      to: fixture.root.appendingPathComponent("README.md")
    )

    for name in [".build", "node_modules", "vendor", "target"] {
      let directory = fixture.root.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("generated\n".utf8).write(to: directory.appendingPathComponent("generated.txt"))
    }

    let initial = ProjectFileTreeScanner.scanLoaded(
      rootURL: fixture.root,
      loadedDirectoryPaths: [fixture.root.path]
    )
    let initialRoot = try XCTUnwrap(initial.root)
    XCTAssertNil(initialRoot.node(withID: sources.path)?.children)
    XCTAssertNil(
      initialRoot.node(
        withID: fixture.root.appendingPathComponent(".build", isDirectory: true).path
      )
    )
    XCTAssertNil(
      initialRoot.node(
        withID: fixture.root.appendingPathComponent("node_modules", isDirectory: true).path
      )
    )
    XCTAssertTrue(
      initialRoot.node(withID: fixture.root.appendingPathComponent("README.md").path) != nil)

    let expanded = ProjectFileTreeScanner.scanLoaded(
      rootURL: fixture.root,
      loadedDirectoryPaths: [fixture.root.path, sources.path]
    )
    XCTAssertEqual(expanded.node(withID: source.path)?.name, "main.swift")

    let manyFilesRoot = fixture.root.appendingPathComponent("many-files", isDirectory: true)
    try FileManager.default.createDirectory(at: manyFilesRoot, withIntermediateDirectories: true)
    for index in 0..<300 {
      try Data("file\n".utf8).write(
        to: manyFilesRoot.appendingPathComponent("file-\(index).txt")
      )
    }
    let bounded = ProjectFileTreeScanner.scanLoaded(
      rootURL: fixture.root,
      loadedDirectoryPaths: [fixture.root.path, manyFilesRoot.path]
    )
    let manyFilesNode = try XCTUnwrap(bounded.node(withID: manyFilesRoot.path))
    XCTAssertEqual(manyFilesNode.children?.count, ProjectFileTreeScanner.maxChildrenPerDirectory)
    XCTAssertTrue(manyFilesNode.hasMoreChildren)
  }

  func testPrefetchedDirectoryCacheRebuildsExpandedTreeWithoutWalkingDisk() throws {
    let fixture = try NavigationFixture()
    let sources = fixture.root.appendingPathComponent("Sources", isDirectory: true)
    let nested = sources.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("main.swift")
    try Data("print(\"cached\")\n".utf8).write(to: file)

    let cache = ProjectFileTreeScanner.prefetchDirectoryCache(rootURL: fixture.root)
    XCTAssertNotNil(cache[fixture.root.path])
    XCTAssertNotNil(cache[sources.path])
    XCTAssertNotNil(cache[nested.path])

    let snapshot = ProjectFileTreeScanner.scanLoaded(
      rootURL: fixture.root,
      loadedDirectoryPaths: [fixture.root.path, sources.path, nested.path],
      directoryCache: cache
    )

    XCTAssertEqual(snapshot.node(withID: file.path)?.name, "main.swift")
  }

  func testWatcherGraphIsLimitedToLoadedDirectories() throws {
    let fixture = try NavigationFixture()
    var loadedPaths: Set<String> = [fixture.root.path]
    for index in 0..<(ProjectFileTreeScanner.maxWatchedDirectories + 40) {
      let directory = fixture.root.appendingPathComponent("directory-\(index)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      loadedPaths.insert(directory.path)
    }

    let watchedDirectories = ProjectFileTreeScanner.directoriesToWatch(
      rootURL: fixture.root,
      loadedDirectoryPaths: loadedPaths
    )
    XCTAssertEqual(watchedDirectories.first?.path, fixture.root.path)
    XCTAssertLessThanOrEqual(
      watchedDirectories.count,
      ProjectFileTreeScanner.maxWatchedDirectories
    )
    let unloadedDirectory = fixture.root.appendingPathComponent("unloaded", isDirectory: true)
    let file = unloadedDirectory.appendingPathComponent("not-a-watched-file.txt")
    try FileManager.default.createDirectory(
      at: unloadedDirectory, withIntermediateDirectories: true)
    try Data("content".utf8).write(to: file)
    let watchedPaths = ProjectFileTreeScanner.pathsToWatch(
      rootURL: fixture.root,
      loadedDirectoryPaths: [fixture.root.path]
    )
    XCTAssertFalse(watchedPaths.contains { $0.path == file.path })
  }

  func testSearchReportsUnicodeLineColumnsAndSkipsGitAndBinaryFiles() throws {
    let fixture = try NavigationFixture()
    let source = fixture.root.appendingPathComponent("source.txt")
    let ignoredDirectory = fixture.root.appendingPathComponent(".git", isDirectory: true)
    let ignored = ignoredDirectory.appendingPathComponent("ignored.txt")
    let binary = fixture.root.appendingPathComponent("binary.dat")
    try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
    try Data("HELLO in git".utf8).write(to: ignored)
    for name in [".build", "node_modules", "vendor"] {
      let directory = fixture.root.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("HELLO in generated content".utf8).write(
        to: directory.appendingPathComponent("ignored.txt")
      )
    }
    try Data([0xFF, 0xFE, 0x00]).write(to: binary)
    try Data("before\n日本Hello\nHELLO again\n".utf8).write(to: source)

    let results = ProjectNavigation.search(
      query: "hello",
      rootURL: fixture.root
    )

    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(results.map(\.relativePath), ["source.txt", "source.txt"])
    XCTAssertEqual(results[0].line, 2)
    XCTAssertEqual(results[0].column, 3)
    XCTAssertEqual(results[0].lineText, "日本Hello")
    XCTAssertEqual(results[0].matchLength, 5)
    XCTAssertEqual(results[1].line, 3)
    XCTAssertEqual(results[1].column, 1)
  }

  func testReplacementPreviewIsPureAndContainsReplacementBytes() throws {
    let fixture = try NavigationFixture()
    let first = fixture.root.appendingPathComponent("first.txt")
    let second = fixture.root.appendingPathComponent("nested.txt")
    try Data("one old\n".utf8).write(to: first)
    try Data("old old\n".utf8).write(to: second)

    let preview = try ProjectNavigation.previewReplacement(
      query: "old",
      replacement: "new",
      rootURL: fixture.root
    )

    XCTAssertEqual(preview.matchCount, 3)
    XCTAssertEqual(preview.files.map(\.relativePath), ["first.txt", "nested.txt"])
    XCTAssertEqual(
      String(data: try Data(contentsOf: first), encoding: .utf8),
      "one old\n"
    )
    XCTAssertEqual(
      String(data: try XCTUnwrap(preview.files.first?.replacementData), encoding: .utf8),
      "one new\n"
    )
    XCTAssertEqual(
      String(data: try XCTUnwrap(preview.files.last?.replacementData), encoding: .utf8),
      "new new\n"
    )
  }

  func testFileURLRejectsAbsoluteAndTraversalPaths() throws {
    let fixture = try NavigationFixture()
    XCTAssertEqual(
      ProjectNavigation.fileURL(for: "nested/file.txt", rootURL: fixture.root)?.path,
      fixture.root.appendingPathComponent("nested/file.txt").path
    )
    XCTAssertNil(ProjectNavigation.fileURL(for: "../outside.txt", rootURL: fixture.root))
    XCTAssertNil(ProjectNavigation.fileURL(for: "/tmp/outside.txt", rootURL: fixture.root))
  }
}

@MainActor
private final class NavigationFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-project-navigation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
}
