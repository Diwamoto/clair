#if os(macOS)
  import AppKit
  import SwiftUI
  import XCTest
  import ClairV2Workspace

  @testable import ClairV2AppKit

  /// U04 mock comparison aid: `CLAIR_SNAPSHOT=1 swift test --filter ChromeSnapshotTests` renders the shell offscreen to /tmp/cmp/native.png
  /// (a Workbench mock screenshot goes beside it as mock.png). Skipped otherwise; it asserts nothing.
  @MainActor final class ChromeSnapshotTests: XCTestCase {
    func fixture(_ root: String, _ files: [String: String]) throws {
      for (p, c) in files {
        let u = URL(fileURLWithPath: root + "/" + p)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try c.write(to: u, atomically: true, encoding: .utf8)
      }
    }

    func testSnapshot() throws {
      try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAIR_SNAPSHOT"] != nil, "opt-in: set CLAIR_SNAPSHOT=1")
      try FileManager.default.createDirectory(atPath: "/tmp/cmp", withIntermediateDirectories: true)
      setenv("CLAIR_CHANNEL", "dev", 1)
      let base = "/tmp/fx/" + UUID().uuidString
      let src = "import SwiftUI\n\n/// The workspace surface owns one pane tree per project.\nstruct ProjectWorkspaceView: View {\n  var body: some View {\n    Text(1)\n  }\n}\n"
      try fixture(base + "/clair", [
        "apple/ClairApp/ContentView.swift": src, "apple/ClairApp/ProjectWorkspace.swift": src, "apple/ClairApp/PaneSplit.swift": src,
        "apple/ClairApp/WorkspaceChrome.swift": src, "apple/ClairApp/SessionRail.swift": src, "crates/a.rs": "fn main(){}", "docs/pane-layout.md": "# x",
      ])
      try fixture(base + "/ccedit", ["project_layout.rs": "fn main(){}"])
      try fixture(base + "/clair-release", ["a.md": "x"])
      let store = ClairV2WorkbenchStore(persistAt: nil)
      for n in ["ccedit", "clair-release", "clair"] { store.run("project.open", ["path": .string(base + "/" + n)]) }
      // project.open puts new Projects last; re-open order is fine for chrome comparison.
      store.run("project.switch", ["name": .string("ccedit")]); store.run("tab.open", ["path": .string("project_layout.rs")])
      store.run("project.switch", ["name": .string("clair")])
      store.run("tab.open", ["path": .string("apple/ClairApp/ProjectWorkspace.swift")])
      store.edited("apple/ClairApp/ProjectWorkspace.swift")
      let host = NSHostingView(rootView: ClairV2AppShell(store: store).frame(width: 1440, height: 900))
      let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
      win.contentView = host
      win.orderBack(nil)
      RunLoop.current.run(until: Date().addingTimeInterval(2))
      host.layoutSubtreeIfNeeded()
      let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cmp/native.png"))
    }
  }
#endif
