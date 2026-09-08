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
