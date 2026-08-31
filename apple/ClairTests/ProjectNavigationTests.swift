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

    let snapshot = ProjectFileTreeScanner.scan(
      rootURL: fixture.root,
      rootChecker: FileSystemProjectRootChecker()
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

  func testSearchReportsUnicodeLineColumnsAndSkipsGitAndBinaryFiles() throws {
    let fixture = try NavigationFixture()
    let source = fixture.root.appendingPathComponent("source.txt")
    let ignoredDirectory = fixture.root.appendingPathComponent(".git", isDirectory: true)
    let ignored = ignoredDirectory.appendingPathComponent("ignored.txt")
    let binary = fixture.root.appendingPathComponent("binary.dat")
    try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
    try Data("HELLO in git".utf8).write(to: ignored)
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

  func testHistoryEntriesAreProjectScopedAndNewestFirst() throws {
    let fixture = try NavigationFixture()
    let first = fixture.root.appendingPathComponent("first.txt")
    let second = fixture.root.appendingPathComponent("second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let projectID = UUID()
    let otherProjectID = UUID()
    let store = ProjectLocalHistoryStore(
      fileURL: fixture.root.appendingPathComponent("editor-history-v1.json")
    )
    let firstDate = Date(timeIntervalSince1970: 100)
    let secondDate = Date(timeIntervalSince1970: 200)
    _ = try store.record(
      projectID: projectID,
      fileURL: first,
      rootURL: fixture.root,
      content: "first-before",
      reason: .save,
      createdAt: firstDate
    )
    _ = try store.record(
      projectID: otherProjectID,
      fileURL: second,
      rootURL: fixture.root,
      content: "other",
      reason: .save,
      createdAt: secondDate
    )
    _ = try store.record(
      projectID: projectID,
      fileURL: second,
      rootURL: fixture.root,
      content: "second-before",
      reason: .externalChange,
      createdAt: secondDate
    )

    let entries = try store.entries(for: projectID)
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries.first?.filePath, "second.txt")
    XCTAssertEqual(entries.last?.filePath, "first.txt")
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
