import XCTest

@testable import ClairWorkspace

/// E15: block parsing, scroll mapping, local-only images, and the preview command.
final class MarkdownPreviewTests: XCTestCase {
  func testParsesBlocksWithSourceLines() {
    let md = """
      # Title #

      Some *text*
      continued.

      - one
        - [x] done
      2. two

      ```swift
      let x = 1
      # not a heading
      ```

      > quoted
      > more

      | a | b |
      |---|:-:|
      | 1 | 2 |

      ![logo](img/logo.png "t")

      ---
      """
    let blocks = MarkdownPreview.parse(md)
    XCTAssertEqual(blocks.map(\.line), [0, 2, 5, 6, 7, 9, 14, 17, 21, 23])
    XCTAssertEqual(blocks.map(\.block), [
      .heading(level: 1, text: "Title"),
      .paragraph("Some *text*\ncontinued."),
      .listItem(marker: "•", depth: 0, text: "one", checked: nil),
      .listItem(marker: "•", depth: 1, text: "done", checked: true),
      .listItem(marker: "2.", depth: 0, text: "two", checked: nil),
      .code(language: "swift", text: "let x = 1\n# not a heading"),
      .quote("quoted\nmore"),
      .table(header: ["a", "b"], rows: [["1", "2"]]),
      .image(alt: "logo", source: "img/logo.png"),
      .rule,
    ])
    XCTAssertEqual(MarkdownPreview.block(at: 12, in: blocks), 5)
    XCTAssertEqual(MarkdownPreview.block(at: 0, in: blocks), 0)
    XCTAssertEqual(MarkdownPreview.parse("a\r\n\r\n#b").map(\.block), [.paragraph("a"), .paragraph("#b")])
  }

  func testImagesStayInsideTheProject() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let r = root.path
    XCTAssertEqual(MarkdownPreview.localImage("a.png", root: r, file: "docs/x.md")?.lastPathComponent, "a.png")
    XCTAssertNotNil(MarkdownPreview.localImage("/logo.png", root: r, file: "docs/x.md"))
    XCTAssertNil(MarkdownPreview.localImage("../../etc/passwd", root: r, file: "docs/x.md"))
    XCTAssertNil(MarkdownPreview.localImage("https://example.com/a.png", root: r, file: "docs/x.md"))
    XCTAssertNil(MarkdownPreview.localImage("file:///etc/hosts", root: r, file: "docs/x.md"))
    try FileManager.default.createSymbolicLink(atPath: r + "/docs/out", withDestinationPath: "/etc")
    XCTAssertNil(MarkdownPreview.localImage("out/hosts", root: r, file: "docs/x.md"))
  }

  func testPreviewCommandOpensOnePaneBesideTheEditor() throws {
    let r = CommandRegistry.workbench
    var s = WorkbenchState()
    XCTAssertEqual(r.commands.first { $0.id == "editor.markdownPreview" }?.shortcut, "⌘⇧V")
    _ = try r.execute("tab.open", ["path": .string("docs/architecture/pane-layout.md")], state: &s).get()
    let focused = s.tree.focused
    _ = try r.execute("editor.markdownPreview", state: &s).get()
    XCTAssertEqual(s.tree.leaves.filter { $0.kind == .preview }.count, 1)
    XCTAssertEqual(s.tree.focused, focused, "the preview must not steal focus from the editor")
    XCTAssertTrue(s.tree.isValid)
    _ = try r.execute("editor.markdownPreview", state: &s).get()
    XCTAssertEqual(s.tree.leaves.filter { $0.kind == .preview }.count, 1)
    let restored = try JSONDecoder().decode(PaneTree.self, from: JSONEncoder().encode(s.tree))
    XCTAssertEqual(restored, s.tree)
  }
}
