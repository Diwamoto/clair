import CoreGraphics
import Foundation
import XCTest

@testable import ClairApp

/// Guards against regressions in the three paths that most often get slow
/// after a feature lands: scanning a large file tree, computing `git status`
/// on a repository with many changes, and planning a text-surface redraw
/// across many rows (the shared engine behind the editor and the terminal).
@MainActor
final class PerformanceTests: XCTestCase {
  func testFileTreeScanPerformanceAcrossManyLoadedDirectories() throws {
    let fixture = try PerformanceFixture()
    var loadedPaths: Set<String> = [fixture.root.path]
    for directoryIndex in 0..<30 {
      let directory = fixture.root.appendingPathComponent(
        "package-\(directoryIndex)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      loadedPaths.insert(directory.path)
      for fileIndex in 0..<50 {
        try Data("content \(fileIndex)\n".utf8).write(
          to: directory.appendingPathComponent("file-\(fileIndex).swift"))
      }
    }

    measure {
      _ = ProjectFileTreeScanner.scanLoaded(
        rootURL: fixture.root,
        loadedDirectoryPaths: loadedPaths
      )
    }
  }

  func testGitStatusPerformanceWithManyChangedFiles() throws {
    let fixture = try PerformanceFixture()
    try fixture.runGit(["init", "--quiet", "-b", "main"])
    try fixture.runGit(["config", "user.name", "Clair Test"])
    try fixture.runGit(["config", "user.email", "clair-test@example.invalid"])
    for index in 0..<500 {
      try Data("baseline \(index)\n".utf8).write(
        to: fixture.root.appendingPathComponent("file-\(index).txt"))
    }
    try fixture.runGit(["add", "."])
    try fixture.runGit(["commit", "--quiet", "-m", "baseline"])
    for index in 0..<500 {
      try Data("changed \(index)\n".utf8).write(
        to: fixture.root.appendingPathComponent("file-\(index).txt"))
    }

    let service = ProjectGitService(rootURL: fixture.root)
    measure {
      _ = try? service.status()
    }
  }

  func testTextSurfaceRenderPlanPerformanceAcrossManyRows() throws {
    let mixedLines = TextSurfaceFixture.mixed.lines
    var lines: [String] = []
    lines.reserveCapacity(3_000)
    for index in 0..<3_000 {
      lines.append(mixedLines[index % mixedLines.count])
    }
    let source = TextFixtureSource(lines: lines)
    let renderer = TextSurfaceRenderer(metrics: TextFontMetrics())
    let fullDamage = TextSurfaceDamage(rows: 0..<lines.count)
    let viewport = CGRect(x: 0, y: 0, width: 900, height: CGFloat(lines.count) * 20)

    measure {
      _ = renderer.plan(
        damage: fullDamage,
        in: viewport,
        viewportWidth: viewport.width,
        source: source
      )
    }
  }
}

@MainActor
private final class PerformanceFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-performance-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  @discardableResult
  func runGit(_ arguments: [String]) throws -> String {
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
    guard process.terminationStatus == 0 else {
      throw PerformanceFixtureError.commandFailed(
        arguments: arguments,
        message: String(decoding: data, as: UTF8.self)
      )
    }
    return String(decoding: data, as: UTF8.self)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
}

private enum PerformanceFixtureError: Error {
  case commandFailed(arguments: [String], message: String)
}
