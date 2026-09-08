import Foundation
import XCTest

@testable import ClairApp

final class ProjectEditorWebBridgeTests: XCTestCase {
  func testChangeUsesUTF16PreEditRangesAndAdvancesOnce() throws {
    let bridge = ProjectEditorWebBridgeModel(content: "🙂abc", revision: 4)
    let change = ProjectEditorWebChange(
      baseRevision: 4,
      changes: [
        ProjectEditorWebEdit(from: 2, to: 3, insert: "X"),
        ProjectEditorWebEdit(from: 5, to: 5, insert: "🙂"),
      ],
      selection: ProjectEditorWebSelection(from: 5, to: 7),
      canUndo: true,
      canRedo: false
    )

    let result = try bridge.apply(change)

    XCTAssertEqual(bridge.content, "🙂Xbc🙂")
    XCTAssertEqual(bridge.revision, 5)
    XCTAssertEqual(result.revision, 5)
    XCTAssertEqual(
      bridge.document.selection,
      ProjectEditorUTF16Range(location: 5, length: 2)
    )
  }

  func testStaleChangeDoesNotMutateAndCanBeResynchronized() throws {
    let bridge = ProjectEditorWebBridgeModel(content: "before", revision: 2)
    let accepted = ProjectEditorWebChange(
      baseRevision: 2,
      changes: [ProjectEditorWebEdit(from: 6, to: 6, insert: "!" )],
      selection: ProjectEditorWebSelection(from: 7, to: 7),
      canUndo: true,
      canRedo: false
    )
    _ = try bridge.apply(accepted)

    let stale = ProjectEditorWebChange(
      baseRevision: 2,
      changes: [ProjectEditorWebEdit(from: 0, to: 0, insert: "x")],
      selection: ProjectEditorWebSelection(from: 1, to: 1),
      canUndo: true,
      canRedo: false
    )
    XCTAssertThrowsError(try bridge.apply(stale)) { error in
      XCTAssertEqual(
        error as? ProjectEditorDocumentError,
        .staleRevision(expected: 2, actual: 3)
      )
    }
    XCTAssertEqual(bridge.content, "before!")
    XCTAssertEqual(bridge.revision, 3)

    bridge.replaceSnapshot(content: "resynced", revision: 8)
    XCTAssertEqual(bridge.content, "resynced")
    XCTAssertEqual(bridge.revision, 8)
    XCTAssertNil(bridge.document.selection)
  }

  func testSelectionOnlyChangeDoesNotAdvanceRevisionOrCaptureSnapshot() throws {
    let bridge = ProjectEditorWebBridgeModel(content: "hello")
    _ = bridge.document.snapshot(reason: .initialLoad)
    let change = ProjectEditorWebSelectionChange(
      selection: ProjectEditorWebSelection(from: 1, to: 3),
      canUndo: false,
      canRedo: false
    )

    try bridge.applySelection(change)

    XCTAssertEqual(bridge.revision, 0)
    XCTAssertEqual(bridge.document.snapshotCaptureCount, 1)
    XCTAssertEqual(
      bridge.document.selection,
      ProjectEditorUTF16Range(location: 1, length: 2)
    )
  }

  func testWebEnvelopeRoundTripsWithoutFullContent() throws {
    let change = ProjectEditorWebChange(
      baseRevision: 9,
      changes: [ProjectEditorWebEdit(from: 3, to: 5, insert: "日本語")],
      selection: ProjectEditorWebSelection(from: 6, to: 6),
      canUndo: true,
      canRedo: true
    )

    let data = try JSONEncoder().encode(change)
    let decoded = try JSONDecoder().decode(ProjectEditorWebChange.self, from: data)

    XCTAssertEqual(decoded, change)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("content"))
  }
}
