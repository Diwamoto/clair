#if os(macOS)
  import AppKit
  import Foundation
  import Testing
  @testable import ClairAppKit

  /// ADR-0025: a file dropped on a terminal is typed as its shell-escaped path, never sent.
  @MainActor @Suite struct TerminalDropTests {
    @Test func droppedFilesAreTypedAsEscapedPathsWithATrailingSpace() {
      #expect(ClairGhosttySurfaceView.dropText(["/a b/c.png", "/d"]) == #"/a\ b/c.png /d "#)
    }

    @Test func onlyFileURLsCountAsDrops() {
      let pb = NSPasteboard(name: NSPasteboard.Name("clair-drop-test-\(UUID().uuidString)"))
      defer { pb.releaseGlobally() }
      pb.clearContents()
      pb.writeObjects([URL(fileURLWithPath: "/tmp/x y") as NSURL])
      #expect(ClairGhosttySurfaceView.droppedPaths(pb) == ["/tmp/x y"])
      pb.clearContents()
      pb.setString("hello", forType: .string)
      #expect(ClairGhosttySurfaceView.droppedPaths(pb).isEmpty)
    }

    @Test func openFileBrowserSitsInTheViewMenu() {
      #expect(ClairCommandMenu.menu("finder.open") == .view)
    }
  }
#endif
