import AppKit
import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class NativeEditorTests: XCTestCase {
  func testEditorSavesOnlyAfterExplicitSaveAndUndoRestoresCleanState() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "notes.txt", content: "before\n")
    let document = try fixture.makeDocument(at: fileURL)

    document.replaceContent("after\n")

    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "before\n")

    document.undo()

    XCTAssertEqual(document.content, "before\n")
    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "before\n")

    document.replaceContent("after\n")
    try document.save()

    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "after\n")
    XCTAssertEqual(document.historyEntries.first?.content, "before\n")
    XCTAssertEqual(document.historyEntries.first?.reason, .save)
  }

  func testEditorPreservesUnicodeEmojiAndCombiningTextAsUTF8() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "unicode.txt", content: "")
    let document = try fixture.makeDocument(at: fileURL)
    let unicodeContent = "日本語🙂 🧑🏽‍💻 e\u{301} と é\n"

    document.replaceContent(unicodeContent)
    try document.save()

    XCTAssertEqual(try Data(contentsOf: fileURL), Data(unicodeContent.utf8))
    XCTAssertEqual(document.content, unicodeContent)
    XCTAssertFalse(document.isDirty)
  }

  func testMarkedTextCommitUpdatesTheDocumentOnce() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "ime.txt", content: "")
    let document = try fixture.makeDocument(at: fileURL)
    let coordinator = ProjectSourceEditorView.Coordinator(document: document)
    let textView = NSTextView(frame: .zero)
    coordinator.textView = textView
    textView.delegate = coordinator
    textView.string = ""

    textView.setMarkedText(
      "日本",
      selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: 0, length: 0)
    )
    XCTAssertTrue(textView.hasMarkedText())

    textView.insertText("日本語", replacementRange: textView.markedRange())
    coordinator.textViewDidChange(Notification(name: NSText.didChangeNotification))

    XCTAssertFalse(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "日本語")
    XCTAssertEqual(document.content, "日本語")
  }

  func testSearchSelectionConvertsLineAndCharacterColumnToUTF16Range() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "selection.txt", content: "one\n日本Hello\nlast\n")
    let document = try fixture.makeDocument(at: fileURL)

    let range = document.selectionRange(
      for: ProjectEditorSelection(line: 2, column: 3, length: 5)
    )

    XCTAssertEqual(range, NSRange(location: 6, length: 5))
  }

  func testExternalRewriteWinsAndCapturesUnsavedBufferForRecovery() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "agent.txt", content: "disk-v1\n")
    let document = try fixture.makeDocument(at: fileURL)
    document.replaceContent("unsaved-v2 日本語\n")

    try Data("disk-v3 from agent\n".utf8).write(to: fileURL)
    XCTAssertTrue(try document.refreshFromDisk())

    XCTAssertEqual(document.content, "disk-v3 from agent\n")
    XCTAssertFalse(document.isDirty)
    let recovery = try XCTUnwrap(
      document.historyEntries.first { $0.reason == .externalChange }
    )
    XCTAssertEqual(recovery.content, "unsaved-v2 日本語\n")
    XCTAssertEqual(try String(contentsOf: fileURL), "disk-v3 from agent\n")

    try document.restoreHistoryEntry(id: recovery.id)
    XCTAssertEqual(document.content, "unsaved-v2 日本語\n")
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "disk-v3 from agent\n")
  }

  func testSaveRefusesToOverwriteAnExternalChange() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "conflict.txt", content: "disk-v1\n")
    let document = try fixture.makeDocument(at: fileURL)
    document.replaceContent("unsaved-v2\n")

    try Data("disk-v3 from agent\n".utf8).write(to: fileURL)

    XCTAssertThrowsError(try document.save()) { error in
      XCTAssertEqual(
        error as? ProjectEditorError,
        .externalChangeDetected(path: fileURL.standardizedFileURL.path)
      )
    }
    XCTAssertEqual(try String(contentsOf: fileURL), "disk-v3 from agent\n")
    XCTAssertEqual(document.content, "disk-v3 from agent\n")
    XCTAssertFalse(document.isDirty)
    XCTAssertTrue(
      document.historyEntries.contains {
        $0.reason == .externalChange && $0.content == "unsaved-v2\n"
      }
    )
  }

  func testExternalDeletionRetainsTheTabForRecovery() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "deleted.txt", content: "keep me\n")
    let document = try fixture.makeDocument(at: fileURL)

    try FileManager.default.removeItem(at: fileURL)
    XCTAssertTrue(try document.refreshFromDisk())

    XCTAssertTrue(document.isMissing)
    XCTAssertTrue(document.isDirty)
    let recovery = try XCTUnwrap(
      document.historyEntries.first { $0.reason == .externalDeletion }
    )
    XCTAssertEqual(recovery.content, "keep me\n")
  }

  func testSurfaceKeepsMultipleEditorTabsIndependent() throws {
    let fixture = try EditorFixture()
    let firstURL = try fixture.makeFile(named: "first.txt", content: "one\n")
    let secondURL = try fixture.makeFile(named: "second.txt", content: "two\n")
    let surface = ProjectSurfaceModel(
      projectID: fixture.projectID,
      rootURL: fixture.root,
      historyStore: fixture.historyStore
    )

    surface.select(nodeID: firstURL.standardizedFileURL.path)
    let first = try XCTUnwrap(surface.activeTab)
    surface.select(nodeID: secondURL.standardizedFileURL.path)
    let second = try XCTUnwrap(surface.activeTab)
    first.replaceContent("edited one\n")

    XCTAssertEqual(surface.editorTabs.map(\.id), [first.id, second.id])
    XCTAssertEqual(first.content, "edited one\n")
    XCTAssertEqual(second.content, "two\n")
    XCTAssertTrue(first.isDirty)
    XCTAssertFalse(second.isDirty)
  }

  func testWatcherReloadsAnExternalRewrite() async throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "watched.txt", content: "before\n")
    let surface = ProjectSurfaceModel(
      projectID: fixture.projectID,
      rootURL: fixture.root,
      historyStore: fixture.historyStore
    )
    surface.select(nodeID: fileURL.standardizedFileURL.path)
    let document = try XCTUnwrap(surface.activeTab)
    document.replaceContent("unsaved\n")

    try Data("external\n".utf8).write(to: fileURL)

    await waitForDocument(document) { document in
      document.content == "external\n" && !document.isDirty
    }
    XCTAssertTrue(
      document.historyEntries.contains {
        $0.reason == .externalChange && $0.content == "unsaved\n"
      }
    )
  }

  func testNonUTF8FileIsRejectedWithoutReplacementCharacters() throws {
    let fixture = try EditorFixture()
    let fileURL = fixture.root.appendingPathComponent("binary.bin")
    try Data([0xFF, 0xFE, 0x00]).write(to: fileURL)
    let surface = ProjectSurfaceModel(
      projectID: fixture.projectID,
      rootURL: fixture.root,
      historyStore: fixture.historyStore
    )

    surface.select(nodeID: fileURL.standardizedFileURL.path)

    XCTAssertNil(surface.activeTab)
    XCTAssertNotNil(surface.lastEditorErrorMessage)
  }

  private func waitForDocument(
    _ document: ProjectEditorTab,
    timeout: TimeInterval = 3,
    matching predicate: (ProjectEditorTab) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate(document) {
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for editor refresh", file: file, line: line)
  }
}

@MainActor
private final class EditorFixture {
  let projectID = UUID()
  let root: URL
  let historyStore: ProjectLocalHistoryStore

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-native-editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    historyStore = ProjectLocalHistoryStore(
      fileURL: root.appendingPathComponent("editor-history-v1.json")
    )
  }

  func makeFile(named name: String, content: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data(content.utf8).write(to: url)
    return url
  }

  func makeDocument(at url: URL) throws -> ProjectEditorTab {
    try ProjectEditorTab(
      projectID: projectID,
      rootURL: root,
      url: url,
      historyStore: historyStore
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
}
