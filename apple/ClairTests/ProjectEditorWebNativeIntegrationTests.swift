import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class ProjectEditorWebNativeIntegrationTests: XCTestCase {
  func testWebRangeTransactionKeepsNativeRevisionAndSaveInSync() throws {
    let fixture = try Fixture()
    let fileURL = fixture.root.appendingPathComponent("bridge.txt")
    try Data("日本語".utf8).write(to: fileURL)
    let document = ProjectEditorTab(
      projectID: UUID(),
      rootURL: fixture.root,
      url: fileURL
    )
    let change = ProjectEditorWebChange(
      baseRevision: document.editorRevision,
      changes: [ProjectEditorWebEdit(from: 3, to: 3, insert: "🙂")],
      selection: ProjectEditorWebSelection(from: 3, to: 5),
      canUndo: true,
      canRedo: false
    )

    let applied = try XCTUnwrap(document.applyEditorChange(change))

    XCTAssertEqual(applied.revision, 1)
    XCTAssertEqual(document.editorRevision, 1)
    XCTAssertEqual(document.content, "日本語🙂")
    XCTAssertTrue(document.isDirty)

    try document.save()
    XCTAssertEqual(try String(contentsOf: fileURL), "日本語🙂")

    let stale = ProjectEditorWebChange(
      baseRevision: 0,
      changes: [ProjectEditorWebEdit(from: 0, to: 0, insert: "x")],
      selection: ProjectEditorWebSelection(from: 1, to: 1),
      canUndo: true,
      canRedo: false
    )
    XCTAssertThrowsError(try document.applyEditorChange(stale))
    XCTAssertEqual(document.content, "日本語🙂")
    XCTAssertEqual(document.editorRevision, 1)
  }

  func testSelectionAndViewportStateStayOnTheNativeDocument() throws {
    let fixture = try Fixture()
    let fileURL = fixture.root.appendingPathComponent("viewport.txt")
    try Data("first\nsecond\nthird\n".utf8).write(to: fileURL)
    let document = ProjectEditorTab(
      projectID: UUID(),
      rootURL: fixture.root,
      url: fileURL
    )

    let edit = ProjectEditorWebChange(
      baseRevision: document.editorRevision,
      changes: [ProjectEditorWebEdit(from: 0, to: 0, insert: "header\n")],
      selection: ProjectEditorWebSelection(from: 7, to: 13),
      scrollTop: 240,
      canUndo: true,
      canRedo: false
    )
    _ = try document.applyEditorChange(edit)

    XCTAssertEqual(
      document.editorSelection,
      ProjectEditorUTF16Range(location: 7, length: 6)
    )
    XCTAssertEqual(document.editorScrollTop, 240)

    let selection = ProjectEditorWebSelectionChange(
      selection: ProjectEditorWebSelection(from: 0, to: 0),
      scrollTop: 480,
      canUndo: true,
      canRedo: false
    )
    document.applyEditorSelection(selection)

    XCTAssertEqual(document.editorSelection, ProjectEditorUTF16Range(location: 0, length: 0))
    XCTAssertEqual(document.editorScrollTop, 480)
    XCTAssertEqual(document.editorRevision, 1)
  }

  func testProjectTabPersistsEditorPositionWithoutBreakingLegacyShape() throws {
    var tab = ProjectPaneTab.editor(path: "/tmp/project/main.swift", title: "main.swift")
    tab.editorSelection = ProjectEditorUTF16Range(location: 18, length: 4)
    tab.editorScrollTop = 360

    let decoded = try JSONDecoder().decode(
      ProjectPaneTab.self,
      from: JSONEncoder().encode(tab)
    )

    XCTAssertEqual(decoded.editorSelection, tab.editorSelection)
    XCTAssertEqual(decoded.editorScrollTop, tab.editorScrollTop)

    let legacyJSON = """
      {"id":"/tmp/project/legacy.txt","kind":"editor","title":"legacy.txt","filePath":"/tmp/project/legacy.txt"}
      """.data(using: .utf8)!
    let legacy = try JSONDecoder().decode(ProjectPaneTab.self, from: legacyJSON)
    XCTAssertNil(legacy.editorSelection)
    XCTAssertNil(legacy.editorScrollTop)
  }

  private final class Fixture {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("clair-web-bridge-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
      )
    }

    deinit {
      try? FileManager.default.removeItem(at: root)
    }
  }
}
