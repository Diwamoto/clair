#if os(macOS)
  import Foundation
  import Testing
  @testable import ClairAppKit

  @Suite struct ClairGhosttyFileLinkTests {
    @Test func resolvesTerminalFileLinks() throws {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
      try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
      try "x".write(toFile: dir + "/src/a.swift", atomically: true, encoding: .utf8)
      let file = (dir + "/src/a.swift" as NSString).standardizingPath
      let rel = ClairGhosttySurfaceView.fileTarget("src/a.swift:12:3", cwd: dir)
      #expect(rel?.path == file && rel?.line == 12 && rel?.column == 2)
      #expect(ClairGhosttySurfaceView.fileTarget("a.swift:7", cwd: dir + "/src")?.line == 7)
      #expect(ClairGhosttySurfaceView.fileTarget(file, cwd: "/")?.line == nil)
      #expect(ClairGhosttySurfaceView.fileTarget("file://" + file, cwd: "/")?.path == file)
      #expect(ClairGhosttySurfaceView.fileTarget("src", cwd: dir) == nil)  // directory
      #expect(ClairGhosttySurfaceView.fileTarget("missing.swift", cwd: dir) == nil)
      #expect(ClairGhosttySurfaceView.fileTarget("ssh://host/src/a.swift", cwd: dir) == nil)
    }
  }
#endif
