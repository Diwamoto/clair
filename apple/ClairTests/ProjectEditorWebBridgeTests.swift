import Foundation
import XCTest

@testable import ClairApp

final class ProjectEditorWebBridgeTests: XCTestCase {
  func testDecodesWebEditAndSelectionMessages() throws {
    // Independent wire fixtures use the keys emitted by editor-web/src/main.ts.
    let editJSON =
      #"{"baseRevision":9,"changes":[{"from":3,"to":5,"insert":"日本語"}],"selection":{"from":6,"to":6},"scrollTop":120,"canUndo":true,"canRedo":false}"#
    let editBody = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(editJSON.utf8)) as? [String: Any])
    let edit = try XCTUnwrap(ProjectEditorWebChange(messageBody: editBody))
    XCTAssertEqual(edit.baseRevision, 9)
    XCTAssertEqual(
      edit.transaction().edits,
      [
        ProjectEditorReplacement(range: .init(location: 3, length: 2), text: "日本語")
      ])
    XCTAssertEqual(edit.selection.range, .init(location: 6, length: 0))
    XCTAssertEqual(edit.scrollTop, 120)
    XCTAssertTrue(edit.canUndo)
    XCTAssertFalse(edit.canRedo)

    let selectionJSON =
      #"{"selection":{"from":10,"to":12},"scrollTop":240,"canUndo":false,"canRedo":true}"#
    let selectionBody = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(selectionJSON.utf8)) as? [String: Any])
    let selection = try XCTUnwrap(ProjectEditorWebSelectionChange(messageBody: selectionBody))
    XCTAssertEqual(selection.selection.range, .init(location: 10, length: 2))
    XCTAssertEqual(selection.scrollTop, 240)
    XCTAssertFalse(selection.canUndo)
    XCTAssertTrue(selection.canRedo)
  }
}
