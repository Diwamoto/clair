import XCTest

@testable import ClairWorkspace

/// V01 test matrix (docs/plans/clair-v01-command-registry.md).
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

  func testProjectSearchIsACommandWithTheAdvertisedShortcut() throws {
    var state = WorkbenchState()
    XCTAssertEqual(r.commands.first { $0.id == "palette.search" }?.shortcut, "⌘⇧F")
    _ = try r.execute("palette.search", state: &state).get()
    XCTAssertEqual(state.palette, .search)
    _ = try r.execute("palette.close", state: &state).get()
    XCTAssertNil(state.palette)
  }

  func testUsageSectionIsReachableThroughSettingsCommand() throws {
    var state = WorkbenchState()
    _ = try r.execute("settings.open", ["section": .string("使用状況")], state: &state).get()
    XCTAssertEqual(state.section, "使用状況")
  }

  func testTerminalShortcutOpensOnlyOneAndSplitShortcutsKeepTheirDirections() throws {
    var state = WorkbenchState()
    state.tree = PaneTree(single: .editor)
    state.panesClosed = true

    XCTAssertEqual(r.commands.first { $0.id == "terminal.show" }?.shortcut, "⌘J")
    XCTAssertEqual(r.commands.first { $0.id == "pane.splitRight" }?.shortcut, "⌘D")
    XCTAssertEqual(r.commands.first { $0.id == "pane.splitDown" }?.shortcut, "⌘⇧D")
    XCTAssertNil(r.commands.first { $0.id == "debug.open" }?.shortcut)

    _ = try r.execute("terminal.show", state: &state).get()
    XCTAssertFalse(state.panesClosed)
    XCTAssertEqual(state.tree.leaves.map(\.kind), [.editor, .terminal])
    let terminal = state.tree.focused
    state.tree.focus(state.tree.leaves[0].id)
    state.tree.toggleMaximize()
    _ = try r.execute("terminal.show", state: &state).get()
    XCTAssertEqual(state.tree.leaves.map(\.kind), [.editor, .terminal])
    XCTAssertEqual(state.tree.focused, terminal)
    XCTAssertNil(state.tree.maximized)

    _ = try r.execute("pane.splitRight", state: &state).get()
    _ = try r.execute("pane.splitDown", state: &state).get()
    XCTAssertEqual(state.tree.leaves.map(\.kind), [.editor, .terminal, .terminal, .terminal])
    guard case .split(.horizontal, _, _, let right) = state.tree.root,
      case .split(.horizontal, _, _, let lower) = right,
      case .split(.vertical, _, _, .leaf(let focused, .terminal)) = lower
    else { return XCTFail("right and down splits must keep their directions") }
    XCTAssertEqual(state.tree.focused, focused)
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

  func testClosingEditorReplacesItAndKeepsItLeftmost() throws {
    var s = WorkbenchState()
    let old = s.tree.focused
    try r.execute("pane.close", state: &s).get()
    XCTAssertFalse(s.panesClosed)
    XCTAssertEqual(s.tree.leaves.map(\.kind), [.editor, .terminal, .terminal])
    XCTAssertNotEqual(s.tree.focused, old)
    XCTAssertEqual(s.tree.leaves.first?.id, s.tree.focused)
    XCTAssertEqual(r.execute("pane.move", ["id": .int(3), "target": .int(s.tree.focused), "edge": .string("left")], state: &s).failure?.code, .preconditionFailed)
    XCTAssertEqual(r.execute("pane.swap", ["idA": .int(s.tree.focused), "idB": .int(2)], state: &s).failure?.code, .preconditionFailed)
  }

  func testOpeningFileRepairsLegacyTerminalOnlyLayout() {
    var s = WorkbenchState()
    s.tree = PaneTree(single: .terminal)
    s.panesClosed = true
    _ = r.execute("tab.open", ["path": .string("docs/architecture/pane-layout.md")], state: &s)
    XCTAssertFalse(s.panesClosed)
    XCTAssertEqual(s.tree.leaves.map(\.kind), [.editor, .terminal])
    XCTAssertEqual(s.active, "docs/architecture/pane-layout.md")
  }

  func testClosingEditorPreservesDirtyBuffer() {
    var s = WorkbenchState()
    XCTAssertEqual(r.preflight("pane.close", [:], s).success, .write)
    s.dirty.insert(s.active!)
    XCTAssertEqual(r.preflight("pane.close", [:], s).success, .write)
    XCTAssertEqual(r.preflight("tab.close", [:], s).success, .destructive)

    XCTAssertEqual(r.execute("pane.close", state: &s), .success(.ok))
    XCTAssertEqual(s.tree.leaves.count, 3)
    XCTAssertTrue(s.dirty.contains(s.active!))

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

  func testTabMove() {
    var s = WorkbenchState()
    s.tabs = ["a", "b", "c"]
    r.execute("tab.move", ["path": .string("a"), "target": .string("c")], state: &s)
    XCTAssertEqual(s.tabs, ["b", "c", "a"])
    r.execute("tab.move", ["path": .string("a"), "target": .string("b")], state: &s)
    XCTAssertEqual(s.tabs, ["a", "b", "c"])
    XCTAssertEqual(r.execute("tab.move", ["path": .string("x"), "target": .string("b")], state: &s).failure?.code, .preconditionFailed)
  }

  func testLastPaneAndTabPreconditions() {
    var s = WorkbenchState()
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

final class SettingsChoiceTests: XCTestCase {
  func testChooseAcceptsOnlyListedValuesAndRoundTrips() throws {
    let r = CommandRegistry.workbench; var s = WorkbenchState()
    XCTAssertEqual(s.choices["tabWidth"], "2")
    _ = r.execute("settings.choose", ["key": .string("tabWidth"), "value": .string("4")], state: &s)
    XCTAssertEqual(s.choices["tabWidth"], "4")
    guard case .failure = r.execute("settings.choose", ["key": .string("tabWidth"), "value": .string("3")], state: &s) else { return XCTFail("3 is not an option") }
    XCTAssertEqual(s.choices["tabWidth"], "4")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID()).json")
    try s.save(to: url); defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertEqual(WorkbenchState.restore(from: url)?.choices["tabWidth"], "4")
  }
}
