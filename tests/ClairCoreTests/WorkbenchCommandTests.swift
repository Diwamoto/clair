import XCTest

@testable import ClairWorkspace

/// V01 test matrix (docs/plans/clair-v01-command-registry.md).
final class WorkbenchCommandTests: XCTestCase {
  let r = CommandRegistry.workbench

  func testPaletteCommandsUseEnglishNameWithTitleLabel() {
    let s = WorkbenchState()
    let en = r.paletteItems(.commands, query: "split right", state: s).first { $0.id == "pane.splitRight" }
    XCTAssertEqual(en?.title, "Pane: Split Right")
    XCTAssertEqual(en?.detail, "Split Pane Right")
    XCTAssertTrue(r.paletteItems(.commands, query: "split pane right", state: s).contains { $0.id == "pane.splitRight" })
  }

  func testRestartChoicesAreSeparatePaletteCommands() throws {
    var state = WorkbenchState()
    state.palette = .commands
    XCTAssertEqual(r.paletteItems(.commands, query: "restart", state: state).map(\.id).filter { $0 == "window.restart" || $0 == "app.restart" }, ["window.restart", "app.restart"])
    XCTAssertEqual(try r.execute("window.restart", state: &state).get(), .ok)
    XCTAssertNil(state.palette)
    XCTAssertEqual(r.execute("app.restart", state: &state), .failure(CommandError(.confirmationRequired, "app.restart is external")))
  }

  func testPaletteAndHarnessProduceSameTransitionAndResult() {
    var viaPalette = WorkbenchState(), viaHarness = WorkbenchState()
    for (query, id) in [("split right", "pane.splitRight"), ("split down", "pane.splitDown"), ("equalize", "pane.equalize"), ("close pane", "pane.close")] {
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

  func testCompareWithDiffsActiveFileAgainstPickedFile() throws {
    var s = WorkbenchState()
    s.projects = [WorkbenchProject(name: "Sample", path: "/tmp")]
    s.project = "Sample"
    let cmd = r.paletteItems(.commands, query: "compare with", state: s)[0]
    XCTAssertEqual(cmd.id, "palette.compare")
    s.active = nil
    if case .success = r.preflight(cmd.id, [:], s) { XCTFail("needs an active file") }
    r.execute("tab.open", ["path": .string("docs/architecture/pane-layout.md")], state: &s)
    XCTAssertEqual(try r.execute(cmd.id, state: &s).get(), .ok)
    XCTAssertEqual(s.palette, .compare)
    let rows = r.paletteItems(.compare, query: "", state: s)
    XCTAssertFalse(rows.map(\.title).contains("docs/architecture/pane-layout.md"))
    let pick = rows[0]
    _ = try r.execute(pick.id, pick.input, state: &s).get()
    XCTAssertEqual(s.activeDiff?.path, "docs/architecture/pane-layout.md")
    XCTAssertEqual(s.activeDiff?.against, pick.title)
  }

  func testCompareWithListsRecentlyOpenedFilesFirstAndPersistsThem() throws {
    var s = WorkbenchState()
    s.projects = [WorkbenchProject(name: "Sample", path: "/tmp")]
    s.project = "Sample"
    let paths = s.files.filter { $0.status != "D" }.map(\.path).suffix(3)
    for p in paths { r.execute("tab.open", ["path": .string(p)], state: &s) }
    let rows = r.paletteItems(.compare, query: "", state: s).map(\.title)
    XCTAssertEqual(Array(rows.prefix(2)), paths.dropLast().reversed())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try s.save(to: url)
    XCTAssertEqual(WorkbenchState.restore(from: url, scanFiles: false)?.recent, s.recent)
    // Open Recent reopens the same list.
    XCTAssertEqual(try r.execute("palette.recent", state: &s).get(), .ok)
    let recent = r.paletteItems(.recent, query: "", state: s)
    XCTAssertEqual(recent.map(\.title), paths.dropLast().reversed())
    _ = try r.execute(recent[1].id, recent[1].input, state: &s).get()
    XCTAssertEqual(s.active, paths.first)
  }

  // Every setting is reachable from ⌘K without opening the settings window.
  func testPaletteChangesSettingsAndInstallsTheCLI() {
    var s = WorkbenchState()
    let wrap = r.paletteItems(.commands, query: "turn word wrap on", state: s)[0]
    XCTAssertEqual(r.execute(wrap.id, wrap.input, state: &s), .success(.ok))
    XCTAssertEqual(s.toggles["softWrap"], true)
    XCTAssertEqual(r.paletteItems(.commands, query: "settings: turn word wrap", state: s).map(\.title), ["Settings: turn Word wrap off"])
    let tab = r.paletteItems(.commands, query: "tab width to 4", state: s)[0]
    r.execute(tab.id, tab.input, state: &s)
    XCTAssertEqual(s.choices["tabWidth"], "4")
    XCTAssertTrue(r.paletteItems(.commands, query: "clair command", state: s).contains { $0.id == "cli.install" })
    XCTAssertEqual(WorkbenchState.settingTitles.keys.sorted(), (WorkbenchState.toggleKeys + WorkbenchState.choiceOptions.keys).sorted())
  }

  func testProjectSearchIsACommandWithTheAdvertisedShortcut() throws {
    var state = WorkbenchState()
    XCTAssertEqual(r.commands.first { $0.id == "palette.search" }?.shortcut, "⌘⇧F")
    _ = try r.execute("palette.search", state: &state).get()
    XCTAssertEqual(state.palette, .search)
    _ = try r.execute("palette.close", state: &state).get()
    XCTAssertNil(state.palette)
  }

  func testTabShortcutsCycleFilesAndTerminalsInTitlebarOrder() throws {
    var state = WorkbenchState()
    state.tree = PaneTree()  // editor | agent / terminal: the layout these tests place into, not the single-editor default
    state.tabs = ["first.swift", "second.swift"]
    state.active = "first.swift"
    XCTAssertEqual(state.titlebarTabs, [.file("first.swift"), .file("second.swift"), .terminal(2), .terminal(3)])
    XCTAssertEqual(state.selectedTitlebarTab, .file("first.swift"))
    XCTAssertEqual(r.commands.first { $0.id == "tab.next" }?.shortcut, "⌃⌘→")
    XCTAssertEqual(r.commands.first { $0.id == "tab.previous" }?.shortcut, "⌃⌘←")
    _ = try r.execute("tab.next", state: &state).get()
    XCTAssertEqual(state.active, "second.swift")
    XCTAssertEqual(state.tree.focused, 1)
    XCTAssertEqual(state.selectedTitlebarTab, .file("second.swift"))
    _ = try r.execute("tab.next", state: &state).get()
    XCTAssertEqual(state.tree.focused, 2)
    XCTAssertEqual(state.selectedTitlebarTab, .terminal(2))
    _ = try r.execute("pane.focus", ["id": .int(1)], state: &state).get()
    XCTAssertEqual(state.selectedTitlebarTab, .file("second.swift"))
    _ = try r.execute("pane.focus", ["id": .int(2)], state: &state).get()
    XCTAssertEqual(state.selectedTitlebarTab, .terminal(2))
    _ = try r.execute("tab.activate", ["path": .string("first.swift")], state: &state).get()
    XCTAssertEqual(state.tree.focused, 1)
    XCTAssertEqual(state.selectedTitlebarTab, .file("first.swift"))
    _ = try r.execute("tab.next", state: &state).get()
    _ = try r.execute("tab.next", state: &state).get()
    XCTAssertEqual(state.tree.focused, 2)
    _ = try r.execute("tab.previous", state: &state).get()
    XCTAssertEqual(state.active, "second.swift")
    XCTAssertEqual(state.tree.focused, 1)
    _ = try r.execute("tab.previous", state: &state).get()
    XCTAssertEqual(state.active, "first.swift")
    _ = try r.execute("tab.previous", state: &state).get()
    XCTAssertEqual(state.tree.focused, 3)
    _ = try r.execute("tab.next", state: &state).get()
    XCTAssertEqual(state.tree.focused, 1)
  }

  func testDiffIsOrderedSelectableAndClosableLikeOtherTabs() throws {
    var state = WorkbenchState()
    state.projects = [WorkbenchProject(name: "Sample", path: "/tmp")]
    state.project = "Sample"
    state.tabs = ["first.swift", "second.swift"]
    state.active = "first.swift"
    let diff = WorkbenchDiffTab(path: "first.swift", staged: false, untracked: false)
    let input: CommandInput = ["path": .string(diff.path), "staged": .bool(false), "untracked": .bool(false)]
    _ = try r.execute("diff.open", input, state: &state).get()
    XCTAssertEqual(state.selectedTitlebarTab, .diff(diff))
    XCTAssertEqual(state.titlebarTabs.filter { $0 == .diff(diff) }.count, 1)
    _ = try r.execute("tab.reorder", ["source": .string(WorkbenchTab.diff(diff).dragID), "target": .string(WorkbenchTab.file("first.swift").dragID)], state: &state).get()
    XCTAssertEqual(state.titlebarTabs.first, .diff(diff))
    _ = try r.execute("tab.next", state: &state).get()
    XCTAssertEqual(state.selectedTitlebarTab, .file("first.swift"))
    _ = try r.execute("diff.activate", input, state: &state).get()
    _ = try r.execute("diff.close", input, state: &state).get()
    XCTAssertNil(state.activeDiff)
    XCTAssertFalse(state.titlebarTabs.contains(.diff(diff)))
    XCTAssertEqual(state.selectedTitlebarTab, .file("first.swift"))
  }

  func testDiffTabsRestoreWithProjectAndOldLayoutStillDecodes() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let snapshot = folder.appending(path: "workspace.json")
    var state = WorkbenchState()
    state.openProject(WorkbenchProject(name: "Sample", path: folder.path), scanFiles: false)
    let diff = WorkbenchDiffTab(path: "changed.swift", staged: false, untracked: false)
    state.openDiff(diff)
    state.moveTab(.diff(diff), to: .terminal(2))
    try state.save(to: snapshot)
    let restored = try XCTUnwrap(WorkbenchState.restore(from: snapshot, scanFiles: false))
    XCTAssertEqual(restored.activeDiff, diff)
    XCTAssertEqual(restored.titlebarTabs, state.titlebarTabs)

    // Old persisted layouts omit every diff field; decoding must supply empty defaults.
    var oldLayout = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state.layout)) as? [String: Any])
    oldLayout.removeValue(forKey: "diffTabs")
    oldLayout.removeValue(forKey: "activeDiff")
    oldLayout.removeValue(forKey: "tabOrder")
    let decoded = try JSONDecoder().decode(ProjectLayout.self, from: JSONSerialization.data(withJSONObject: oldLayout))
    XCTAssertTrue(decoded.diffTabs.isEmpty)
  }

  func testFocusingAPaneClearsDiffTabSelection() throws {
    var state = WorkbenchState()
    state.tree = PaneTree()  // editor | agent / terminal: the layout these tests place into, not the single-editor default
    let diff = WorkbenchDiffTab(path: "first.swift", staged: false, untracked: false)
    state.openDiff(diff)
    XCTAssertEqual(state.selectedTitlebarTab, .diff(diff))
    _ = try r.execute("pane.focus", ["id": .int(2)], state: &state).get()
    XCTAssertEqual(state.selectedTitlebarTab, .terminal(2))
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
    s.tree = PaneTree()  // editor | agent / terminal: the layout these tests place into, not the single-editor default
    let old = s.tree.focused
    try r.execute("pane.close", state: &s).get()
    XCTAssertFalse(s.panesClosed)
    XCTAssertEqual(s.tree.leaves.map(\.kind), [.editor, .terminal, .terminal])
    XCTAssertNotEqual(s.tree.focused, old)
    XCTAssertEqual(s.tree.leaves.first?.id, s.tree.focused)
    XCTAssertEqual(r.execute("pane.move", ["id": .int(3), "target": .int(s.tree.focused), "edge": .string("left")], state: &s).failure?.code, .preconditionFailed)
    XCTAssertEqual(r.execute("pane.swap", ["idA": .int(s.tree.focused), "idB": .int(2)], state: &s).failure?.code, .preconditionFailed)
  }

  func testClosingEmptyEditorRemovesItOnlyBesideOtherPanes() throws {
    var s = WorkbenchState()
    s.tree = PaneTree()  // editor | terminals
    let file = s.active!
    try r.execute("tab.close", state: &s).get()
    s.tree.focus(1)
    try r.execute("pane.close", state: &s).get()
    XCTAssertEqual(s.tree.leaves.map(\.kind), [.terminal, .terminal])
    XCTAssertTrue(s.tree.isValid, "a restored layout keeps the terminals")
    try r.execute("tab.open", ["path": .string(file)], state: &s).get()
    XCTAssertEqual(s.tree.leaves.map(\.kind), [.editor, .terminal, .terminal])

    s.tree = PaneTree(single: .editor); s.active = nil
    try r.execute("pane.close", state: &s).get()
    XCTAssertEqual(s.tree.leaves.map(\.kind), [.editor], "the only pane is never removed")
  }

  func testClosingTheLastFileLeavesOnlyOneEmptyEditor() throws {
    var s = WorkbenchState()
    s.tree = PaneTree()  // editor 1 | terminals, one open file
    try r.execute("pane.splitRight", state: &s).get()
    XCTAssertEqual(s.tree.leaves.map(\.kind), [.editor, .editor, .terminal, .terminal])
    try r.execute("tab.close", state: &s).get()
    XCTAssertEqual(s.tree.leaves.map(\.kind), [.editor, .terminal, .terminal])
    s.tree.focus(1)
    try r.execute("pane.splitDown", state: &s).get()  // no file: splitting the empty editor adds a terminal
    XCTAssertEqual(s.tree.leaves.filter { $0.kind == .editor }.count, 1)
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
    s.tree = PaneTree()  // editor | agent / terminal: the layout these tests place into, not the single-editor default
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

  func testReopenClosedTabs() throws {
    var s = WorkbenchState()
    s.tree = PaneTree()  // editor | agent / terminal: the layout these tests place into, not the single-editor default
    let file = s.active!
    try r.execute("tab.close", state: &s).get()
    let terminal = s.tree.leaves.first { $0.kind == .terminal }!.id
    s.tree.focus(terminal)
    try r.execute("pane.close", state: &s).get()
    let terminals = s.tree.leaves.filter { $0.kind == .terminal }.count
    try r.execute("tab.reopenClosed", state: &s).get()  // newest first: a fresh terminal
    XCTAssertEqual(s.tree.leaves.filter { $0.kind == .terminal }.count, terminals + 1)
    try r.execute("tab.reopenClosed", state: &s).get()
    XCTAssertEqual(s.active, file)
    XCTAssertEqual(r.execute("tab.reopenClosed", state: &s).failure?.code, .preconditionFailed)
    for _ in 0..<12 { s.recordClosed(.file(file)) }
    XCTAssertEqual(s.closedTabs.count, 10)
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

  func testFontSizesDefaultToShippedSizesAndFontFamilyRoundTrips() throws {
    let r = CommandRegistry.workbench; var s = WorkbenchState()
    XCTAssertEqual(s.choices["editorFontSize"], "12")
    XCTAssertEqual(s.choices["terminalFontSize"], "13")
    XCTAssertEqual(r.execute("settings.font", ["key": .string("terminal"), "value": .string("Menlo")], state: &s), .success(.ok))
    // The terminal family becomes a Ghostty config line, so a newline must never get in.
    guard case .failure = r.execute("settings.font", ["key": .string("terminal"), "value": .string("Menlo\nfont-size = 99")], state: &s) else {
      return XCTFail("control characters are rejected")
    }
    XCTAssertEqual(s.fonts["terminal"], "Menlo")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID()).json")
    try s.save(to: url); defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertEqual(WorkbenchState.restore(from: url)?.fonts, ["editor": "", "terminal": "Menlo"])
  }
}
