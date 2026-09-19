import XCTest

@testable import ClairV2Workspace

/// V01 test matrix (docs/plans/clair-v2-v01-command-registry.md).
final class WorkbenchCommandTests: XCTestCase {
  let r = CommandRegistry.workbench

  func testPaletteAndHarnessProduceSameTransitionAndResult() {
    var viaPalette = WorkbenchState(), viaHarness = WorkbenchState()
    for (query, id) in [("右に分割", "pane.splitRight"), ("下に分割", "pane.splitDown"), ("均等", "pane.equalize"), ("閉じる", "pane.close")] {
      let item = r.paletteItems(.commands, query: query, state: viaPalette).first { $0.id == id }!
      let a = r.execute(item.id, item.input, state: &viaPalette)
      let b = r.execute(id, state: &viaHarness)
      XCTAssertEqual(a, b, id)
      XCTAssertEqual(viaPalette, viaHarness, id)
    }
    let file = r.paletteItems(.files, query: "pane-layout", state: viaPalette)[0]
    r.execute(file.id, file.input, state: &viaPalette)
    r.execute("tab.open", ["path": .string("docs/architecture/pane-layout.md")], state: &viaHarness)
    XCTAssertEqual(viaPalette, viaHarness)
    XCTAssertEqual(r.execute("state.snapshot", state: &viaHarness), .success(.snapshot(viaPalette)))
  }

  func testSchemaValidation() {
    var s = WorkbenchState()
    let bad: [(String, CommandInput)] = [
      ("pane.focus", [:]),  // missing
      ("pane.focus", ["id": .string("1")]),  // wrong type
      ("pane.splitRight", ["x": .int(1)]),  // unknown argument
      ("settings.open", ["section": .string("存在しない")]),  // not allowed
    ]
    for (id, input) in bad {
      XCTAssertEqual(r.execute(id, input, state: &s).failure?.code, .invalidInput, id)
    }
    XCTAssertEqual(r.execute("nope", state: &s).failure?.code, .unknownCommand)
    XCTAssertEqual(r.execute("pane.focus", ["id": .int(99)], state: &s).failure?.code, .preconditionFailed)
    XCTAssertEqual(s, WorkbenchState(), "failed commands must not mutate state")
  }

  func testPreflightEscalatesCloseWithDirtyBufferToDestructive() {
    var s = WorkbenchState()
    XCTAssertEqual(r.preflight("pane.close", [:], s).success, .write)
    s.dirty.insert(s.active!)
    XCTAssertEqual(r.preflight("pane.close", [:], s).success, .destructive)
    XCTAssertEqual(r.preflight("tab.close", [:], s).success, .destructive)

    let before = s
    XCTAssertEqual(r.execute("pane.close", state: &s).failure?.code, .confirmationRequired)
    XCTAssertEqual(s, before)
    XCTAssertEqual(r.execute("pane.close", confirmed: true, state: &s), .success(.ok))
    XCTAssertEqual(s.tree.leaves.count, 2)

    s.tree.focus(2)  // closing a non-editor pane keeps the buffer → stays write
    XCTAssertEqual(r.preflight("pane.close", [:], s).success, .write)
  }

  func testPreflightNeverLowersFixedRisk() {
    var s = WorkbenchState()
    s.dirty.insert(s.active!)
    for d in r.commands {
      if let risk = r.preflight(d.id, [:], s).success { XCTAssertGreaterThanOrEqual(risk, d.risk, d.id) }
    }
  }

  func testLastPaneAndTabPreconditions() {
    var s = WorkbenchState()
    r.execute("pane.close", state: &s); r.execute("pane.close", state: &s)
    XCTAssertEqual(r.execute("pane.close", state: &s).failure?.code, .preconditionFailed)
    r.execute("tab.close", state: &s)
    XCTAssertNil(s.active)
    XCTAssertEqual(r.execute("tab.close", state: &s).failure?.code, .preconditionFailed)
    XCTAssertEqual(r.execute("file.save", state: &s).failure?.code, .preconditionFailed)
  }

  func testDescriptorsAndJSONRoundTrip() throws {
    XCTAssertEqual(Set(r.commands.map(\.id)).count, r.commands.count)
    let shortcuts = r.commands.compactMap(\.shortcut)
    XCTAssertEqual(Set(shortcuts).count, shortcuts.count)
    XCTAssertFalse(r.commands.first { $0.id == "settings.set" }!.aiAvailable)
    XCTAssertTrue(r.commands.first { $0.id == "state.snapshot" }!.aiAvailable)

    var s = WorkbenchState()
    r.execute("pane.splitDown", state: &s)
    let result = r.execute("state.snapshot", state: &s).success!
    let json = try JSONEncoder().encode(result)
    XCTAssertEqual(try JSONDecoder().decode(CommandResult.self, from: json), result)
    let input = try JSONDecoder().decode(CommandInput.self, from: Data(#"{"id": 2, "ratio": 0.3}"#.utf8))
    XCTAssertEqual(r.execute("pane.setRatio", input, state: &s), .success(.ok))
  }
}

extension Result {
  var success: Success? { try? get() }
  var failure: Failure? { if case .failure(let e) = self { e } else { nil } }
}
